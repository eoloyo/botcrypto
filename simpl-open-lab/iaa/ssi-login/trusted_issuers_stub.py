#!/usr/bin/env python3
"""trusted_issuers_stub.py <port> <issuer-did-file> — stand-in for Simpl's Users and Roles service.

Serves only what the OpenID4VP identity provider calls at every login: `GET /trustedIssuers`
(filtered on status=ENABLED), returning one trusted issuer whose `credentialQuery` is the walt.id
verifier2 session request (cross-device flow, DCQL query for a jwt_vc_json
SimplDataspaceMembershipCredential). Field names follow TrustedIssuerResponseDTO /
TrustedIssuersPagedResponseDTO of simpl-api-iaa 3.0.0. Each request is logged to stdout."""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
ISSUER_DID = open(sys.argv[2]).read().strip()
ISSUER_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, ISSUER_DID))

CREDENTIAL_QUERY = {
    "flow_type": "cross_device",
    "core_flow": {
        "dcql_query": {
            "credentials": [{
                "id": "simpl_membership",
                "format": "jwt_vc_json",
                "meta": {"type_values": [["VerifiableCredential", "SimplDataspaceMembershipCredential"]]},
            }]
        }
    },
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        print(f"[users-roles] GET {self.path}", flush=True)
        if not self.path.split("?")[0].endswith("/trustedIssuers"):
            self.send_error(404)
            return
        body = json.dumps({
            "items": [{
                "id": ISSUER_ID,
                "name": "Simpl dataspace membership",
                "issuerUri": ISSUER_DID,
                "keyIdentifier": ISSUER_DID + "#0",
                "credentialQuery": CREDENTIAL_QUERY,
                "status": "ENABLED",
                "creationTimestamp": "2026-10-29T00:00:00Z",
                "updateTimestamp": "2026-10-29T00:00:00Z",
            }],
            "page": 0, "pageSize": 10, "total": 1,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
