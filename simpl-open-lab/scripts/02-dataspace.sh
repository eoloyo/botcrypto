#!/usr/bin/env bash
# Bring up Postgres + S3 + two EDC connectors and run a real provider->consumer transfer.
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
start_bg() { local name="$1"; shift; log "starting $name"; noproxy_env nohup "$@" >"$RUN/$name.log" 2>&1 & echo $! >"$RUN/$name.pid"; }

# ---- PostgreSQL on :5433 (data dir under postgres user's home) ---------------
PGDATA=/var/lib/postgresql/lab-pgdata
if ! PGPASSWORD=postgres psql -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -c 'select 1' >/dev/null 2>&1; then
  if [ ! -d "$PGDATA" ]; then
    mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"
    runuser -u postgres -- initdb -D "$PGDATA" -A trust >/dev/null
  fi
  runuser -u postgres -- pg_ctl -D "$PGDATA" -o "-p $PG_PORT -c listen_addresses=127.0.0.1" -l "$PGDATA/server.log" start
  wait_http "http://127.0.0.1:$PG_PORT" 5 || true; sleep 2
  runuser -u postgres -- psql -p $PG_PORT -d postgres -c "ALTER USER postgres PASSWORD 'postgres';" >/dev/null
fi
# provider gets its own DB (consumer uses the default 'postgres' db)
runuser -u postgres -- psql -p $PG_PORT -d postgres -c "CREATE DATABASE providerdb;" 2>/dev/null || true
log "PostgreSQL up on :$PG_PORT"

# ---- S3 (moto) + buckets -----------------------------------------------------
if ! curl -s -o /dev/null "http://localhost:$MOTO_PORT/" 2>/dev/null; then
  start_bg moto "$LAB_ROOT/motoenv/bin/moto_server" -p $MOTO_PORT -H 127.0.0.1
  wait_http "http://localhost:$MOTO_PORT/" 20
fi
"$LAB_ROOT/motoenv/bin/python" - <<PY
import boto3
s3=boto3.client("s3",endpoint_url="http://localhost:$MOTO_PORT",aws_access_key_id="minioadmin",aws_secret_access_key="minioadmin",region_name="us-east-1")
for b in ["provider-bucket","consumer-bucket"]:
    try: s3.create_bucket(Bucket=b)
    except Exception: pass
s3.put_object(Bucket="provider-bucket",Key="example-s3.txt",Body=b"This is an example file for provider-bucket.\n")
print("S3 buckets ready:",[b["Name"] for b in s3.list_buckets()["Buckets"]])
PY

# ---- EDC connectors ----------------------------------------------------------
CONN="$LAB_ROOT/src/connector-be"
# point the provider's datasource at our single Postgres (its own DB)
sed -i 's#jdbc:postgresql://localhost:5432/postgres#jdbc:postgresql://localhost:'"$PG_PORT"'/providerdb#g' "$CONN/local/provider-config.properties"
JAR="$CONN/target/basic-connector.jar"
if ! curl -s -o /dev/null "http://localhost:$PROVIDER_MGMT/management/v3/assets/request" 2>/dev/null; then
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres EDC_DATASOURCE_POLICY_PASSWORD=postgres \
    start_bg provider-edc java -Dedc.fs.config="$CONN/local/provider-config.properties" -jar "$JAR"
fi
if ! curl -s -o /dev/null "http://localhost:$CONSUMER_MGMT/management/v3/assets/request" 2>/dev/null; then
  EDC_DATASOURCE_DEFAULT_PASSWORD=postgres \
    start_bg consumer-edc java -Dedc.fs.config="$CONN/local/consumer-config.properties" -jar "$JAR"
fi
log "waiting for connectors..."
for i in $(seq 1 60); do
  grep -q "ready" "$RUN/provider-edc.log" 2>/dev/null && grep -q "ready" "$RUN/consumer-edc.log" 2>/dev/null && break; sleep 2
done
log "connectors ready (provider :$PROVIDER_MGMT, consumer :$CONSUMER_MGMT)"

# ---- run the transfer (asset->policy->contractdef->catalog->negotiate->transfer->verify)
P="http://localhost:$PROVIDER_MGMT/management/v3"; PROTO="http://localhost:$PROVIDER_DSP/protocol"; C="http://localhost:$CONSUMER_MGMT/management/v3"
H=(-H "Content-Type: application/json" -H "x-api-key: password")
V='{"@vocab":"https://w3id.org/edc/v0.0.1/ns/"}'
log "1) provider: asset/policy/contract-definition"
curl -s "${H[@]}" -X POST $P/assets -d '{"@context":'"$V"',"@id":"example-s3-asset","properties":{"name":"Example S3 File","contenttype":"text/plain"},"dataAddress":{"type":"MinioS3","bucketName":"provider-bucket","objectName":"example-s3.txt","endpoint":"http://localhost:'"$MOTO_PORT"'","region":"us-east-1","accessKeyId":"minioadmin","secretAccessKey":"minioadmin"}}' >/dev/null
curl -s "${H[@]}" -X POST $P/policydefinitions -d '{"@context":'"$V"',"@id":"minio-s3-policy","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@type":"Set","permission":[{"action":"use"}],"prohibition":[],"obligation":[]}}' >/dev/null
curl -s "${H[@]}" -X POST $P/contractdefinitions -d '{"@context":'"$V"',"@id":"minio-s3-contract-def","accessPolicyId":"minio-s3-policy","contractPolicyId":"minio-s3-policy","assetsSelector":[]}' >/dev/null

log "2) consumer: catalog -> negotiate -> transfer -> verify"
# use the moto venv python (has boto3 + urllib); system python3 may lack boto3
"$LAB_ROOT/motoenv/bin/python" - "$C" "$PROTO" "$MOTO_PORT" <<'PY'
import sys,json,time,urllib.request
C,PROTO,MOTO=sys.argv[1],sys.argv[2],sys.argv[3]
def call(url,body):
    r=urllib.request.Request(url,data=json.dumps(body).encode(),headers={"Content-Type":"application/json","x-api-key":"password"})
    return json.load(urllib.request.urlopen(r))
V={"@vocab":"https://w3id.org/edc/v0.0.1/ns/"}
cat=call(f"{C}/catalog/request",{"@context":V,"@type":"CatalogRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http"})
offer=cat["dcat:dataset"]["odrl:hasPolicy"]["@id"]; print("offer:",offer[:40],"...")
neg=call(f"{C}/contractnegotiations",{"@context":{**V,"odrl":"http://www.w3.org/ns/odrl/2/"},"@type":"ContractRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@id":offer,"@type":"Offer","assigner":"provider","target":"example-s3-asset","permission":[{"action":"use"}],"prohibition":[],"obligation":[]}})
nid=neg["@id"]; ag=None
for _ in range(20):
    st=json.load(urllib.request.urlopen(urllib.request.Request(f"{C}/contractnegotiations/{nid}",headers={"x-api-key":"password"})))
    ag=st.get("contractAgreementId")
    if ag: break
    time.sleep(2)
print("agreement:",ag)
tr=call(f"{C}/transferprocesses",{"@context":V,"@type":"TransferRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http","contractId":ag,"assetId":"example-s3-asset","transferType":"MinioS3-PUSH","dataDestination":{"type":"MinioS3","bucketName":"consumer-bucket","objectName":"example-s3.txt","endpoint":f"http://localhost:{MOTO}","region":"us-east-1","accessKeyId":"minioadmin","secretAccessKey":"minioadmin"}})
tid=tr["@id"]; state=None
for _ in range(20):
    st=json.load(urllib.request.urlopen(urllib.request.Request(f"{C}/transferprocesses/{tid}",headers={"x-api-key":"password"})))
    state=st.get("state"); print("transfer:",state)
    if state in ("COMPLETED","TERMINATED"): break
    time.sleep(2)
import boto3
s3=boto3.client("s3",endpoint_url=f"http://localhost:{MOTO}",aws_access_key_id="minioadmin",aws_secret_access_key="minioadmin",region_name="us-east-1")
objs=[o["Key"] for o in s3.list_objects_v2(Bucket="consumer-bucket").get("Contents",[])]
print("consumer-bucket:",objs)
print(">>> TRANSFER VERIFIED" if "example-s3.txt" in objs else ">>> TRANSFER NOT VERIFIED")
PY
