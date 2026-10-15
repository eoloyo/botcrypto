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
# Services started by 06/07/08+ without a pid file. A JVM left running while
# 01-setup rebuilds its jar fails every request with NoClassDefFoundError.
pkill -f "fc-service-server.jar" 2>/dev/null || true
pkill -f "$LAB_ROOT/src/.*\.jar" 2>/dev/null || true
pkill -f "python3 $REPO_LAB_DIR/" 2>/dev/null || true
pkill -f "/var/lib/postgresql/neo4j" 2>/dev/null || true
redis-cli -p 30379 -a admin shutdown nosave >/dev/null 2>&1 || true
log "stopped."
