#!/usr/bin/env python3
# ============================================================================
# edc011-present.py — fully-verified DCP Presentation Flow on native EDC 0.11.
#
# Orchestrates a real DCP presentation against the Eclipse EDC 0.11 IdentityHub:
#   - generates an EC P-256 key for the PROVIDER (the IdentityHub participant that
#     holds the credential) and for the VERIFIER (the caller);
#   - hosts both DID documents as did:web over http (port 7100);
#   - boots the IdentityHub with the Simpl seed extension, injecting the provider
#     key + the provider/verifier DIDs so the participant is created with a key we
#     control and a resolvable DID;
#   - builds the DCP self-issued token exactly as EDC's JwtCreationUtil.generateSiToken
#     does (an SI token signed by the verifier key, wrapping an access token signed by
#     the provider key that carries the requested scope);
#   - POSTs the PresentationQueryMessage for the SimplDataspaceMembershipCredential and
#     reads back a Verifiable Presentation.
#
# Prereqs: identity-hub.jar + seed-extension.jar built (run edc011-identityhub.sh once),
#          python3 `cryptography`, JDK on PATH. Self-contained; no Simpl mesh.
# ============================================================================
import os, sys, json, base64, time, subprocess, threading, urllib.request, urllib.parse, signal
from http.server import BaseHTTPRequestHandler, HTTPServer
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives import hashes

HERE = os.path.dirname(os.path.abspath(__file__))
JAR = os.environ.get("IH_JAR", f"{HERE}/../../src/identityhub/launcher/identityhub/build/libs/identity-hub.jar")
EXT = os.environ.get("EXT_JAR", f"{HERE}/seed-extension/seed-extension.jar")
SCRATCH = "/tmp/claude-0/-home-user-botcrypto/4a0d9b60-0ac8-5e05-a42d-82e53b1735bc/scratchpad"
DID_PORT = 7100
SCOPE = "org.eclipse.edc.vc.type:SimplDataspaceMembershipCredential:read"
PROVIDER_DID = f"did:web:localhost%3A{DID_PORT}:simpl-provider"
VERIFIER_DID = f"did:web:localhost%3A{DID_PORT}:verifier"

b64u = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
i2b = lambda n: n.to_bytes(32, "big")

def gen_key():
    k = ec.generate_private_key(ec.SECP256R1())
    n = k.private_numbers(); pn = n.public_numbers
    pub = {"kty": "EC", "crv": "P-256", "x": b64u(i2b(pn.x)), "y": b64u(i2b(pn.y))}
    priv = dict(pub); priv["d"] = b64u(i2b(n.private_value))
    return k, priv, pub

def did_doc(did, pub):
    vm = did + "#key-1"
    return {"@context": ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/suites/jws-2020/v1"],
            "id": did,
            "verificationMethod": [{"id": vm, "type": "JsonWebKey2020", "controller": did, "publicKeyJwk": pub}],
            "authentication": [vm], "assertionMethod": [vm]}

def jwt(priv_key, kid, claims):
    hdr = {"alg": "ES256", "typ": "JWT", "kid": kid}
    si = (b64u(json.dumps(hdr).encode()) + "." + b64u(json.dumps(claims).encode())).encode()
    r, s = decode_dss_signature(priv_key.sign(si, ec.ECDSA(hashes.SHA256())))
    return si.decode() + "." + b64u(i2b(r) + i2b(s))

# ---- keys + DID documents ----
prov_key, prov_priv, prov_pub = gen_key()
ver_key, ver_priv, ver_pub = gen_key()
DOCS = {"/simpl-provider/did.json": did_doc(PROVIDER_DID, prov_pub),
        "/verifier/did.json": did_doc(VERIFIER_DID, ver_pub)}

class DidHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in DOCS:
            body = json.dumps(DOCS[self.path]).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass

httpd = HTTPServer(("0.0.0.0", DID_PORT), DidHandler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
print(f"1) did:web server on :{DID_PORT} serving provider + verifier DID docs")

# ---- boot IdentityHub seeded with the provider key + resolvable DIDs ----
raw_vc = open(f"{SCRATCH}/simpl-vc.jwt").read().strip() if os.path.exists(f"{SCRATCH}/simpl-vc.jwt") else "eyPLACEHOLDER.simpl.jwt"
env = {k: v for k, v in os.environ.items()
       if k not in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "NO_PROXY", "no_proxy",
                    "ALL_PROXY", "all_proxy", "JAVA_TOOL_OPTIONS")}
env.update({
    "WEB_HTTP_PORT": "8080", "WEB_HTTP_PATH": "/api",
    "WEB_HTTP_IDENTITY_PORT": "8181", "WEB_HTTP_IDENTITY_PATH": "/api/identity",
    "WEB_HTTP_PRESENTATION_PORT": "8182", "WEB_HTTP_PRESENTATION_PATH": "/api/resolution",
    "WEB_HTTP_STS_PORT": "8183", "WEB_HTTP_STS_PATH": "/api/sts",
    "WEB_HTTP_ACCOUNTS_PORT": "8184", "WEB_HTTP_ACCOUNTS_PATH": "/api/accounts",
    "EDC_IH_IAM_ID": "did:web:localhost", "EDC_API_ACCOUNTS_KEY": "password",
    "EDC_IAM_ACCESSTOKEN_JTI_VALIDATION": "false", "EDC_SQL_SCHEMA_AUTOCREATE": "true",
    "EDC_IAM_DID_WEB_USE_HTTPS": "false",
    "SIMPL_RAW_VC": raw_vc,
    "SIMPL_PROVIDER_DID": PROVIDER_DID,
    "SIMPL_PROVIDER_PRIVATE_JWK": json.dumps(prov_priv),
    "SIMPL_PROVIDER_PUBLIC_JWK": json.dumps(prov_pub),
})
os.system("fuser -k 8080/tcp 2>/dev/null; sleep 2")
log = open("/tmp/ih-present.log", "w")
proc = subprocess.Popen(["java", "-cp", f"{JAR}:{EXT}", "org.eclipse.edc.boot.system.runtime.BaseRuntime"],
                        cwd=os.path.dirname(JAR), env=env, stdout=log, stderr=subprocess.STDOUT,
                        preexec_fn=os.setsid)
print("2) booting IdentityHub (seeded provider key + DID)…")
for _ in range(45):
    try:
        if urllib.request.urlopen("http://localhost:8080/api/check/health", timeout=2).status == 200:
            break
    except Exception:
        time.sleep(2)
time.sleep(2)

try:
    # ---- DCP self-issued token (== JwtCreationUtil.generateSiToken) ----
    now = int(time.time()); exp = now + 3600
    access = jwt(prov_key, PROVIDER_DID + "#key-1",
                 {"aud": PROVIDER_DID, "iss": PROVIDER_DID, "sub": VERIFIER_DID,
                  "scope": SCOPE, "exp": exp, "jti": "acc-" + str(now)})
    si = jwt(ver_key, VERIFIER_DID + "#key-1",
             {"aud": PROVIDER_DID, "iss": VERIFIER_DID, "sub": VERIFIER_DID,
              "client_id": VERIFIER_DID, "token": access, "exp": exp, "jti": "si-" + str(now)})
    print("3) built DCP self-issued token (SI token wrapping a scoped access token)")

    # ---- presentation query ----
    ctx = base64.urlsafe_b64encode(b"simpl-provider").decode()
    query = {"@context": ["https://identity.foundation/presentation-exchange/submission/v1",
                          "https://w3id.org/tractusx-trust/v0.8"],
             "@type": "PresentationQueryMessage", "scope": [SCOPE]}
    req = urllib.request.Request(
        f"http://localhost:8182/api/resolution/v1/participants/{ctx}/presentations/query",
        data=json.dumps(query).encode(),
        headers={"Content-Type": "application/json", "Authorization": si})
    try:
        resp = urllib.request.urlopen(req, timeout=15).read().decode()
    except urllib.error.HTTPError as e:
        resp = e.read().decode()
        print(f"4) presentation query HTTP {e.code}: {resp[:400]}")
        sys.exit(2)
    print("4) presentation query -> 200")
    d = json.loads(resp)

    def jwt_payload(tok):
        return json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "=" * (-len(tok.split(".")[1]) % 4)))

    # the response carries a JWT Verifiable Presentation; decode it and the embedded VC(s)
    pres = d.get("presentation")
    vp_payload = jwt_payload(pres) if isinstance(pres, str) and pres.count(".") == 2 else pres
    vcs = (vp_payload.get("vp") or {}).get("verifiableCredential", []) if isinstance(vp_payload, dict) else []
    types = []
    for vc in (vcs if isinstance(vcs, list) else [vcs]):
        payload = jwt_payload(vc) if isinstance(vc, str) and vc.count(".") == 2 else vc
        inner = (payload.get("vc") or payload) if isinstance(payload, dict) else {}
        types += inner.get("type", []) if isinstance(inner.get("type"), list) else [inner.get("type")]
    ok = "SimplDataspaceMembershipCredential" in types
    print("\n=== VERIFIER RESPONSE (Verifiable Presentation) ===")
    print("   VP signed by      :", jwt_payload(pres).get("iss") if isinstance(pres, str) else "?")
    print("   credentials in VP :", types)
    print("   contains SimplDataspaceMembershipCredential:", ok)
    if ok:
        print("\nDCP PRESENTATION VERIFIED ON NATIVE EDC 0.11 — the IdentityHub validated the")
        print("self-issued token (verifier DID + scoped access token), resolved the credential by")
        print("scope, and returned a Verifiable Presentation of the Simpl membership credential.")
    else:
        print("   raw (first 600):", blob[:600])
        sys.exit(3)
finally:
    try: os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception: pass
    httpd.shutdown()
