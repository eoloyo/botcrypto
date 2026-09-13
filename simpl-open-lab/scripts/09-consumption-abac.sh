#!/usr/bin/env bash
# Demonstrate CONSUMPTION ABAC: a provider offer whose contract policy requires the
# CONSUMER identity attribute. A consumer presenting CONSUMER may negotiate (transact);
# a consumer presenting only DATA_SEARCHER is DENIED — exactly the design rule
# ("a searcher can browse the catalogue but cannot start a contract negotiation").
#
# This uses the connector's OWN shipped enforcement (no connector code change here):
#   policy/function/ConsumptionConstraintFunction  (reads identity_attributes claim)
#   policy/service/PolicyFunctionsExtension         (binds `consumption` to NEGOTIATION_SCOPE)
# The provider's contract policy carries:
#   permission[use] constraint { leftOperand=consumption, operator=odrl:eq, rightOperand=CONSUMER }
#
# Identity source: this script flips the consumer connector's identity between the two
# cases via the connector's `mocked.agent.identity.attributes` lever. That proves the
# AUTHORIZATION decision on the shipped policy engine + a real EDC negotiation. Sourcing
# those attributes authentically over the Tier-2 mesh (SAP-issued, per iaa/patches/
# connector-tier2-identity.patch) is the authenticity upgrade on top of this — see
# catalogue/PROVIDER-PUBLICATION.md.
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
CONN="$LAB_ROOT/src/connector-be"; JAR="$CONN/target/basic-connector.jar"
PY="$LAB_ROOT/motoenv/bin/python"   # has boto3
# Strip HTTP(S)_PROXY *and* NO_PROXY/ALL_PROXY (inlined — noproxy_env is a shell function,
# not an executable, so it can't be invoked through `env`). The EDC config loader fails at
# boot with "Duplicate key no.proxy" if the sandbox's duplicate no_proxy vars leak in.
bg(){ setsid env -u JAVA_TOOL_OPTIONS -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
        -u NO_PROXY -u no_proxy -u ALL_PROXY -u all_proxy "$@" </dev/null >>"$RUN/09.log" 2>&1 & disown 2>/dev/null || true; }
waitport(){ for _ in $(seq 1 "${2:-60}"); do (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null && { exec 3>&-; return 0; }; sleep 2; done; return 1; }

[ -f "$JAR" ] || { log "connector jar missing — run 02-dataspace.sh or 08 first"; exit 1; }

# ── infra: Postgres (providerdb), moto S3 + buckets ───────────────────────────────────
"$LAB_ROOT/motoenv/bin/moto_server" -p "$MOTO_PORT" -H 127.0.0.1 >>"$RUN/moto.log" 2>&1 &
waitport "$MOTO_PORT" 20 || true
runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE providerdb;" 2>/dev/null || true
"$PY" - <<PY
import boto3
s3=boto3.client("s3",endpoint_url="http://localhost:$MOTO_PORT",aws_access_key_id="minioadmin",aws_secret_access_key="minioadmin",region_name="us-east-1")
for b in ["provider-bucket","consumer-bucket"]:
    try: s3.create_bucket(Bucket=b)
    except Exception: pass
s3.put_object(Bucket="provider-bucket",Key="example-s3.txt",Body=b"ABAC demo payload\n")
print("buckets ready")
PY

# ── build a mocked-identity base64 for a single attribute code (CONSUMER or DATA_SEARCHER)
mock_for(){ # mock_for <CODE>
  "$PY" - "$1" <<'PY'
import sys,json,base64,uuid
code=sys.argv[1]
item={"id":str(uuid.uuid4()),"code":code,"name":code.title(),"description":code,
      "assignableToRoles":True,"enabled":True,"assignedToParticipant":True,
      "creationTimestamp":"2026-01-30T10:36:54.237051Z","updateTimestamp":"2026-01-30T10:36:54.237051Z"}
print(base64.b64encode(json.dumps({"self":"/x","pageSize":100,"page":0,"total":1,"items":[item]}).encode()).decode())
PY
}

# ── provider connector (once) ─────────────────────────────────────────────────────────
sed -i 's#jdbc:postgresql://localhost:5432/postgres#jdbc:postgresql://localhost:'"$PG_PORT"'/providerdb#g' "$CONN/local/provider-config.properties" 2>/dev/null || true
if ! (exec 3<>/dev/tcp/127.0.0.1/$PROVIDER_MGMT) 2>/dev/null; then
  log "starting provider connector"
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres EDC_DATASOURCE_POLICY_PASSWORD=postgres \
    bg java -Dedc.fs.config="$CONN/local/provider-config.properties" -jar "$JAR"
  waitport "$PROVIDER_MGMT" 90 || { log "provider connector did not start"; exit 1; }
fi
P="http://localhost:$PROVIDER_MGMT/management/v3"; PROTO="http://localhost:$PROVIDER_DSP/protocol"
H=(-H "Content-Type: application/json" -H "x-api-key: password"); V='{"@vocab":"https://w3id.org/edc/v0.0.1/ns/"}'
log "provider: asset + open access policy + CONSUMER-constrained contract policy + contract-def"
curl -s "${H[@]}" -X POST $P/assets -d '{"@context":'"$V"',"@id":"abac-asset","properties":{"name":"ABAC demo"},"dataAddress":{"type":"MinioS3","bucketName":"provider-bucket","objectName":"example-s3.txt","endpoint":"http://localhost:'"$MOTO_PORT"'","region":"us-east-1","accessKeyId":"minioadmin","secretAccessKey":"minioadmin"}}' >/dev/null || true
# access policy: open (so a searcher can still SEE the offer in the catalog)
curl -s "${H[@]}" -X POST $P/policydefinitions -d '{"@context":'"$V"',"@id":"open-access","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@type":"Set","permission":[{"action":"use"}]}}' >/dev/null || true
# contract policy: require the CONSUMER identity attribute to negotiate (consumption eq CONSUMER)
curl -s "${H[@]}" -X POST $P/policydefinitions -d '{"@context":{"@vocab":"https://w3id.org/edc/v0.0.1/ns/","odrl":"http://www.w3.org/ns/odrl/2/"},"@id":"consumer-only","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@type":"Set","permission":[{"action":"use","constraint":{"@type":"AtomicConstraint","leftOperand":"consumption","operator":{"@id":"odrl:eq"},"rightOperand":"CONSUMER"}}]}}' >/dev/null || true
curl -s "${H[@]}" -X POST $P/contractdefinitions -d '{"@context":'"$V"',"@id":"abac-cdef","accessPolicyId":"open-access","contractPolicyId":"consumer-only","assetsSelector":[]}' >/dev/null || true

# ── run one negotiation as a given identity, report ALLOW/DENY ────────────────────────
run_case(){ # run_case <CODE> <expect: ALLOW|DENY>
  local code="$1" expect="$2" cfg="$RUN/consumer-$code.properties"
  cp "$CONN/local/consumer-config.properties" "$cfg"
  local mock; mock="$(mock_for "$code")"
  sed -i "s#^mocked.agent.identity.attributes=.*#mocked.agent.identity.attributes=$mock#" "$cfg"
  # (re)start the consumer connector with this identity
  pkill -f 'consumer-[A-Z_]*\.properties' 2>/dev/null || true
  ps -eo pid,args | grep 'consumer-config.properties' | grep -v grep | awk '{print $1}' | xargs -r kill 2>/dev/null || true
  sleep 2
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres bg java -Dedc.fs.config="$cfg" -jar "$JAR"
  waitport "$CONSUMER_MGMT" 90 || { log "consumer connector ($code) did not start"; return 1; }
  sleep 3
  log "── identity=$code (expect $expect) ──"
  "$PY" - "http://localhost:$CONSUMER_MGMT/management/v3" "$PROTO" "$code" "$expect" <<'PY'
import sys,json,time,urllib.request,urllib.error
C,PROTO,code,expect=sys.argv[1:5]
def call(u,b):
    r=urllib.request.Request(u,data=json.dumps(b).encode(),headers={"Content-Type":"application/json","x-api-key":"password"})
    return json.load(urllib.request.urlopen(r))
def gett(u): return json.load(urllib.request.urlopen(urllib.request.Request(u,headers={"x-api-key":"password"})))
V={"@vocab":"https://w3id.org/edc/v0.0.1/ns/"}
cat=call(f"{C}/catalog/request",{"@context":V,"@type":"CatalogRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http"})
ds=cat.get("dcat:dataset"); ds=ds[0] if isinstance(ds,list) else ds
print(f"   catalog: offer visible = {bool(ds)} (access policy is open, so a searcher SEES it)")
off=ds["odrl:hasPolicy"]; off=off[0] if isinstance(off,list) else off; offer_id=off["@id"]
neg=call(f"{C}/contractnegotiations",{"@context":{**V,"odrl":"http://www.w3.org/ns/odrl/2/"},"@type":"ContractRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@id":offer_id,"@type":"Offer","assigner":"provider","target":"abac-asset","permission":[{"action":"use","constraint":{"@type":"AtomicConstraint","leftOperand":"consumption","operator":{"@id":"odrl:eq"},"rightOperand":"CONSUMER"}}]}})
nid=neg["@id"]; state=None; agree=None
for _ in range(20):
    st=gett(f"{C}/contractnegotiations/{nid}"); state=st.get("state"); agree=st.get("contractAgreementId")
    if state in ("FINALIZED","TERMINATED") or agree: break
    time.sleep(2)
allowed = agree is not None and state!="TERMINATED"
print(f"   negotiation state={state} agreement={'yes' if allowed else 'no'}")
ok = (allowed and expect=="ALLOW") or (not allowed and expect=="DENY")
print(f"   >>> {code}: {'ALLOWED' if allowed else 'DENIED'} — {'PASS' if ok else 'FAIL'} (expected {expect})")
sys.exit(0 if ok else 1)
PY
}

RC=0
run_case CONSUMER      ALLOW || RC=1
run_case DATA_SEARCHER DENY  || RC=1
[ "$RC" = 0 ] && log "CONSUMPTION ABAC ENFORCED — CONSUMER may transact, DATA_SEARCHER denied." \
             || { log "ABAC demo FAILED — see $RUN/09.log"; exit 1; }
