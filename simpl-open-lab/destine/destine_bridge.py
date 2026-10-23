#!/usr/bin/env python3
"""destine_bridge.py — the DestinE side of the EOSC → DestinE pilot: turn DestinE Data Lake
collections into Simpl offers on a provider connector.

  destine_bridge.py plan     <out-dir>                 read the HDA STAC catalogue, write offers.json
                                                       and one Simpl self-description per offer
  destine_bridge.py register <out-dir> <mgmt-url>      create the asset, policy and contract
                                                       definition for every offer on the provider

The HDA STAC catalogue (collection metadata) is public; reading items or data needs a DestinE
account. Each offer therefore points its data address at dedl_access.py, the provider agent's
access layer, which fetches from HDA with DESTINE_TOKEN when one is set and otherwise from the
dataset's public producer (Eurostat) as a stand-in. Collections with no public producer (the
digital twins) only work with a token.

Policies mirror DestinE's access policy at organisation level, using the attribute check the Simpl
connector ships (ConsumptionConstraintFunction: the consumer must hold an identity attribute):
  open     DestinE "general public" data   → CONSUMER
  upgraded DestinE upgraded-access data    → DESTINE_UPGRADED_ACCESS
"""
import copy
import json
import os
import ssl
import sys
import urllib.request

HDA = "https://hda.data.destination-earth.eu/stac"
HERE = os.path.dirname(os.path.abspath(__file__))
SD_TEMPLATE = os.path.join(HERE, "..", "catalogue", "mock-data", "default-sd.json")
ACCESS_URL = os.environ.get("DEDL_ACCESS_URL", "http://localhost:8790")
PROVIDER_DSP = os.environ.get("PROVIDER_DSP_URL", "http://localhost:19194/protocol")

# Which collections to offer, their DestinE access tier, and the public stand-in (Eurostat dataset
# code + the subset baked into the offer: the basic connector pushes, so the query can't come from
# the consumer at transfer time).
OFFERS = {
    "STAT.EUSTAT.DAT.POP_DENSITY_NUTS3": {
        "tier": "open",
        "subset": "population density, all NUTS 3 regions, 2021",
        "standin": {"dataset": "demo_r_d3dens", "params": {"time": "2021"}},
    },
    "STAT.EUSTAT.DAT.SHARE_ENERGY_FROM_RENEWABLE": {
        "tier": "open",
        "subset": "renewable share of gross final energy consumption (%), all countries, 2015–2021",
        "standin": {"dataset": "nrg_ind_ren",
                    "params": {"nrg_bal": "REN", "unit": "PC",
                               "sinceTimePeriod": "2015", "untilTimePeriod": "2021"}},
    },
    "EO.ECMWF.DAT.DT_CLIMATE_ADAPTATION": {
        "tier": "upgraded",
        "subset": "Climate DT, 2 m temperature, one day (needs DestinE upgraded access)",
        "standin": None,
    },
}
POLICY = {"open": "CONSUMER", "upgraded": "DESTINE_UPGRADED_ACCESS"}
EDC = {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}
CONSUMPTION = "https://w3id.org/edc/v0.0.1/ns/consumption"


def fetch(url):
    ctx = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE") or None)
    with urllib.request.urlopen(url, timeout=60, context=ctx) as r:
        return json.load(r)


def asset_id(collection):
    return "destine-" + collection.lower().replace(".", "-").replace("_", "-")


def plan(out):
    os.makedirs(os.path.join(out, "self-descriptions"), exist_ok=True)
    offers = []
    for cid, cfg in OFFERS.items():
        c = fetch(f"{HDA}/collections/{cid}")
        providers = [p["name"] for p in c.get("providers", [])]
        licence = next((l["href"] for l in c.get("links", []) if l.get("rel") == "license"), c.get("license"))
        o = {
            "id": asset_id(cid),
            "collection": cid,
            "title": c["title"],
            "description": c.get("dedl:short_description") or c.get("description", "")[:300],
            "tier": cfg["tier"],
            "requires": POLICY[cfg["tier"]],
            "subset": cfg["subset"],
            "licence": licence,
            "providers": providers,
            "temporal": c.get("extent", {}).get("temporal", {}).get("interval", [[None, None]])[0],
            "stac": f"{HDA}/collections/{cid}",
            "standin": cfg["standin"],
            "access": f"{ACCESS_URL}/collections/{cid}",
        }
        offers.append(o)
        with open(os.path.join(out, "self-descriptions", o["id"] + ".json"), "w") as f:
            json.dump(self_description(o), f, indent=2)
        print(f"  {cid:46} tier={o['tier']:8} requires={o['requires']}")
    with open(os.path.join(out, "offers.json"), "w") as f:
        json.dump(offers, f, indent=2)
    print(f"{len(offers)} offers → {out}/offers.json")


def self_description(o):
    """A Simpl DataOffering self-description for the offer, from the lab's SD template: the
    generic service properties carry the DestinE metadata; the rest of the template is kept."""
    sd = copy.deepcopy(json.load(open(SD_TEMPLATE)))
    s = sd["credentialSubject"]
    s["@id"] = f"did:web:destine.example.eu:DataOffering:{o['id']}"
    g = s["simpl:generalServiceProperties"]
    g["simpl:name"] = o["title"]
    g["simpl:description"] = f"{o['description']} Subset: {o['subset']}. Source: DestinE Data Lake ({o['collection']})."
    g["simpl:serviceAccessPoint"] = {"@type": "xsd:anyURI", "@value": PROVIDER_DSP}
    s["simpl:dataProperties"]["simpl:format"] = "application/json"
    s["dct:source"] = {"@id": o["stac"]}
    s["dct:license"] = {"@id": o["licence"]} if o["licence"] else None
    s["dct:publisher"] = o["providers"]
    return sd


def mgmt(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "x-api-key": "password"})
    # the connector runs on localhost: no proxy
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        opener.open(req, timeout=30).read()
        return "created"
    except urllib.error.HTTPError as e:
        return "exists" if e.code == 409 else f"HTTP {e.code}: {e.read()[:200]!r}"


def register(out, base):
    offers = json.load(open(os.path.join(out, "offers.json")))
    # access policy: open, so every participant sees DestinE's offers in the catalogue
    print("  policy open-access:", mgmt(base, "/policydefinitions", {
        "@context": EDC, "@id": "open-access",
        "policy": {"@context": "http://www.w3.org/ns/odrl.jsonld", "@type": "Set", "permission": [{"action": "use"}]}}))
    for tier, code in POLICY.items():
        print(f"  policy destine-{tier} (requires {code}):", mgmt(base, "/policydefinitions", {
            "@context": {**EDC, "odrl": "http://www.w3.org/ns/odrl/2/"}, "@id": f"destine-{tier}",
            "policy": {"@context": "http://www.w3.org/ns/odrl.jsonld", "@type": "Set",
                       "permission": [{"action": "use", "constraint": {
                           "@type": "AtomicConstraint", "leftOperand": CONSUMPTION,
                           "operator": {"@id": "odrl:eq"}, "rightOperand": code}}]}}))
    for o in offers:
        print(f"  asset {o['id']}:", mgmt(base, "/assets", {
            "@context": EDC, "@id": o["id"],
            "properties": {"name": o["title"], "description": o["subset"], "destine:collection": o["collection"],
                           "destine:tier": o["tier"], "licence": o["licence"], "source": o["stac"]},
            "dataAddress": {"type": "HttpData", "baseUrl": o["access"], "method": "GET"}}))
        print(f"  contract {o['id']}:", mgmt(base, "/contractdefinitions", {
            "@context": EDC, "@id": "cdef-" + o["id"], "accessPolicyId": "open-access",
            "contractPolicyId": f"destine-{o['tier']}",
            "assetsSelector": [{"@type": "Criterion", "operandLeft": "https://w3id.org/edc/v0.0.1/ns/id",
                                "operator": "=", "operandRight": o["id"]}]}))


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "plan":
        plan(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "register":
        register(sys.argv[2], sys.argv[3].rstrip("/"))
    else:
        sys.exit(__doc__)
