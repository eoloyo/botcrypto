#!/usr/bin/env bash
# enroll.sh <authprov_port> <org> <is_authority true|false>
# Full provider/authority credential enrollment + onboarding seed + install.
# Echoes the participant UUID + credential id.
set -e
AP_PORT="$1"; ORG="$2"; ISAUTH="$3"
SCR=/tmp/claude-0/-home-user-botcrypto/4a0d9b60-0ac8-5e05-a42d-82e53b1735bc/scratchpad
UUID=$(python3 -c "import uuid;print(uuid.uuid4())")
TOK=$(python3 "$SCR/jwks-tier1.py" token "$UUID")
AUTHZ="Authorization: Bearer $TOK"

# 1) keypair
KPID=$(curl -s -X POST "http://localhost:$AP_PORT/tier1/v2/keypairs" -H "$AUTHZ" -H "Content-Type: application/json" \
  -d "{\"name\":\"kp-$UUID\",\"active\":true}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
# 2) CSR
CSR=$(curl -s -X POST "http://localhost:$AP_PORT/tier1/v2/keypairs/$KPID/csr" -H "$AUTHZ" -H "Content-Type: application/json" \
  -d "{\"commonName\":\"$UUID\",\"organization\":\"$ORG\",\"organizationalUnit\":\"dataspace\",\"country\":\"EU\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['csr'])")
# 3) sign via CA shim
LEAF=/tmp/$UUID-leaf.pem
python3 - "$CSR" "$LEAF" <<'PY'
import sys,json,urllib.request,ssl
r=json.load(urllib.request.urlopen(urllib.request.Request("https://localhost:30443/ejbca/ejbca-rest-api/v1/certificate/pkcs10enroll",
  data=json.dumps({"certificate_request":sys.argv[1],"certificate_authority_name":"ManagementCA","include_chain":True}).encode(),
  headers={"Content-Type":"application/json"}),context=ssl._create_unverified_context()))
open(sys.argv[2],"w").write("-----BEGIN CERTIFICATE-----\n"+"\n".join(r["certificate"][i:i+64] for i in range(0,len(r["certificate"]),64))+"\n-----END CERTIFICATE-----\n")
PY
# 4) compute credential id + seed identity-provider (authority_identityprovider DB)
CID=$(python3 - "$LEAF" <<'PY'
import hashlib,sys
from cryptography.x509 import load_pem_x509_certificate
from cryptography.hazmat.primitives.serialization import Encoding
der=load_pem_x509_certificate(open(sys.argv[1],"rb").read()).public_bytes(Encoding.DER)
A="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
def b58(b):
    n=int.from_bytes(b,'big');s=""
    while n>0:n,r=divmod(n,58);s=A[r]+s
    return "1"*(len(b)-len(b.lstrip(b'\0')))+s
print("z"+b58(hashlib.sha384(der).digest()))
PY
)
SERIAL=$(openssl x509 -in "$LEAF" -noout -serial | sed 's/serial=//')
B64=$(base64 -w0 "$LEAF")
PID=$(python3 -c "import uuid;print(uuid.uuid4())"); CREDROW=$(python3 -c "import uuid;print(uuid.uuid4())")
export PGPASSWORD=authority_identityprovider
psql -h 127.0.0.1 -p 5433 -U authority_identityprovider -d authority_identityprovider -v ON_ERROR_STOP=1 >/dev/null <<SQL
DELETE FROM credential WHERE credential_id='$CID';
INSERT INTO participant (id,organization,is_authority,participant_type,creation_timestamp,update_timestamp,applicant_email)
 VALUES ('$PID','$ORG',$ISAUTH,'UNDEFINED',now(),now(),'$UUID@local') ON CONFLICT (id) DO NOTHING;
INSERT INTO credential (id,participant_id,credential_type,certificate_authority,serial,credential_id,status,content,issuance_date,last_update_timestamp)
 VALUES ('$CREDROW','$PID','X509_IDENTITY','OnBoardingCA','$SERIAL','$CID','VALID',decode('$B64','base64'),now(),now());
UPDATE participant SET active_credential_id='$CREDROW' WHERE id='$PID';
SQL
# 5) install the credential on the auth_provider
RESP=$(python3 - "$TOK" "$LEAF" "$AP_PORT" <<'PY'
import sys,json,urllib.request
body=json.dumps({"content":open(sys.argv[2]).read(),"reason":"local onboarding"}).encode()
req=urllib.request.Request("http://localhost:"+sys.argv[3]+"/tier1/v2/credentials",data=body,headers={"Authorization":"Bearer "+sys.argv[1],"Content-Type":"application/json"},method="POST")
try:
  r=urllib.request.urlopen(req);print("install",r.status)
except urllib.error.HTTPError as e:
  print("install",e.code)
PY
)
ACTIVE=$(curl -s -H "$AUTHZ" "http://localhost:$AP_PORT/tier1/v2/credentials/active" | head -c 40)
echo "UUID=$UUID KPID=$KPID CID=$CID $RESP active_head=${ACTIVE:0:30}"
echo "$UUID" > /tmp/last-uuid.txt; echo "$LEAF" > /tmp/last-leaf.txt; echo "$CID" > /tmp/last-cid.txt
