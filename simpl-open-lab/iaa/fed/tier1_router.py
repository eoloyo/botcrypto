#!/usr/bin/env python3
"""tier1_router.py <port> <authp-port> <sap-port> <idp-port> — stand-in for an authority's Tier-1
gateway, routing only: /authApi/** → authentication provider, /sapApi/** → security-attributes
provider, /identityManagementApi/** → identity provider (the prefixes another authority's identity
provider uses when it discovers this one, DiscoveryAdapterFactoryImpl). No authentication: the
discovery endpoints are the authority's public profile."""
import http.server
import sys
import urllib.error
import urllib.request

port, authp, sap, idp = (int(a) for a in sys.argv[1:5])
ROUTES = {"/authApi": authp, "/sapApi": sap, "/identityManagementApi": idp}
local = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class Router(http.server.BaseHTTPRequestHandler):
    def route(self):
        prefix = next((p for p in ROUTES if self.path.startswith(p + "/")), None)
        if prefix is None:
            return self.reply(404, b"no route", "text/plain")
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))) or None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection")}
        req = urllib.request.Request(f"http://localhost:{ROUTES[prefix]}{self.path[len(prefix):]}",
                                     data=body, headers=headers, method=self.command)
        try:
            with local.open(req, timeout=30) as r:
                self.reply(r.status, r.read(), r.headers.get("Content-Type", "application/json"))
        except urllib.error.HTTPError as e:
            self.reply(e.code, e.read(), e.headers.get("Content-Type", "application/json"))

    def reply(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        sys.stderr.write(f"{self.command} {self.path} → {code}\n")

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = route

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Router).serve_forever()
