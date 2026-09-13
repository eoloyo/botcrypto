#!/usr/bin/env python3
# Minimal quality-scoring-service stub for the Federated Catalogue.
# Returns a JSON-LD quality report the catalogue parses (sh:ValidationReport ->
# mqr:hasProfileScore with weightedScore >= thresholdValue so publish passes).
from http.server import BaseHTTPRequestHandler, HTTPServer
import json

REPORT = {
  "@context": {"sh": "http://www.w3.org/ns/shacl#", "mqr": "http://example.org/mqr/report#"},
  "@id": "urn:qs:report:1",
  "@type": "sh:ValidationReport",
  "sh:conforms": True,
  "mqr:hasProfileScore": {
    "@id": "urn:qs:profilescore:1",
    "mqr:weightedScore": 1.0,
    "mqr:thresholdValue": 0.0,
    "mqr:classificationLabel": "A",
    "mqr:thresholdStatus": "PASSED",
    "mqr:reachedClassification": "A"
  },
  "mqr:hasDimensionScore": [{
    "@id": "urn:qs:dim:1",
    "mqr:dimensionName": "completeness",
    "mqr:score": 1.0,
    "mqr:thresholdValue": 0.0,
    "mqr:classificationLabel": "A",
    "mqr:thresholdStatus": "PASSED"
  }],
  "mqr:hasRuleEvaluation": [{
    "@id": "urn:qs:rule:1",
    "mqr:rule": "R1", "mqr:ruleName": "has-title", "mqr:status": "PASSED"
  }]
}

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        ln = int(self.headers.get("Content-Length", 0)); self.rfile.read(ln)
        self._send(200, REPORT)
    def do_GET(self):
        self._send(200, {"status": "UP"})
    def log_message(self, *a): pass

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8085), H).serve_forever()
