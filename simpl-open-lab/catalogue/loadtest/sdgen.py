"""sdgen.py — generate unique, schema-conformant Self-Descriptions from the lab's default SD.

Each call returns a DataOffering SD with a fresh @id and varied, searchable claims (name, description,
offering type, format, price, currency, provider), so the catalogue stores distinct entries and search
filters have something to match. Signature verification is off in this catalogue config
(federated-catalogue.verification.vc-signature=false), so the detached proof block is left as-is; what
is exercised is RDF extraction + SHACL schema + semantics + quality scoring + the Postgres write."""
import base64
import copy
import json
import os
import random
import uuid

_BASE = json.load(open(os.path.join(os.path.dirname(__file__), "..", "mock-data", "default-sd.json")))

FORMATS = ["xml", "json", "csv", "parquet", "geojson", "netcdf"]
TYPES = ["data", "service", "infrastructure"]
CURRENCIES = ["EUR", "PLN", "USD", "SEK"]
DOMAINS = ["energy", "mobility", "agriculture", "health", "earth-observation", "manufacturing"]
PRICE_TYPES = ["commercial", "free", "negotiated"]


def _b64id():
    return base64.urlsafe_b64encode(uuid.uuid4().bytes).rstrip(b"=").decode()


def make(seq=None):
    """Return one fresh SD dict. Only free-text fields are varied; SHACL-pinned enums (offeringType,
    format, currency, priceType) are left at the default so every SD stays schema-conformant. The
    domain keyword is embedded in name + description so search filters have something to match."""
    d = copy.deepcopy(_BASE)
    cs = d["credentialSubject"]
    domain = DOMAINS[seq % len(DOMAINS)] if seq is not None else random.choice(DOMAINS)
    tag = seq if seq is not None else uuid.uuid4().hex[:8]
    cs["@id"] = "did:web:registry.gaia-x.eu:DataOffering:" + _b64id()
    gsp = cs["simpl:generalServiceProperties"]
    gsp["simpl:name"] = f"{domain}-offering-{tag}"
    gsp["simpl:description"] = f"{domain} data offering {tag} for load testing"
    cs["simpl:providerInformation"]["simpl:contact"] = f"provider{(seq or random.randint(1, 400)) % 400}@example.eu"
    return d


if __name__ == "__main__":
    import sys
    json.dump(make(int(sys.argv[1]) if len(sys.argv) > 1 else None), sys.stdout)
