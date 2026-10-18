#!/usr/bin/env bash
# measure.sh <manifest.yaml> <deployment-name> <label> : deploy, then time container start, app start
# (Spring "Started ... process running for"), pod Ready (probe-gated); then CPU-seconds + memory of the
# gVisor sandbox (from the host: the runsc sandbox process holding the pod).
M=$1; DEP=$2; LABEL=$3; NS=authority01; K="docker exec -i k3s-gvisor kubectl -n $NS"
$K delete deploy "$DEP" --ignore-not-found --wait=true >/dev/null 2>&1
for _ in $(seq 1 60); do [ -z "$($K get pods -l app.kubernetes.io/name=$DEP --no-headers 2>/dev/null)" ] && break; sleep 2; done
t0=$(date +%s.%N); $K apply -f - < "$M" >/dev/null
pod=""; for _ in $(seq 1 60); do pod=$($K get pods --no-headers -o custom-columns=:metadata.name 2>/dev/null | grep "^$DEP-" | head -1); [ -n "$pod" ] && break; sleep 1; done
started=""; spring=""; ready=""
for _ in $(seq 1 1200); do
  now=$(date +%s.%N)
  [ -z "$started" ] && [ "$($K get pod $pod -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)" != "" ] && started=$now
  [ -n "$started" ] && [ -z "$spring" ] && $K logs $pod 2>/dev/null | grep -q "process running for" && spring=$now
  [ -z "$ready" ] && [ "$($K get pod $pod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && ready=$now
  [ -n "$ready" ] && [ -n "$spring" ] && break
  st=$($K get pod $pod -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null); [ "${st:-0}" -gt 0 ] && { echo "[$LABEL] container restarted ($st) — see logs"; break; }
  sleep 0.5
done
d(){ [ -n "$1" ] && python3 -c "print(f'{$1-$t0:.1f}s')" || echo "-"; }
appline=$($K logs $pod 2>/dev/null | grep -o "Started [A-Za-z]* in [0-9.]* seconds (process running for [0-9.]*)" | tail -1)
# the sandbox of this pod: runsc processes whose cmdline carries the pod's sandbox id
sid=$(docker exec k3s-gvisor crictl pods --name "$pod" -q 2>/dev/null | head -1)
cpu=0; rss=0
for p in $(pgrep -f "runsc.*${sid:0:12}" 2>/dev/null); do
  f=($(cut -d' ' -f14,15 /proc/$p/stat 2>/dev/null)); cpu=$((cpu + ${f[0]:-0} + ${f[1]:-0}))
  r=$(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null); rss=$((rss + ${r:-0}))
done
wss=$(docker exec k3s-gvisor crictl stats --id "$(docker exec k3s-gvisor crictl ps --pod "$sid" -q 2>/dev/null | head -1)" -o json 2>/dev/null | python3 -c "import sys,json;s=json.load(sys.stdin)['stats'][0];print(int(s['memory']['workingSetBytes']['value'])//2**20)" 2>/dev/null)
echo "[$LABEL] container started $(d $started) | Spring ready $(d $spring) [$appline] | pod Ready $(d $ready) | sandbox CPU $(python3 -c "print(round($cpu/$(getconf CLK_TCK),1))")s, RSS $((rss/1024)) MB, container working set ${wss:-?} MB"
