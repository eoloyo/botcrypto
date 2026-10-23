#!/usr/bin/env python3
"""eu_node_storage.py <dir> [port] — the researcher's EU Node workspace (stand-in for File Sync &
Share): the consumer connector pushes transferred data here; each POST /<name> is saved as
<dir>/<name>."""
import http.server
import os
import sys

root = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8798
os.makedirs(root, exist_ok=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        name = os.path.basename(self.path.split("?", 1)[0].strip("/")) or "upload"
        body = self.read_body()
        with open(os.path.join(root, name), "wb") as f:
            f.write(body)
        sys.stderr.write(f"stored {name}: {len(body)} bytes\n")
        self.send_response(200)
        self.send_header("Content-Length", "0")
        # without this the data plane pools the connection, the next push finds it closed and its
        # retry cannot replay the already-consumed source stream ("IOException: closed")
        self.send_header("Connection", "close")
        self.end_headers()

    do_PUT = do_POST

    def read_body(self):
        if "chunked" not in self.headers.get("Transfer-Encoding", "").lower():
            return self.rfile.read(int(self.headers.get("Content-Length", 0)))
        # the connector's data plane streams the push with chunked encoding
        body = b""
        while True:
            size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
            if size == 0:
                self.rfile.readline()
                return body
            body += self.rfile.read(size)
            self.rfile.readline()

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
