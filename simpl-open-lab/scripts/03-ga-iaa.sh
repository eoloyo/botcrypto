#!/usr/bin/env bash
# Bring up the Governance Authority identity stack: Keycloak + the CA shim (EJBCA replacement)
# + identity-provider, then issue and verify a real participant X.509 credential.
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
start_bg() { local name="$1"; shift; log "starting $name"; noproxy_env nohup "$@" >"$RUN/$name.log" 2>&1 & echo $! >"$RUN/$name.pid"; }

# ---- CA shim (implements the exact EJBCA REST surface Simpl uses) ------------
if ! curl -s -o /dev/null "http://localhost:$SHIM_HTTP/status" 2>/dev/null; then
  start_bg ejbca-shim "$LAB_ROOT/ejbca-shim"
  wait_http "http://localhost:$SHIM_HTTP/status" 20
fi
log "CA shim up (HTTP :$SHIM_HTTP, HTTPS :$SHIM_HTTPS)"

# ---- Keycloak (OIDC identity core) ------------------------------------------
if ! curl -s -o /dev/null "http://localhost:$KEYCLOAK_PORT/" 2>/dev/null; then
  KC_BOOTSTRAP_ADMIN_USERNAME=admin KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
    start_bg keycloak "$LAB_ROOT/keycloak/bin/kc.sh" start-dev --http-port=$KEYCLOAK_PORT --http-host=127.0.0.1
  for i in $(seq 1 40); do curl -s -o /dev/null "http://localhost:$KEYCLOAK_PORT/realms/master" && break; sleep 2; done
fi
log "Keycloak up on :$KEYCLOAK_PORT"

# ---- Postgres DB for identity-provider --------------------------------------
runuser -u postgres -- psql -p $PG_PORT -d postgres <<'SQL' 2>/dev/null || true
CREATE ROLE authority_identityprovider LOGIN PASSWORD 'authority_identityprovider';
CREATE DATABASE authority_identityprovider OWNER authority_identityprovider;
SQL

# ---- truststore so identity-provider trusts the shim's TLS cert --------------
TRUST="$LAB_ROOT/run/shim-trust.jks"
echo | openssl s_client -connect localhost:$SHIM_HTTPS -servername localhost 2>/dev/null | openssl x509 > "$RUN/shim-server.pem"
rm -f "$TRUST"
"$JAVA_HOME/bin/keytool" -importcert -noprompt -alias shim -file "$RUN/shim-server.pem" -keystore "$TRUST" -storepass changeit >/dev/null 2>&1
log "shim truststore built"

# ---- boot identity-provider against the shim --------------------------------
IDP="$LAB_ROOT/src/identity-provider"; JAR="$(ls "$IDP"/target/identity-provider-*.jar | grep -v original | head -1)"
if ! curl -s -o /dev/null "http://localhost:$IDENTITY_PROVIDER_PORT/actuator/health" 2>/dev/null; then
  start_bg identity-provider java -jar "$JAR" \
    --spring.profiles.active=local \
    --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/authority_identityprovider \
    --spring.datasource.username=authority_identityprovider \
    --spring.datasource.password=authority_identityprovider \
    --spring.ssl.bundle.jks.ejbca.truststore.location="file:$TRUST" \
    --spring.ssl.bundle.jks.ejbca.truststore.password=changeit \
    --ejbca.url=https://localhost:$SHIM_HTTPS \
    --server.port=$IDENTITY_PROVIDER_PORT \
    --simpl.automatic-renewal.default-initialization.use-api=false
  wait_http "http://localhost:$IDENTITY_PROVIDER_PORT/actuator/health" 90
fi
log "identity-provider health: $(curl -s http://localhost:$IDENTITY_PROVIDER_PORT/actuator/health)"

# ---- issue + verify a participant credential --------------------------------
IDPAPI="http://localhost:$IDENTITY_PROVIDER_PORT/tier1/v2"
log "creating participant"
PID=$(curl -s -X POST $IDPAPI/participants -H "Content-Type: application/json" \
  -d '{"organization":"Acme Data Corp","applicantEmail":"applicant@acme.example","isAuthority":false}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
log "participant=$PID  -> generating CSR + submitting"
openssl req -newkey rsa:2048 -nodes -keyout "$RUN/part.key" -out "$RUN/part.csr" \
  -subj "/CN=$PID/O=Acme Data Corp/OU=agents/C=BE" >/dev/null 2>&1
python3 - "$IDPAPI" "$PID" "$RUN/part.csr" <<'PY'
import sys,json,urllib.request
idp,pid,csrf=sys.argv[1],sys.argv[2],sys.argv[3]
csr=open(csrf).read()
urllib.request.urlopen(urllib.request.Request(f"{idp}/participants/{pid}/csr",data=json.dumps({"csr":csr}).encode(),headers={"Content-Type":"application/json"},method="PUT"))
print("CSR submitted")
PY
log "requesting credential (identity-provider -> CA shim pkcs10enroll)"
curl -s -X POST $IDPAPI/participants/$PID/credentials -H "Content-Type: application/json" \
  -d '{"reason":"initial enrollment"}' | python3 -c "import sys,json;d=json.load(sys.stdin);print('credential status=',d.get('status'),'id=',str(d.get('credentialId'))[:20])"

log "verifying issued cert from Postgres chains to the shim CA"
export PGPASSWORD=authority_identityprovider
psql -h 127.0.0.1 -p $PG_PORT -U authority_identityprovider -d authority_identityprovider -tA \
  -c "select encode(content,'hex') from credential limit 1;" | tr -d ' \n' \
  | python3 -c "import sys;open('$RUN/ga-chain.pem','wb').write(bytes.fromhex(sys.stdin.read()))"
python3 - "$RUN" <<'PY'
import re,sys,subprocess
run=sys.argv[1]; pem=open(f"{run}/ga-chain.pem").read()
c=re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",pem,re.S)
open(f"{run}/leaf.pem","w").write(c[0]+"\n"); open(f"{run}/ca.pem","w").write(c[1]+"\n")
print(subprocess.run(["openssl","x509","-in",f"{run}/leaf.pem","-noout","-subject","-issuer","-serial"],capture_output=True,text=True).stdout)
print(subprocess.run(["openssl","verify","-CAfile",f"{run}/ca.pem",f"{run}/leaf.pem"],capture_output=True,text=True).stdout)
PY
log "DONE. The Governance Authority issued a verifiable X.509 identity via the lightweight CA."
