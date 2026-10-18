#!/usr/bin/env bash
# cpu-profile.sh — where the CPU goes while the agent starts (cpu-report.py reads the output).
#
#   cpu-profile.sh sample <out.tsv>    every 10 s until killed: CPU-ns of every pod's cgroup, of the
#                                      kubepods slice and of the whole k3s container (= pods + k3s,
#                                      containerd, runsc shims). Pod cgroups include init containers
#                                      and gVisor's own work (Sentry, gofer).
#   cpu-profile.sh threads <out.tsv>   once: the /proc stat line of every thread of every JVM in
#                                      authority01/common01, read inside the sandbox (JIT, GC, application).
set -uo pipefail
C=k3s-gvisor
mode=${1:?sample|threads}; out=${2:?output file}

case $mode in
sample)
  echo -e "t\tkind\tns\tpod\tcpu_ns" > "$out"
  while true; do
    docker exec $C sh -c '
      t=$(date +%s); cg=/sys/fs/cgroup/cpuacct
      echo "$t	total	-	k3s-container	$(cat $cg/cpuacct.usage)"
      echo "$t	total	-	kubepods	$(cat $cg/kubepods/cpuacct.usage)"
      kubectl get pods -A -o jsonpath="{range .items[*]}{.metadata.uid} {.metadata.namespace} {.metadata.name}{\"\n\"}{end}" 2>/dev/null |
      while read -r uid ns name; do
        for d in $cg/kubepods/pod$uid $cg/kubepods/burstable/pod$uid $cg/kubepods/besteffort/pod$uid; do
          [ -f $d/cpuacct.usage ] && { echo "$t	pod	$ns	$name	$(cat $d/cpuacct.usage)"; break; }
        done
      done' >> "$out" 2>/dev/null
    sleep 10
  done ;;
threads)
  # raw /proc/<pid>/task/<tid>/stat lines, parsed by cpu-report.py (some images have no awk)
  echo -e "ns\tpod\tpid\tstat" > "$out"
  for ns in authority01 common01; do
    for pod in $(docker exec $C kubectl -n $ns get pods --field-selector=status.phase=Running -o name | cut -d/ -f2); do
      docker exec $C kubectl -n $ns exec "$pod" -- sh -c '
        for p in /proc/[0-9]*; do
          [ "$(cat $p/comm 2>/dev/null)" = java ] || continue
          echo "${p#/proc/}	PROCESS $(cat $p/stat)"
          for t in $p/task/*; do echo "${p#/proc/}	$(cat $t/stat)"; done
        done' 2>/dev/null | sed "s/^/$ns\t$pod\t/" >> "$out"
    done
  done ;;
esac
