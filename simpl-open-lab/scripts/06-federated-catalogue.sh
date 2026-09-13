#!/usr/bin/env bash
# Bring up the Gaia-X Federated Catalogue and PUBLISH a Tier-A conformant
# Self-Description FULLY LOCALLY (offline) — publish -> quality-scoring -> store ->
# graph -> query, with no external/hardcoded services.
#
# The Federated Catalogue (catalogue-be, Java pkg eu.xfsc.fc) is the Gaia-X XFSC
# Federation Catalogue: it stores Self-Descriptions in PostgreSQL, extracts their
# claims to RDF (Apache Jena), validates them against SHACL shapes, computes a
# quality score, imports the RDF into Neo4j (via neosemantics / n10s) and offers
# publish / search / openCypher-query.
#
# WHY THIS SCRIPT EXISTS -------------------------------------------------------
# Out of the box POST /self-descriptions cannot complete off-cluster because the
# publish path makes a MANDATORY synchronous call to the quality-scoring-service
# at a HARD-CODED Kubernetes hostname:
#     QUALITY_SCORING_URL default = https://quality-scoring-service.authority01.svc.cluster.local:8080
# Off the cluster that is NXDOMAIN -> HTTP 500 and the SD is never stored. We point
# it at a tiny local stub (qs-stub.py) that returns a valid MQR quality report so
# the SD classifies Tier "A" and publication succeeds.
#
# Two further local realities are handled here:
#  (1) Graph writes. In this fork graphStore.addClaims() is called ONLY by the
#      GraphRebuilder, whose REST endpoint ships annotated @Component (never
#      registered as an MVC handler) and whose worker pool interrupts the n10s
#      import after a 100 ms grace. patches/catalogue-local.patch turns the
#      endpoint into a real @RestController("/graph-rebuild") and lengthens the
#      grace, so a one-shot rebuild reliably populates Neo4j.
#  (2) Neo4j auth. The autowired Neo4j Driver connects with scheme 'none'
#      (Spring Boot defaults), so we run Neo4j with auth disabled for the lab.
#
# PUBLICATION prerequisites the Simpl fork enforces (all satisfied below):
#   (a) the `http://w3id.org/gaia-x/simpl#` ontology loaded (simpl-ontology.ttl)
#   (b) the offering's SHACL shape loaded (test-schema.ttl)
#   (c) the provider's NAMED data-schema resolvable via schemasDao.selectByName()
#       — the SD's credentialSubject.dct:conformsTo -> dct:schemaName "DataSchema"
#       — registered directly in the `schemas` table (normally a schema-manager job)
#
# RESULT (verified): POST /self-descriptions -> 201 with qualityAssessment
# classification "A"; GET /self-descriptions -> totalCount 1; POST /graph-rebuild
# populates Neo4j; POST /query (openCypher) returns the offering and its properties.
source "$(dirname "$0")/env.sh"

CAT="$LAB_ROOT/src/catalogue-be"
MOCK="$REPO_LAB_DIR/catalogue/mock-data"
PATCH="$REPO_LAB_DIR/catalogue/patches/catalogue-local.patch"
QS_STUB="$REPO_LAB_DIR/catalogue/qs-stub.py"
QS_PORT=8085
CAT_PORT=8081
NEO=/var/lib/postgresql/neo4j
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"

# ---- 1. Neo4j 5.26 + neosemantics + APOC, auth DISABLED ----------------------
if ! curl -s -o /dev/null http://127.0.0.1:7474 2>/dev/null; then
  if [ ! -x "$NEO/bin/neo4j" ]; then
    log "downloading Neo4j 5.26 + neosemantics + APOC..."
    d="$LAB_ROOT/neo4j-dl"; mkdir -p "$d"
    curl -fsSL -o "$d/neo4j.tgz"        https://dist.neo4j.org/neo4j-community-5.26.0-unix.tar.gz
    curl -fsSL -o "$d/neosemantics.jar" https://github.com/neo4j-labs/neosemantics/releases/download/5.26.0/neosemantics-5.26.0.jar
    curl -fsSL -o "$d/apoc.jar"         https://github.com/neo4j/apoc/releases/download/5.26.0/apoc-5.26.0-core.jar
    rm -rf "$NEO"; mkdir -p "$NEO"; tar xzf "$d/neo4j.tgz" -C "$NEO" --strip-components=1
    cp "$d/neosemantics.jar" "$d/apoc.jar" "$NEO/plugins/"
    cat >> "$NEO/conf/neo4j.conf" <<CONF
server.default_listen_address=127.0.0.1
dbms.security.procedures.unrestricted=apoc.*,n10s.*,gds.*
dbms.security.procedures.allowlist=apoc.*,n10s.*,gds.*
server.memory.heap.max_size=1g
dbms.security.auth_enabled=false
CONF
    chown -R postgres:postgres "$NEO"
  fi
  # make sure auth is disabled even if the dir predates this script
  grep -q "^dbms.security.auth_enabled=false" "$NEO/conf/neo4j.conf" \
    || printf '\ndbms.security.auth_enabled=false\n' >> "$NEO/conf/neo4j.conf"
  runuser -u postgres -- env JAVA_HOME="$JAVA_HOME" "$NEO/bin/neo4j" start
  wait_http "http://127.0.0.1:7474" 60
fi
# wait for bolt to accept cypher, then init the neosemantics graph config
neo_cypher() { curl -s -X POST http://127.0.0.1:7474/db/neo4j/tx/commit \
  -H "Content-Type: application/json" -d "{\"statements\":[{\"statement\":\"$1\"}]}"; }
for _ in $(seq 1 30); do neo_cypher 'RETURN 1 AS ok' | grep -q '"row":\[1\]' && break; sleep 1; done
neo_cypher 'CREATE CONSTRAINT n10s_unique_uri IF NOT EXISTS FOR (r:Resource) REQUIRE r.uri IS UNIQUE' >/dev/null
neo_cypher 'CALL n10s.graphconfig.init({handleVocabUris:\"MAP\",handleMultival:\"ARRAY\",multivalPropList:[\"http://w3id.org/gaia-x/service#claimsGraphUri\"]})' >/dev/null 2>&1 || true
log "Neo4j up (bolt :7687, auth disabled) with neosemantics+APOC initialised"

# ---- 2. apply the local patch + build catalogue-be ---------------------------
[ -d "$CAT/.git" ] || { log "catalogue-be missing — run 01-setup.sh first"; exit 1; }
if ! git -C "$CAT" apply --reverse --check "$PATCH" 2>/dev/null; then
  log "applying catalogue-local.patch (wires /graph-rebuild + rebuild grace)"
  git -C "$CAT" apply "$PATCH" || { log "patch failed to apply — is catalogue-be at a compatible revision?"; exit 1; }
fi
if [ ! -f "$CAT/target/fc-service-server.jar" ] || [ "$PATCH" -nt "$CAT/target/fc-service-server.jar" ]; then
  log "building catalogue-be..."
  ( cd "$CAT" && noproxy_env mvn -q -B -ntp -DskipTests -Dspotless.check.skip=true \
      -Dspotless.apply.skip=true -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package )
fi

# ---- 3. catalogue DB ---------------------------------------------------------
runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE catalogue;" 2>/dev/null || true

# ---- 4. quality-scoring stub -------------------------------------------------
if ! curl -s -o /dev/null "http://127.0.0.1:$QS_PORT" 2>/dev/null; then
  nohup python3 "$QS_STUB" > "$RUN/qs-stub.log" 2>&1 & echo $! > "$RUN/qs-stub.pid"
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$QS_PORT" 2>/dev/null && break; sleep 1; done
fi
log "quality-scoring stub up on :$QS_PORT (returns a valid Tier-A MQR report)"

# ---- 5. boot the catalogue pointing at the local stub + graph store ----------
if ! curl -s -o /dev/null "http://localhost:$CAT_PORT/self-descriptions" 2>/dev/null; then
  ( cd "$CAT" && noproxy_env SCHEMA_MANAGER_SUBSCRIPTION_ENABLED=false \
      nohup java -jar target/fc-service-server.jar \
        --server.port=$CAT_PORT \
        --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/catalogue \
        --spring.datasource.username=postgres --spring.datasource.password=postgres \
        --graphstore.uri=bolt://localhost:7687 \
        --federated-catalogue.verification.doc-loader.enable-http=false \
        --federated-catalogue.verification.doc-loader.enable-local-cache=true \
        --quality-scoring.url=http://localhost:$QS_PORT \
        > "$RUN/catalogue.log" 2>&1 & echo $! > "$RUN/catalogue.pid" )
  wait_http "http://localhost:$CAT_PORT/self-descriptions" 90
fi
log "Federated Catalogue up on :$CAT_PORT"

# ---- 6. load ontology + SHACL shape, register the named DataSchema -----------
curl -s -o /dev/null -X POST "http://localhost:$CAT_PORT/schemas" \
  -H "Content-Type: application/json" --data-binary @"$MOCK/simpl-ontology.ttl"
curl -s -o /dev/null -X POST "http://localhost:$CAT_PORT/schemas" \
  -H "Content-Type: application/json" --data-binary @"$MOCK/test-schema.ttl"
# (c) the named data-schema the SD's dct:conformsTo -> dct:schemaName points at.
#     Normally produced by schema-manager; here inserted straight into `schemas`.
export PGPASSWORD=postgres
if ! psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d catalogue -tAc \
      "select 1 from schemas where name='DataSchema';" 2>/dev/null | grep -q 1; then
  log "registering named data-schema 'DataSchema'"
  # base64 (only [A-Za-z0-9+/=], no quotes) embeds safely as a SQL string literal,
  # sidestepping every shell/psql quoting hazard in the multi-line TTL body.
  B64=$(base64 -w0 "$MOCK/test-schema.ttl")
  psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d catalogue -v ON_ERROR_STOP=1 -c \
    "INSERT INTO schemas (id, name, version, resource_type, status, schema_body, creation_date, modification_date)
     VALUES (gen_random_uuid(), 'DataSchema', '21', 'data', 'PUBLISHED',
             convert_from(decode('$B64','base64'),'UTF8'), now(), now());"
fi
log "schemas loaded:"; curl -s "http://localhost:$CAT_PORT/schemas" | python3 -c \
  "import sys,json;d=json.load(sys.stdin);print('  ontologies:',len(d.get('ontologies',[])),'| shapes:',len(d.get('shapes',[])))" 2>/dev/null

# ---- 7. PUBLISH the Tier-A conformant Self-Description ------------------------
log "POST /self-descriptions (Tier-A conformant SD)"
RESP=$(curl -s -w '\n%{http_code}' -X POST "http://localhost:$CAT_PORT/self-descriptions" \
  -H "Content-Type: application/json" --data-binary @"$MOCK/default-sd.json")
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" = "201" ]; then
  echo "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);q=d.get('qualityAssessment',{}).get('overall',{});print('  published OK — id:',d.get('id'));print('  classification:',q.get('classification'),'| score:',q.get('score'),'| status:',q.get('status') or q.get('thresholdStatus'))" 2>/dev/null
elif echo "$BODY" | grep -q "already exists"; then
  log "  SD already published (idempotent) — ok"
else
  log "  publish returned HTTP $CODE: $BODY"
fi

# ---- 8. populate the graph + query it ---------------------------------------
log "POST /graph-rebuild (extract claims -> import to Neo4j)"
curl -s -o /dev/null -X POST "http://localhost:$CAT_PORT/graph-rebuild" \
  -H "Content-Type: application/json" -d '{"chunkCount":1,"chunkId":0,"threads":1,"batchSize":10}'
sleep 7   # let the (patched) rebuild worker finish the n10s import before shutdown
log "graph contents:"; neo_cypher 'MATCH (n:Resource) RETURN count(n) AS c' | python3 -c \
  "import sys,json;print('  Resource nodes:',json.load(sys.stdin)['results'][0]['data'][0]['row'][0])" 2>/dev/null
log "POST /query (openCypher) — the published DataOffering:"
curl -s -X POST "http://localhost:$CAT_PORT/query" -H "Content-Type: application/json" \
  -d '{"statement":"MATCH (n:Resource) WHERE n.uri CONTAINS \"DataOffering\" RETURN n.uri AS uri","parameters":{}}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);[print('  ',i.get('uri')) for i in d.get('items',[])]" 2>/dev/null

log "GET /self-descriptions:"; curl -s "http://localhost:$CAT_PORT/self-descriptions" | python3 -c \
  "import sys,json;print('  total self-descriptions:',json.load(sys.stdin).get('totalCount'))" 2>/dev/null
log "Federated Catalogue Tier-A publication complete — fully local, no external services."
