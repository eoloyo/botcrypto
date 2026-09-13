#!/usr/bin/env bash
# Publish a Self-Description the INTENDED way — as a provider agent through the full
# Tier-2 machine-identity mTLS mesh (NOT the catalogue's internal ingest API):
#
#   sd-tooling-be  POST /v1/selfDescriptions/publications
#     -> FederatedCatalogueTier2Client (mTLS, provider Tier-2 credential + ephemeral proof)
#       -> tier2-gateway :8443  (EphemeralProof -> OCSP -> Headers -> ABAC filters, mTLS)
#         -> /fc route (StripPrefix) -> fc-service :8081  ->  SD stored, status "active"
#
# VERIFIED GREEN. See catalogue/PROVIDER-PUBLICATION.md for the architecture + findings.
#
# Prereqs: run 01-setup.sh (clones + builds), 06-federated-catalogue.sh concepts, and
# have the IAA repos cloned under $LAB_ROOT/src/iaa (authentication_provider,
# identity-provider, security-attributes-provider, tier2-gateway). This script applies
# two local patches, brings up the whole mesh, onboards+enrolls the authority and the
# provider, and publishes.
#
# Two local patches make the released code work locally (both committed under the repo):
#   - catalogue/patches/catalogue-local.patch      (fc-service: wire GraphRebuilder, etc.)
#   - iaa/patches/tier2-gateway-local-trust.patch  (gateway: implement the trusted-cert
#     TODO stub to load the lab CA — otherwise mTLS client validation rejects everyone)
# And the enhanced ejbca-shim (persistent CA + AIA + caIssuers + OCSP with critical nonce).
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
SRC="$LAB_ROOT/src"; IAA="$SRC"          # all repos clone flat under $LAB_ROOT/src/<name>
JH=/usr/lib/jvm/java-21-openjdk-amd64
GL="https://code.europa.eu/simpl/simpl-open"
bg(){ setsid env -u JAVA_TOOL_OPTIONS -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy "$@" </dev/null >>"$RUN/mesh.log" 2>&1 & disown 2>/dev/null || true; }
up(){ curl -sk -o /dev/null "$1" 2>/dev/null; }
waitup(){ local u="$1" n="${2:-60}"; for _ in $(seq 1 "$n"); do up "$u" && return 0; sleep 2; done; return 1; }

# ── 0a. clone every repo this script needs (idempotent) ──────────────────────────────
mkdir -p "$SRC"
clone(){ [ -d "$SRC/$2/.git" ] || { log "cloning $2"; GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$GL/$1.git" "$SRC/$2"; }; }
clone "integration/resource-discovery/resource-catalogue/federated-catalogue/catalogue-be" catalogue-be
clone "development/iaa/authentication_provider"       authentication_provider
clone "development/iaa/identity-provider"             identity-provider
clone "development/iaa/security-attributes-provider"  security-attributes-provider
clone "development/iaa/tier2-gateway"                 tier2-gateway
clone "governance/resource-management/metadata-description/resource-description-tooling/sd-tooling-be" sd-tooling-be

# ── 0b. infra: Postgres + Redis + CA shim + JWKS + OCSP + quality-scoring ─────────────
PGDATA=/var/lib/postgresql/lab-pgdata
if ! PGPASSWORD=postgres psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -c 'select 1' >/dev/null 2>&1; then
  [ -d "$PGDATA" ] || { mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"; runuser -u postgres -- initdb -D "$PGDATA" -A trust >/dev/null; }
  runuser -u postgres -- pg_ctl -D "$PGDATA" -o "-p $PG_PORT -c listen_addresses=127.0.0.1" -l "$PGDATA/server.log" start
  for _ in $(seq 1 15); do runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "ALTER USER postgres PASSWORD 'postgres';" >/dev/null
fi
for db in catalogue authprovider authority_authprovider authority_securityattributesprovider; do
  runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE $db;" 2>/dev/null || true
done
runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c \
  "CREATE ROLE authority_identityprovider LOGIN PASSWORD 'authority_identityprovider';" 2>/dev/null || true
runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c \
  "CREATE DATABASE authority_identityprovider OWNER authority_identityprovider;" 2>/dev/null || true
redis-cli -p 30379 -a admin ping 2>/dev/null | grep -q PONG || \
  { nohup redis-server --port 30379 --requirepass admin >"$RUN/redis.log" 2>&1 & sleep 2; }
# CA shim (persistent CA) + OCSP responder + local Tier-1 JWKS + quality-scoring stub
( cd "$REPO_LAB_DIR/ejbca-shim" && [ -x ./ejbca-shim ] || GOFLAGS=-mod=mod noproxy_env go build -o ejbca-shim . )
up https://localhost:$SHIM_HTTPS/status || bg "$REPO_LAB_DIR/ejbca-shim/ejbca-shim"
up http://localhost:9099/certs   || bg python3 "$REPO_LAB_DIR/iaa/jwks-tier1.py"
up http://localhost:30081/ocsp   || bg python3 "$REPO_LAB_DIR/iaa/ocsp-responder.py"
up http://localhost:8085         || bg python3 "$REPO_LAB_DIR/catalogue/qs-stub.py"
# Neo4j (auth disabled + n10s) is brought up by 06-federated-catalogue.sh below.
log "infra up (Postgres, Redis, CA shim, JWKS, OCSP, quality-scoring)"

# ── 1. fc-service (catalogue) with schemas + named DataSchema ─────────────────────────
bash "$(dirname "$0")/06-federated-catalogue.sh" >/dev/null 2>&1 || true
waitup http://localhost:8081/self-descriptions 60 && log "fc-service up on :8081"

# ── 2. apply the gateway trust patch, then build the IAA services ─────────────────────
GW="$IAA/tier2-gateway"
git -C "$GW" apply --reverse --check "$REPO_LAB_DIR/iaa/patches/tier2-gateway-local-trust.patch" 2>/dev/null \
  || git -C "$GW" apply "$REPO_LAB_DIR/iaa/patches/tier2-gateway-local-trust.patch" 2>/dev/null || true
mvnb(){ ( cd "$1" && noproxy_env mvn -q -B -ntp -DskipTests -Dspotless.check.skip=true \
  -Dspotless.apply.skip=true -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package ); }
for svc in authentication_provider identity-provider security-attributes-provider tier2-gateway sd-tooling-be; do
  ls "$SRC/$svc"/target/*.jar >/dev/null 2>&1 || { log "building $svc"; mvnb "$SRC/$svc"; }
done

jar(){ ls "$1"/target/*.jar | head -1; }
# ── 3. boot the IAA mesh ──────────────────────────────────────────────────────────────
# identity-provider (:8103, the participant registry the GA + SAP call internally)
up http://localhost:8103/actuator/health || bg env JAVA_HOME=$JH java -jar "$(jar "$IAA/identity-provider")" \
  --spring.profiles.active=local --server.port=8103 \
  --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/authority_identityprovider \
  --spring.datasource.username=authority_identityprovider --spring.datasource.password=authority_identityprovider \
  --spring.data.redis.host=localhost --spring.data.redis.port=30379 --spring.data.redis.username=default --spring.data.redis.password=admin \
  --open-id-connect.certs-endpoint=http://localhost:9099/certs
# authentication_provider — GA (:8105, authority) and provider (:8104, participant)
apboot(){ bg env JAVA_HOME=$JH java -jar "$(jar "$IAA/authentication_provider")" \
  --spring.profiles.active=$2 --server.port=$1 \
  --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/$3 \
  --spring.datasource.username=postgres --spring.datasource.password=postgres \
  --spring.data.redis.host=localhost --spring.data.redis.port=30379 --spring.data.redis.username=default --spring.data.redis.password=admin \
  --client.authority.url=$4 --open-id-connect.certs-endpoint=http://localhost:9099/certs \
  --microservice.identity-provider.url=http://localhost:8103 --microservice.security-attributes-provider.url=http://localhost:8102 \
  --simpl.gateway.tier-one-url=http://localhost:8101 --simpl.gateway.tier-two-url=https://localhost:8443; }
up http://localhost:8105/actuator/health || apboot 8105 local-authority authority_authprovider https://localhost:$SHIM_HTTPS
up http://localhost:8104/actuator/health || apboot 8104 local-consumer  authprovider           https://localhost:8443
# SAP (:8102, GA ephemeral-proof needs it)
up http://localhost:8102/actuator/health || bg env JAVA_HOME=$JH java -jar "$(jar "$IAA/security-attributes-provider")" \
  --spring.profiles.active=local --server.port=8102 \
  --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/authority_securityattributesprovider \
  --spring.datasource.username=postgres --spring.datasource.password=postgres \
  --spring.data.redis.host=localhost --spring.data.redis.port=30379 --spring.data.redis.username=default --spring.data.redis.password=admin \
  --microservice.identity-provider.url=http://localhost:8103 --microservice.authentication-provider.url=http://localhost:8105 \
  --simpl.ephemeral-proof.issuer-url=https://localhost:8443 --open-id-connect.certs-endpoint=http://localhost:9099/certs
for p in 8103 8104 8105 8102; do waitup http://localhost:$p/actuator/health 60 >/dev/null || log "WARN: :$p not healthy"; done
log "IAA mesh up (identity-provider, GA+provider auth_provider, SAP)"

# ── 4. enroll the AUTHORITY (root of trust) then boot the gateway with its identity ───
bash "$REPO_LAB_DIR/iaa/enroll.sh" 8105 "Local Authority" true  | tail -1
GWJAR="$(jar "$GW")"
gwboot(){ bg env JAVA_HOME=$JH java -jar "$GWJAR" --spring.profiles.active=local-authority --server.port=8443 \
  --spring.data.redis.host=localhost --spring.data.redis.port=30379 --spring.data.redis.username=default --spring.data.redis.password=admin \
  --sap.url=http://localhost:8102 --identity-provider.url=http://localhost:8103 \
  --authentication-provider.url=http://localhost:8105 --users-roles.url=http://localhost:8106 \
  --federated-catalogue.url=http://localhost:8081 --keypair.algorithm=EC; }
# (re)start the gateway so it fetches its server identity from the now-credentialed GA
ps -eo pid,args | grep 'tier2-gateway-local.jar' | grep -v grep | awk '{print $1}' | xargs -r kill 2>/dev/null || true
sleep 2; gwboot; waitup https://localhost:8443/actuator/health 60 && log "tier2-gateway up on :8443 (mTLS, GA identity)"

# ── 5. enroll the PROVIDER (registers with the GA through the gateway mTLS) ────────────
bash "$REPO_LAB_DIR/iaa/enroll.sh" 8104 "ACME Provider" false | tail -1
PUUID=$(cat /tmp/last-uuid.txt)
# fetch+cache an ephemeral proof for the provider (GA -> SAP), then boot sd-tooling-be
TOK=$(python3 "$REPO_LAB_DIR/iaa/jwks-tier1.py" token "$PUUID")
curl -s -o /dev/null -H "Authorization: Bearer $TOK" http://localhost:8104/tier1/v2/ephemeralProof || true

# ── 6. sd-tooling-be (the real publisher) pointed at the gateway ──────────────────────
SDT="$LAB_ROOT/src/sd-tooling-be"
up http://localhost:8090/status || bg env JAVA_HOME=$JH java -jar "$(jar "$SDT")" \
  --server.port=8090 --web.mvc.bearer-token.required=false \
  --vc-issuer.api-key=localkey --vc-issuer.client-id=local-client --vc-issuer.service.url=http://localhost:9085/vcIssuerService \
  --authentication-provider.service.url=http://localhost:8104 \
  --federated-catalogue.tier2-gateway.url=https://localhost:8443 --federated-catalogue.tier2-gateway.path-prefix=/fc \
  --otel.sdk.disabled=true
waitup http://localhost:8090/status 60 && log "sd-tooling-be up on :8090"

# ── 7. PUBLISH through the mesh + verify ──────────────────────────────────────────────
SD="$LAB_ROOT/src/catalogue-be/src/test/resources/mock-data/default-sd.json"
[ -f "$SD" ] || SD="$REPO_LAB_DIR/catalogue/mock-data/default-sd.json"
log "POST /v1/selfDescriptions/publications (through the Tier-2 mTLS mesh)"
curl -s -w '\n  HTTP %{http_code}\n' -X POST http://localhost:8090/v1/selfDescriptions/publications \
  -H "Content-Type: application/json" --data-binary @"$SD" | tail -2
log "fc-service self-descriptions:"; curl -s http://localhost:8081/self-descriptions | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print('  totalCount:',d.get('totalCount'));[print('   ',i.get('meta',i).get('id'),i.get('meta',i).get('status')) for i in d.get('items',[])[:3]]" 2>/dev/null
log "provider-agent publish through the full Tier-2 mTLS mesh — complete."
