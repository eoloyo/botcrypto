#!/usr/bin/env python3
# ============================================================================
# DCP / SSI credential-exchange demo for Simpl-Open.
#
# Proves the credential core that a Simpl-Open DCP (Decentralized Claims
# Protocol) / SSI setup relies on, using walt.id — the stack Simpl-Open itself
# selected for its SSI verifier (architecture ADR 007, "OpenID4VP verifier for
# SSI Tier 1 authentication - walt.id", Accepted).
#
# Flow (all real crypto, no mocks):
#   1. Onboard a Governance-Authority-style ISSUER identity (key + DID).
#   2. Onboard a participant-agent HOLDER identity (key + DID).
#   3. ISSUER issues a `SimplDataspaceMembershipCredential` to the holder,
#      carrying governed identity attributes (e.g. CONSUMER, DATA_SEARCHER) —
#      the same attributes Simpl's SAP assigns today via the ephemeral proof.
#   4. A VERIFIER opens an OID4VP presentation session requesting that type.
#   5. The HOLDER builds and signs a Verifiable Presentation (ES256, bound to
#      the verifier's nonce + client_id) and submits it (direct_post).
#   6. The VERIFIER validates signature + holder-binding + type -> verified.
#
# This is the presentation-exchange that DCP defines for machine identity —
# here demonstrated at the credential/verifier layer. Wiring it into the EDC
# connector's DSP handshake (Tier-2, replacing the ephemeral proof) is the next
# increment and needs the connector on an EDC version that ships the DCP
# IdentityHub (see README).
# ============================================================================
import json, base64, urllib.request, urllib.parse, sys

ISS = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:7002"   # walt.id issuer-api
VER = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:7003"   # walt.id verifier-api
ATTRS = ["CONSUMER", "DATA_SEARCHER"]

b64u_d = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
b64u_e = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")

def jpost(base, path, body):
    r = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                               headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(r, timeout=30).read().decode()

def get(u):
    return urllib.request.urlopen(u, timeout=30).read().decode()

def form_post(url, fields):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        return urllib.request.urlopen(req, timeout=30).read().decode() or "202 accepted"
    except urllib.error.HTTPError as e:
        return "HTTP %d: %s" % (e.code, e.read().decode()[:200])

# 1 + 2 — issuer (GA) and holder (participant agent) identities
issuer = json.loads(jpost(ISS, "/onboard/issuer", {"key": {"keyType": "secp256r1"}}))
holder = json.loads(jpost(ISS, "/onboard/issuer", {"key": {"keyType": "secp256r1"}}))
iKey, iDid = issuer["issuerKey"], issuer["issuerDid"]
sKey, sDid = holder["issuerKey"], holder["issuerDid"]
print("1) issuer (GA)        :", iDid[:46], "...")
print("2) holder (agent)     :", sDid[:46], "...")

# 3 — issue the Simpl membership VC with governed identity attributes
vc = {
    "@context": ["https://www.w3.org/2018/credentials/v1"],
    "type": ["VerifiableCredential", "SimplDataspaceMembershipCredential"],
    "issuer": iDid,
    "credentialSubject": {
        "id": sDid,
        "participantId": "urn:simpl:participant:acme-data-bv",
        "legalName": "Acme Data BV",
        "dataspaceRole": "Provider",
        "identityAttributes": ATTRS,
    },
}
vcjwt = jpost(ISS, "/raw/jwt/sign",
              {"issuerKey": iKey, "issuerDid": iDid, "subjectDid": sDid, "credentialData": vc}).strip().strip('"')
print("3) issued VC          : SimplDataspaceMembershipCredential  attrs=%s  (%d-char JWT)" % (ATTRS, len(vcjwt)))

# 4 — verifier opens an OID4VP presentation session
authz = jpost(VER, "/openid4vc/verify",
              {"request_credentials": [{"format": "jwt_vc_json", "type": "SimplDataspaceMembershipCredential"}]})
q = urllib.parse.parse_qs(authz.split("?", 1)[1])
state, nonce, client_id = q["state"][0], q["nonce"][0], q["client_id"][0]
resp_uri = q["response_uri"][0]
pd = json.loads(get(q["presentation_definition_uri"][0]))
did_id, defn_id = pd["input_descriptors"][0]["id"], pd["id"]
print("4) verifier session   :", state, "  asks for:", did_id)

# 5 — holder signs a Verifiable Presentation (ES256, bound to nonce + client_id)
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives import hashes
priv = ec.derive_private_key(int.from_bytes(b64u_d(sKey["jwk"]["d"]), "big"), ec.SECP256R1())
hdr = {"alg": "ES256", "typ": "JWT", "kid": sDid + "#0"}
vp = {"iss": sDid, "sub": sDid, "aud": client_id, "nonce": nonce, "jti": "urn:uuid:vp-1",
      "vp": {"@context": ["https://www.w3.org/2018/credentials/v1"], "type": ["VerifiablePresentation"],
             "holder": sDid, "verifiableCredential": [vcjwt]}}
si = (b64u_e(json.dumps(hdr).encode()) + "." + b64u_e(json.dumps(vp).encode())).encode()
r, s = decode_dss_signature(priv.sign(si, ec.ECDSA(hashes.SHA256())))
vp_jwt = si.decode() + "." + b64u_e(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
submission = {"id": "sub-1", "definition_id": defn_id, "descriptor_map": [
    {"id": did_id, "format": "jwt_vp", "path": "$",
     "path_nested": {"id": did_id, "format": "jwt_vc", "path": "$.vp.verifiableCredential[0]"}}]}
res = form_post(resp_uri, {"vp_token": vp_jwt, "presentation_submission": json.dumps(submission), "state": state})
print("5) holder presented VP:", res[:60])

# 6 — verifier verdict
sess = json.loads(get("%s/openid4vc/session/%s" % (VER, state)))
verified = sess.get("verificationResult")
print("6) VERIFIER VERDICT   : verified =", verified)
if verified is not True:
    print("   session:", json.dumps(sess)[:400])
    sys.exit(1)
print()
print("DCP-STYLE PRESENTATION EXCHANGE VERIFIED — a GA-issued Simpl membership credential")
print("carrying governed identity attributes was presented by the holder and validated by the")
print("walt.id verifier (signature + holder-binding). This is the credential core Tier-2 DCP needs.")
