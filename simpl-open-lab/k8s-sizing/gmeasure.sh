#!/usr/bin/env bash
# gmeasure.sh <label> <readiness-url> <wait-after-ready-s> -- <docker run args...>
# Generic: start a container (name gm), wait until <readiness-url> answers 2xx/3xx, idle N seconds,
# then report wall time to ready, CPU-seconds and memory working set (cgroup v1, minus inactive file cache).
LABEL=$1; URL=$2; IDLE=$3; shift 4
docker rm -f gm >/dev/null 2>&1
t0=$(date +%s.%N); docker run -d --name gm "$@" >/dev/null || { echo "[$LABEL] docker run failed"; exit 1; }
ready=""
for _ in $(seq 1 2400); do
  c=$(curl -s -m2 -o /dev/null -w '%{http_code}' "$URL"); case "$c" in 2??|3??) ready=$(date +%s.%N); break;; esac
  [ "$(docker inspect -f '{{.State.Running}}' gm 2>/dev/null)" = true ] || { echo "[$LABEL] exited"; docker logs gm 2>&1 | tail -3 | cut -c1-200; exit 1; }
  sleep 0.25
done
sleep "$IDLE"
id=$(docker inspect -f '{{.Id}}' gm)
cpu=$(cat /sys/fs/cgroup/cpuacct/docker/$id/cpuacct.usage 2>/dev/null || cat /sys/fs/cgroup/cpu,cpuacct/docker/$id/cpuacct.usage)
mg=/sys/fs/cgroup/memory/docker/$id
use=$(cat $mg/memory.usage_in_bytes); inact=$(awk '/^total_inactive_file /{print $2}' $mg/memory.stat)
python3 -c "print(f'[$LABEL] ready {$ready-$t0:.1f}s | CPU {$cpu/1e9:.1f}s | working set {($use-$inact)//2**20} MB (after ${IDLE}s idle)')"
docker rm -f gm >/dev/null 2>&1
