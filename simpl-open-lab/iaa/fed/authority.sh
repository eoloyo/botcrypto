#!/usr/bin/env bash
# authority.sh <A|B> — one Simpl governance authority from the federation-era IAA services
# (identity-provider-be, security-attributes-provider-be, authentication-provider-be), with its own
# CA (ejbca-shim), databases and Redis database, then its bootstrap: the same calls as the
# authority-iaa chart's init-authority Job (keypair → dataspace → CSR → participant → CSR upload →
# credential → install).
#
#   A  "EOSC research data space"   idp :8203  sap :8202  authp :8205  CA :32080/:32443
#   B  "DestinE data space"         idp :8303  sap :8302  authp :8305  CA :33080/:33443
#
# Each authority's Tier-2 gateway URL (the issuer of its ephemeral proofs, and the key another
# authority trusts it by) is https://localhost:8<n>43; no gateway listens there in this lab.
set -euo pipefail
source "$(dirname "$0")/../../scripts/env.sh"
X=${1:?A or B}
case $X in
  A) N=2; NAME="EOSC research data space"; ORG="EOSC Association (lab)"; RDB=1 ;;
  B) N=3; NAME="DestinE data space";       ORG="DestinE Governance (lab)"; RDB=2 ;;
  *) echo "A or B"; exit 1 ;;
esac
FED="$LAB_ROOT/fed/$X"; SRC="$LAB_ROOT/src-fed"; mkdir -p "$FED"
IDP=8${N}03 SAP=8${N}02 AUTHP=8${N}05 CAH=3${N}080 CAS=3${N}443 T2="https://localhost:8${N}43"
db=$(echo "fed${X}" | tr A-Z a-z)
LOG="$FED/services.log"
bg(){ setsid env -u JAVA_TOOL_OPTIONS -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy "$@" </dev/null >>"$LOG" 2>&1 & disown 2>/dev/null || true; }
up(){ curl -sf --noproxy '*' -o /dev/null "$1"; }
waitup(){ for _ in $(seq 1 "${2:-90}"); do up "$1" && return 0; sleep 2; done; return 1; }
jar(){ ls "$SRC/$1"/target/*-1.0.0-local.jar | head -1; }
call(){ # call METHOD URL [json] — prints the body, fails on non-2xx
  local out code; out=$(mktemp)
  code=$(curl -s --noproxy '*' -o "$out" -w '%{http_code}' -X "$1" "$2" -H 'Content-Type: application/json' ${3:+--data-raw "$3"})
  cat "$out"; rm -f "$out"
  [[ $code == 2* ]] || { echo " ← HTTP $code from $1 $2" >&2; return 1; }
}

# ── infrastructure ─────────────────────────────────────────────────────────────────────
PGDATA=/var/lib/postgresql/lab-pgdata
if ! PGPASSWORD=postgres psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -c 'select 1' >/dev/null 2>&1; then
  [ -d "$PGDATA" ] || { mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"; runuser -u postgres -- initdb -D "$PGDATA" -A trust >/dev/null; }
  runuser -u postgres -- pg_ctl -D "$PGDATA" -o "-p $PG_PORT -c listen_addresses=127.0.0.1 -c max_connections=300" -l "$PGDATA/server.log" start >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "ALTER USER postgres PASSWORD 'postgres';" >/dev/null 2>&1 || true
fi
redis-cli -p 30379 -a admin ping 2>/dev/null | grep -q PONG || \
  { setsid redis-server --port 30379 --requirepass admin >"$LAB_ROOT/fed/redis.log" 2>&1 & sleep 2; }
for s in idp sap authp; do
  runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE ${db}_$s;" >/dev/null 2>&1 || true
done
OCSP=3${N}081
up "http://localhost:$CAH/status" || SHIM_DIR="$FED" SHIM_HTTP_PORT=$CAH SHIM_HTTPS_PORT=$CAS SHIM_CA_ORG="$ORG" \
  SHIM_OCSP_URL="http://localhost:$OCSP/ocsp" bg "$REPO_LAB_DIR/ejbca-shim/ejbca-shim"
waitup "http://localhost:$CAH/status" 15
up "http://localhost:$OCSP/" || OCSP_CA_DIR="$FED" OCSP_PORT=$OCSP bg python3 "$REPO_LAB_DIR/iaa/ocsp-responder.py"
waitup "http://localhost:$OCSP/" 15
# the identity provider calls the CA over TLS: trust this authority's CA
[ -f "$FED/truststore.jks" ] || keytool -importcert -noprompt -alias ca -file "$FED/shim-ca.pem" \
  -keystore "$FED/truststore.jks" -storepass changeit >/dev/null
up http://localhost:9099/certs || bg python3 "$REPO_LAB_DIR/iaa/jwks-tier1.py"
# the authentication provider fails a credential install when it cannot publish the event
(exec 3<>/dev/tcp/127.0.0.1/9092) 2>/dev/null || SIMPL_BROKER=kafka bash "$REPO_LAB_DIR/iaa/broker.sh" >/dev/null

PG=(--spring.datasource.username=postgres --spring.datasource.password=postgres)
RD=(--spring.data.redis.host=localhost --spring.data.redis.port=30379 --spring.data.redis.username=default
    --spring.data.redis.password=admin --spring.data.redis.database=$RDB)
J=(java -Xmx384m -jar)

# ── services ───────────────────────────────────────────────────────────────────────────
up "http://localhost:$IDP/actuator/health" || bg "${J[@]}" "$(jar idp-be)" --spring.profiles.active=local \
  --server.port=$IDP --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/${db}_idp "${PG[@]}" "${RD[@]}" \
  --spring.ssl.bundle.jks.ejbca.truststore.location=file:$FED/truststore.jks --ejbca.url=https://localhost:$CAS \
  --microservice.security-attributes-provider.url=http://localhost:$SAP \
  --microservice.authentication-provider.url=http://localhost:$AUTHP \
  --management.otlp.tracing.endpoint= --management.tracing.sampling.probability=0
up "http://localhost:$SAP/actuator/health" || bg "${J[@]}" "$(jar sap-be)" --spring.profiles.active=local \
  --server.port=$SAP --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/${db}_sap "${PG[@]}" "${RD[@]}" \
  --microservice.identity-provider.url=http://localhost:$IDP --microservice.authentication-provider.url=http://localhost:$AUTHP \
  --simpl.ephemeral-proof.issuer-url=$T2 --simpl.ephemeral-proof.expire-after=10m \
  --management.otlp.tracing.endpoint= --management.tracing.sampling.probability=0
up "http://localhost:$AUTHP/actuator/health" || bg "${J[@]}" "$(jar authp-be)" --spring.profiles.active=local,local-authority \
  --server.port=$AUTHP --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/${db}_authp "${PG[@]}" "${RD[@]}" \
  --microservice.identity-provider.url=http://localhost:$IDP --microservice.security-attributes-provider.url=http://localhost:$SAP \
  --client.authority.url=$T2 --simpl.gateway.tier-two-url=$T2 --simpl.gateway.tier-one-url=http://localhost:8${N}00 \
  --open-id-connect.certs-endpoint=http://localhost:9099/certs --dataspace.name="$NAME" \
  --spring.kafka.producer.properties.max.block.ms=1500 \
  --management.otlp.tracing.endpoint= --management.tracing.sampling.probability=0
for p in $IDP $SAP $AUTHP; do
  waitup "http://localhost:$p/actuator/health" 120 || { log "authority $X: :$p not healthy — see $LOG"; exit 1; }
done
T1=8${N}00   # this authority's public Tier-1 address (the authorityUri other authorities discover)
(exec 3<>/dev/tcp/127.0.0.1/$T1) 2>/dev/null || bg python3 -I "$REPO_LAB_DIR/iaa/fed/tier1_router.py" $T1 $AUTHP $SAP $IDP
log "authority $X ($NAME) services up: idp :$IDP  sap :$SAP  authp :$AUTHP  CA :$CAS  tier-1 :$T1"

# ── bootstrap (init-authority Job sequence), once ──────────────────────────────────────
if [ -s "$FED/credential.json" ]; then log "authority $X already initialised"; exit 0; fi
A="http://localhost:$AUTHP/tier1/v2"; I="http://localhost:$IDP/tier1/v2"
KP=$(call POST "$A/keypairs" '{"name":"initialization-authority"}' | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["id"])')
call PUT "$A/identity/dataspace" "{\"name\":\"$NAME\",\"contactEmail\":\"authority-$X@lab.example.eu\"}" >/dev/null
call POST "$A/keypairs/$KP/csr" "{\"commonName\":\"authority-$X\",\"country\":\"EU\",\"organization\":\"$ORG\",\"organizationalUnit\":\"governance\"}" >"$FED/csr.json"
PID=$(call POST "$I/participants" "{\"organization\":\"$ORG\",\"contactEmail\":\"authority-$X@lab.example.eu\",\"isAuthority\":true,\"publicGatewayUrl\":\"$T2\"}" \
  | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["id"])')
call PUT "$I/participants/$PID/csr" "$(cat "$FED/csr.json")" >/dev/null
call POST "$I/participants/$PID/credentials" '{"reason":"initialization-authority"}' >"$FED/cert.json"
call POST "$A/credentials" "$(python3 -I -c 'import json,sys;print(json.dumps({"reason":"initialization-authority","content":json.load(open(sys.argv[1]))["content"]}))' "$FED/cert.json")" >/dev/null
echo "$PID" >"$FED/participant-id"
cp "$FED/cert.json" "$FED/credential.json"
log "authority $X initialised: participant $PID, credential installed"
