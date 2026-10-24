#!/usr/bin/env python3
"""exchange.py — the live Tier-2 federated ephemeral-proof exchange on top of the BP02D federation
(run federate.py first). A university consumer in the EOSC data space (A) gets a real, A-signed
ephemeral proof carrying its EOSC attributes; the DestinE data space (B) security-attributes
provider exchanges it for a B-signed proof carrying the MAPPED attributes.

  1. onboard a consumer at A   generate an EC key + CSR locally, A's identity provider signs it
                               (A's CA), register the consumer's Tier-1 public key, assign it the
                               EOSC attributes CONSUMER + EOSC_DESTINE_PARTNER
  2. A issues the proof        POST A-SAP /tier2/v2/token with a proof-of-possession signed by the
                               consumer key -> an A-signed ephemeral proof with its EOSC attributes
  3. B exchanges it            POST B-SAP /tier2/v2/token/exchange with the A proof -> B verifies A
                               is a trusted authority, applies the BP02D mapping, and issues a
                               B-signed proof carrying CONSUMER + DESTINE_UPGRADED_ACCESS
  4. check                     decode both proofs; the EOSC-only RESEARCH_ORG is not granted, and the
                               mapped DestinE attribute appears only after the exchange

Lab shortcut (documented): the Credential-Id header is set directly on the Tier-2 calls, which the
Tier-2 gateway would otherwise set after the mTLS handshake; no gateway is run. Everything the
security-attributes providers do — proof issuance, trust check, attribute mapping, signing — is the
services' own code. Nothing is forged: B only ever maps a genuinely A-signed proof.
"""
import base64
import hashlib
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from uuid import uuid4

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature
from cryptography.x509.oid import NameOID

A = {"idp": 8203, "sap": 8202}
B = {"idp": 8303, "sap": 8302}
STATE = "/root/simpl-open-lab-work/fed"
local = urllib.request.build_opener(urllib.request.ProxyHandler({}))
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58(b):
    n = int.from_bytes(b, "big")
    s = ""
    while n > 0:
        n, r = divmod(n, 58)
        s = B58[r] + s
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + s


def call(method, url, body=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {})}
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with local.open(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw[:1] in (b"{", b"[") else raw.decode())
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw[:1] in (b"{", b"[") else raw.decode())


def credential_id(cert_pem):
    der = x509.load_pem_x509_certificate(cert_pem.encode()).public_bytes(serialization.Encoding.DER)
    return "z" + b58(hashlib.sha384(der).digest())


def jwt_claims(token):
    p = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))


def attr_codes(claims):
    """the identity-attribute codes carried in an ephemeral-proof JWT, however they are nested."""
    found = []

    def walk(x):
        if isinstance(x, dict):
            if "code" in x and isinstance(x["code"], str):
                found.append(x["code"])
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    for k, v in claims.items():
        if "attribut" in k.lower():
            walk(v)
    return sorted(set(found))


def pop(private_key, alg):
    """a SignatureProof: sign '<timestamp>_<nonce>' with the consumer key. `alg` picks the ECDSA
    hash so we can match the SAP's configured signature-algorithm."""
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    nonce = str(uuid4())
    der = private_key.sign(f"{ts}_{nonce}".encode(), ec.ECDSA(alg))
    return {"timestamp": ts, "nonce": nonce, "signature": base64.b64encode(der).decode()}


def main():
    # EOSC attributes to assign the consumer (default: an EOSC-DestinE partner); the exchanged,
    # B-side attributes are written to exchange.json for the connector ABAC step (18-...).
    eosc_attrs = (sys.argv[1].split(",") if len(sys.argv) > 1 else ["CONSUMER", "EOSC_DESTINE_PARTNER"])
    org = "University of Example"
    print(f"1) onboard a consumer at A (EOSC), attributes {eosc_attrs}")
    key = ec.generate_private_key(ec.SECP256R1())
    pub_pem = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    uid = str(uuid4())
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([
               x509.NameAttribute(NameOID.COMMON_NAME, uid),
               x509.NameAttribute(NameOID.ORGANIZATION_NAME, org),
               x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "consumer"),
               x509.NameAttribute(NameOID.COUNTRY_NAME, "EU")]))
           .sign(key, hashes.SHA256()))
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()

    s, p = call("POST", f"http://localhost:{A['idp']}/tier1/v2/participants",
                {"organization": org, "contactEmail": "consumer@uni.example.eu",
                 "isAuthority": False, "publicGatewayUrl": "http://localhost:8200"})
    if s >= 300:
        sys.exit(f"   create participant failed: HTTP {s} {p}")
    pid = p["id"]
    print(f"   participant {pid}")
    s, _ = call("PUT", f"http://localhost:{A['idp']}/tier1/v2/participants/{pid}/csr", {"csr": csr_pem})
    print(f"   csr upload: HTTP {s}")
    s, cert = call("POST", f"http://localhost:{A['idp']}/tier1/v2/participants/{pid}/credentials",
                   {"reason": "federation exchange demo"})
    if s >= 300:
        sys.exit(f"   credential creation failed: HTTP {s} {cert}")
    content = cert["content"]
    cred_id = credential_id(content)
    print(f"   credential issued by A's CA; credential id {cred_id[:14]}...")

    # activate the credential at A (the agent's authp does this on install, over a Tier-2 callback)
    s, _ = call("PATCH", f"http://localhost:{A['idp']}/tier2/v2/credentials",
                {"newCredentialId": cred_id}, {"Credential-Id": cred_id})
    print(f"   credential activated at A: HTTP {s}")
    s, _ = call("PUT", f"http://localhost:{A['idp']}/tier2/v2/tierOnePublicKey",
                {"publicKey": pub_pem}, {"Credential-Id": cred_id})
    print(f"   tier-one public key registered: HTTP {s}")
    s, _ = call("PUT", f"http://localhost:{A['sap']}/tier1/v2/participants/{pid}/identityAttributes",
                [{"code": c} for c in eosc_attrs])
    print(f"   assigned {' + '.join(eosc_attrs)}: HTTP {s}")

    print("2) A issues an ephemeral proof to the consumer (proof of possession)")
    a_proof = None
    # the SAP's proof-of-possession signature-algorithm is "ECDSA", which resolves to SHA1withECDSA
    for alg_name, alg in (("SHA1withECDSA", hashes.SHA1()), ("SHA256withECDSA", hashes.SHA256())):
        s, tok = call("POST", f"http://localhost:{A['sap']}/tier2/v2/token",
                      pop(key, alg), {"Credential-Id": cred_id})
        if s < 300:
            a_proof = tok["token"]
            print(f"   A issued a proof (proof-of-possession alg {alg_name})")
            break
        print(f"   token with {alg_name}: HTTP {s} {str(tok)[:120]}")
    if not a_proof:
        sys.exit("   could not obtain an A-signed proof")
    a_codes = attr_codes(jwt_claims(a_proof))
    print(f"   A proof attributes: {a_codes}")

    print("3) B exchanges the A proof (trust check + BP02D mapping)")
    b_cred = credential_id(json.load(open(f"{STATE}/B/cert.json"))["content"])
    s, tok = call("POST", f"http://localhost:{B['sap']}/tier2/v2/token/exchange",
                  {"ephemeralProof": a_proof}, {"Credential-Id": b_cred})
    if s >= 300:
        sys.exit(f"   exchange failed: HTTP {s} {tok}")
    b_proof = tok["token"]
    b_codes = attr_codes(jwt_claims(b_proof))
    print(f"   B issued a proof after exchange; attributes: {b_codes}")

    print("4) check")
    # the exchange applied the BP02D mapping: CONSUMER->CONSUMER, EOSC_DESTINE_PARTNER->
    # DESTINE_UPGRADED_ACCESS; an EOSC-only code never appears raw on the B side.
    expected = {c for a in a_codes for c in {"CONSUMER": ["CONSUMER"],
                "EOSC_DESTINE_PARTNER": ["DESTINE_UPGRADED_ACCESS"]}.get(a, [])}
    ok = set(b_codes) == expected and "EOSC_DESTINE_PARTNER" not in b_codes
    print(f"   EOSC side (A):    {a_codes}")
    print(f"   DestinE side (B): {b_codes}")
    json.dump({"eosc_attributes": a_codes, "destine_attributes": b_codes},
              open(f"{STATE}/exchange.json", "w"), indent=2)
    print("\nLIVE FEDERATED EXCHANGE OK" if ok else "\nEXCHANGE RAN — review attributes above")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
