#!/usr/bin/env python3
# ============================================================================
# edc011-dcp-transfer.py — increment E, Stage 3: a DSP transfer between two Simpl
# connectors that is GATED by a DCP-verified SimplDataspaceMembershipCredential.
#
# Pieces (all native EDC 0.11.1, no mocks):
#   - three EC P-256 keys: Governance Authority (issuer), provider connector, consumer connector;
#   - did:web documents for all three, served over http on :7100; the connector documents list a
#     CredentialService endpoint on the IdentityHub;
#   - GA-signed JWT Verifiable Credentials (SimplDataspaceMembershipCredential, subject = connector DID,
#     claim identityAttributes) seeded into one IdentityHub that hosts both participants;
#   - both connectors built from connector-be + connector-dcp-0.11.patch: EDC's DCP IdentityService with
#     the embedded STS (key supplied through config), plus SimplDcpExtension, which requires the
#     membership scope on every DSP request and maps the verified credential's identityAttributes onto
#     Simpl's `identity_attributes` claim, so Simpl's existing edc:consumption ABAC rule decides.
#
# Scenarios (each on fresh databases and freshly booted runtimes):
#   positive          credential with CONSUMER         -> transfer COMPLETED, file delivered
#   abac-deny         credential with DATA_SEARCHER    -> catalog OK, negotiation TERMINATED
#   untrusted-issuer  provider trusts another issuer   -> catalog request rejected
#   no-credential     consumer holds no credential     -> catalog request rejected
#
# Run with the moto venv python (it has boto3 + cryptography):
#   ../../motoenv/bin/python edc011-dcp-transfer.py        (or set SCENARIOS=positive,abac-deny)
# ============================================================================
import base64, json, os, re, signal, subprocess, sys, threading, time, urllib.error, urllib.request, uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.abspath(os.path.join(HERE, "..", ".."))
CONN = os.environ.get("CONN_DIR", os.path.join(LAB, "src", "connector-be"))
CONN_JAR = os.path.join(CONN, "target", "basic-connector.jar")
IH_JAR = os.environ.get("IH_JAR", os.path.join(LAB, "src", "identityhub", "launcher", "identityhub", "build", "libs", "identity-hub.jar"))
IH_EXT = os.environ.get("EXT_JAR", os.path.join(HERE, "seed-extension", "seed-extension.jar"))
RUN = os.environ.get("RUN_DIR", "/tmp/edc011-dcp")
MOTO_BIN = os.path.join(LAB, "motoenv", "bin", "moto_server")
PG_PORT, MOTO_PORT, DID_PORT, IH_API = 5433, 9000, 7100, 8090
SCOPE = "org.eclipse.edc.vc.type:SimplDataspaceMembershipCredential:read"
os.makedirs(RUN, exist_ok=True)


def did(name):
    return f"did:web:localhost%3A{DID_PORT}:{name}"


GA, OTHER_GA, PROV, CONS = did("ga"), did("other-ga"), did("provider"), did("consumer")

# ---------------------------------------------------------------- keys, DIDs, credentials
b64u = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
i2b = lambda n: n.to_bytes(32, "big")


def gen_key():
    k = ec.generate_private_key(ec.SECP256R1())
    n = k.private_numbers(); pn = n.public_numbers
    pub = {"kty": "EC", "crv": "P-256", "x": b64u(i2b(pn.x)), "y": b64u(i2b(pn.y))}
    priv = dict(pub); priv["d"] = b64u(i2b(n.private_value))
    return {"key": k, "priv": priv, "pub": pub}


def jwt(key, kid, claims):
    hdr = {"alg": "ES256", "typ": "JWT", "kid": kid}
    si = (b64u(json.dumps(hdr).encode()) + "." + b64u(json.dumps(claims).encode())).encode()
    r, s = decode_dss_signature(key.sign(si, ec.ECDSA(hashes.SHA256())))
    return si.decode() + "." + b64u(i2b(r) + i2b(s))


KEYS = {n: gen_key() for n in ("ga", "provider", "consumer")}
IH_PARTICIPANT = {"provider": "provider", "consumer": "consumer"}  # IdentityHub participant ids


def cs_endpoint(pid):
    return f"http://localhost:8182/api/resolution/v1/participants/{base64.urlsafe_b64encode(pid.encode()).decode()}"


def did_doc(d, pub, service=None):
    vm = d + "#key-1"
    doc = {"@context": ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/suites/jws-2020/v1"],
           "id": d,
           "verificationMethod": [{"id": vm, "type": "JsonWebKey2020", "controller": d, "publicKeyJwk": pub}],
           "authentication": [vm], "assertionMethod": [vm]}
    if service:
        doc["service"] = [{"id": d + "#credential-service", "type": "CredentialService", "serviceEndpoint": service}]
    return doc


DOCS = {
    "/ga/did.json": did_doc(GA, KEYS["ga"]["pub"]),
    "/provider/did.json": did_doc(PROV, KEYS["provider"]["pub"], cs_endpoint("provider")),
    "/consumer/did.json": did_doc(CONS, KEYS["consumer"]["pub"], cs_endpoint("consumer")),
}

VC_CONTEXT = ["https://www.w3.org/2018/credentials/v1",
              {"simpl": "https://w3id.org/simpl/v1#",
               "SimplDataspaceMembershipCredential": "simpl:SimplDataspaceMembershipCredential",
               "identityAttributes": {"@id": "simpl:identityAttributes", "@container": "@set"}}]


def mint_vc(holder, attributes):
    now = datetime.now(timezone.utc)
    vc = {"@context": VC_CONTEXT, "id": f"urn:uuid:{uuid.uuid4()}",
          "type": ["VerifiableCredential", "SimplDataspaceMembershipCredential"],
          "issuer": GA, "issuanceDate": (now - timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
          "expirationDate": (now + timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"),
          "credentialSubject": {"id": holder, "identityAttributes": attributes}}
    claims = {"iss": GA, "sub": holder, "jti": vc["id"], "iat": int(now.timestamp()) - 60,
              "nbf": int(now.timestamp()) - 60, "exp": int((now + timedelta(days=30)).timestamp()), "vc": vc}
    return jwt(KEYS["ga"]["key"], GA + "#key-1", claims)


class DidHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(DOCS[self.path]).encode() if self.path in DOCS else None
        self.send_response(200 if body else 404)
        if body:
            self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, *a):
        pass


# ---------------------------------------------------------------- process + infra helpers
BASE_ENV = {k: v for k, v in os.environ.items() if k not in (
    "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "NO_PROXY", "no_proxy", "ALL_PROXY", "all_proxy",
    "JAVA_TOOL_OPTIONS")}
BASE_ENV["PATH"] = "/usr/lib/postgresql/16/bin:" + BASE_ENV.get("PATH", "/usr/bin:/bin")
PROCS = {}
PORTS = [IH_API, 8181, 8182, 8183, 8184, 19191, 19192, 19193, 19194, 19291, 29191, 29192, 29193, 29194, 29291]


def log(msg):
    print(f"\033[1;34m[dcp-transfer]\033[0m {msg}", flush=True)


def start(name, cmd, env, cwd):
    f = open(os.path.join(RUN, name + ".log"), "w")
    PROCS[name] = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT, preexec_fn=os.setsid)


def stop_all():
    for p in PROCS.values():
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        except Exception:
            pass
    PROCS.clear()
    for port in PORTS:
        subprocess.run(["fuser", "-k", f"{port}/tcp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)


def wait_log(name, ok, bad=("EdcInjectionException", "Exception in thread \"main\""), timeout=120):
    path = os.path.join(RUN, name + ".log")
    t0 = time.time()
    while time.time() - t0 < timeout:
        txt = open(path, errors="replace").read() if os.path.exists(path) else ""
        if re.search(ok, txt):
            return True
        for b in bad:
            if b in txt:
                raise RuntimeError(f"{name} failed to boot ({b}); see {path}")
        if PROCS.get(name) and PROCS[name].poll() is not None:
            raise RuntimeError(f"{name} exited early; see {path}")
        time.sleep(1.5)
    raise RuntimeError(f"{name} not ready after {timeout}s; see {path}")


def http(method, url, body=None, key="password"):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json", "x-api-key": key})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip().startswith(("{", "[")) else raw)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def psql(sql, db="postgres"):
    env = dict(BASE_ENV, PGPASSWORD="postgres")
    return subprocess.run(["psql", "-h", "127.0.0.1", "-p", str(PG_PORT), "-U", "postgres", "-d", db, "-qtc", sql],
                          env=env, capture_output=True, text=True)


def ensure_postgres():
    if psql("select 1").returncode == 0:
        return
    pgdata = "/var/lib/postgresql/lab-pgdata"
    env = dict(BASE_ENV, PATH="/usr/lib/postgresql/16/bin:" + BASE_ENV.get("PATH", ""))
    if not os.path.isdir(pgdata):
        os.makedirs(pgdata); subprocess.run(["chown", "-R", "postgres:postgres", pgdata]); os.chmod(pgdata, 0o700)
        subprocess.run(["runuser", "-u", "postgres", "--", "initdb", "-D", pgdata, "-A", "trust"], env=env, capture_output=True)
    subprocess.run(["runuser", "-u", "postgres", "--", "pg_ctl", "-D", pgdata, "-o", f"-p {PG_PORT} -c listen_addresses=127.0.0.1",
                    "-l", pgdata + "/server.log", "start"], env=env, capture_output=True)
    time.sleep(3)
    subprocess.run(["runuser", "-u", "postgres", "--", "psql", "-p", str(PG_PORT), "-d", "postgres", "-c",
                    "ALTER USER postgres PASSWORD 'postgres';"], env=env, capture_output=True)


def reset_dbs():
    for db in ("dcp_provider", "dcp_consumer"):
        psql(f"DROP DATABASE IF EXISTS {db} WITH (FORCE);")
        psql(f"CREATE DATABASE {db};")


def s3():
    import boto3
    return boto3.client("s3", endpoint_url=f"http://localhost:{MOTO_PORT}", aws_access_key_id="minioadmin",
                        aws_secret_access_key="minioadmin", region_name="us-east-1")


def ensure_moto():
    try:
        urllib.request.urlopen(f"http://localhost:{MOTO_PORT}/", timeout=2)
    except Exception:
        subprocess.Popen([MOTO_BIN, "-p", str(MOTO_PORT), "-H", "127.0.0.1"], cwd=LAB, env=BASE_ENV,
                         stdout=open(os.path.join(RUN, "moto.log"), "w"), stderr=subprocess.STDOUT, preexec_fn=os.setsid)
        for _ in range(30):
            try:
                urllib.request.urlopen(f"http://localhost:{MOTO_PORT}/", timeout=2); break
            except Exception:
                time.sleep(1)
    c = s3()
    for b in ("provider-bucket", "consumer-bucket"):
        try:
            c.create_bucket(Bucket=b)
        except Exception:
            pass
    c.put_object(Bucket="provider-bucket", Key="example-s3.txt", Body=b"Delivered under a DCP-verified Simpl membership credential.\n")


def consumer_objects():
    return [o["Key"] for o in s3().list_objects_v2(Bucket="consumer-bucket").get("Contents", [])]


# ---------------------------------------------------------------- runtimes
def boot_identityhub(consumer_attrs):
    seed = [
        {"id": "provider", "did": PROV, "privateJwk": json.dumps(KEYS["provider"]["priv"]), "publicJwk": json.dumps(KEYS["provider"]["pub"]),
         "rawVc": mint_vc(PROV, ["DATA_PROVIDER"]), "issuer": GA, "attributes": ["DATA_PROVIDER"]},
        {"id": "consumer", "did": CONS, "privateJwk": json.dumps(KEYS["consumer"]["priv"]), "publicJwk": json.dumps(KEYS["consumer"]["pub"]),
         "rawVc": mint_vc(CONS, consumer_attrs) if consumer_attrs is not None else None, "issuer": GA,
         "attributes": consumer_attrs or []},
    ]
    env = dict(BASE_ENV, **{
        "WEB_HTTP_PORT": str(IH_API), "WEB_HTTP_PATH": "/api",
        "WEB_HTTP_IDENTITY_PORT": "8181", "WEB_HTTP_IDENTITY_PATH": "/api/identity",
        "WEB_HTTP_PRESENTATION_PORT": "8182", "WEB_HTTP_PRESENTATION_PATH": "/api/resolution",
        "WEB_HTTP_STS_PORT": "8183", "WEB_HTTP_STS_PATH": "/api/sts",
        "WEB_HTTP_ACCOUNTS_PORT": "8184", "WEB_HTTP_ACCOUNTS_PATH": "/api/accounts",
        "EDC_IH_IAM_ID": "did:web:localhost", "EDC_API_ACCOUNTS_KEY": "password",
        "EDC_IAM_ACCESSTOKEN_JTI_VALIDATION": "false", "EDC_SQL_SCHEMA_AUTOCREATE": "true",
        "EDC_IAM_DID_WEB_USE_HTTPS": "false", "SIMPL_SEED_JSON": json.dumps(seed)})
    start("identityhub", ["java", "-cp", f"{IH_JAR}:{IH_EXT}", "org.eclipse.edc.boot.system.runtime.BaseRuntime"],
          env, os.path.dirname(IH_JAR))
    wait_log("identityhub", r"\[SIMPL-SEED\] done \(multi\)")


def boot_connector(role, my_did, key, trusted_issuer):
    db = "dcp_provider" if role == "provider" else "dcp_consumer"
    props = {
        "edc.fs.config": os.path.join(CONN, "local", f"{role}-config.properties"),
        "edc.participant.id": my_did, "edc.iam.issuer.id": my_did,
        "edc.iam.sts.privatekey.alias": "simpl.sts.key", "edc.iam.sts.publickey.id": my_did + "#key-1",
        "simpl.sts.key": json.dumps(key["priv"]),
        "edc.iam.did.web.use.https": "false", "edc.iam.accesstoken.jti.validation": "false",
        "edc.iam.trusted-issuer.ga.id": trusted_issuer,
        "edc.datasource.default.url": f"jdbc:postgresql://localhost:{PG_PORT}/{db}",
        "edc.datasource.policy.url": f"jdbc:postgresql://localhost:{PG_PORT}/{db}",
        "edc.api.auth.key": "password",
    }
    env = dict(BASE_ENV, EDC_DATASOURCE_DEFAULT_PASSWORD="postgres", EDC_DATASOURCE_POLICY_PASSWORD="postgres")
    extra = [f"--log-level={os.environ['EDC_LOG_LEVEL']}"] if os.environ.get("EDC_LOG_LEVEL") else []
    start(role, ["java"] + [f"-D{k}={v}" for k, v in props.items()] + ["-jar", CONN_JAR] + extra, env, CONN)


# ---------------------------------------------------------------- the DSP flow
P, C = "http://localhost:19193/management/v3", "http://localhost:29193/management/v3"
PROTO = "http://localhost:19194/protocol"
V = {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}
CONSTRAINT = {"@type": "AtomicConstraint", "leftOperand": "https://w3id.org/edc/v0.0.1/ns/consumption",
              "operator": {"@id": "odrl:eq"}, "rightOperand": "CONSUMER"}


def provider_offer():
    http("POST", f"{P}/assets", {"@context": V, "@id": "dcp-asset", "properties": {"name": "DCP-gated S3 file"},
         "dataAddress": {"type": "MinioS3", "bucketName": "provider-bucket", "objectName": "example-s3.txt",
                         "endpoint": f"http://localhost:{MOTO_PORT}", "region": "us-east-1",
                         "accessKeyId": "minioadmin", "secretAccessKey": "minioadmin"}})
    http("POST", f"{P}/policydefinitions", {"@context": V, "@id": "open-access", "policy": {
        "@context": "http://www.w3.org/ns/odrl.jsonld", "@type": "Set", "permission": [{"action": "use"}]}})
    http("POST", f"{P}/policydefinitions", {"@context": {**V, "odrl": "http://www.w3.org/ns/odrl/2/"}, "@id": "consumer-only",
         "policy": {"@context": "http://www.w3.org/ns/odrl.jsonld", "@type": "Set",
                    "permission": [{"action": "use", "constraint": CONSTRAINT}]}})
    http("POST", f"{P}/contractdefinitions", {"@context": V, "@id": "dcp-def", "accessPolicyId": "open-access",
         "contractPolicyId": "consumer-only", "assetsSelector": []})


def run_flow():
    """Returns (stage_reached, outcome, detail)."""
    code, cat = http("POST", f"{C}/catalog/request", {"@context": V, "@type": "CatalogRequest", "counterPartyAddress": PROTO,
                                                       "counterPartyId": PROV, "protocol": "dataspace-protocol-http"})
    if code != 200 or not isinstance(cat, dict):
        return "catalog", "REJECTED", f"HTTP {code}: {str(cat)[:220]}"
    ds = cat.get("dcat:dataset")
    ds = next((d for d in (ds if isinstance(ds, list) else [ds]) if d and d.get("@id") == "dcp-asset"), None)
    if not ds:
        return "catalog", "NO-OFFER", json.dumps(cat)[:220]
    off = ds["odrl:hasPolicy"]; off = off[0] if isinstance(off, list) else off
    policy = {"@context": "http://www.w3.org/ns/odrl.jsonld", "@id": off["@id"], "@type": "Offer", "assigner": PROV,
              "target": "dcp-asset", "permission": [{"action": "use", "constraint": CONSTRAINT}]}
    code, neg = http("POST", f"{C}/contractnegotiations", {"@context": {**V, "odrl": "http://www.w3.org/ns/odrl/2/"},
                     "@type": "ContractRequest", "counterPartyAddress": PROTO, "protocol": "dataspace-protocol-http", "policy": policy})
    if code != 200:
        return "negotiation", "REJECTED", f"HTTP {code}: {str(neg)[:220]}"
    nid, st = neg["@id"], {}
    for _ in range(40):
        _, st = http("GET", f"{C}/contractnegotiations/{nid}")
        if st.get("state") in ("FINALIZED", "TERMINATED"):
            break
        time.sleep(1.5)
    if st.get("state") != "FINALIZED":
        return "negotiation", st.get("state", "?"), str(st.get("errorDetail", ""))[:220]
    code, tr = http("POST", f"{C}/transferprocesses", {"@context": V, "@type": "TransferRequest", "counterPartyAddress": PROTO,
                    "protocol": "dataspace-protocol-http", "contractId": st["contractAgreementId"], "assetId": "dcp-asset",
                    "transferType": "MinioS3-PUSH", "dataDestination": {
                        "type": "MinioS3", "bucketName": "consumer-bucket", "objectName": "example-s3.txt",
                        "endpoint": f"http://localhost:{MOTO_PORT}", "region": "us-east-1",
                        "accessKeyId": "minioadmin", "secretAccessKey": "minioadmin"}})
    if code != 200:
        return "transfer", "REJECTED", f"HTTP {code}: {str(tr)[:220]}"
    tid, ts = tr["@id"], {}
    for _ in range(40):
        _, ts = http("GET", f"{C}/transferprocesses/{tid}")
        if ts.get("state") in ("COMPLETED", "TERMINATED"):
            break
        time.sleep(1.5)
    objs = consumer_objects()
    return "transfer", ts.get("state", "?"), f"agreement {st['contractAgreementId'][:8]}…, consumer-bucket={objs}"


def evidence(role):
    txt = open(os.path.join(RUN, role + ".log"), errors="replace").read()
    lines = [l.strip() for l in txt.splitlines() if "[SIMPL-DCP] verified" in l]
    errs = [l.strip() for l in txt.splitlines() if any(k in l for k in (
        "No VerifiableCredentials", "not trusted", "Credential is not trusted", "issuer", "Unauthorized"))
        and ("WARNING" in l or "SEVERE" in l or "DEBUG" in l)]
    return lines, errs


SCENARIOS = [
    # name, consumer attributes (None = no credential), issuer the PROVIDER trusts, expectation
    ("positive", ["CONSUMER", "DATA_SEARCHER"], GA, ("transfer", "COMPLETED")),
    ("abac-deny", ["DATA_SEARCHER"], GA, ("negotiation", "TERMINATED")),
    ("untrusted-issuer", ["CONSUMER"], OTHER_GA, ("catalog", "REJECTED")),
    ("no-credential", None, GA, ("catalog", "REJECTED")),
]


def main():
    wanted = [s.strip() for s in os.environ.get("SCENARIOS", "").split(",") if s.strip()]
    for f in (CONN_JAR, IH_JAR, IH_EXT):
        if not os.path.exists(f):
            sys.exit(f"missing {f} — build connector-be with the DCP patch and the seed extension first")
    httpd = ThreadingHTTPServer(("0.0.0.0", DID_PORT), DidHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log(f"did:web documents on :{DID_PORT} — GA {GA}, provider {PROV}, consumer {CONS}")
    ensure_postgres()
    ensure_moto()
    results = []
    try:
        for name, attrs, trusted, expect in SCENARIOS:
            if wanted and name not in wanted:
                continue
            log(f"=== scenario {name}: consumer credential {attrs if attrs is not None else 'NONE'}; provider trusts {trusted.split(':')[-1]}")
            stop_all(); reset_dbs()
            try:
                s3().delete_object(Bucket="consumer-bucket", Key="example-s3.txt")
            except Exception:
                pass
            boot_identityhub(attrs)
            boot_connector("provider", PROV, KEYS["provider"], trusted)
            boot_connector("consumer", CONS, KEYS["consumer"], GA)
            wait_log("provider", r"Runtime \S+ ready"); wait_log("consumer", r"Runtime \S+ ready")
            provider_offer()
            stage, outcome, detail = run_flow()
            ok = (stage, outcome) == expect
            pv, pe = evidence("provider"); cv, _ = evidence("consumer")
            log(f"    -> {stage}: {outcome}  ({detail})")
            for l in (pv[:1] + cv[:1]):
                log("       evidence: " + l[l.find('[SIMPL-DCP]'):][:200])
            for l in pe[:2]:
                log("       provider: " + l[:200])
            log(f"    {'PASS' if ok else 'FAIL'} (expected {expect[0]} {expect[1]})")
            results.append((name, stage, outcome, ok))
    finally:
        stop_all()
        httpd.shutdown()
    print("\nscenario           reached       outcome      result")
    for name, stage, outcome, ok in results:
        print(f"{name:<18} {stage:<13} {outcome:<12} {'PASS' if ok else 'FAIL'}")
    print(f"\nlogs: {RUN}/{{identityhub,provider,consumer}}.log")
    sys.exit(0 if results and all(r[3] for r in results) else 1)


if __name__ == "__main__":
    main()
