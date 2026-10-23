#!/usr/bin/env python3
"""dedl_access.py <offers.json> [port] — the provider agent's access layer to the DestinE Data Lake.

The provider connector's data plane calls GET /collections/<id>; this answers with the offer's
baked subset:
  - DESTINE_TOKEN set  → HDA STAC search on the collection, then the first item's first asset,
                         with the token as a bearer (path written against the HDA STAC API, not
                         run in the lab: there is no DestinE account here)
  - otherwise          → the dataset's public producer (Eurostat dissemination API) as a stand-in;
                         403 for collections that have none (the digital twins)
It runs with the sandbox's internet proxy, which the connector itself does not use. In a real
deployment this is the provider agent's own HDA client, next to its data plane.
"""
import http.server
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request

HDA = "https://hda.data.destination-earth.eu/stac"
EUROSTAT = "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data"
offers = {o["collection"]: o for o in json.load(open(sys.argv[1]))}
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8790
token = os.environ.get("DESTINE_TOKEN")
ctx = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE") or None)


def get(url, headers=None, body=None):
    req = urllib.request.Request(url, data=body, headers=headers or {})
    with urllib.request.urlopen(req, timeout=120, context=ctx) as r:
        return r.read(), r.headers.get("Content-Type", "application/octet-stream")


def from_hda(o):
    auth = {"Authorization": f"Bearer {token}"}
    found, _ = get(f"{HDA}/search", {**auth, "Content-Type": "application/json"},
                   json.dumps({"collections": [o["collection"]], "limit": 1}).encode())
    items = json.loads(found).get("features", [])
    if not items:
        raise LookupError("no item in " + o["collection"])
    asset = next(iter(items[0]["assets"].values()))
    return get(asset["href"], auth)


def from_standin(o):
    s = o["standin"]
    q = urllib.parse.urlencode({"format": "JSON", "lang": "EN", **s["params"]})
    return get(f"{EUROSTAT}/{s['dataset']}?{q}")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        cid = urllib.parse.urlparse(self.path).path.rsplit("/", 1)[-1]
        o = offers.get(cid)
        try:
            if o is None:
                raise KeyError(cid)
            if token:
                body, ctype, source = *from_hda(o), "hda"
            elif o["standin"]:
                body, ctype, source = *from_standin(o), "standin:eurostat/" + o["standin"]["dataset"]
            else:
                return self.reply(403, b"no DestinE credentials: " + cid.encode() + b" is only served by HDA")
            self.reply(200, body, ctype, source)
        except KeyError:
            self.reply(404, b"unknown collection")
        except Exception as e:  # upstream failure → 502 so the transfer fails visibly
            self.reply(502, str(e).encode())

    def reply(self, code, body, ctype="text/plain", source=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if source:
            self.send_header("X-DestinE-Source", source)
        self.end_headers()
        self.wfile.write(body)
        sys.stderr.write(f"{self.path} → {code} {source or ''} {len(body)} bytes\n")

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
