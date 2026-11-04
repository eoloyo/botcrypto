#!/usr/bin/env python3
"""test_chain.py — accept/reject tests for ebsi_trust_webhook against a local stub EBSI.

The stub serves the two EBSI APIs the check uses (DID Registry v5, Trusted Issuers Registry v5) from a
synthetic Root TAO -> TAO -> TI chain whose accreditation JWTs are really signed (Root: ES256K, TAO and
TI: ES256), so signature verification, expiry, pinning, response-binding and fail-closed are all
exercised for real. Real-registry coverage is in README (live pilot run); this is the deterministic part.

  python3 test_chain.py
"""
import base64
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 18095
os.environ["EBSI_API"] = f"http://127.0.0.1:{PORT}"
os.environ["EBSI_CACHE_TTL"] = "0"
os.environ["EBSI_TIMEOUT"] = "3"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ebsi_trust_webhook as e  # noqa: E402
from cryptography.hazmat.primitives import hashes  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature  # noqa: E402

ALPHA = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58(b):
    n, out = int.from_bytes(b, "big"), ""
    while n:
        n, r = divmod(n, 58)
        out = ALPHA[r] + out
    return out


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def new_did():
    return "did:ebsi:z" + b58(b"\x01" + os.urandom(16))


class Actor:
    def __init__(self, curve, alg):
        self.did, self.alg, self.key = new_did(), alg, ec.generate_private_key(curve)
        self.kid = f"{self.did}#{b64u(os.urandom(8))}"
        n = self.key.public_key().public_numbers()
        self.jwk = {"kty": "EC", "crv": "secp256k1" if alg == "ES256K" else "P-256",
                    "x": b64u(n.x.to_bytes(32, "big")), "y": b64u(n.y.to_bytes(32, "big"))}

    def doc(self, did=None):
        did = did or self.did
        return {"@context": ["https://www.w3.org/ns/did/v1"], "id": did,
                "verificationMethod": [{"id": self.kid, "type": "JsonWebKey2020", "controller": did,
                                        "publicKeyJwk": self.jwk}]}

    def sign(self, header, payload):
        si = f"{b64u(json.dumps(header).encode())}.{b64u(json.dumps(payload).encode())}"
        r, s = decode_dss_signature(self.key.sign(si.encode(), ec.ECDSA(hashes.SHA256())))
        return si + "." + b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def accreditation(signer, subject_did, kind, exp_delta=86400 * 365, signing_actor=None):
    now = int(time.time())
    sa = signing_actor or signer
    types = (["VerifiableCredential", "VerifiableAttestation", "VerifiableAuthorisationForTrustChain"]
             if kind == "TRUSTCHAIN" else
             ["VerifiableCredential", "VerifiableAttestation", "VerifiableAccreditation",
              "VerifiableAccreditationToAttest" if kind == "TI" else "VerifiableAccreditationToAccredit"])
    payload = {"iss": signer.did, "sub": subject_did, "iat": now, "nbf": now - 5, "exp": now + exp_delta,
               "vc": {"@context": ["https://www.w3.org/2018/credentials/v1"],
                      "type": types,
                      "issuer": signer.did, "credentialSubject": {"id": subject_did, "accreditedFor": [
                          {"schemaId": "https://api-pilot.ebsi.eu/trusted-schemas-registry/v3/schemas/x",
                           "types": ["VerifiableCredential"]}]}}}
    return sa.sign({"alg": sa.alg, "typ": "JWT", "kid": sa.kid}, payload)


class World:
    """Mutable in-memory EBSI: DID docs and TIR records, served by the stub."""
    def __init__(self):
        self.docs, self.tir, self.down = {}, {}, False

    def register(self, actor, itype, tao, root, body):
        self.docs[actor.did] = actor.doc()
        self.tir[actor.did] = [{"body": body, "hash": b64u(os.urandom(8)), "issuerType": itype,
                                "tao": tao.did if tao else actor.did, "rootTao": root.did}]


W = World()


class Stub(BaseHTTPRequestHandler):
    def _j(self, code, o):
        b = json.dumps(o).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        if W.down:
            return self._j(500, {"error": "down"})
        p = self.path.split("?")[0].split("/")
        # /did-registry/v5/identifiers/<did>   /trusted-issuers-registry/v5/issuers/<did>[/attributes[/<id>]]
        if p[1] == "did-registry":
            did = p[4]
            d = W.docs.get(did)
            doc = W.docs.get("swap:" + did) or d
            return self._j(200, doc) if doc else self._j(404, {})
        did = p[4]
        recs = W.tir.get(did)
        if recs is None:
            return self._j(404, {})
        shown = W.tir.get("swap:" + did, [None])[0]  # TIR answering with another DID's record
        shown_did = shown["did"] if shown else did
        if len(p) == 5:
            return self._j(200, {"did": shown_did, "attributes": "x", "hasAttributes": True})
        if len(p) == 6:
            return self._j(200, {"items": [{"id": format(i, "x") * 4} for i, _ in enumerate(recs, 10)]})
        i = int(p[6][0], 16) - 10
        return self._j(200, {"did": shown_did, "attribute": recs[i]})

    def log_message(self, *a):
        pass


def build(self_issued_root=False):
    """Default = the structure seen in the live pilot TIR: the Root TAO is authorised by a separate EBSI
    trust-anchor DID with a VerifiableAuthorisationForTrustChain; TAO and TI hold accreditations."""
    W.__init__()
    root, tao, ti = Actor(ec.SECP256K1(), "ES256K"), Actor(ec.SECP256R1(), "ES256"), Actor(ec.SECP256R1(), "ES256")
    anchor = Actor(ec.SECP256R1(), "ES256")
    W.docs[anchor.did] = anchor.doc()
    W.anchor = anchor
    W.register(root, "RootTAO", None, root,
               accreditation(root, root.did, "TAO") if self_issued_root
               else accreditation(anchor, root.did, "TRUSTCHAIN"))
    W.register(tao, "TAO", root, root, accreditation(root, tao.did, "TAO"))
    W.register(ti, "TI", tao, root, accreditation(tao, ti.did, "TI"))
    e.ROOTS = {root.did}
    e._cache.clear()
    return root, tao, ti


def verdict(did):
    e._cache.clear()
    try:
        return "TRUSTED", e.check_issuer(did)
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


@case("valid chain  TI -> TAO -> Root(pinned)  [ES256 + ES256K]", "TRUSTED")
def _(): return build()[2].did


@case("valid chain with a self-accredited Root TAO (alternative root shape)", "TRUSTED")
def _(): return build(self_issued_root=True)[2].did


@case("Root TAO's trust-chain authorisation forged (signed by a key that is not the anchor's)", "REJECT", "does not verify")
def _():
    r, t, ti = build(); mallory = Actor(ec.SECP256R1(), "ES256"); mallory.kid = W.anchor.kid
    W.tir[r.did][0]["body"] = accreditation(W.anchor, r.did, "TRUSTCHAIN", signing_actor=mallory); return ti.did


@case("Root TAO is not the pinned EBSI root", "REJECT", "not a pinned EBSI root")
def _():
    r, t, ti = build(); e.ROOTS = {new_did()}; return ti.did


@case("TI accreditation forged: signed by a key that is not the TAO's", "REJECT", "does not verify")
def _():
    r, t, ti = build(); mallory = Actor(ec.SECP256R1(), "ES256")
    mallory.kid = t.kid  # claims the TAO's kid, signs with its own key
    W.tir[ti.did][0]["body"] = accreditation(t, ti.did, "TI", signing_actor=mallory); return ti.did


@case("TI accreditation expired", "REJECT", "expired")
def _():
    r, t, ti = build(); W.tir[ti.did][0]["body"] = accreditation(t, ti.did, "TI", exp_delta=-3600); return ti.did


@case("registry's recorded TAO differs from the accreditation signer", "REJECT", "differs from the TAO")
def _():
    r, t, ti = build(); W.tir[ti.did][0]["tao"] = r.did; return ti.did


@case("TAO in the chain is not itself accredited by the root (forged TAO accreditation)", "REJECT", "does not verify")
def _():
    r, t, ti = build(); mallory = Actor(ec.SECP256K1(), "ES256K"); mallory.kid = r.kid
    W.tir[t.did][0]["body"] = accreditation(r, t.did, "TAO", signing_actor=mallory); return ti.did


@case("DID Registry answers with a document for a DIFFERENT DID (openvc #267 class)", "REJECT", "not")
def _():
    r, t, ti = build(); other = Actor(ec.SECP256R1(), "ES256"); W.docs["swap:" + ti.did] = other.doc(); return ti.did


@case("TIR answers with a record for a DIFFERENT DID (openvc #267 class)", "REJECT", "not")
def _():
    r, t, ti = build(); W.tir["swap:" + ti.did] = [{"did": t.did}]; return ti.did


@case("DID resolves but is not in the Trusted Issuers Registry", "REJECT", "not registered")
def _():
    r, t, ti = build(); del W.tir[ti.did]; return ti.did


@case("a TAO presented as the credential issuer (leaf must be TI)", "REJECT", "not allowed here")
def _():
    r, t, ti = build(); return t.did


@case("non-EBSI issuer DID (did:jwk) -- the 'any issuer' gap", "REJECT", "not a did:ebsi")
def _():
    build(); return "did:jwk:eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2In0"


@case("EBSI unreachable -> fail closed (503), never a pass", "UPSTREAM")
def _():
    r, t, ti = build(); W.down = True; return ti.did


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    bad = 0
    for name, want, contains, fn in CASES:
        W.down = False
        got, detail = verdict(fn())
        ok = got == want and (contains is None or contains in str(detail))
        bad += not ok
        shown = " -> ".join(h["issuerType"] for h in detail) if got == "TRUSTED" else str(detail)[:110]
        print(f"[{'PASS' if ok else 'FAIL'}] {name}\n        {got}: {shown}")
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
