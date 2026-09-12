#!/usr/bin/env bash
# Build + run the Tier-1 (and Tier-2) gateways.
#
# tier1-gateway is a Spring Cloud Gateway (reactive/Netty). In the authority
# profile it:
#   - proxies /auth/** -> Keycloak
#   - routes /identityApplicantApi/** -> identity-provider (:8103), /authApi/** -> authentication-provider, etc.
#   - proxies OCSP/CA/CRL to the CA (ejbca.url -> our shim on :30443)
#   - ENFORCES OIDC auth on the backend routes (Spring Security resource server,
#     jwt-configuration realms: primary=authority, applicant=onboarding)
#
# It boots and proxies out of the box. A *fully authenticated* call additionally needs
# (the official Kubernetes topology handles these; they are the remaining local wiring):
#   1. Keycloak realms `authority` and `onboarding` with a client + user + Simpl roles.
#   2. Keycloak's frontend/issuer URL aligned to the gateway's /auth path so the token
#      issuer (${gateway.url}/auth/realms/<realm>) matches what the gateway validates.
#   3. The backends' Tier-1 verifier (TierOneAuthInfoRSAVerifier) trusting the RS256 key
#      the token is signed with (Keycloak's realm key), i.e. the backend resolves the
#      right RSAPublicKey.
# tier2-gateway is the machine-to-machine (mTLS / Tier-2) enforcement point and additionally
# needs X.509 client certs issued by the CA — build it here; full mTLS wiring is a further step.
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
IAA="$LAB_ROOT/src"

# clone + build the gateways if needed
for g in tier1-gateway tier2-gateway; do
  [ -d "$IAA/$g/.git" ] || GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$GL/development/iaa/$g.git" "$IAA/$g"
  [ -f "$IAA/$g"/target/$g-*.jar ] || ( cd "$IAA/$g" && mvn -q -B -ntp -DskipTests \
      -Dspotless.check.skip=true -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package )
done

# boot tier1-gateway (authority profile) pointing at our Keycloak + backends + CA shim
JAR=$(ls "$IAA/tier1-gateway"/target/tier1-gateway-*.jar | grep -v original | head -1)
noproxy_env nohup java -jar "$JAR" \
  --spring.profiles.active=local,authority,local-authority \
  --keycloak.url=http://localhost:$KEYCLOAK_PORT \
  --ejbca.url=https://localhost:$SHIM_HTTPS \
  --identity-provider.url=http://localhost:$IDENTITY_PROVIDER_PORT \
  --server.port=8100 >"$RUN/tier1-gateway.log" 2>&1 & echo $! >"$RUN/tier1-gateway.pid"
wait_http "http://localhost:8100/auth/realms/master" 60

log "tier1-gateway on :8100"
log "  /auth/realms/master  -> $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8100/auth/realms/master)  (proxied to Keycloak)"
log "  /identityApplicantApi (no token) -> $(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8100/identityApplicantApi/tier1/v2/participants -H 'Content-Type: application/json' -d '{}')  (401 = auth enforced, expected)"
log "tier2-gateway jar built: $(ls "$IAA"/tier2-gateway/target/tier2-gateway-*.jar 2>/dev/null | grep -v original | head -1)"
log "See the header of this script for the remaining wiring to complete an authenticated call."
