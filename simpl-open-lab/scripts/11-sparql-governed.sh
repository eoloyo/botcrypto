#!/usr/bin/env bash
# GOVERNED SPARQL THROUGH THE EDC CONNECTOR — no new connector code, just config.
#
# Proves the near-term "PPDS knowledge graph as a governed data product" claim: a consumer
# discovers a SPARQL data service in the connector's catalogue, negotiates a CONTRACT, and the
# provider connector's data-plane fetches the SPARQL results and delivers them under that
# agreement. The data is REAL: the live EU Public Procurement / Publications Office (Cellar)
# SPARQL endpoint, modelled in the eProcurement Ontology (ePO).
#
# Mechanism (all stock Simpl basic-connector — only an HttpData asset + policy + contract-def):
#   consumer: catalog/request -> contractnegotiations -> transferprocesses (HttpData-PUSH)
#   provider data-plane: GET <sparql-endpoint?query=…>  ->  PUSH the results to the consumer sink
#
# Honest scope: this basic-connector build ships the HTTP data-plane but NOT the
# DataPlaneAuthorizationService needed for consumer-PULL (dynamic per-request queries with an EDR
# token) — so the query is baked into the asset and delivered by PUSH. Dynamic querying and true
# federation (Catena-X Knowledge Agents / CX-0084) are the connector-extension work on top.
#
# Two localhost helpers bridge the sandbox only (the connector runs proxy-unset, so it reaches
# localhost, not the internet): a SHIM forwards the query to the live EU endpoint; a SINK captures
# the pushed results. In a real deployment the provider connector sits next to the KG and the
# consumer has its own data sink — neither helper is part of the pattern.
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
CONN="$LAB_ROOT/src/connector-be"; JAR="$CONN/target/basic-connector.jar"
SHIM_PORT=8777; SINK_PORT=8778
UPSTREAM="http://publications.europa.eu/webapi/rdf/sparql"
[ -f "$JAR" ] || { log "connector jar missing — run 02-dataspace.sh first"; exit 1; }
noenv(){ env -u JAVA_TOOL_OPTIONS -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
         -u NO_PROXY -u no_proxy -u ALL_PROXY -u all_proxy "$@"; }

# ── 0. Postgres (connector store) ─────────────────────────────────────────────────────
PGDATA=/var/lib/postgresql/lab-pgdata
if ! PGPASSWORD=postgres psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -c 'select 1' >/dev/null 2>&1; then
  [ -d "$PGDATA" ] || { mkdir -p "$PGDATA"; chown -R postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"; runuser -u postgres -- initdb -D "$PGDATA" -A trust >/dev/null; }
  runuser -u postgres -- pg_ctl -D "$PGDATA" -o "-p $PG_PORT -c listen_addresses=127.0.0.1" -l "$PGDATA/server.log" start >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "ALTER USER postgres PASSWORD 'postgres';" >/dev/null 2>&1 || true
fi
runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE providerdb;" 2>/dev/null || true
log "Postgres up on :$PG_PORT"

# ── 1. SHIM (query -> live EU endpoint) and SINK (capture pushed results) ──────────────
cat > "$RUN/sparql_shim.py" <<PY
import http.server,socketserver,urllib.request,urllib.parse
UP="$UPSTREAM"
class H(http.server.BaseHTTPRequestHandler):
    def q(self):
        if self.command=="POST":
            b=self.rfile.read(int(self.headers.get("Content-Length",0))).decode("utf-8","replace")
            return urllib.parse.parse_qs(b).get("query",[b])[0]
        return urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("query",[""])[0]
    def go(self):
        try:
            out=urllib.request.urlopen(urllib.request.Request(UP,data=urllib.parse.urlencode({"query":self.q()}).encode(),headers={"Accept":"application/sparql-results+json"}),timeout=45).read()
            self.send_response(200);self.send_header("Content-Type","application/sparql-results+json");self.send_header("Content-Length",str(len(out)));self.end_headers();self.wfile.write(out)
        except Exception as e:
            m=str(e).encode();self.send_response(502);self.send_header("Content-Length",str(len(m)));self.end_headers();self.wfile.write(m)
    def do_GET(self):self.go()
    def do_POST(self):self.go()
    def log_message(self,*a):pass
socketserver.TCPServer.allow_reuse_address=True
socketserver.TCPServer(("127.0.0.1",$SHIM_PORT),H).serve_forever()
PY
cat > "$RUN/sparql_sink.py" <<PY
import http.server,socketserver
OUT="$RUN/sparql_sink_out.json"
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        te=(self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in te:
            body=b""
            while True:
                s=int(self.rfile.readline().strip() or b"0",16)
                if s==0:self.rfile.readline();break
                body+=self.rfile.read(s);self.rfile.readline()
        else:
            body=self.rfile.read(int(self.headers.get("Content-Length",0)))
        open(OUT,"wb").write(body);self.send_response(200);self.send_header("Content-Length","2");self.end_headers();self.wfile.write(b"ok")
    def do_PUT(self):self.do_POST()
    def log_message(self,*a):pass
socketserver.TCPServer.allow_reuse_address=True
socketserver.TCPServer(("127.0.0.1",$SINK_PORT),H).serve_forever()
PY
fuser -k "$SHIM_PORT/tcp" "$SINK_PORT/tcp" 2>/dev/null || true; sleep 1
setsid python3 "$RUN/sparql_shim.py" >"$RUN/sparql_shim.log" 2>&1 & disown
setsid python3 "$RUN/sparql_sink.py" >"$RUN/sparql_sink.log" 2>&1 & disown
sleep 2
rm -f "$RUN/sparql_sink_out.json"
curl -s -m 45 --data-urlencode 'query=ASK { ?s ?p ?o }' "http://127.0.0.1:$SHIM_PORT/sparql" | grep -q '"boolean": true' \
  && log "SPARQL shim reaches the live EU endpoint (ASK -> true)" || { log "shim cannot reach EU endpoint"; exit 1; }

# ── 2. connectors (provider + consumer) ───────────────────────────────────────────────
sed -i 's#jdbc:postgresql://localhost:5432/postgres#jdbc:postgresql://localhost:'"$PG_PORT"'/providerdb#g' "$CONN/local/provider-config.properties" 2>/dev/null || true
up(){ curl -s -o /dev/null -H 'x-api-key: password' -X POST "http://localhost:$1/management/v3/assets/request" -H 'Content-Type: application/json' -d '{}'; }
up "$PROVIDER_MGMT" || EDC_DATASOURCE_DEFAULT_PASSWORD=postgres EDC_DATASOURCE_POLICY_PASSWORD=postgres \
  setsid noenv java -Dedc.fs.config="$CONN/local/provider-config.properties" -jar "$JAR" </dev/null >"$RUN/provider-edc.log" 2>&1 & disown
up "$CONSUMER_MGMT" || EDC_DATASOURCE_DEFAULT_PASSWORD=postgres \
  setsid noenv java -Dedc.fs.config="$CONN/local/consumer-config.properties" -jar "$JAR" </dev/null >"$RUN/consumer-edc.log" 2>&1 & disown
for _ in $(seq 1 60); do up "$PROVIDER_MGMT" && up "$CONSUMER_MGMT" && break; sleep 2; done
log "connectors up (provider :$PROVIDER_MGMT, consumer :$CONSUMER_MGMT)"

# ── 3. provider registers the SPARQL endpoint as an HttpData asset (query baked in) ────
P="http://localhost:$PROVIDER_MGMT/management/v3"; H=(-H "Content-Type: application/json" -H "x-api-key: password")
V='{"@vocab":"https://w3id.org/edc/v0.0.1/ns/"}'
SPARQL='PREFIX epo:<http://data.europa.eu/a4g/ontology#> SELECT (COUNT(*) AS ?procedures) WHERE { ?s a epo:Procedure }'
BASEURL=$(python3 -c "import urllib.parse,sys;print('http://localhost:$SHIM_PORT/sparql?'+urllib.parse.urlencode({'query':sys.argv[1]}))" "$SPARQL")
curl -s "${H[@]}" -X POST "$P/assets" -d '{"@context":'"$V"',"@id":"ppds-sparql-push","properties":{"name":"PPDS procurement count (ePO SPARQL)","ontology":"eProcurement Ontology"},"dataAddress":{"type":"HttpData","baseUrl":"'"$BASEURL"'","method":"GET"}}' >/dev/null || true
curl -s "${H[@]}" -X POST "$P/policydefinitions" -d '{"@context":'"$V"',"@id":"ppds-open","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@type":"Set","permission":[{"action":"use"}]}}' >/dev/null || true
# target ONLY this asset so leftover broad contract-defs from 02/09 don't offer it under a different policy
curl -s "${H[@]}" -X POST "$P/contractdefinitions" -d '{"@context":'"$V"',"@id":"ppds-sparql-cdef","accessPolicyId":"ppds-open","contractPolicyId":"ppds-open","assetsSelector":[{"operandLeft":"https://w3id.org/edc/v0.0.1/ns/id","operator":"=","operandRight":"ppds-sparql-push"}]}' >/dev/null || true
log "provider: HttpData(SPARQL) asset + open policy + dedicated contract-def registered"

# ── 4. consumer: discover -> negotiate -> transfer(PUSH) -> read the delivered results ─
noenv python3 - "http://localhost:$CONSUMER_MGMT/management/v3" "http://localhost:$PROVIDER_DSP/protocol" "$RUN/sparql_sink_out.json" <<'PY'
import sys,json,time,urllib.request
C,PROTO,OUT=sys.argv[1],sys.argv[2],sys.argv[3]; ASSET="ppds-sparql-push"
def call(u,b): return json.load(urllib.request.urlopen(urllib.request.Request(u,data=json.dumps(b).encode(),headers={"Content-Type":"application/json","x-api-key":"password"})))
def get(u):    return json.load(urllib.request.urlopen(urllib.request.Request(u,headers={"x-api-key":"password"})))
V={"@vocab":"https://w3id.org/edc/v0.0.1/ns/"}
cat=call(f"{C}/catalog/request",{"@context":V,"@type":"CatalogRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http"})
dsl=cat["dcat:dataset"]; dsl=dsl if isinstance(dsl,list) else [dsl]
ds=next(d for d in dsl if (d.get("@id") or d.get("id"))==ASSET)
offs=ds["odrl:hasPolicy"]; offs=offs if isinstance(offs,list) else [offs]
# pick an OPEN offer (no constraint) so the request policy matches what the provider offers
def constrained(o):
    return any(p.get("odrl:constraint") or p.get("constraint") for p in (o.get("odrl:permission") if isinstance(o.get("odrl:permission"),list) else [o.get("odrl:permission")] if o.get("odrl:permission") else []))
off=next((o for o in offs if not constrained(o)), offs[0])
print("1) discovered SPARQL data service in catalogue; offer:",off["@id"][:44],"...")
neg=call(f"{C}/contractnegotiations",{"@context":{**V,"odrl":"http://www.w3.org/ns/odrl/2/"},"@type":"ContractRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http","policy":{"@context":"http://www.w3.org/ns/odrl.jsonld","@id":off["@id"],"@type":"Offer","assigner":"provider","target":ASSET,"permission":[{"action":"use"}],"prohibition":[],"obligation":[]}})
nid=neg["@id"]; ag=None
for _ in range(30):
    st=get(f"{C}/contractnegotiations/{nid}"); ag=st.get("contractAgreementId")
    if ag or st.get("state")=="TERMINATED": break
    time.sleep(2)
print("2) contract agreement:",ag); assert ag,"no agreement"
tr=call(f"{C}/transferprocesses",{"@context":V,"@type":"TransferRequest","counterPartyAddress":PROTO,"protocol":"dataspace-protocol-http","contractId":ag,"assetId":ASSET,"transferType":"HttpData-PUSH","dataDestination":{"type":"HttpData","baseUrl":"http://localhost:8778/","method":"POST"}})
tid=tr["@id"]; ts=None
for _ in range(30):
    ts=get(f"{C}/transferprocesses/{tid}").get("state")
    if ts in ("COMPLETED","TERMINATED"): break
    time.sleep(2)
print("3) transfer state:",ts); assert ts=="COMPLETED","transfer "+str(ts)
time.sleep(1); d=json.load(open(OUT)); n=d["results"]["bindings"][0]["procedures"]["value"]
print("4) GOVERNED SPARQL VERIFIED — real EU ePO procurement data via the connector under contract")
print("   epo:Procedure count =",n)
PY
log "governed SPARQL-through-the-connector complete."
