#!/usr/bin/env python3
"""source_sink.py — the two ends of the load test, in one process.

  :8901  source   GET /data?size=N streams N bytes (what the provider's data plane reads)
  :8902  sink     POST/PUT /<name> consumes the pushed body without storing it, and counts it;
                  GET /stats returns {"complete": n, "bytes": b}

Both answer with Connection: close: the data plane otherwise pools the connection and its retry on
a closed one cannot replay a consumed stream (see destine/eu_node_storage.py)."""
import http.server
import json
import threading
import urllib.parse

CHUNK = b"x" * 65536
lock = threading.Lock()
stats = {"complete": 0, "bytes": 0}


class Source(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        size = int(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("size", ["1048576"])[0])
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.send_header("Connection", "close")
        self.end_headers()
        left = size
        while left > 0:
            n = min(left, len(CHUNK))
            self.wfile.write(CHUNK[:n])
            left -= n

    def log_message(self, *a):
        pass


class Sink(http.server.BaseHTTPRequestHandler):
    def read_body(self):
        if "chunked" not in self.headers.get("Transfer-Encoding", "").lower():
            left, got = int(self.headers.get("Content-Length", 0)), 0
            while left > 0:
                b = self.rfile.read(min(left, 65536))
                if not b:
                    break
                got += len(b)
                left -= len(b)
            return got
        got = 0
        while True:
            size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
            if size == 0:
                self.rfile.readline()
                return got
            left = size
            while left > 0:
                b = self.rfile.read(min(left, 65536))
                left -= len(b)
                got += len(b)
            self.rfile.readline()

    def do_POST(self):
        got = self.read_body()
        with lock:
            stats["complete"] += 1
            stats["bytes"] += got
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    do_PUT = do_POST

    def do_GET(self):
        with lock:
            body = json.dumps(stats).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


for port, handler in ((8901, Source), (8902, Sink)):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
