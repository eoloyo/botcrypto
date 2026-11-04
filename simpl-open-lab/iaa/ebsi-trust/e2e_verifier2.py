#!/usr/bin/env python3
"""e2e_verifier2.py — the EBSI trust policy inside the real walt.id verifier2, same credential, with/without.

Needs walt.id verifier2 (:7004) + wallet2 (:7006) and ebsi_trust_webhook.py (:8091) running (see run.sh).
The wallet holds a credential from the lab issuer (did:jwk, ES256) — an issuer EBSI has never heard of.

  A) policies = [signature]                    -> what Simpl's Tier-1 login does today
  B) policies = [signature, webhook(EBSI)]     -> same credential, EBSI issuer trust added

Both go through the same OpenID4VP exchange (wallet presents, verifier2 evaluates, we read the session)."""
import json
import sys
import time
import urllib.request

VERIFIER, WALLET = "http://localhost:7004", "http://localhost:7006"
WEBHOOK = "http://127.0.0.1:8091/verify"
RUN = "/root/simpl-open-lab-work/ssi-run"


def call(method, url, body=None):
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=60) as r:
        return json.load(r)


def verify(wallet_id, vc_policies):
    query = {"flow_type": "cross_device", "core_flow": {
        "dcql_query": {"credentials": [{"id": "simpl_membership", "format": "jwt_vc_json",
                                        "meta": {"type_values": [["VerifiableCredential", "SimplDataspaceMembershipCredential"]]}}]},
        "policies": {"vc_policies": vc_policies}}}
    s = call("POST", f"{VERIFIER}/verification-session/create", query)
    call("POST", f"{WALLET}/wallet/{wallet_id}/credentials/present", {"requestUrl": s["bootstrapAuthorizationRequestUrl"]})
    for _ in range(30):
        info = call("GET", f"{VERIFIER}/verification-session/{s['sessionId']}/info")
        if info["status"] in ("SUCCESSFUL", "FAILED", "UNSUCCESSFUL"):
            break
        time.sleep(1)
    return info


def summarise(info):
    res = info.get("policy_results") or {}
    rows = []
    for p in res.get("vc_policies") or []:
        pol = p["policy"]["policy"]
        why = ""
        if not p.get("success"):
            why = json.dumps(p.get("error") or p.get("result") or p.get("errors") or "")[:160]
        rows.append(f"    vc policy {pol:10s} {'PASS' if p.get('success') else 'FAIL'} {why}")
    return info["status"], res.get("overallSuccess"), rows


def main():
    wid = open(f"{RUN}/ebsi-wid").read().strip()
    out = {}
    for label, pols in (("A  signature only (today)", [{"policy": "signature"}]),
                        ("B  signature + EBSI issuer trust", [{"policy": "signature"}, {"policy": "webhook", "url": WEBHOOK}])):
        status, overall, rows = summarise(verify(wid, pols))
        print(f"{label}\n    session {status}, overallSuccess={overall}")
        print("\n".join(rows))
        out[label[0]] = (status, overall)
    ok = out["A"][1] is True and out["B"][1] is False
    print("\nRESULT:", "EBSI policy rejects the non-EBSI issuer that today's login accepts" if ok else "UNEXPECTED — inspect")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
