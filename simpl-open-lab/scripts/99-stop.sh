#!/usr/bin/env bash
# Stop everything the lab started.   Usage: ./99-stop.sh [--wipe]
#   --wipe  also delete all persistent state (Postgres cluster, Neo4j graph,
#           Redis) so the next 07 is a true COLD boot: fresh initdb, fresh
#           Liquibase migrations, fresh enrolment. Use it to clear accumulated
#           participants / stale ephemeral proofs that make republish flaky.
#           It does NOT touch the built jars or the Neo4j install (no rebuild,
#           no re-download).
WIPE=0; [ "${1:-}" = "--wipe" ] && WIPE=1
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
pkill -f "kafka.Kafka" 2>/dev/null || true          # SIMPL_BROKER=kafka
pkill -f "redpanda start" 2>/dev/null || true       # SIMPL_BROKER=redpanda

if [ "$WIPE" = 1 ]; then
  # give the postgres/neo4j processes a moment to release their data dirs
  for _ in 1 2 3 4 5 6 7 8; do pgrep -f "lab-pgdata|/var/lib/postgresql/neo4j|kafka.Kafka" >/dev/null 2>&1 || break; sleep 1; done
  pkill -9 -f "lab-pgdata" 2>/dev/null || true
  pkill -9 -f "kafka.Kafka" 2>/dev/null || true
  pkill -9 -f "/var/lib/postgresql/neo4j" 2>/dev/null || true
  sleep 1
  # Postgres: delete the whole cluster — 07 recreates it (initdb) + every DB/role.
  rm -rf "$PGDATA" && log "wiped Postgres cluster ($PGDATA)"
  # Neo4j: delete only the graph data, keep the install (bin/conf/plugins) so no re-download.
  rm -rf /var/lib/postgresql/neo4j/data && log "wiped Neo4j graph data"
  rm -rf "$LAB_ROOT/kafka-logs" && log "wiped Kafka log dir (broker.sh re-formats it)"
  rm -f "$RUN/07-publication.env"   # the SD it vouched for is gone with the catalogue DB
  # Redis has no persistence configured; stopping it above already cleared it. Remove any stray dump.
  rm -f "$LAB_ROOT"/dump.rdb /var/lib/postgresql/dump.rdb 2>/dev/null || true
  log "COLD state: next ./07-tier2-provider-publish.sh will initdb + migrate + re-enrol from scratch."
fi
log "stopped."
