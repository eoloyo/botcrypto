#!/usr/bin/env bash
# FULL END-TO-END: a CONSUMER discovers a provider's data offering in the Gaia-X
# Federated Catalogue, reads the provider connector's DSP endpoint out of the
# discovered Self-Description, then negotiates + transfers the actual data from the
# provider over EDC. This joins the two dataspace discovery layers the lab otherwise
# runs separately (06/07 = catalogue, 02 = EDC transfer):
#
#   fc-service  (semantic discovery: WHO offers what, and WHERE is their connector)
#     │  GET /self-descriptions?withContent=true -> SD -> simpl:serviceAccessPoint
#     ▼
#   provider EDC connector DSP  http://localhost:19194/protocol   (offer + asset id)
#     │  catalog/request -> contractnegotiations -> transferprocesses (MinioS3-PUSH)
#     ▼
#   consumer-bucket receives example-s3.txt   (the real bytes moved provider->consumer)
#
# The bridge is the SD's serviceAccessPoint (catalogue/mock-data/default-sd.json),
# which names the provider connector's DSP endpoint ($PROVIDER_DSP). The consumer never
# hardcodes that endpoint — it reads it from the catalogue.
#
# Prereqs are handled here (idempotent): if the catalogue has no SD it runs 07 (which
# clones+builds the mesh and publishes through the Tier-2 mTLS path, itself running 06);
# it builds connector-be if missing and runs 02 to bring up the EDC dataspace.
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
HERE="$(cd "$(dirname "$0")" && pwd)"
CAT="http://localhost:8081"
py(){ "$LAB_ROOT/motoenv/bin/python" "$@"; }   # has boto3

total(){ curl -s "$CAT/self-descriptions" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo 0; }
waitc(){ local u="$1" n="${2:-60}"; for _ in $(seq 1 "$n"); do curl -s -o /dev/null "$u" && return 0; sleep 2; done; return 1; }

# ── 1. ensure the Federated Catalogue has the SD published (runs 07 -> 06 if empty) ──
if [ "$(total)" -lt 1 ]; then
  log "catalogue has no Self-Description yet — running 07 (Tier-2 provider publish)"
  bash "$HERE/07-tier2-provider-publish.sh"
fi
waitc "$CAT/self-descriptions" 30 || { log "fc-service not reachable on :8081"; exit 1; }
log "Federated Catalogue up — self-descriptions totalCount=$(total)"

# ── 2. ensure the EDC dataspace is up (build connector-be if missing, then run 02) ──
CONN="$LAB_ROOT/src/connector-be"
if [ ! -f "$CONN/target/basic-connector.jar" ]; then
  log "connector-be jar missing — cloning/building it"
  [ -d "$CONN/.git" ] || GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
    "$GL/integration/resource-sharing/resource-sharing-runtime/connector/connector-be.git" "$CONN"
  ( cd "$CONN" && noproxy_env mvn -q -B -ntp -DskipTests -Dspotless.check.skip=true \
      -Dspotless.apply.skip=true -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package )
fi
log "bringing up the EDC dataspace (provider+consumer connectors, provider asset/policy/contract)"
bash "$HERE/02-dataspace.sh" >>"$RUN/08.log" 2>&1 || { log "02-dataspace.sh failed — see $RUN/08.log"; exit 1; }
waitc "http://localhost:$CONSUMER_MGMT/management/v3/assets/request" 30 || true
log "EDC connectors up (provider :$PROVIDER_MGMT, consumer :$CONSUMER_MGMT)"

# ── 3. DISCOVERY — consumer reads the connector endpoint out of the catalogue ────────
log "consumer discovery: GET $CAT/self-descriptions (semantic catalogue)"
DISCO=$(python3 - "$CAT" <<'PY'
import sys, json, urllib.request
CAT = sys.argv[1]
def get(u): return urllib.request.urlopen(urllib.request.Request(u), timeout=15).read().decode()

def find_sap(node):
    """Recursively find a serviceAccessPoint / any DSP protocol URL in an SD."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k.endswith("serviceAccessPoint"):
                val = v.get("@value") if isinstance(v, dict) else v
                if isinstance(val, str) and val:
                    return val
            r = find_sap(v)
            if r: return r
    elif isinstance(node, list):
        for it in node:
            r = find_sap(it)
            if r: return r
    elif isinstance(node, str) and "/protocol" in node and node.startswith("http"):
        return node
    return None

lst = json.loads(get(f"{CAT}/self-descriptions?withMeta=true&withContent=true"))
best = {}
for it in (lst.get("items") or []):
    meta = it.get("meta") or {}
    content = it.get("content")
    if content is None:
        h = meta.get("sdHash") or meta.get("id")
        if not h: continue
        content = get(f"{CAT}/self-descriptions/{h}")
    try: sd = json.loads(content)
    except Exception: continue
    ep = find_sap(sd)
    if ep:
        cs = sd.get("credentialSubject", {}) if isinstance(sd, dict) else {}
        sid = (cs.get("@id") if isinstance(cs, dict) else None) or meta.get("id") or meta.get("sdHash")
        best = {"id": sid, "endpoint": ep}
        break
print(json.dumps(best))
PY
)
echo "  discovered: $DISCO"
ENDPOINT=$(echo "$DISCO" | python3 -c "import sys,json;print(json.load(sys.stdin).get('endpoint',''))")
SDID=$(echo "$DISCO"     | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
[ -n "$ENDPOINT" ] || { log "no DataOffering with a serviceAccessPoint found in the catalogue"; exit 1; }
log "discovered provider connector DSP endpoint = $ENDPOINT  (from catalogue SD: $SDID)"
# (semantic-search face of the same discovery — best-effort, non-fatal)
curl -s -X POST "$CAT/query" -H "Content-Type: application/json" \
  -d '{"statement":"MATCH (n:Resource) WHERE n.uri CONTAINS \"DataOffering\" RETURN n.uri AS uri LIMIT 3","parameters":{}}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);[print('   catalogue node:',i.get('uri')) for i in d.get('items',[])]" 2>/dev/null || true

# ── 4. clear consumer-bucket so the final proof is attributable to THIS transfer ─────
py - <<PY
import boto3
s3=boto3.client("s3",endpoint_url="http://localhost:$MOTO_PORT",aws_access_key_id="minioadmin",aws_secret_access_key="minioadmin",region_name="us-east-1")
try: s3.delete_object(Bucket="consumer-bucket",Key="example-s3.txt")
except Exception: pass
print("consumer-bucket cleared for the discovery-driven transfer")
PY

# ── 5. NEGOTIATE + TRANSFER against the DISCOVERED endpoint (EDC layer) ───────────────
C="http://localhost:$CONSUMER_MGMT/management/v3"
log "consumer -> discovered endpoint: catalog -> negotiate -> transfer -> verify"
python3 - "$C" "$ENDPOINT" "$MOTO_PORT" <<'PY'
import sys, json, time, urllib.request
C, PROTO, MOTO = sys.argv[1], sys.argv[2], sys.argv[3]
def call(url, body):
    r = urllib.request.Request(url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "x-api-key": "password"})
    return json.load(urllib.request.urlopen(r))
def gett(url):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"x-api-key": "password"})))
V = {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}

# 1) EDC catalog at the DISCOVERED endpoint -> concrete offer + asset id
cat = call(f"{C}/catalog/request", {"@context": V, "@type": "CatalogRequest",
      "counterPartyAddress": PROTO, "protocol": "dataspace-protocol-http"})
ds = cat["dcat:dataset"]
ds = ds[0] if isinstance(ds, list) else ds
offer = ds["odrl:hasPolicy"]
offer = offer[0] if isinstance(offer, list) else offer
offer_id = offer["@id"]
asset_id = ds.get("@id") or ds.get("id")
print(f"  EDC offer: {offer_id[:44]}...  asset: {asset_id}")

# 2) contract negotiation
neg = call(f"{C}/contractnegotiations", {"@context": {**V, "odrl": "http://www.w3.org/ns/odrl/2/"},
      "@type": "ContractRequest", "counterPartyAddress": PROTO, "protocol": "dataspace-protocol-http",
      "policy": {"@context": "http://www.w3.org/ns/odrl.jsonld", "@id": offer_id, "@type": "Offer",
                 "assigner": "provider", "target": asset_id,
                 "permission": [{"action": "use"}], "prohibition": [], "obligation": []}})
nid = neg["@id"]; ag = None
for _ in range(20):
    st = gett(f"{C}/contractnegotiations/{nid}"); ag = st.get("contractAgreementId")
    if ag: break
    time.sleep(2)
print("  agreement:", ag)
assert ag, "contract negotiation did not produce an agreement"

# 3) transfer (MinioS3 push into consumer-bucket)
tr = call(f"{C}/transferprocesses", {"@context": V, "@type": "TransferRequest",
      "counterPartyAddress": PROTO, "protocol": "dataspace-protocol-http",
      "contractId": ag, "assetId": asset_id, "transferType": "MinioS3-PUSH",
      "dataDestination": {"type": "MinioS3", "bucketName": "consumer-bucket", "objectName": "example-s3.txt",
          "endpoint": f"http://localhost:{MOTO}", "region": "us-east-1",
          "accessKeyId": "minioadmin", "secretAccessKey": "minioadmin"}})
tid = tr["@id"]; state = None
for _ in range(20):
    st = gett(f"{C}/transferprocesses/{tid}"); state = st.get("state"); print("  transfer:", state)
    if state in ("COMPLETED", "TERMINATED"): break
    time.sleep(2)
assert state == "COMPLETED", f"transfer ended {state}"

# 4) verify the bytes landed
import boto3
s3 = boto3.client("s3", endpoint_url=f"http://localhost:{MOTO}", aws_access_key_id="minioadmin",
                  aws_secret_access_key="minioadmin", region_name="us-east-1")
objs = [o["Key"] for o in s3.list_objects_v2(Bucket="consumer-bucket").get("Contents", [])]
print("  consumer-bucket:", objs)
assert "example-s3.txt" in objs, "file not present in consumer-bucket"
PY

log "DISCOVERY→TRANSFER VERIFIED — consumer discovered SD $SDID in the catalogue,"
log "  read connector endpoint $ENDPOINT from it, negotiated over EDC, and pulled the"
log "  data into consumer-bucket. Full provider→catalogue→consumer→transfer path is green."
