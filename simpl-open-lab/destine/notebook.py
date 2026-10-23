#!/usr/bin/env python3
"""notebook.py <token-file> <collection|list> — what the researcher runs in an EU Node notebook.

  1. who am I: the consumer agent's Keycloak validates the token (userinfo); the consumer agent's
     own rule lets only members of the climate research group (eduPersonEntitlement from the EOSC
     AAI) use DestinE data. This is the only per-user check: the provider sees the organisation.
  2. discover: the consumer connector asks the DestinE provider connector for its catalogue (DSP)
  3. contract: negotiate the offer; the provider's policy checks the organisation's attributes
  4. transfer: the provider's data plane pushes the subset into EU Node storage
  5. analyse it

Settings come from the environment (defaults match the lab): KC_URL, CONSUMER_MGMT_URL,
PROVIDER_DSP_URL, STORAGE_URL, STORAGE_DIR.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

KC = os.environ.get("KC_URL", "http://127.0.0.1:8180")
C = os.environ.get("CONSUMER_MGMT_URL", "http://localhost:29193/management/v3")
PROTO = os.environ.get("PROVIDER_DSP_URL", "http://localhost:19194/protocol")
STORAGE_URL = os.environ.get("STORAGE_URL", "http://localhost:8798")
STORAGE_DIR = os.environ.get("STORAGE_DIR", "/tmp/eu-node-storage")
GROUP = "urn:geant:eosc-federation.eu:group:climate-adaptation-research#aai.eosc.eu"
CONSUMPTION = "https://w3id.org/edc/v0.0.1/ns/consumption"
V = {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}
local = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(url, body=None, headers=None):
    h = {"Content-Type": "application/json", "x-api-key": "password", **(headers or {})}
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers=h)
    with local.open(req, timeout=60) as r:
        return json.load(r)


def as_list(x):
    return x if isinstance(x, list) else [x] if x else []


def whoami(token):
    try:
        me = call(f"{KC}/realms/consumer-agent/protocol/openid-connect/userinfo",
                  headers={"Authorization": "Bearer " + token, "x-api-key": ""})
    except urllib.error.HTTPError as e:
        sys.exit(f"1) login rejected by the consumer agent (HTTP {e.code})")
    groups = as_list(me.get("eduperson_entitlement"))
    print(f"1) {me['preferred_username']} from {as_list(me.get('schac_home_organization'))}, entitlements {groups}")
    if GROUP not in groups:
        print("   DENIED by the consumer agent: DestinE data is for the climate research group only")
        sys.exit(3)
    print("   allowed: member of the climate research group")


def catalogue():
    cat = call(f"{C}/catalog/request", {"@context": V, "@type": "CatalogRequest",
                                         "counterPartyAddress": PROTO, "protocol": "dataspace-protocol-http"})
    return {d.get("@id"): d for d in as_list(cat.get("dcat:dataset"))}


def offer_requirement(ds):
    off = as_list(ds["odrl:hasPolicy"])[0]
    c = as_list(off.get("odrl:permission"))[0].get("odrl:constraint", {})
    return off["@id"], c.get("odrl:rightOperand")


def negotiate(asset, offer_id, needs):
    policy = {"@context": "http://www.w3.org/ns/odrl.jsonld", "@id": offer_id, "@type": "Offer",
              "assigner": "provider", "target": asset,
              "permission": [{"action": "use", "constraint": {"@type": "AtomicConstraint",
                              "leftOperand": CONSUMPTION, "operator": {"@id": "odrl:eq"}, "rightOperand": needs}}],
              "prohibition": [], "obligation": []}
    neg = call(f"{C}/contractnegotiations", {"@context": {**V, "odrl": "http://www.w3.org/ns/odrl/2/"},
                                             "@type": "ContractRequest", "counterPartyAddress": PROTO,
                                             "protocol": "dataspace-protocol-http", "policy": policy})
    for _ in range(30):
        st = call(f"{C}/contractnegotiations/{neg['@id']}")
        if st.get("state") in ("FINALIZED", "TERMINATED"):
            return st.get("state"), st.get("contractAgreementId")
        time.sleep(2)
    return st.get("state"), None


def transfer(asset, agreement, name):
    tp = call(f"{C}/transferprocesses", {
        "@context": V, "@type": "TransferRequest", "counterPartyAddress": PROTO,
        "protocol": "dataspace-protocol-http", "contractId": agreement, "assetId": asset,
        "transferType": "HttpData-PUSH",
        "dataDestination": {"type": "HttpData", "baseUrl": f"{STORAGE_URL}/{name}", "method": "POST"}})
    for _ in range(45):
        st = call(f"{C}/transferprocesses/{tp['@id']}")
        if st.get("state") in ("COMPLETED", "TERMINATED"):
            return st.get("state"), st.get("errorDetail")
        time.sleep(2)
    return st.get("state"), "timed out"


def jsonstat_rows(doc):
    """Flatten a Eurostat JSON-stat 2.0 response into ({dimension: label}, value) rows."""
    ids, sizes, dims = doc["id"], doc["size"], doc["dimension"]
    keys = []
    for d in ids:
        idx = dims[d]["category"]["index"]
        order = sorted(idx, key=idx.get) if isinstance(idx, dict) else idx
        keys.append([(k, dims[d]["category"]["label"].get(k, k)) for k in order])
    for flat, v in doc["value"].items():
        n, row = int(flat), {}
        for d, size, k in reversed(list(zip(ids, sizes, keys))):
            row[d] = k[n % size]
            n //= size
        yield row, v


def analyse(collection, path):
    doc = json.load(open(path))
    rows = list(jsonstat_rows(doc))
    print(f"5) analysis of {doc.get('label')} ({len(rows)} values, Eurostat update {doc.get('updated', '?')[:10]})")
    if collection.endswith("POP_DENSITY_NUTS3"):
        nuts3 = [(r["geo"], v) for r, v in rows if len(r["geo"][0]) == 5]
        print(f"   {len(nuts3)} NUTS 3 regions; densest (inhabitants/km²):")
        for (code, label), v in sorted(nuts3, key=lambda x: -x[1])[:5]:
            print(f"     {code}  {label[:40]:40} {v:>9,.0f}")
    elif collection.endswith("SHARE_ENERGY_FROM_RENEWABLE"):
        by = {}
        for r, v in rows:
            by.setdefault(r["geo"], {})[r["time"][0]] = v
        change = [(g, s["2021"] - s["2015"]) for g, s in by.items() if "2015" in s and "2021" in s and len(g[0]) == 2]
        print("   largest rise in renewable share 2015→2021 (percentage points):")
        for (code, label), d in sorted(change, key=lambda x: -x[1])[:5]:
            print(f"     {code}  {label[:30]:30} {d:+5.1f}  (now {by[(code, label)]['2021']:.1f} %)")


def main(token_file, target):
    whoami(open(token_file).read().strip())
    offers = catalogue()
    print(f"2) DestinE offers in the provider's catalogue: {len(offers)}")
    for aid, ds in sorted(offers.items()):
        print(f"   {aid:55} needs {offer_requirement(ds)[1]}")
    if target == "list":
        return
    asset = "destine-" + target.lower().replace(".", "-").replace("_", "-")
    offer_id, needs = offer_requirement(offers[asset])
    state, agreement = negotiate(asset, offer_id, needs)
    print(f"3) contract for {asset}: {state}" + (f", agreement {agreement[:8]}…" if agreement else ""))
    if not agreement:
        print(f"   DENIED by DestinE's policy: the organisation lacks {needs}")
        sys.exit(4)
    name = asset + ".json"
    path = os.path.join(STORAGE_DIR, name)
    if os.path.exists(path):
        os.remove(path)
    state, err = transfer(asset, agreement, name)
    print(f"4) transfer: {state}" + (f" ({err})" if err else ""))
    if state != "COMPLETED" or not os.path.exists(path):
        print("   no data delivered")
        sys.exit(5)
    print(f"   delivered to EU Node storage: {path} ({os.path.getsize(path):,} bytes)")
    analyse(target, path)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
