#!/usr/bin/env python3
"""mint_credential.py <holder-did> [state-dir] — act as the trusted issuer for the wallet login.

Signs a W3C Verifiable Credential in the `jwt_vc_json` format that Simpl's OpenID4VP identity provider
accepts (ES256, issuer `did:jwk`), issued to the wallet holder's DID, and prints the compact JWT.

The issuer key is created once and kept in <state-dir>/issuer-key.pem; its `did:jwk` (printed to stderr
and written to <state-dir>/issuer.did) is what the trusted-issuers record in Users and Roles names.
In the official set-up this step is an OpenID4VCI issuer (walt.id issuer2 or the Governance Authority's
issuer service); here it is done locally because the walt.id issuer image could not be pulled, and the
wallet imports the result (`POST /wallet/{id}/credentials/import`)."""
import base64
import json
import os
import sys
import time
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

CREDENTIAL_TYPE = "SimplDataspaceMembershipCredential"


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def load_or_create_key(path):
    if os.path.exists(path):
        return serialization.load_pem_private_key(open(path, "rb").read(), password=None)
    key = ec.generate_private_key(ec.SECP256R1())
    open(path, "wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                             serialization.NoEncryption()))
    return key


def public_jwk(key):
    nums = key.public_key().public_numbers()
    return {"kty": "EC", "crv": "P-256",
            "x": b64u(nums.x.to_bytes(32, "big")), "y": b64u(nums.y.to_bytes(32, "big"))}


def sign_es256(key, signing_input):
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def main():
    holder = sys.argv[1]
    state = sys.argv[2] if len(sys.argv) > 2 else "/root/simpl-open-lab-work/ssi-run"
    os.makedirs(state, exist_ok=True)
    key = load_or_create_key(os.path.join(state, "issuer-key.pem"))
    jwk = public_jwk(key)
    issuer_did = "did:jwk:" + b64u(json.dumps(jwk, separators=(",", ":")).encode())
    open(os.path.join(state, "issuer.did"), "w").write(issuer_did)

    now = int(time.time())
    vc = {
        "@context": ["https://www.w3.org/2018/credentials/v1"],
        "id": f"urn:uuid:{uuid.uuid4()}",
        "type": ["VerifiableCredential", CREDENTIAL_TYPE],
        "issuer": issuer_did,
        "issuanceDate": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "credentialSubject": {
            "id": holder,
            "firstName": os.environ.get("SUBJECT_FIRST", "Ada"),
            "familyName": os.environ.get("SUBJECT_LAST", "Researcher"),
            "email": os.environ.get("SUBJECT_EMAIL", "ada.researcher@university-example.eu"),
            "organisation": os.environ.get("SUBJECT_ORG", "University of Example"),
            "identityAttributes": ["CONSUMER", "DATA_SEARCHER"],
        },
    }
    header = {"alg": "ES256", "typ": "JWT", "kid": issuer_did + "#0"}
    payload = {"iss": issuer_did, "sub": holder, "nbf": now, "iat": now, "exp": now + 365 * 86400,
               "jti": vc["id"], "vc": vc}
    signing_input = (b64u(json.dumps(header, separators=(",", ":")).encode()) + "."
                     + b64u(json.dumps(payload, separators=(",", ":")).encode())).encode()
    print(signing_input.decode() + "." + b64u(sign_es256(key, signing_input)))
    print(f"issuer {issuer_did}", file=sys.stderr)


if __name__ == "__main__":
    main()
