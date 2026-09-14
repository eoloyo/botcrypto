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
# Self-contained: this script clones every repo it needs under $LAB_ROOT/src/<name>,
# applies the two local patches, builds the jars (bounded-parallel; skips ones already
# built), brings up the whole mesh, onboards+enrolls the authority and the provider, and
# publishes. First run clones + builds ~6 services (minutes); re-runs reuse the jars.
# Optional fast path: set $SIMPL_JARS_RELEASE to download prebuilt jars instead (see §2).
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

# ── 2. apply the local patches, then build the IAA services ───────────────────────────
GW="$IAA/tier2-gateway"
# apply a repo patch idempotently (skip if already applied)
applypatch(){ # applypatch <repo-dir> <patch-file>
  local d="$1" p="$2"
  [ -f "$p" ] || return 0
  git -C "$d" apply --reverse --check "$p" 2>/dev/null && return 0   # already applied
  git -C "$d" apply "$p" 2>/dev/null || git -C "$d" apply --3way "$p" 2>/dev/null || \
    { log "WARN: could not apply $(basename "$p")"; return 0; }
  log "applied $(basename "$p")"
}
# gateway: trust store (loadTrustedCertificates stub) + /fc route to fc-service
applypatch "$GW" "$REPO_LAB_DIR/iaa/patches/tier2-gateway-local-trust.patch"
applypatch "$GW" "$REPO_LAB_DIR/iaa/patches/tier2-gateway-fc-route.patch"
# auth-provider: make the startup tier-one key-push non-fatal (so :8104 boots on a fresh agent)
applypatch "$IAA/authentication_provider" "$REPO_LAB_DIR/iaa/patches/authprovider-startup-keypush-nonfatal.patch"
# sd-tooling-be: add GET /v1/selfDescriptions/discover/{id} — a credential-backed catalogue READ
# through the Tier-2 gateway (FederatedCatalogueTier2Client.getSelfDescription), so discovery is
# gated by the same mTLS + ephemeral-proof + ABAC perimeter as publish (see 10-gated-discovery.sh)
applypatch "$SRC/sd-tooling-be" "$REPO_LAB_DIR/iaa/patches/sdtooling-fc-read.patch"
mvnb(){ ( cd "$1" && noproxy_env mvn -q -B -ntp -DskipTests -Dspotless.check.skip=true \
  -Dspotless.apply.skip=true -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package ); }

# Optional fast path (opt-in): if $SIMPL_JARS_RELEASE is set to a base URL that serves the
# prebuilt service jars as <svc>.jar (e.g. the download URL of a GitHub Release produced by
# .github/workflows/build-simpl-jars.yml), download them instead of Maven-building. For a
# private repo, set $SIMPL_JARS_TOKEN to a token with `repo` scope. Any download that fails
# falls back to a local build, so this is always safe to leave unset (the default: build).
fetch_jar(){ # fetch_jar <svc> -> populates $SRC/<svc>/target/<svc>.jar
  local svc="$1" dst="$SRC/$1/target"; mkdir -p "$dst"
  local hdr=(); [ -n "${SIMPL_JARS_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer $SIMPL_JARS_TOKEN")
  curl -fsSL "${hdr[@]}" -o "$dst/$svc.jar" "${SIMPL_JARS_RELEASE%/}/$svc.jar"
}
build_one(){ # build_one <svc>: idempotent — skip if a jar exists, else download or build
  local svc="$1"
  ls "$SRC/$svc"/target/*.jar >/dev/null 2>&1 && return 0
  if [ -n "${SIMPL_JARS_RELEASE:-}" ]; then
    log "downloading prebuilt $svc jar"
    fetch_jar "$svc" && return 0
    log "download failed for $svc; building locally instead"
  fi
  log "building $svc (log: $RUN/build-$svc.log)"; mvnb "$SRC/$svc" >"$RUN/build-$svc.log" 2>&1
}
# The 5 IAA/publisher services are independent, so build them with bounded parallelism
# (default 3 at a time; override with $SIMPL_BUILD_PARALLELISM) to roughly halve the
# cold-start build phase without OOMing a memory-heavy box. catalogue-be is built by 06.
SVCS=(authentication_provider identity-provider security-attributes-provider tier2-gateway sd-tooling-be)
BUILD_PAR="${SIMPL_BUILD_PARALLELISM:-3}"; batch=(); build_fail=0
run_batch(){ local pids=() svc pid
  for svc in "${batch[@]}"; do build_one "$svc" & pids+=($!); done
  for pid in "${pids[@]}"; do wait "$pid" || build_fail=1; done
  batch=(); }
for svc in "${SVCS[@]}"; do
  batch+=("$svc"); [ "${#batch[@]}" -ge "$BUILD_PAR" ] && run_batch
done
[ "${#batch[@]}" -gt 0 ] && run_batch
[ "$build_fail" -eq 0 ] || { log "ERROR: a service build failed — see $RUN/build-*.log"; exit 1; }

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
# NOTE: the participant auth_provider (:8104) points client.authority.url at the gateway
# (:8443) and calls it at startup — a hard dependency. The gateway isn't up until step 4
# (it needs the GA credentialed first), so :8104 is booted THERE, after the gateway, to
# avoid a fatal "Connection refused localhost:8443 / Application run failed" at boot.
# SAP (:8102, GA ephemeral-proof needs it)
up http://localhost:8102/actuator/health || bg env JAVA_HOME=$JH java -jar "$(jar "$IAA/security-attributes-provider")" \
  --spring.profiles.active=local --server.port=8102 \
  --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/authority_securityattributesprovider \
  --spring.datasource.username=postgres --spring.datasource.password=postgres \
  --spring.data.redis.host=localhost --spring.data.redis.port=30379 --spring.data.redis.username=default --spring.data.redis.password=admin \
  --microservice.identity-provider.url=http://localhost:8103 --microservice.authentication-provider.url=http://localhost:8105 \
  --simpl.ephemeral-proof.issuer-url=https://localhost:8443 --open-id-connect.certs-endpoint=http://localhost:9099/certs
for p in 8103 8105 8102; do waitup http://localhost:$p/actuator/health 60 >/dev/null || log "WARN: :$p not healthy"; done
log "IAA authority side up (identity-provider, GA auth_provider, SAP)"

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

# now the gateway is up, boot the PARTICIPANT auth_provider (:8104) — it hard-depends on
# the gateway at startup (client.authority.url=https://localhost:8443).
up http://localhost:8104/actuator/health || apboot 8104 local-consumer authprovider https://localhost:8443
waitup http://localhost:8104/actuator/health 90 >/dev/null && log "participant auth_provider up on :8104" || log "WARN: :8104 not healthy"

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
