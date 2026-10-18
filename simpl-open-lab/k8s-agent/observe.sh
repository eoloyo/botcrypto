#!/usr/bin/env bash
# observe.sh <t0 epoch seconds> — the deploy timeline: seconds from the apply at t0 until each pod in
# authority01 is Ready, written to $WORK/timeline.tsv. deploy.sh runs it after applying; run it by
# itself to resume a timeline whose observer died, with the original apply time.
set -uo pipefail
t0=${1:?t0}
WORK="${WORK:-/root/simpl-agent-build/deploy}"
C=k3s-gvisor
K() { docker exec -i $C kubectl "$@"; }
log() { echo "[$(date +%T)] $*"; }
# The API server is often too busy to answer while everything starts: a failed `get pods` skips a
# pass rather than ending the run (or counting as "nothing left to wait for").
: > "$WORK/timeline.tsv"
declare -A seen
deadline=$(( t0 + ${TIMEOUT:-2400} ))
while [ "$(date +%s)" -lt $deadline ]; do
  if ! pods=$(K -n authority01 get pods --no-headers 2>/dev/null) || [ -z "$pods" ]; then
    [ "$(docker inspect -f '{{.State.Running}}' $C)" = true ] || log "the cluster container is not running"
    sleep 5; continue
  fi
  while read -r name ready status restarts; do
    [ -n "${seen[$name]:-}" ] && continue
    if [ "${ready%/*}" = "${ready#*/}" ] && [ "$status" = Running ]; then
      seen[$name]=1; printf '%s\t%d\t%s\n' "$name" $(( $(date +%s) - t0 )) "$restarts" | tee -a "$WORK/timeline.tsv"
    fi
  done < <(awk '$3!="Completed"{print $1, $2, $3, $4}' <<<"$pods")
  notready=$(awk '$3!="Completed"{split($2,a,"/"); if(a[1]!=a[2]||$3!="Running") n++} END{print n+0}' <<<"$pods")
  [ "$notready" = 0 ] && [ ${#seen[@]} -gt 0 ] && break
  sleep 5
done
started=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' $C)" +%s)
[ "$started" -gt "$t0" ] && log "WARNING: the cluster container restarted during this run ($(date -d @$started +%T)): the timeline is not valid"
log "done after $(( $(date +%s) - t0 ))s; not ready:"
K -n authority01 get pods --no-headers | awk '{split($2,a,"/"); if(a[1]!=a[2]&&$3!="Completed") print}' || true
