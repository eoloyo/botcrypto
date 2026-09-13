#!/usr/bin/env python3
# Minimal OCSP responder for the local Simpl lab. Signs GOOD responses with the
# shim CA key and echoes the request nonce in responseExtensions (which the Simpl
# IAA OCSP client requires, and which x/crypto/ocsp cannot emit).
import sys, glob
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime, timezone, timedelta
from cryptography import x509
from cryptography.x509 import ocsp
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.serialization import load_pem_private_key

CA   = x509.load_pem_x509_certificate(open("/tmp/shim-ca.pem","rb").read())
CKEY = load_pem_private_key(open("/tmp/shim-ca.key","rb").read(), password=None)
NONCE_OID = x509.ObjectIdentifier("1.3.6.1.5.5.7.48.1.2")

def _der_len(b, i):
    # returns (length, index-after-length-bytes)
    n = b[i]; i += 1
    if n & 0x80 == 0:
        return n, i
    k = n & 0x7f; ln = 0
    for _ in range(k):
        ln = (ln << 8) | b[i]; i += 1
    return ln, i

def extract_nonce_extnvalue(der):
    # Find the nonce OID, then return the CONTENT of the following extnValue OCTET STRING.
    oid = bytes([0x06,0x09,0x2B,0x06,0x01,0x05,0x05,0x07,0x30,0x01,0x02])
    i = der.find(oid)
    if i < 0:
        return None
    j = i + len(oid)
    # optional critical BOOLEAN could appear; skip if present
    if j < len(der) and der[j] == 0x01:  # BOOLEAN
        ln, j = _der_len(der, j+1); j += ln
    if j >= len(der) or der[j] != 0x04:  # extnValue OCTET STRING
        return None
    ln, j = _der_len(der, j+1)
    return der[j:j+ln]

def load_known_leaves():
    # Every provider/agent leaf the lab has issued (serial -> cert).
    out = {}
    for p in glob.glob("/tmp/prov-*.pem") + glob.glob("/tmp/agent-*.pem") + glob.glob("/tmp/*-leaf.pem"):
        try:
            c = x509.load_pem_x509_certificate(open(p,"rb").read())
            out[c.serial_number] = c
        except Exception:
            pass
    return out

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        ln = int(self.headers.get("Content-Length", 0))
        der = self.rfile.read(ln)
        open("/tmp/last-ocsp-req.bin","wb").write(der)
        try:
            req = ocsp.load_der_ocsp_request(der)
        except Exception as e:
            self.send_response(400); self.end_headers(); self.wfile.write(str(e).encode()); return
        leaves = load_known_leaves()
        leaf = leaves.get(req.serial_number)
        b = ocsp.OCSPResponseBuilder()
        if leaf is not None:
            b = b.add_response(cert=leaf, issuer=CA, algorithm=hashes.SHA256(),
                               cert_status=ocsp.OCSPCertStatus.GOOD,
                               this_update=datetime.now(timezone.utc)-timedelta(minutes=1),
                               next_update=datetime.now(timezone.utc)+timedelta(days=7),
                               revocation_time=None, revocation_reason=None)
            b = b.responder_id(ocsp.OCSPResponderEncoding.NAME, CA)
            # Echo the request's nonce extnValue VERBATIM (BouncyCastle and
            # cryptography wrap the nonce differently; a verbatim echo always matches).
            raw = extract_nonce_extnvalue(der)
            if raw is not None:
                # The Simpl client marks the nonce extension critical=TRUE and compares
                # the FULL extension DER, so echo it critical too.
                b = b.add_extension(x509.UnrecognizedExtension(NONCE_OID, raw), critical=True)
            resp = b.sign(CKEY, hashes.SHA256())
        else:
            resp = ocsp.OCSPResponseBuilder.build_unsuccessful(ocsp.OCSPResponseStatus.UNAUTHORIZED)
        out = resp.public_bytes(serialization.Encoding.DER)
        self.send_response(200); self.send_header("Content-Type","application/ocsp-response")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"OCSP responder up")
    def log_message(self,*a): pass

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 30081), H).serve_forever()
