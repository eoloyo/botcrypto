#!/usr/bin/env bash
# usage.sh [namespace...] — memory and CPU time actually used by each pod, next to what it requests.
# metrics-server is off and `crictl stats` times out under gVisor, so this reads the gVisor sandbox
# processes from the host, as ../k8s-sizing/measure.sh does: RSS and CPU-seconds of the runsc
# processes whose command line carries the pod's sandbox id. Prints TSV.
set -uo pipefail
NSS=("${@:-authority01}")
C=k3s-gvisor
K() { docker exec $C kubectl "$@"; }
tck=$(getconf CLK_TCK); page=$(getconf PAGESIZE)
printf 'namespace\tpod\trss_MiB\tcpu_s\treq_mem_MiB\tlim_mem_MiB\treq_cpu_m\n'
for ns in "${NSS[@]}"; do
  K -n "$ns" get pods -o json | python3 -c '
import json, sys
def mem(v):
    v = str(v); f = {"Ki": 1/1024, "Mi": 1, "Gi": 1024, "M": 1, "G": 1000}
    for k, m in f.items():
        if v.endswith(k): return float(v[:-len(k)]) * m
    return float(v) / 2**20 if v else 0
def cpu(v):
    v = str(v); return float(v[:-1]) if v.endswith("m") else float(v or 0) * 1000
for p in json.load(sys.stdin)["items"]:
    if p["status"].get("phase") != "Running": continue
    rq = rl = c = 0
    for ct in p["spec"]["containers"]:
        r = ct.get("resources") or {}
        rq += mem((r.get("requests") or {}).get("memory", 0)); rl += mem((r.get("limits") or {}).get("memory", 0))
        c += cpu((r.get("requests") or {}).get("cpu", 0))
    print(p["metadata"]["name"], int(rq), int(rl), int(c))' |
  while read -r pod rq rl rc; do
    sid=$(docker exec $C crictl pods --namespace "$ns" --name "^$pod\$" -q 2>/dev/null | head -1)
    rss=0; ticks=0
    for p in $(pgrep -f "runsc.*${sid:0:12}" 2>/dev/null); do
      read -r -a st < /proc/$p/stat 2>/dev/null || continue
      ticks=$(( ticks + st[13] + st[14] ))
      rss=$(( rss + $(awk '{print $2}' /proc/$p/statm 2>/dev/null || echo 0) ))
    done
    printf '%s\t%s\t%d\t%.1f\t%s\t%s\t%s\n' "$ns" "$pod" $(( rss * page / 1048576 )) \
      "$(echo "$ticks / $tck" | bc -l)" "$rq" "$rl" "$rc"
  done
done
