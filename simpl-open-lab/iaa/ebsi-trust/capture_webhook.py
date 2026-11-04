#!/usr/bin/env python3
"""capture_webhook.py <port> — logs every request the verifier2 `webhook` policy sends, replies 200."""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); raw = self.rfile.read(n)
        print("=== POST", self.path, dict(self.headers), flush=True); print(raw.decode()[:6000], flush=True)
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b'{"verified":true}')
    def log_message(self, *a): pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
