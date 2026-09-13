#!/usr/bin/env python3
# Local Tier-1 OIDC signing authority: serves a JWKS and mints RS256 tokens the
# authentication_provider will accept (it RS256-verifies against its certs-endpoint).
import json, base64, time, sys, os
from http.server import BaseHTTPRequestHandler, HTTPServer
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
import jwt  # PyJWT

KID = "local-tier1"
KEY_PEM = "/tmp/claude-0/-home-user-botcrypto/4a0d9b60-0ac8-5e05-a42d-82e53b1735bc/scratchpad/tier1-rsa.pem"

def load_or_make_key():
    if os.path.exists(KEY_PEM):
        return serialization.load_pem_private_key(open(KEY_PEM,'rb').read(), password=None)
    k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    open(KEY_PEM,'wb').write(k.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    return k

key = load_or_make_key()
pub = key.public_key().public_numbers()
def b64u(n): 
    b = n.to_bytes((n.bit_length()+7)//8, 'big'); return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
JWKS = {"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":KID,"n":b64u(pub.n),"e":b64u(pub.e)}]}

def mint(pid, cid=None):
    now=int(time.time())
    claims={"sub":pid,"idp":"SIMPL_AUTH",
      "client-roles":["APPLICANT","SIMPL_USER","ONBOARDING_MANAGER",
        "TIER_1_AUTHORIZATION_MANAGER","TIER_1_USER_AND_ROLES_MANAGER",
        "TIER_2_AUTHORIZATION_MANAGER","TIER_2_IDENTITY_ATTRIBUTES_MANAGER"],
      "identity_attributes":[], "email":"provider@acme.example","preferred_username":"provider",
      "given_name":"Pro","family_name":"Vider","sid":"sess-1",
      "iss":"http://localhost:9099","iat":now,"exp":now+3600}
    if cid: claims["credential_id"]=cid
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid":KID})

if __name__=="__main__":
    if len(sys.argv)>1 and sys.argv[1]=="token":
        print(mint(sys.argv[2] if len(sys.argv)>2 else "did:web:provider", sys.argv[3] if len(sys.argv)>3 else None)); sys.exit(0)
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            b=json.dumps(JWKS).encode()
            self.send_response(200); self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
        def log_message(self,*a): pass
    HTTPServer(("127.0.0.1",9099),H).serve_forever()
