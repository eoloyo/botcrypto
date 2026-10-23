#!/usr/bin/env bash
# EOSC RESEARCHER → DESTINE DATA THROUGH SIMPL (pilot step 1: open data, end to end).
#
#   DestinE side   destine_bridge.py reads the DestinE Data Lake's public STAC catalogue and puts
#                  three collections on the provider connector as Simpl offers, with policies that
#                  mirror DestinE's access tiers; dedl_access.py is the provider's access layer
#   EOSC side      the researcher logs in at the consumer agent's Keycloak, which brokers to an
#                  "eosc-aai" realm (stand-in for the EOSC federated AAI); notebook.py runs in the
#                  "EU Node": checks the user, discovers, negotiates, receives, analyses
#
# Cases:
#   A  researcher (climate group), open DestinE data → contract, data in EU Node storage, analysis
#   B  student, same university, no entitlement      → stopped by the consumer agent
#   C  Climate DT, organisation without upgraded access → contract refused by DestinE's policy
#   D  Climate DT, organisation granted upgraded access → contract agreed; data needs DestinE
#      credentials (DESTINE_TOKEN), so without them the transfer fails at the access layer
#
# Stand-ins (lab only): the eosc-aai realm for the EOSC AAI; Eurostat's public API for DestinE's
# hosted copy of the same Eurostat datasets (HDA item access needs a DestinE account; set
# DESTINE_TOKEN to use HDA); mocked organisation attributes on the consumer connector, as in 09.
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
CONN="$LAB_ROOT/src/connector-be"; JAR="$CONN/target/basic-connector.jar"
D="$REPO_LAB_DIR/destine"; OUT="$RUN/destine"; STORE="$RUN/eu-node-storage"; mkdir -p "$OUT" "$STORE"
LOG="$RUN/16.log"; PY="python3 -I"
export STORAGE_DIR="$STORE" KC_URL="http://127.0.0.1:$KEYCLOAK_PORT"
bg(){ setsid env -u JAVA_TOOL_OPTIONS -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
        -u NO_PROXY -u no_proxy -u ALL_PROXY -u all_proxy "$@" </dev/null >>"$LOG" 2>&1 & disown 2>/dev/null || true; }
waitport(){ for _ in $(seq 1 "${2:-60}"); do (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null && { exec 3>&-; return 0; }; sleep 2; done; return 1; }
[ -f "$JAR" ] || { log "connector jar missing — run 01-setup.sh (or 02) first"; exit 1; }

# ── 0. Postgres, Keycloak, provider connector ─────────────────────────────────────────
PGDATA=/var/lib/postgresql/lab-pgdata
if ! PGPASSWORD=postgres psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -c 'select 1' >/dev/null 2>&1; then
  [ -d "$PGDATA" ] || { mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"; runuser -u postgres -- initdb -D "$PGDATA" -A trust >/dev/null; }
  runuser -u postgres -- pg_ctl -D "$PGDATA" -o "-p $PG_PORT -c listen_addresses=127.0.0.1" -l "$PGDATA/server.log" start >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "ALTER USER postgres PASSWORD 'postgres';" >/dev/null 2>&1 || true
fi
runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE providerdb;" >/dev/null 2>&1 || true
log "Postgres up on :$PG_PORT"
if ! waitport "$KEYCLOAK_PORT" 1; then
  KC_BOOTSTRAP_ADMIN_USERNAME=admin KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
    bg "$LAB_ROOT/keycloak/bin/kc.sh" start-dev --http-port="$KEYCLOAK_PORT" --http-host=127.0.0.1
fi
sed -i 's#jdbc:postgresql://localhost:5432/postgres#jdbc:postgresql://localhost:'"$PG_PORT"'/providerdb#g' "$CONN/local/provider-config.properties"
if ! waitport "$PROVIDER_MGMT" 1; then
  log "starting the DestinE provider connector"
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres EDC_DATASOURCE_POLICY_PASSWORD=postgres \
    bg java -Dedc.fs.config="$CONN/local/provider-config.properties" -jar "$JAR"
fi
waitport "$PROVIDER_MGMT" 90 || { log "provider connector did not start (see $LOG)"; exit 1; }

# ── 1. DestinE side: bridge the catalogue, start the access layer ─────────────────────
log "1) DestinE bridge: STAC catalogue → Simpl offers"
$PY "$D/destine_bridge.py" plan "$OUT"
sleep 3
$PY "$D/destine_bridge.py" register "$OUT" "http://localhost:$PROVIDER_MGMT/management/v3"
pkill -f '[d]edl_access.py' 2>/dev/null || true
pkill -f '[e]u_node_storage.py' 2>/dev/null || true
# the access layer keeps the sandbox's internet proxy (it fetches from DestinE / Eurostat)
setsid $PY "$D/dedl_access.py" "$OUT/offers.json" 8790 </dev/null >>"$RUN/dedl-access.log" 2>&1 &
bg $PY "$D/eu_node_storage.py" "$STORE" 8798
waitport 8790 10 && waitport 8798 10 || { log "access layer or storage did not start"; exit 1; }

# ── 2. EOSC side: login through the consumer agent's broker ──────────────────────────
waitport "$KEYCLOAK_PORT" 90 || { log "Keycloak did not start"; exit 1; }
for _ in $(seq 1 30); do curl -sf --noproxy '*' -o /dev/null "$KC_URL/realms/master" && break; sleep 2; done
log "2) EOSC AAI stand-in brokered into the consumer agent's Keycloak"
$PY "$D/eosc_aai.py" setup "$KC_URL"
$PY "$D/eosc_aai.py" login "$KC_URL" "$RUN/researcher.token" a.researcher
$PY "$D/eosc_aai.py" login "$KC_URL" "$RUN/student.token" b.student

# ── consumer connector with the EOSC organisation's attributes ───────────────────────
consumer_as(){ # consumer_as CODE...  (re)start the consumer connector holding these attributes
  local cfg="$RUN/consumer-eosc.properties" mock
  mock="$($PY - "$@" <<'PY'
import sys,json,base64,uuid
items=[{"id":str(uuid.uuid4()),"code":c,"name":c.title(),"description":c,"assignableToRoles":True,"enabled":True,
        "assignedToParticipant":True,"creationTimestamp":"2026-10-23T00:00:00Z","updateTimestamp":"2026-10-23T00:00:00Z"}
       for c in sys.argv[1:]]
print(base64.b64encode(json.dumps({"self":"/x","pageSize":100,"page":0,"total":len(items),"items":items}).encode()).decode())
PY
)"
  cp "$CONN/local/consumer-config.properties" "$cfg"
  sed -i "s#^mocked.agent.identity.attributes=.*#mocked.agent.identity.attributes=$mock#" "$cfg"
  pkill -f 'consumer-[A-Za-z_]*\.properties' 2>/dev/null || true
  ps -eo pid,args | grep 'consumer-config.properties' | grep -v grep | awk '{print $1}' | xargs -r kill 2>/dev/null || true
  for _ in $(seq 1 15); do waitport "$CONSUMER_MGMT" 1 || break; sleep 1; done
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres bg java -Dedc.fs.config="$cfg" -jar "$JAR"
  waitport "$CONSUMER_MGMT" 90 || { log "consumer connector did not start (see $LOG)"; exit 1; }
  sleep 3
  log "   consumer organisation holds: $*"
}
nb(){ $PY "$D/notebook.py" "$@"; }
expect(){ # expect <exit-code> <label> -- command...
  local want=$1 label=$2; shift 3; local rc=0; "$@" || rc=$?
  if [ "$rc" = "$want" ]; then log "   ✔ $label"; else log "   ✘ $label (exit $rc, expected $want)"; FAIL=1; fi
}
FAIL=0

log "3) the university's consumer agent (attributes CONSUMER, RESEARCH_ORG)"
consumer_as CONSUMER RESEARCH_ORG
log "── A: researcher, open DestinE data ──"
expect 0 "A1 population density delivered and analysed" -- nb "$RUN/researcher.token" STAT.EUSTAT.DAT.POP_DENSITY_NUTS3
expect 0 "A2 renewable-energy share delivered and analysed" -- nb "$RUN/researcher.token" STAT.EUSTAT.DAT.SHARE_ENERGY_FROM_RENEWABLE
log "── B: student without the entitlement ──"
expect 3 "B stopped by the consumer agent before any contract" -- nb "$RUN/student.token" STAT.EUSTAT.DAT.POP_DENSITY_NUTS3
log "── C: Climate DT without upgraded access ──"
expect 4 "C contract refused by DestinE's policy" -- nb "$RUN/researcher.token" EO.ECMWF.DAT.DT_CLIMATE_ADAPTATION

log "── D: the university is granted DestinE upgraded access ──"
consumer_as CONSUMER RESEARCH_ORG DESTINE_UPGRADED_ACCESS
if [ -n "${DESTINE_TOKEN:-}" ]; then
  expect 0 "D Climate DT data delivered from HDA" -- nb "$RUN/researcher.token" EO.ECMWF.DAT.DT_CLIMATE_ADAPTATION
else
  expect 5 "D contract agreed, data blocked: no DestinE credentials in the lab" -- nb "$RUN/researcher.token" EO.ECMWF.DAT.DT_CLIMATE_ADAPTATION
fi

[ "$FAIL" = 0 ] && log "EOSC → DESTINE VIA SIMPL: all cases behaved as expected" \
               || { log "some cases failed — see $LOG and $RUN/dedl-access.log"; exit 1; }
