#!/usr/bin/env bash
# Bring up the Gaia-X Federated Catalogue (the GA-hosted rich catalog with signed
# Self-Descriptions) and exercise its schema-load + search API.
#
# The Federated Catalogue (catalogue-be, Java pkg eu.xfsc.fc) is the Gaia-X XFSC
# Federation Catalogue: it stores Self-Descriptions as RDF in Neo4j (via neosemantics),
# validates them against SHACL shapes, and offers publish/search/query.
#
# WHAT THIS SETS UP (all verified working):
#   - Neo4j 5.26 + neosemantics (n10s) + APOC plugins  (the RDF graph store)
#   - catalogue-be running against Neo4j + PostgreSQL   (boots, Liquibase-migrated)
#   - POST /schemas          -> load SHACL shapes/ontologies (simpl# + DataOffering shape)
#   - GET  /schemas          -> lists loaded ontologies/shapes
#   - GET  /self-descriptions, /selfDescriptions/quickSearch, POST /query  -> discovery
#
# PUBLICATION requirement discovered (POST /self-descriptions):
#   The Simpl fork requires (a) the `http://w3id.org/gaia-x/simpl#` ontology loaded,
#   (b) the offering's SHACL shape loaded (e.g. simpl:DataOffering), AND (c) the
#   provider's NAMED DATA SCHEMA resolvable via schemasDao.selectByName(<dct:schemaName>)
#   — e.g. "DataSchema" referenced by the SD's credentialSubject.dct:conformsTo.
#   That named data-schema is a schema-manager artifact tied to the specific offering
#   (the catalogue unit tests insert it directly into the schema store). A fully real
#   publication therefore needs schema-manager wired to assemble+register those named
#   schemas, plus the Resource-Offering-Editor to build a conformant, signed SD.
#   Everything up to that point — catalogue, RDF store, SHACL validation, schema load,
#   search — runs here.
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
NEO=/var/lib/postgresql/neo4j
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

# ---- Neo4j 5.26 + plugins ----------------------------------------------------
if ! curl -s -o /dev/null http://127.0.0.1:7474 2>/dev/null; then
  if [ ! -x "$NEO/bin/neo4j" ]; then
    log "downloading Neo4j 5.26 + neosemantics + APOC..."
    d="$LAB_ROOT/neo4j-dl"; mkdir -p "$d"
    curl -fsSL -o "$d/neo4j.tgz" https://dist.neo4j.org/neo4j-community-5.26.0-unix.tar.gz
    curl -fsSL -o "$d/neosemantics.jar" https://github.com/neo4j-labs/neosemantics/releases/download/5.26.0/neosemantics-5.26.0.jar
    curl -fsSL -o "$d/apoc.jar" https://github.com/neo4j/apoc/releases/download/5.26.0/apoc-5.26.0-core.jar
    rm -rf "$NEO"; mkdir -p "$NEO"; tar xzf "$d/neo4j.tgz" -C "$NEO" --strip-components=1
    cp "$d/neosemantics.jar" "$d/apoc.jar" "$NEO/plugins/"
    cat >> "$NEO/conf/neo4j.conf" <<CONF
server.default_listen_address=127.0.0.1
dbms.security.procedures.unrestricted=apoc.*,n10s.*,gds.*
dbms.security.procedures.allowlist=apoc.*,n10s.*,gds.*
dbms.security.auth_minimum_password_length=6
server.memory.heap.max_size=1g
CONF
    chown -R postgres:postgres "$NEO"
    runuser -u postgres -- env JAVA_HOME="$JAVA_HOME" "$NEO/bin/neo4j-admin" dbms set-initial-password neo12345
  fi
  runuser -u postgres -- env JAVA_HOME="$JAVA_HOME" "$NEO/bin/neo4j" start
  wait_http "http://127.0.0.1:7474" 40
fi
log "Neo4j up (bolt :7687) with neosemantics+APOC"

# ---- catalogue DB + boot -----------------------------------------------------
runuser -u postgres -- psql -p $PG_PORT -d postgres -c "CREATE DATABASE catalogue;" 2>/dev/null || true
CAT="$LAB_ROOT/src/catalogue-be"
[ -f "$CAT"/target/fc-service-server.jar ] || ( cd "$CAT" && mvn -q -B -ntp -DskipTests \
   -Dspotless.check.skip=true -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package )
if ! curl -s -o /dev/null "http://localhost:8081/self-descriptions" 2>/dev/null; then
  # NOTE: leave quality-scoring ENABLED (its bean is a hard dependency of selfDescriptionService)
  ( cd "$CAT" && env -u JAVA_TOOL_OPTIONS SCHEMA_MANAGER_SUBSCRIPTION_ENABLED=false GRAPHSTORE_PASSWORD=neo12345 \
      nohup java -jar target/fc-service-server.jar --server.port=8081 \
        --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/catalogue \
        --spring.datasource.username=postgres --spring.datasource.password=postgres \
        > "$RUN/catalogue.log" 2>&1 & echo $! > "$RUN/catalogue.pid" )
  wait_http "http://localhost:8081/self-descriptions" 60
fi
log "Federated Catalogue up on :8081"

# ---- load shapes + show catalog state ---------------------------------------
SHP="$CAT/src/test/resources/mock-data/simpl-ontology.ttl"
DSHP=$(ls "$LAB_ROOT"/src/*/src/test/resources/shacl/validation/data/data-offeringShape.ttl 2>/dev/null | head -1)
[ -f "$SHP" ] && curl -s -o /dev/null -X POST http://localhost:8081/schemas -H "Content-Type: application/json" --data-binary @"$SHP"
[ -n "$DSHP" ] && curl -s -o /dev/null -X POST http://localhost:8081/schemas -H "Content-Type: application/json" --data-binary @"$DSHP"
log "schemas loaded:"; curl -s http://localhost:8081/schemas | python3 -c "import sys,json;d=json.load(sys.stdin);print('  ontologies:',d.get('ontologies'));print('  shapes:',len(d.get('shapes',[])))" 2>/dev/null
log "catalog contents:"; curl -s "http://localhost:8081/self-descriptions" | python3 -c "import sys,json;print('  self-descriptions total:',json.load(sys.stdin).get('totalCount'))" 2>/dev/null
log "(publication requires the named data-schema registered — see header)"
