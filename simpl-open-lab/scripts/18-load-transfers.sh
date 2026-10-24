#!/usr/bin/env bash
# MANY SIMULTANEOUS CONSUMERS AGAINST ONE PROVIDER CONNECTOR.
#
#   ./18-load-transfers.sh [N=50] [payload sizes in bytes, default "1000000 20000000"]
#
# Brings up the provider and consumer connectors (connector-be, embedded data plane, one instance
# each, as the chart's default replicaCount: 1), a local data source and sink, then for each payload
# size runs N concurrent contract negotiations followed by N concurrent transfers (one agreement each,
# like N users of the consumer organisation). See load/transfer_load.py for what is measured.
set -euo pipefail
source "$(dirname "$0")/env.sh"
N=${1:-50}; SIZES=${2:-"1000000 20000000"}
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"; LOG="$RUN/18.log"
CONN="$LAB_ROOT/src/connector-be"; JAR="$CONN/target/basic-connector.jar"; L="$REPO_LAB_DIR/load"
bg(){ setsid env -u JAVA_TOOL_OPTIONS -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
        -u NO_PROXY -u no_proxy "$@" </dev/null >>"$LOG" 2>&1 & disown 2>/dev/null || true; }
waitport(){ for _ in $(seq 1 "${2:-60}"); do (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null && { exec 3>&-; return 0; }; sleep 2; done; return 1; }
[ -f "$JAR" ] || { log "connector jar missing — run 01-setup.sh first"; exit 1; }

PGDATA=/var/lib/postgresql/lab-pgdata
if ! PGPASSWORD=postgres psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -c 'select 1' >/dev/null 2>&1; then
  [ -d "$PGDATA" ] || { mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"; runuser -u postgres -- initdb -D "$PGDATA" -A trust >/dev/null; }
  runuser -u postgres -- pg_ctl -D "$PGDATA" -o "-p $PG_PORT -c listen_addresses=127.0.0.1 -c max_connections=300" -l "$PGDATA/server.log" start >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "ALTER USER postgres PASSWORD 'postgres';" >/dev/null 2>&1 || true
fi
runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE providerdb;" >/dev/null 2>&1 || true
sed -i 's#jdbc:postgresql://localhost:5432/postgres#jdbc:postgresql://localhost:'"$PG_PORT"'/providerdb#g' "$CONN/local/provider-config.properties"

waitport 8902 1 || bg python3 -I "$L/source_sink.py"
if ! waitport "$PROVIDER_MGMT" 1; then
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres EDC_DATASOURCE_POLICY_PASSWORD=postgres \
    bg java -Dedc.fs.config="$CONN/local/provider-config.properties" -jar "$JAR"
fi
if ! waitport "$CONSUMER_MGMT" 1; then
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres bg java -Dedc.fs.config="$CONN/local/consumer-config.properties" -jar "$JAR"
fi
waitport "$PROVIDER_MGMT" 90 && waitport "$CONSUMER_MGMT" 90 && waitport 8902 10 || { log "start-up failed — see $LOG"; exit 1; }
sleep 5
PPID_=$(pgrep -f '[p]rovider-config.properties' | head -1)
log "provider connector pid $PPID_; machine: $(nproc) cores, $(free -g | awk '/Mem:/{print $2}') GB"
for size in $SIZES; do
  log "── $N concurrent consumers, $((size / 1000000)) MB payload ──"
  python3 -I "$L/transfer_load.py" "$N" "$size" "$PPID_"
done
