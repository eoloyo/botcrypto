#!/usr/bin/env python3
"""transfer_load.py <n> <payload-bytes> <provider-pid> — N simultaneous consumptions through the
Simpl connector (connector-be): N concurrent contract negotiations, then N concurrent transfers
(HttpData-PUSH, the only transfer type the basic connector enables), each with its own agreement as
N separate users of the consumer organisation would have.

Prints latency percentiles per phase, failures, delivered bytes and throughput, and the provider
connector process's CPU seconds and peak memory (sampled from /proc every 0.5 s)."""
import base64
import json
import os
import statistics
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

N, SIZE, PROVIDER_PID = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
P = "http://localhost:19193/management/v3"
C = "http://localhost:29193/management/v3"
PROTO = "http://localhost:19194/protocol"
SINK = "http://localhost:8902"
V = {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}
ASSET = f"load-asset-{SIZE}"
local = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(url, body=None, method=None):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "x-api-key": "password"},
                                 method=method)
    with local.open(req, timeout=120) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def setup_provider():
    for path, body in (
        ("/assets", {"@context": V, "@id": ASSET, "properties": {"name": f"load {SIZE} bytes"},
                     "dataAddress": {"type": "HttpData", "baseUrl": f"http://localhost:8901/data?size={SIZE}",
                                     "method": "GET"}}),
        ("/policydefinitions", {"@context": V, "@id": "load-open",
                                "policy": {"@context": "http://www.w3.org/ns/odrl.jsonld", "@type": "Set",
                                           "permission": [{"action": "use"}]}}),
        ("/contractdefinitions", {"@context": V, "@id": f"load-cdef-{SIZE}", "accessPolicyId": "load-open",
                                  "contractPolicyId": "load-open",
                                  "assetsSelector": [{"@type": "Criterion",
                                                      "operandLeft": "https://w3id.org/edc/v0.0.1/ns/id",
                                                      "operator": "=", "operandRight": ASSET}]})):
        try:
            call(P + path, body)
        except urllib.error.HTTPError as e:
            if e.code != 409:
                raise


def offer():
    cat = call(C + "/catalog/request", {"@context": V, "@type": "CatalogRequest", "counterPartyAddress": PROTO,
                                        "protocol": "dataspace-protocol-http"})
    ds = cat.get("dcat:dataset")
    ds = [d for d in (ds if isinstance(ds, list) else [ds]) if d.get("@id") == ASSET][0]
    off = ds["odrl:hasPolicy"]
    # other contract definitions in the provider DB (e.g. the pilot's destine-cdef, whose empty
    # assetsSelector matches every asset) add constrained offers; take the one from load-cdef
    own = base64.b64encode(f"load-cdef-{SIZE}".encode()).decode()
    return [o for o in (off if isinstance(off, list) else [off]) if o["@id"].split(":")[0] == own][0]["@id"]


def wait(url, done, timeout=600):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = call(url)
        if st.get("state") in done:
            return st
        time.sleep(0.5)
    return {"state": "TIMEOUT"}


def negotiate(offer_id):
    t0 = time.time()
    try:
        policy = {"@context": "http://www.w3.org/ns/odrl.jsonld", "@id": offer_id, "@type": "Offer",
                  "assigner": "provider", "target": ASSET, "permission": [{"action": "use"}],
                  "prohibition": [], "obligation": []}
        neg = call(C + "/contractnegotiations", {"@context": {**V, "odrl": "http://www.w3.org/ns/odrl/2/"},
                                                 "@type": "ContractRequest", "counterPartyAddress": PROTO,
                                                 "protocol": "dataspace-protocol-http", "policy": policy})
        st = wait(f"{C}/contractnegotiations/{neg['@id']}", ("FINALIZED", "TERMINATED"))
        return st.get("contractAgreementId"), time.time() - t0, st.get("state")
    except Exception as e:
        return None, time.time() - t0, f"ERROR {e}"


def transfer(i, agreement):
    t0 = time.time()
    try:
        tp = call(C + "/transferprocesses", {
            "@context": V, "@type": "TransferRequest", "counterPartyAddress": PROTO,
            "protocol": "dataspace-protocol-http", "contractId": agreement, "assetId": ASSET,
            "transferType": "HttpData-PUSH",
            "dataDestination": {"type": "HttpData", "baseUrl": f"{SINK}/t{i}", "method": "POST"}})
        st = wait(f"{C}/transferprocesses/{tp['@id']}", ("COMPLETED", "TERMINATED"))
        return time.time() - t0, st.get("state"), st.get("errorDetail")
    except Exception as e:
        return time.time() - t0, f"ERROR {e}", None


class Sampler(threading.Thread):
    """CPU seconds and peak RSS of the provider connector process."""
    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.peak_rss, self.running = pid, 0, True
        self.cpu0 = self.cpu()

    def cpu(self):
        f = open(f"/proc/{self.pid}/stat").read().rsplit(")", 1)[1].split()
        return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK")

    def run(self):
        while self.running:
            for line in open(f"/proc/{self.pid}/status"):
                if line.startswith("VmRSS:"):
                    self.peak_rss = max(self.peak_rss, int(line.split()[1]))
            time.sleep(0.5)


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))] if xs else 0


def sink_stats():
    return json.load(local.open(f"{SINK}/stats", timeout=10))


def main():
    setup_provider()
    offer_id = offer()
    rss0 = int([l for l in open(f"/proc/{PROVIDER_PID}/status") if l.startswith("VmRSS:")][0].split()[1])
    s = Sampler(PROVIDER_PID)
    s.start()
    print(f"{N} concurrent consumers, payload {SIZE / 1e6:.1f} MB each; provider RSS before: {rss0 / 1024:.0f} MB")

    t0 = time.time()
    with ThreadPoolExecutor(N) as ex:
        negs = list(ex.map(lambda _: negotiate(offer_id), range(N)))
    neg_wall = time.time() - t0
    ok = [a for a, _, st in negs if a]
    lat = [d for a, d, _ in negs if a]
    bad = [st for a, _, st in negs if not a]
    print(f"negotiations: {len(ok)}/{N} agreed in {neg_wall:.1f} s  "
          f"(p50 {pct(lat, 50):.1f} s, p90 {pct(lat, 90):.1f} s, max {max(lat, default=0):.1f} s)"
          + (f"  failures: {bad[:3]}" if bad else ""))

    before = sink_stats()
    t0 = time.time()
    with ThreadPoolExecutor(N) as ex:
        trs = list(ex.map(lambda ia: transfer(*ia), enumerate(ok)))
    tr_wall = time.time() - t0
    s.running = False
    after = sink_stats()
    lat = [d for d, st, _ in trs if st == "COMPLETED"]
    bad = [(st, (err or "")[:100]) for d, st, err in trs if st != "COMPLETED"]
    delivered = after["bytes"] - before["bytes"]
    complete = after["complete"] - before["complete"]
    print(f"transfers:    {len(lat)}/{len(ok)} COMPLETED in {tr_wall:.1f} s  "
          f"(p50 {pct(lat, 50):.1f} s, p90 {pct(lat, 90):.1f} s, max {max(lat, default=0):.1f} s)")
    print(f"delivered:    {complete} complete bodies, {delivered / 1e6:.1f} MB "
          f"-> {delivered / 1e6 / tr_wall:.1f} MB/s end to end")
    if bad:
        print(f"failures:     {len(bad)}  e.g. {bad[:3]}")
    print(f"provider:     {s.cpu() - s.cpu0:.0f} CPU-s over both phases, peak RSS {s.peak_rss / 1024:.0f} MB "
          f"(+{(s.peak_rss - rss0) / 1024:.0f} MB)")


if __name__ == "__main__":
    main()
