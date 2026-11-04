#!/usr/bin/env python3
"""ebsi_trust_webhook.py — EBSI issuer-trust check for walt.id verifier2's `webhook` VC policy.

Simpl's Tier-1 login verifies a presented credential with walt.id verifier2, which checks signature,
holder binding, nonce and validity but has NO issuer-trust policy for EBSI (its policy list is
signature, expiration, not-before, allowed-issuer, schema, regex, credential-status, revoked-status-list,
vical, etsi-trust-list, webhook). The `webhook` policy POSTs the credential (JSON, top-level `issuer` and
`subject`) to a URL and treats 2xx as pass, anything else as fail. This service is that URL.

For the credential's issuer DID it requires, in order:
  1. it is a `did:ebsi` DID that resolves in the EBSI DID Registry (response DID bound to the request);
  2. it is registered in the EBSI Trusted Issuers Registry (response DID bound to the request);
  3. it holds an unexpired accreditation attribute whose JWT signature verifies against the accrediting
     authority's registered key (ES256 / ES256K), and the accrediting authority is itself accredited, up
     the chain TI -> TAO -> Root TAO;
  4. the chain ends at a Root TAO listed in EBSI_ROOTS (pin it; unset = any root, reported as a warning).
Fails closed: any EBSI API error is a 503, never a pass.

  EBSI_API=https://api-pilot.ebsi.eu  EBSI_ROOTS=did:ebsi:zRoot...  ./ebsi_trust_webhook.py 8091
  POST /verify   <- verifier2 webhook policy (credential JSON)       200 trusted / 403 not trusted / 503 EBSI down
  GET  /check?did=did:ebsi:...   same check without a credential, for testing
"""
import base64
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

BASE = os.environ.get("EBSI_API", "https://api-pilot.ebsi.eu").rstrip("/")
DID_REG = BASE + "/did-registry/v5/identifiers/"
TIR = BASE + "/trusted-issuers-registry/v5/issuers/"
ROOTS = {r for r in os.environ.get("EBSI_ROOTS", "").split(",") if r}
LEAF_TYPES = {t for t in os.environ.get("EBSI_LEAF_TYPES", "TI").split(",") if t}
TTL = int(os.environ.get("EBSI_CACHE_TTL", "300"))
TIMEOUT = int(os.environ.get("EBSI_TIMEOUT", "30"))
MAX_DEPTH = 4
DID_EBSI = re.compile(r"^did:ebsi:z[1-9A-HJ-NP-Za-km-z]{16,40}$")

_opener = urllib.request.build_opener(urllib.request.ProxyHandler({})) if BASE.startswith(
    ("http://127.", "http://localhost")) else urllib.request.build_opener()
_cache, _lock = {}, threading.Lock()


class Reject(Exception):
    """The issuer is not trusted (HTTP 403)."""


class Upstream(Exception):
    """EBSI could not be reached or answered garbage (HTTP 503, fail closed)."""


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def get_json(url):
    with _lock:
        hit = _cache.get(url)
        if hit and time.time() - hit[0] < TTL:
            return hit[1]
    req = urllib.request.Request(url, headers={"Accept": "application/did+ld+json, application/json;q=0.9, */*;q=0.5"})
    for attempt in (1, 2):  # the EBSI pilot API has multi-second tail latency: one retry, then fail closed
        try:
            with _opener.open(req, timeout=TIMEOUT) as r:
                val = json.load(r)
            break
        except urllib.error.HTTPError as e:
            if e.code in (400, 404):
                val = None  # registry says "no such record": that is an answer, not an outage
                break
            if attempt == 2 or e.code < 500:
                raise Upstream(f"{url} -> HTTP {e.code}")
        except (urllib.error.URLError, TimeoutError, ValueError, OSError) as e:
            if attempt == 2:
                raise Upstream(f"{url} -> {e}")
    with _lock:
        _cache[url] = (time.time(), val)
    return val


def did_doc(did):
    doc = get_json(DID_REG + urllib.parse.quote(did, safe=":"))
    if not doc:
        raise Reject(f"{did} does not resolve in the EBSI DID Registry")
    if doc.get("id") != did:  # bind the response to the request
        raise Reject(f"DID Registry returned a document for {doc.get('id')!r}, not {did}")
    return doc


def verification_key(kid):
    did = kid.split("#")[0]
    for vm in did_doc(did).get("verificationMethod", []):
        if vm.get("id") == kid and vm.get("publicKeyJwk"):
            return vm["publicKeyJwk"]
    raise Reject(f"key {kid} is not in the DID document of {did}")


def verify_jws(compact, jwk, what="accreditation"):
    h, p, s = compact.split(".")
    alg = json.loads(b64d(h)).get("alg")
    curve = {"ES256": ec.SECP256R1(), "ES256K": ec.SECP256K1()}.get(alg)
    if curve is None or jwk.get("kty") != "EC":
        raise Reject(f"unsupported {what} signature algorithm {alg!r}")
    pub = ec.EllipticCurvePublicNumbers(int.from_bytes(b64d(jwk["x"]), "big"),
                                        int.from_bytes(b64d(jwk["y"]), "big"), curve).public_key()
    sig = b64d(s)
    if len(sig) != 64:
        raise Reject(f"malformed {what} signature")
    try:
        pub.verify(encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")),
                   f"{h}.{p}".encode(), ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        raise Reject(f"{what} signature does not verify against the registered key")


def attributes(did):
    """All TIR attribute records of a registered issuer; None if the DID is not in the registry."""
    issuer = get_json(TIR + urllib.parse.quote(did, safe=":"))
    if not issuer:
        return None
    if issuer.get("did") != did:  # bind the response to the request
        raise Reject(f"TIR returned a record for {issuer.get('did')!r}, not {did}")
    out = []
    listing = get_json(TIR + urllib.parse.quote(did, safe=":") + "/attributes") or {}
    for item in listing.get("items", [])[:25]:
        rec = get_json(TIR + urllib.parse.quote(did, safe=":") + "/attributes/" + item["id"])
        if rec and rec.get("did") == did and rec.get("attribute", {}).get("body", "").count(".") == 2:
            out.append(rec["attribute"])
    return out


def walk(did, depth=0, leaf=True):
    """Return the accreditation trail for `did` up to a Root TAO, or raise Reject."""
    if depth > MAX_DEPTH:
        raise Reject("accreditation chain too deep")
    attrs = attributes(did)
    if attrs is None:
        raise Reject(f"{did} is not registered in the EBSI Trusted Issuers Registry")
    why = []
    for att in attrs:
        try:
            return _validate(did, att, depth, leaf)
        except Reject as e:
            why.append(str(e))
    raise Reject(f"{did} has no valid accreditation ({'; '.join(why) or 'no attributes'})")


def _validate(did, att, depth, leaf):
    itype = att.get("issuerType")
    allowed = LEAF_TYPES if leaf else {"TAO", "RootTAO"}
    if itype not in allowed:
        raise Reject(f"issuerType {itype!r} not allowed here (need one of {sorted(allowed)})")
    header = json.loads(b64d(att["body"].split(".")[0]))
    payload = json.loads(b64d(att["body"].split(".")[1]))
    vc = payload.get("vc", {})
    vtypes = [str(t) for t in vc.get("type", [])]
    # TI / TAO hold a VerifiableAccreditation. A Root TAO is authorised by EBSI's trust anchor with a
    # VerifiableAuthorisationForTrustChain (observed in the live pilot TIR), or is self-accredited.
    is_accreditation = any(t.startswith("VerifiableAccreditation") for t in vtypes)
    is_trust_chain = "VerifiableAuthorisationForTrustChain" in vtypes
    if not (is_accreditation or (itype == "RootTAO" and is_trust_chain)):
        raise Reject(f"attribute is not an accreditation for a {itype} (types: {vtypes})")
    if payload.get("sub") != did:
        raise Reject("accreditation subject is not this issuer")
    now = time.time()
    if payload.get("exp", now + 1) <= now or payload.get("nbf", 0) > now:
        raise Reject("accreditation is expired or not yet valid")
    signer = (payload.get("iss") or header.get("kid", "").split("#")[0])
    kid = header.get("kid", "")
    if kid.split("#")[0] != signer:
        raise Reject("accreditation kid does not belong to its issuer")
    hop = {"did": did, "issuerType": itype, "accreditedBy": signer,
           "accreditedFor": vc.get("credentialSubject", {}).get("accreditedFor")}
    if itype == "RootTAO":
        if not is_trust_chain and signer != did:
            raise Reject("Root TAO accreditation is neither self-issued nor an EBSI trust-chain authorisation")
        if ROOTS and did not in ROOTS:
            raise Reject(f"Root TAO {did} is not a pinned EBSI root")
        verify_jws(att["body"], verification_key(kid))
        hop["root_pinned"] = bool(ROOTS)
        return [hop]
    if signer != att.get("tao"):
        raise Reject("accreditation signer differs from the TAO the registry records")
    verify_jws(att["body"], verification_key(kid))
    return [hop] + walk(signer, depth + 1, leaf=False)


def check_issuer(did):
    if not isinstance(did, str) or not DID_EBSI.match(did):
        raise Reject(f"issuer {did!r} is not a did:ebsi DID")
    did_doc(did)
    return walk(did)


# ---- Tier 2: a foreign authority's issuer is a did:web (X.509-backed), EBSI only knows did:ebsi ----------------
# The authority links the two: its did:web document carries a `LinkedEbsiIdentity` service whose endpoint is
# {"ebsiDid": "did:ebsi:...", "proof": "<JWS signed by a key of that did:ebsi, subject = this did:web>"}.
# Claiming a public did:ebsi proves nothing, so the proof (control of the EBSI DID) is verified before the
# EBSI chain walk. This linkage format is the lab's own; EBSI/Simpl define none.
DID_WEB = re.compile(r"^did:web:[A-Za-z0-9.\-]+(?:%3[Aa]\d{1,5})?(?::[A-Za-z0-9._~\-]+)*$")
MAX_DOC = 256 * 1024


def allow_local():
    """Lab only: let did:web point at localhost over http. Never set in production."""
    return os.environ.get("EBSI_DIDWEB_ALLOW_LOCAL") == "1"


def did_web_url(did):
    if not DID_WEB.match(did):
        raise Reject(f"{did!r} is not a valid did:web")
    host, *path = [urllib.parse.unquote(p) for p in did[len("did:web:"):].split(":")]
    name = host.rsplit(":", 1)[0] if re.search(r":\d+$", host) else host
    local = name in ("localhost", "127.0.0.1")
    if local and not allow_local():
        raise Reject("did:web host is local")
    if not local:  # SSRF guard: the issuer comes from a presentation by a not-yet-trusted participant
        import ipaddress
        import socket
        try:
            addrs = {a[4][0] for a in socket.getaddrinfo(name, None)}
        except OSError as e:
            raise Upstream(f"cannot resolve {name}: {e}")
        for a in addrs:
            ip = ipaddress.ip_address(a)
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
                raise Reject(f"did:web host {name} resolves to a non-public address")
    return f"{'http' if local else 'https'}://{host}/{'/'.join(path) + '/' if path else '.well-known/'}did.json"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def fetch_did_web(did):
    url = did_web_url(did)
    opener = urllib.request.build_opener(_NoRedirect, *([urllib.request.ProxyHandler({})] if url.startswith("http://") else []))
    try:
        with opener.open(urllib.request.Request(url, headers={"Accept": "application/did+json, application/json"}), timeout=TIMEOUT) as r:
            raw = r.read(MAX_DOC + 1)
    except urllib.error.HTTPError as e:
        if e.code in (404, 410):
            raise Reject(f"{did} has no DID document ({e.code})")
        raise Upstream(f"{url} -> HTTP {e.code}")  # includes 3xx: redirects are refused
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise Upstream(f"{url} -> {e}")
    if len(raw) > MAX_DOC:
        raise Reject("did:web document too large")
    try:
        doc = json.loads(raw)
    except ValueError:
        raise Reject("did:web document is not JSON")
    if not isinstance(doc, dict) or doc.get("id") != did:  # bind the document to the DID asked for
        raise Reject(f"did:web document is for {doc.get('id') if isinstance(doc, dict) else None!r}, not {did}")
    return doc


def linked_ebsi_did(web_did, doc):
    """The did:ebsi the authority proves it controls, or Reject."""
    claimed = {x for x in doc.get("alsoKnownAs", []) if isinstance(x, str) and x.startswith("did:ebsi:")}
    links = [s.get("serviceEndpoint") for s in doc.get("service", [])
             if isinstance(s, dict) and s.get("type") == "LinkedEbsiIdentity" and isinstance(s.get("serviceEndpoint"), dict)]
    if not links:
        raise Reject(f"{web_did} links no EBSI identity")
    ep = links[0]
    ebsi, proof = ep.get("ebsiDid"), ep.get("proof")
    if not isinstance(ebsi, str) or not DID_EBSI.match(ebsi) or not isinstance(proof, str) or proof.count(".") != 2:
        raise Reject("malformed EBSI identity link")
    if claimed and ebsi not in claimed:
        raise Reject("alsoKnownAs and the EBSI identity link name different DIDs")
    header, payload = json.loads(b64d(proof.split(".")[0])), json.loads(b64d(proof.split(".")[1]))
    kid = header.get("kid", "")
    if kid.split("#")[0] != ebsi or payload.get("iss") != ebsi:
        raise Reject("link proof is not issued by the linked EBSI DID")
    if payload.get("sub") != web_did:
        raise Reject("link proof is for a different did:web")
    if payload.get("exp", 0) <= time.time():
        raise Reject("link proof expired")
    verify_jws(proof, verification_key(kid), what="EBSI identity link proof")
    return ebsi


def check_web(verification_method):
    """Tier 2: is the authority behind this did:web verification method an EBSI-accredited Trusted Issuer?"""
    web_did = (verification_method or "").split("#")[0]
    if not web_did.startswith("did:web:"):
        raise Reject(f"issuer {verification_method!r} is not a did:web")
    ebsi = linked_ebsi_did(web_did, fetch_did_web(web_did))
    did_doc(ebsi)
    return {"didWeb": web_did, "ebsiDid": ebsi, "chain": walk(ebsi)}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _decide(self, did):
        try:
            trail = check_issuer(did)
            print(f"[ebsi-trust] TRUSTED  {did}  via {' -> '.join(h['issuerType'] for h in trail)}", flush=True)
            self._send(200, {"trusted": True, "issuer": did, "chain": trail})
        except Reject as e:
            print(f"[ebsi-trust] REJECT   {did}  {e}", flush=True)
            self._send(403, {"trusted": False, "issuer": did, "reason": str(e)})
        except Upstream as e:
            print(f"[ebsi-trust] UPSTREAM {did}  {e}  (fail closed)", flush=True)
            self._send(503, {"trusted": False, "issuer": did, "reason": f"EBSI unavailable: {e}"})

    def _decide_web(self, vm):
        try:
            ev = check_web(vm)
            print(f"[ebsi-trust] TRUSTED  {vm}  = {ev['ebsiDid']}  via {' -> '.join(h['issuerType'] for h in ev['chain'])}", flush=True)
            self._send(200, {"trusted": True, "issuer": vm, **ev})
        except Reject as e:
            print(f"[ebsi-trust] REJECT   {vm}  {e}", flush=True)
            self._send(403, {"trusted": False, "issuer": vm, "reason": str(e)})
        except Upstream as e:
            print(f"[ebsi-trust] UPSTREAM {vm}  {e}  (fail closed)", flush=True)
            self._send(503, {"trusted": False, "issuer": vm, "reason": f"unavailable: {e}"})

    def do_POST(self):
        try:
            cred = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except ValueError:
            return self._send(400, {"trusted": False, "reason": "body is not JSON"})
        issuer = cred.get("issuer") or (cred.get("credentialData") or {}).get("issuer")
        if isinstance(issuer, dict):
            issuer = issuer.get("id")
        self._decide(issuer)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/healthz":
            return self._send(200, {"ok": True, "ebsi": BASE, "pinned_roots": sorted(ROOTS)})
        if u.path == "/check":
            return self._decide(urllib.parse.parse_qs(u.query).get("did", [""])[0])
        if u.path == "/check-web":  # Tier 2: ?vm=did:web:...#key
            return self._decide_web(urllib.parse.parse_qs(u.query).get("vm", [""])[0])
        self.send_error(404)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8091
    print(f"[ebsi-trust] :{port}  EBSI={BASE}  pinned roots={sorted(ROOTS) or 'NONE (any root accepted)'}  "
          f"leaf types={sorted(LEAF_TYPES)}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
