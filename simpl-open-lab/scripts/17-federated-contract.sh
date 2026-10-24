#!/usr/bin/env bash
# THE PROVIDER'S CONTRACT DECISION, DRIVEN BY THE FEDERATED (MAPPED) ATTRIBUTES.
#
# Ties pilot step 3 to the connector's ABAC: an EOSC consumer's identity is exchanged across the
# EOSC->DestinE federation (iaa/fed), and the attributes that come out the DestinE side are what
# the DestinE provider connector's ConsumptionConstraintFunction actually checks for a contract on
# a DESTINE_UPGRADED_ACCESS-gated offer.
#
#   partner consumer : EOSC attrs CONSUMER + EOSC_DESTINE_PARTNER  -exchange->  B: CONSUMER + DESTINE_UPGRADED_ACCESS  -> ALLOW
#   plain consumer   : EOSC attrs CONSUMER                          -exchange->  B: CONSUMER                            -> DENY
#
# The DestinE-side attributes are NOT hand-picked here (unlike 16-destine-eosc.sh's mock): they are
# the real output of the live ephemeral-proof exchange (iaa/fed/exchange.py) over the released BP02D
# mapping. The two authorities must be up and federated first (iaa/fed/authority.sh A|B + federate.py).
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; FED="$LAB_ROOT/fed"; mkdir -p "$RUN"
CONN="$LAB_ROOT/src/connector-be"; JAR="$CONN/target/basic-connector.jar"
D="$REPO_LAB_DIR/iaa/fed"; LOG="$RUN/17.log"; PY="python3 -I"
bg(){ setsid env -u JAVA_TOOL_OPTIONS -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
        -u NO_PROXY -u no_proxy "$@" </dev/null >>"$LOG" 2>&1 & disown 2>/dev/null || true; }
waitport(){ for _ in $(seq 1 "${2:-60}"); do (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null && { exec 3>&-; return 0; }; sleep 2; done; return 1; }
[ -f "$JAR" ] || { log "connector jar missing — run 02-dataspace.sh first"; exit 1; }

# ── authorities + federation ──────────────────────────────────────────────────────────
for p in 8203 8202 8303 8302; do curl -sf --noproxy '*' -o /dev/null "http://localhost:$p/actuator/health" || {
  log "authorities not up — run: iaa/fed/authority.sh B && iaa/fed/authority.sh A"; exit 1; }; done
$PY "$D/federate.py" "$FED" >>"$LOG" 2>&1 && log "federation B<-A active with attribute mapping" || { log "federate.py failed — see $LOG"; exit 1; }

# ── provider connector with a DESTINE_UPGRADED_ACCESS-gated offer ──────────────────────
PGDATA=/var/lib/postgresql/lab-pgdata
PGPASSWORD=postgres psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -c 'select 1' >/dev/null 2>&1 || {
  runuser -u postgres -- pg_ctl -D "$PGDATA" -o "-p $PG_PORT -c listen_addresses=127.0.0.1" -l "$PGDATA/server.log" start >/dev/null 2>&1 || true; sleep 3; }
runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE providerdb;" >/dev/null 2>&1 || true
sed -i 's#jdbc:postgresql://localhost:5432/postgres#jdbc:postgresql://localhost:'"$PG_PORT"'/providerdb#g' "$CONN/local/provider-config.properties"
waitport "$PROVIDER_MGMT" 1 || { log "starting DestinE provider connector"; EDC_DATASOURCE_DEFAULT_PASSWORD=postgres EDC_DATASOURCE_POLICY_PASSWORD=postgres bg java -Dedc.fs.config="$CONN/local/provider-config.properties" -jar "$JAR"; }
waitport "$PROVIDER_MGMT" 90 || { log "provider connector did not start"; exit 1; }
P="http://localhost:$PROVIDER_MGMT/management/v3"; PROTO="http://localhost:$PROVIDER_DSP/protocol"
H=(-H "Content-Type: application/json" -H "x-api-key: password"); V='{"@vocab":"https://w3id.org/edc/v0.0.1/ns/"}'
CONSUMPTION="https://w3id.org/edc/v0.0.1/ns/consumption"
curl -s "${H[@]}" -X POST $P/assets -d '{"@context":'"$V"',"@id":"destine-climate-dt","properties":{"name":"DestinE Climate DT (federated offer)"},"dataAddress":{"type":"HttpData","baseUrl":"http://localhost:8790/collections/EO.ECMWF.DAT.DT_CLIMATE_ADAPTATION","method":"GET"}}' >/dev/null || true
curl -s "${H[@]}" -X POST $P/policydefinitions -d '{"@context":'"$V"',"@id":"open-access","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@type":"Set","permission":[{"action":"use"}]}}' >/dev/null || true
curl -s "${H[@]}" -X POST $P/policydefinitions -d '{"@context":{"@vocab":"https://w3id.org/edc/v0.0.1/ns/","odrl":"http://www.w3.org/ns/odrl/2/"},"@id":"needs-upgraded","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@type":"Set","permission":[{"action":"use","constraint":{"@type":"AtomicConstraint","leftOperand":"'"$CONSUMPTION"'","operator":{"@id":"odrl:eq"},"rightOperand":"DESTINE_UPGRADED_ACCESS"}}]}}' >/dev/null || true
curl -s "${H[@]}" -X POST $P/contractdefinitions -d '{"@context":'"$V"',"@id":"destine-cdef","accessPolicyId":"open-access","contractPolicyId":"needs-upgraded","assetsSelector":[]}' >/dev/null || true
log "provider offers DestinE Climate DT, gated on DESTINE_UPGRADED_ACCESS"

# ── for each EOSC consumer: exchange its identity, then negotiate with the mapped attributes ──
mock_from_codes(){ $PY - "$@" <<'PY'
import sys,json,base64,uuid
items=[{"id":str(uuid.uuid4()),"code":c,"name":c.title(),"description":c,"assignableToRoles":True,
        "enabled":True,"assignedToParticipant":True,"creationTimestamp":"2026-10-24T00:00:00Z","updateTimestamp":"2026-10-24T00:00:00Z"} for c in sys.argv[1:]]
print(base64.b64encode(json.dumps({"self":"/x","pageSize":100,"page":0,"total":len(items),"items":items}).encode()).decode())
PY
}
negotiate(){ # negotiate <mock-b64> ; prints ALLOW|DENY
  local cfg="$RUN/consumer-fed.properties"; cp "$CONN/local/consumer-config.properties" "$cfg"
  sed -i "s#^mocked.agent.identity.attributes=.*#mocked.agent.identity.attributes=$1#" "$cfg"
  ps -eo pid,args | grep 'consumer-config.properties\|consumer-fed.properties' | grep -v grep | awk '{print $1}' | xargs -r kill 2>/dev/null || true
  for _ in $(seq 1 10); do waitport "$CONSUMER_MGMT" 1 || break; sleep 1; done
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres bg java -Dedc.fs.config="$cfg" -jar "$JAR"
  waitport "$CONSUMER_MGMT" 90 || { echo ERR; return; }
  sleep 3
  $PY - "http://localhost:$CONSUMER_MGMT/management/v3" "$PROTO" <<'PY'
import sys,json,time,urllib.request
C,PROTO=sys.argv[1:3]; V={"@vocab":"https://w3id.org/edc/v0.0.1/ns/"}
def call(u,b):
    r=urllib.request.Request(u,data=json.dumps(b).encode(),headers={"Content-Type":"application/json","x-api-key":"password"})
    return json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(r,timeout=30))
def get(u): return json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(urllib.request.Request(u,headers={"x-api-key":"password"}),timeout=30))
cat=call(f"{C}/catalog/request",{"@context":V,"@type":"CatalogRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http"})
ds=cat.get("dcat:dataset"); ds=ds[0] if isinstance(ds,list) else ds
off=ds["odrl:hasPolicy"]; off=off[0] if isinstance(off,list) else off
policy={"@context":"http://www.w3.org/ns/odrl.jsonld","@id":off["@id"],"@type":"Offer","assigner":"provider",
        "target":ds.get("@id"),"permission":[{"action":"use","constraint":{"@type":"AtomicConstraint",
        "leftOperand":"https://w3id.org/edc/v0.0.1/ns/consumption","operator":{"@id":"odrl:eq"},"rightOperand":"DESTINE_UPGRADED_ACCESS"}}],"prohibition":[],"obligation":[]}
neg=call(f"{C}/contractnegotiations",{"@context":{**V,"odrl":"http://www.w3.org/ns/odrl/2/"},"@type":"ContractRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http","policy":policy})
for _ in range(20):
    st=get(f"{C}/contractnegotiations/{neg['@id']}")
    if st.get("state") in ("FINALIZED","TERMINATED"): break
    time.sleep(2)
print("ALLOW" if st.get("contractAgreementId") and st.get("state")!="TERMINATED" else "DENY")
PY
}
run_consumer(){ # run_consumer <label> <eosc-attrs csv> <expect>
  log "── $1: EOSC attributes [$2] ──"
  $PY "$D/exchange.py" "$2" >>"$LOG" 2>&1 || { log "   exchange failed — see $LOG"; FAIL=1; return; }
  local bcodes; bcodes=$($PY -c "import json;print(' '.join(json.load(open('$FED/exchange.json'))['destine_attributes']))")
  log "   exchanged to DestinE attributes: [$bcodes]"
  local got; got=$(negotiate "$(mock_from_codes $bcodes)")
  if [ "$got" = "$3" ]; then log "   contract: $got — PASS (expected $3)"; else log "   contract: $got — FAIL (expected $3)"; FAIL=1; fi
}
FAIL=0
run_consumer "partner consumer" "CONSUMER,EOSC_DESTINE_PARTNER" ALLOW
run_consumer "plain consumer"   "CONSUMER"                      DENY
[ "$FAIL" = 0 ] && log "PROVIDER CONTRACT DECISION DRIVEN BY FEDERATED ATTRIBUTES — partner ALLOW, plain DENY" \
               || { log "see $LOG"; exit 1; }
