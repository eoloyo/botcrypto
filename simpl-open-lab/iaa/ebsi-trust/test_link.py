#!/usr/bin/env python3
"""test_link.py — Tier 2: did:web authority -> linked did:ebsi -> EBSI accreditation chain.

Reuses the stub EBSI and the synthetic Root TAO -> TAO -> TI chain of test_chain.py and adds a local
did:web server. The authority's did:web document carries a `LinkedEbsiIdentity` service whose proof is a JWS
signed by the EBSI DID's key, so claiming somebody else's public EBSI DID must fail.

  python3 test_link.py
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ["EBSI_DIDWEB_ALLOW_LOCAL"] = "1"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_chain as tc  # noqa: E402  (sets EBSI_API to its stub and imports the module as tc.e)

e = tc.e
WEB_PORT = 18096
PAGES = {}  # path -> (status, body bytes, extra headers)


class WebStub(BaseHTTPRequestHandler):
    def do_GET(self):
        status, body, headers = PAGES.get(self.path, (404, b"{}", {}))
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def web_did(name):
    return f"did:web:localhost%3A{WEB_PORT}:{name}"


def proof(ebsi, sub, exp_delta=3600, signer=None, iss=None):
    s = signer or ebsi
    now = int(time.time())
    return s.sign({"alg": s.alg, "typ": "JWT", "kid": s.kid},
                  {"iss": iss or ebsi.did, "sub": sub, "iat": now, "exp": now + exp_delta})


def publish(name, ebsi_did, prf, also=None, doc_id=None, extra_service=True):
    did = web_did(name)
    doc = {"@context": ["https://www.w3.org/ns/did/v1"], "id": doc_id or did,
           "verificationMethod": [{"id": did + "#key-1", "type": "JsonWebKey2020", "controller": did,
                                   "x5u": "https://example.invalid/chain.pem"}]}
    if also is not None:
        doc["alsoKnownAs"] = also
    if extra_service:
        doc["service"] = [{"id": did + "#ebsi", "type": "LinkedEbsiIdentity",
                           "serviceEndpoint": {"ebsiDid": ebsi_did, "proof": prf}}]
    PAGES[f"/{name}/did.json"] = (200, json.dumps(doc).encode(), {"Content-Type": "application/did+json"})
    return did + "#key-1"


def verdict(vm):
    e._cache.clear()
    try:
        ev = e.check_web(vm)
        return "TRUSTED", ev
    except e.Reject as x:
        return "REJECT", str(x)
    except e.Upstream as x:
        return "UPSTREAM", str(x)


CASES = []


def case(name, want, contains=None):
    def deco(fn):
        CASES.append((name, want, contains, fn))
        return fn
    return deco


def fresh():
    PAGES.clear()
    tc.W.down = False
    os.environ["EBSI_DIDWEB_ALLOW_LOCAL"] = "1"
    return tc.build()


@case("authority links an accredited EBSI TI with a valid proof of control", "TRUSTED")
def _():
    r, t, ti = fresh(); n = "auth"
    return publish(n, ti.did, proof(ti, web_did(n)), also=[ti.did])


@case("no EBSI identity linked in the did:web document", "REJECT", "links no EBSI identity")
def _():
    r, t, ti = fresh(); return publish("auth", ti.did, "x", extra_service=False)


@case("authority CLAIMS an accredited TI's public did:ebsi but cannot sign as it", "REJECT", "does not verify")
def _():
    r, t, ti = fresh(); n = "thief"; thief = tc.Actor(tc.ec.SECP256R1(), "ES256"); thief.kid = ti.kid
    return publish(n, ti.did, proof(ti, web_did(n), signer=thief), also=[ti.did])


@case("proof replayed from another authority (subject is a different did:web)", "REJECT", "different did:web")
def _():
    r, t, ti = fresh(); return publish("copycat", ti.did, proof(ti, web_did("victim")), also=[ti.did])


@case("link proof expired", "REJECT", "expired")
def _():
    r, t, ti = fresh(); n = "auth"; return publish(n, ti.did, proof(ti, web_did(n), exp_delta=-60), also=[ti.did])


@case("alsoKnownAs names a different DID than the link", "REJECT", "different DIDs")
def _():
    r, t, ti = fresh(); n = "auth"; return publish(n, ti.did, proof(ti, web_did(n)), also=[tc.new_did()])


@case("proof issuer is not the linked EBSI DID", "REJECT", "not issued by the linked EBSI DID")
def _():
    r, t, ti = fresh(); n = "auth"; return publish(n, ti.did, proof(ti, web_did(n), iss=t.did), also=[ti.did])


@case("linked EBSI DID is not accredited (a TAO, not a TI)", "REJECT", "not allowed here")
def _():
    r, t, ti = fresh(); n = "auth"; return publish(n, t.did, proof(t, web_did(n)), also=[t.did])


@case("linked EBSI DID is not in the Trusted Issuers Registry", "REJECT", "not registered")
def _():
    r, t, ti = fresh(); n = "auth"; del tc.W.tir[ti.did]; return publish(n, ti.did, proof(ti, web_did(n)), also=[ti.did])


@case("accreditation chain broken (forged TAO accreditation) behind a valid link", "REJECT", "does not verify")
def _():
    r, t, ti = fresh(); n = "auth"; m = tc.Actor(tc.ec.SECP256K1(), "ES256K"); m.kid = r.kid
    tc.W.tir[t.did][0]["body"] = tc.accreditation(r, t.did, "TAO", signing_actor=m)
    return publish(n, ti.did, proof(ti, web_did(n)), also=[ti.did])


@case("did:web document is for another DID", "REJECT", "not did:web")
def _():
    r, t, ti = fresh(); n = "auth"; return publish(n, ti.did, proof(ti, web_did(n)), also=[ti.did], doc_id="did:web:evil.example")


@case("did:web host redirects (refused: no redirects followed)", "UPSTREAM")
def _():
    r, t, ti = fresh(); PAGES["/auth/did.json"] = (302, b"", {"Location": "http://127.0.0.1:1/x"}); return web_did("auth") + "#key-1"


@case("did:web document is oversized", "REJECT", "too large")
def _():
    r, t, ti = fresh(); PAGES["/auth/did.json"] = (200, b" " * (e.MAX_DOC + 10), {}); return web_did("auth") + "#key-1"


@case("did:web host is private (SSRF guard, localhost not allowed)", "REJECT", "local")
def _():
    r, t, ti = fresh(); os.environ.pop("EBSI_DIDWEB_ALLOW_LOCAL"); return web_did("auth") + "#key-1"


@case("did:web host resolves to a private address (SSRF guard)", "REJECT", "non-public")
def _():
    fresh(); return "did:web:localtest.me:auth#key-1" if False else "did:web:10.0.0.5:auth#key-1"


@case("malformed did:web (path traversal characters)", "REJECT", "not a valid did:web")
def _():
    fresh(); return "did:web:localhost%3A18096:..%2f..%2fetc#k"


@case("issuer is not a did:web", "REJECT", "not a did:web")
def _():
    fresh(); return "did:jwk:abc#0"


@case("EBSI unreachable behind a valid link -> fail closed", "UPSTREAM")
def _():
    r, t, ti = fresh(); n = "auth"; vm = publish(n, ti.did, proof(ti, web_did(n)), also=[ti.did]); tc.W.down = True; return vm


@case("did:web host unreachable -> fail closed", "UPSTREAM")
def _():
    fresh(); return "did:web:localhost%3A1:auth#key-1"


def http_contract():
    """The real sidecar over HTTP, called the way the Java EbsiTrustAdapterImpl calls it: GET /check-web with the
    verification method percent-encoded in `vm` ('#' -> %23, '%3A' -> %253A). 200 / 403 / 503 are the contract."""
    import urllib.error
    import urllib.parse
    import urllib.request
    srv = ThreadingHTTPServer(("127.0.0.1", 18097), e.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(vm):
        try:
            with opener.open("http://127.0.0.1:18097/check-web?vm=" + urllib.parse.quote(vm, safe=""), timeout=30) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as x:
            return x.code, json.load(x)

    rows, bad = [], 0
    r, t, ti = fresh(); n = "auth"
    vm = publish(n, ti.did, proof(ti, web_did(n)), also=[ti.did])
    e._cache.clear(); code, ans = call(vm)
    rows.append(("accredited authority", 200, code, ans.get("trusted") is True and ans.get("ebsiDid") == ti.did))
    r, t, ti = fresh(); vm = publish("auth", ti.did, "x", extra_service=False)
    e._cache.clear(); code, ans = call(vm)
    rows.append(("not linked", 403, code, ans.get("trusted") is False and "reason" in ans))
    r, t, ti = fresh(); vm = publish("auth", ti.did, proof(ti, web_did("auth")), also=[ti.did]); tc.W.down = True
    e._cache.clear(); code, ans = call(vm)
    rows.append(("EBSI down", 503, code, ans.get("trusted") is False))
    for name, want, code, shape in rows:
        ok = code == want and shape
        bad += not ok
        print(f"[{'PASS' if ok else 'FAIL'}] HTTP contract: {name} -> {code} (want {want})")
    return bad


def main():
    for srv, port, h in ((tc.ThreadingHTTPServer(("127.0.0.1", tc.PORT), tc.Stub), tc.PORT, None),
                         (ThreadingHTTPServer(("127.0.0.1", WEB_PORT), WebStub), WEB_PORT, None)):
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    bad = 0
    for name, want, contains, fn in CASES:
        got, detail = verdict(fn())
        ok = got == want and (contains is None or contains in str(detail))
        bad += not ok
        shown = (f"{detail['didWeb'][-12:]} = {detail['ebsiDid'][-8:]} via " + " -> ".join(h["issuerType"] for h in detail["chain"])) \
            if got == "TRUSTED" else str(detail)[:105]
        print(f"[{'PASS' if ok else 'FAIL'}] {name}\n        {got}: {shown}")
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    contract_bad = http_contract()
    print(f"HTTP contract: {3 - contract_bad}/3 passed")
    sys.exit(1 if bad or contract_bad else 0)


if __name__ == "__main__":
    main()
