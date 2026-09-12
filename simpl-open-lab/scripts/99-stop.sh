#!/usr/bin/env bash
# Stop everything the lab started.
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"
for pf in "$RUN"/*.pid; do
  [ -f "$pf" ] || continue
  pid=$(cat "$pf"); name=$(basename "$pf" .pid)
  if kill -0 "$pid" 2>/dev/null; then log "stopping $name ($pid)"; kill "$pid" 2>/dev/null || true; fi
  rm -f "$pf"
done
# stop postgres cluster
PGDATA=/var/lib/postgresql/lab-pgdata
[ -d "$PGDATA" ] && runuser -u postgres -- pg_ctl -D "$PGDATA" stop 2>/dev/null || true
# belt-and-suspenders: kill known jars/procs still around
pkill -f "basic-connector.jar" 2>/dev/null || true
pkill -f "identity-provider-.*\.jar" 2>/dev/null || true
pkill -f "ejbca-shim" 2>/dev/null || true
pkill -f "moto_server" 2>/dev/null || true
pkill -f "kc.sh" 2>/dev/null || true
log "stopped."
