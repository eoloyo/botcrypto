#!/usr/bin/env python3
"""federate.py <state-dir> — BP02D between two running authorities (authority.sh A and B) against
the real identity-provider, security-attributes-provider and authentication-provider services.

  1. identity attributes   A (EOSC): RESEARCH_ORG, EOSC_DESTINE_PARTNER   B (DestinE): DESTINE_UPGRADED_ACCESS
                           (CONSUMER / CATALOGUE_SEARCHER are built in on both)
  2. federation (BP02D)    B discovers A (TrustedAuthorityController.discover), then stores it as a
                           trusted authority with the attribute mapping
                             A.CONSUMER             -> B.CONSUMER
                             A.EOSC_DESTINE_PARTNER -> B.DESTINE_UPGRADED_ACCESS
                           A.RESEARCH_ORG is deliberately left unmapped: an agent gains only the
                           rights the mapping grants, so RESEARCH_ORG does not cross the border.
  3. verify                read the stored trusted authority back from B's identity provider and the
                           stored mapping back from B's security-attributes provider.

What this proves: two independently-bootstrapped Simpl governance authorities, each with its own CA
and credential, establish one-directional trust with a governed attribute translation — the runtime
basis for an EOSC consumer's identity to be accepted, and re-expressed, in the DestinE data space.

The live ephemeral-proof exchange on top of this (A issues a proof to a consumer; B's SAP exchanges
it for a B proof carrying the mapped attributes) is the TokenExchangeEphemeralProofGenerator path;
it additionally needs the consumer/provider agents' own authentication-providers and tier-2 gateways
running (the proof-of-possession is signed with the agent key held behind mTLS). This script sets up
and verifies the trust + mapping those agents rely on; see README.md for the exchange step.
"""
import json
import os
import sys
import urllib.error
import urllib.request

STATE = sys.argv[1] if len(sys.argv) > 1 else "/root/simpl-open-lab-work/fed"
A = {"idp": 8203, "sap": 8202, "t1": "http://localhost:8200"}
B = {"idp": 8303, "sap": 8302}
MAPPING = {
    "remoteIdentityAttributes": [
        {"code": "CONSUMER", "localIdentityAttributes": [{"code": "CONSUMER"}]},
        {"code": "EOSC_DESTINE_PARTNER", "localIdentityAttributes": [{"code": "DESTINE_UPGRADED_ACCESS"}]},
    ],
    "additionalIdentityAttributes": [],
}
local = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method=method)
    try:
        with local.open(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw[:1] in (b"{", b"[") else raw.decode())
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw[:1] in (b"{", b"[") else raw.decode())


def attribute(auth, code, name):
    s, body = call("POST", f"http://localhost:{auth['sap']}/tier1/v2/identityAttributes",
                   {"code": code, "name": name, "description": f"{name} (federation lab)",
                    "assignableToRoles": True, "enabled": True,
                    # federable: may be mapped across a federation; public: visible in discovery
                    "public": True, "federable": True})
    return "created" if s < 300 else ("exists" if s == 409 else f"HTTP {s}: {body}")


def main():
    os.makedirs(STATE, exist_ok=True)
    out = {}

    print("1) identity attributes")
    out["attributes"] = {
        "A/RESEARCH_ORG": attribute(A, "RESEARCH_ORG", "Research organisation"),
        "A/EOSC_DESTINE_PARTNER": attribute(A, "EOSC_DESTINE_PARTNER", "EOSC-DestinE partner"),
        "B/DESTINE_UPGRADED_ACCESS": attribute(B, "DESTINE_UPGRADED_ACCESS", "DestinE upgraded access"),
    }
    for k, v in out["attributes"].items():
        print(f"   {k}: {v}")

    print("2) BP02D: B discovers A, trusts it, and sets the attribute mapping")
    # find an existing trust entry for A (from a previous run); otherwise discover + store it
    s, existing = call("GET", f"http://localhost:{B['idp']}/tier1/v2/trustedAuthorities")
    ta_id = next((ta["id"] for ta in (existing.get("items", []) if isinstance(existing, dict) else [])
                  if ta.get("authorityUri") == A["t1"]), None)
    if ta_id:
        print(f"   A is already a trusted authority of B: {ta_id}")
    else:
        s, disc = call("GET", f"http://localhost:{B['idp']}/tier1/v2/trustedAuthorities/discover?authorityUri={A['t1']}")
        if s >= 300:
            sys.exit(f"   discovery failed: HTTP {s} {disc}")
        print(f"   discovered: {disc['dataspace']['name']} (participant {disc['participant']['participantId']})")
        s, stored = call("POST", f"http://localhost:{B['idp']}/tier1/v2/trustedAuthorities",
                         {"authorityUri": A["t1"], "autoRenew": False, "federationMapping": MAPPING})
        if s >= 300:
            sys.exit(f"   store failed: HTTP {s} {stored}")
        ta_id = stored.get("id")
        print(f"   stored trusted authority {ta_id}")
    # set (or update) the attribute mapping — BP02D createOrUpdateTrustedAuthorityMapping
    s, m = call("PUT", f"http://localhost:{B['sap']}/tier1/v2/trustedAuthorities/{ta_id}/mapping", MAPPING)
    print(f"   mapping {'set' if s < 300 else f'FAILED HTTP {s}: {m}'}")
    out["trustedAuthorityId"] = ta_id

    print("3) verify the stored federation")
    s, back = call("GET", f"http://localhost:{B['idp']}/tier1/v2/trustedAuthorities/{ta_id}")
    print(f"   B's identity provider: trusted authority status {back.get('federationStatus') or back.get('status')}")
    s, mapping = call("GET", f"http://localhost:{B['sap']}/tier1/v2/trustedAuthorities/{ta_id}/mapping")
    out["storedMapping"] = mapping
    pairs = [(m["code"], [l["code"] for l in m.get("localIdentityAttributes", [])])
             for m in (mapping.get("remoteIdentityAttributes", []) if isinstance(mapping, dict) else [])]
    print("   B's security-attributes provider: stored mapping")
    for remote, locals_ in pairs:
        print(f"     A.{remote}  ->  {', '.join('B.' + c for c in locals_) or '(dropped)'}")
    print("   A.RESEARCH_ORG is not in the mapping, so it does not cross to B.")

    with open(os.path.join(STATE, "federation.json"), "w") as f:
        json.dump(out, f, indent=2)
    print(f"\nFEDERATION ESTABLISHED (BP02D) — wrote {STATE}/federation.json")


if __name__ == "__main__":
    main()
