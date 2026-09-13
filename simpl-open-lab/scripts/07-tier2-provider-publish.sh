#!/usr/bin/env bash
# Reproduce the INTENDED provider-agent publication path (Tier-2 machine identity),
# not the catalogue's internal ingest API. See catalogue/PROVIDER-PUBLICATION.md.
#
# Intended chain:
#   sd-tooling-be (enrich -> sign via VC Issuer -> publish)
#     -> FederatedCatalogueTier2Client
#       -> [Tier-2 mTLS ephemeral-proof preflight against the IAA]
#         -> tier2-gateway (mTLS termination, routes /fc/*) -> fc-service
#
# This script stands up that subsystem incrementally. It is a WORK IN PROGRESS:
# the pieces marked [OK] run and are verified here; the pieces marked [TODO] are
# the remaining Tier-2 trust-fabric wiring (documented in PROVIDER-PUBLICATION.md).
#
#   [OK]   Redis (authentication_provider dependency)
#   [OK]   authentication_provider boots (Liquibase-migrated, participant profile)
#   [OK]   sd-tooling-be (the real publisher) boots and drives the publish to
#          exactly {tier2-gateway}/fc/self-descriptions via the Tier-2 client
#   [OK]   Tier-1 OIDC signing authority: iaa/jwks-tier1.py — auth-provider accepts
#          its RS256 tokens (TierOneAuthInfoRSAVerifier, JWKS at certs-endpoint)
#   [OK]   provider keypair + CSR via /tier1/v2/keypairs (+ /csr)
#   [OK]   CA enrollment: the Go shim issues certs with AIA, serves the CA cert at
#          the caIssuers URL, and runs an OCSP responder (iaa/ocsp-responder.py:
#          GOOD + verbatim critical nonce + SHA256 certID). Local credential
#          validation on POST /tier1/v2/credentials PASSES.
#   [BLOCKED] credential install then calls the Governance Authority over Tier-2
#          mTLS to register the credential (503, tx rolls back). Needs the
#          authority-side IAA + tier2-gateway mTLS + SAP — the two-sided trust
#          fabric. See catalogue/PROVIDER-PUBLICATION.md for the full analysis.
#   [OK]   authority-side authentication_provider (authority profile) as the GA:
#          boots on :8105, own DB (authority_authprovider), profile local-authority
#   [OK]   tier2-gateway (Spring Cloud Gateway) boots on :8443 and ENFORCES mTLS
#          (rejects no-client-cert). routes-authority.yml routes /identityApi,
#          /authApi, /sapApi to the backends; global filters EphemeralProof ->
#          OCSP -> Headers -> ABAC.
#   [TODO] point the gateway client-truststore at the CA shim; onboard the
#          participant in the GA; satisfy the ephemeral-proof + ABAC filters so
#          the credential registration passes through the mTLS mesh
#   [TODO] security-attributes-provider (SAP) for /sapApi/tier2/v2/token
#   [TODO] point sd-tooling-be at the gateway and publish through the full path
#
# FULL MESH now boots: fc-service, participant auth_provider (:8104), GA
# auth_provider (:8105), tier2-gateway (:8443 mTLS), sd-tooling-be (:8090),
# + jwks/ocsp/ca-shim/redis. The remaining work is mesh trust-wiring, not builds.
#
# The participant-side enrollment (all [OK] above) is reproduced by:
#   iaa/jwks-tier1.py  (Tier-1 tokens) + iaa/ocsp-responder.py + the ejbca-shim,
#   then: create keypair -> generate CSR (CN = participant UUID) -> shim pkcs10enroll
#   -> POST /tier1/v2/credentials (validation passes; GA registration is the wall).
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
IAA="$LAB_ROOT/src/iaa"
GL="https://code.europa.eu/simpl/simpl-open"
AUTHPROV_PORT=8104
SDTOOL_PORT=8090

# ---- Redis -------------------------------------------------------------------
if ! redis-cli -p 30379 -a admin ping 2>/dev/null | grep -q PONG; then
  nohup redis-server --port 30379 --requirepass admin > "$RUN/redis.log" 2>&1 &
  for _ in $(seq 1 10); do redis-cli -p 30379 -a admin ping 2>/dev/null | grep -q PONG && break; sleep 1; done
fi
log "Redis up on :30379"

# ---- authentication_provider -------------------------------------------------
# clone + build if missing
[ -d "$IAA/authentication_provider/.git" ] || \
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$GL/development/iaa/authentication_provider.git" "$IAA/authentication_provider"
AP="$IAA/authentication_provider"
[ -f "$AP"/target/authenticationprovider-local.jar ] || ( cd "$AP" && noproxy_env mvn -q -B -ntp -DskipTests \
   -Dspotless.check.skip=true -Dspotless.apply.skip=true -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package )

runuser -u postgres -- psql -p "$PG_PORT" -d postgres -c "CREATE DATABASE authprovider;" 2>/dev/null || true

if ! curl -s -o /dev/null "http://localhost:$AUTHPROV_PORT/actuator/health" 2>/dev/null; then
  # KEY boot facts learned:
  #  - profile 'local-consumer' == [local, participant]; the @Participant beans
  #    (InstallationServiceParticipantImpl) require the 'participant' profile.
  #  - do NOT exclude KafkaAutoConfiguration: KafkaMessagePublisher needs a
  #    KafkaTemplate bean (created lazily; the broker is not contacted at boot).
  #  - Liquibase migrates the empty DB on first boot (ddl-auto=validate).
  ( cd "$AP" && noproxy_env nohup java -jar target/authenticationprovider-local.jar \
      --spring.profiles.active=local-consumer \
      --server.port=$AUTHPROV_PORT \
      --spring.datasource.url=jdbc:postgresql://localhost:$PG_PORT/authprovider \
      --spring.datasource.username=postgres --spring.datasource.password=postgres \
      --client.authority.url=https://localhost:$SHIM_HTTPS \
      --open-id-connect.certs-endpoint=http://localhost:$KEYCLOAK_PORT/realms/simpl/protocol/openid-connect/certs \
      --microservice.identity-provider.url=http://localhost:$IDENTITY_PROVIDER_PORT \
      --management.otlp.tracing.endpoint=http://localhost:4318/v1/traces \
      --simpl.gateway.tier-one-url=http://localhost:8101 \
      --simpl.gateway.tier-two-url=https://localhost:8443 \
      > "$RUN/authprov.log" 2>&1 & echo $! > "$RUN/authprov.pid" )
  wait_http "http://localhost:$AUTHPROV_PORT/actuator/health" 90
fi
log "authentication_provider up on :$AUTHPROV_PORT (health: $(curl -s http://localhost:$AUTHPROV_PORT/actuator/health 2>/dev/null))"

# ---- sd-tooling-be (the real provider publisher) -----------------------------
[ -d "$LAB_ROOT/src/sd-tooling-be/.git" ] || GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
  "$GL/governance/resource-management/metadata-description/resource-description-tooling/sd-tooling-be.git" \
  "$LAB_ROOT/src/sd-tooling-be"
SDT="$LAB_ROOT/src/sd-tooling-be"
[ -f "$SDT"/target/sdtooling-api-be.jar ] || ( cd "$SDT" && noproxy_env mvn -q -B -ntp -DskipTests \
   -Dspotless.check.skip=true -Dspotless.apply.skip=true -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package )

if ! curl -s -o /dev/null "http://localhost:$SDTOOL_PORT/status" 2>/dev/null; then
  ( cd "$SDT" && noproxy_env nohup java -jar target/sdtooling-api-be.jar \
      --server.port=$SDTOOL_PORT \
      --web.mvc.bearer-token.required=false \
      --vc-issuer.api-key=localkey --vc-issuer.client-id=local-client \
      --vc-issuer.service.url=http://localhost:9085/vcIssuerService \
      --authentication-provider.service.url=http://localhost:$AUTHPROV_PORT \
      --federated-catalogue.tier2-gateway.url=https://localhost:8443 \
      --otel.sdk.disabled=true \
      > "$RUN/sdtool.log" 2>&1 & echo $! > "$RUN/sdtool.pid" )
  wait_http "http://localhost:$SDTOOL_PORT/status" 60
fi
log "sd-tooling-be up on :$SDTOOL_PORT (the real provider-agent publisher)"
log "publish target it drives: {federated-catalogue.tier2-gateway.url}/fc/self-descriptions"
log ""
log "Remaining Tier-2 wiring is [TODO] — see catalogue/PROVIDER-PUBLICATION.md."
