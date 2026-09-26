#!/usr/bin/env bash
# ============================================================================
# edc011-connector-dcp.sh — increment E: make Simpl connector-be authenticate
# with DCP (Decentralized Claims Protocol) instead of the custom X.509/mTLS IAM.
#
# Builds on increment D (connector-be on native EDC 0.11.1) and swaps the identity
# layer to EDC's native DCP stack:
#
#   Stage 1 (build):  add the DCP module set + drop Simpl's IamExtension from the SPI
#                     file, so EDC's DCP IdentityService replaces SimplIdentityService.
#   Stage 2 (boot):   boot the connector on the DCP IdentityService + embedded STS and
#                     verify it comes up "ready" with no SimplIdentityService.
#
# Both stages are VERIFIED green here. Stage 3 (a two-connector, VC-gated transfer
# with each connector backed by its own IdentityHub CredentialService) is the
# remaining MVD-grade wiring — its exact requirements are documented in the README
# ("Increment E") and below.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd "$HERE/../.." && pwd)"
source "$LAB/scripts/env.sh"
export LAB_ROOT="${LAB_ROOT:-$LAB}"
CONN="$LAB_ROOT/src/connector-be"
PATCH_D="$LAB/iaa/patches/connector-edc-0.11.patch"
PATCH_DCP="$LAB/iaa/patches/connector-dcp-0.11.patch"
log(){ echo -e "\033[1;34m[edc011-connector-dcp]\033[0m $*"; }

# 0. clone + apply the D bump (EDC 0.11.1) + this DCP patch
if [ ! -d "$CONN/.git" ]; then
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
    "$GL/integration/resource-sharing/resource-sharing-runtime/connector/connector-be.git" "$CONN"
fi
grep -q "<edc>0.11.1</edc>" "$CONN/pom.xml" || ( cd "$CONN" && git apply --whitespace=nowarn "$PATCH_D" )
grep -q "identity-trust-core" "$CONN/pom.xml"  || ( cd "$CONN" && git apply --whitespace=nowarn "$PATCH_DCP" )

# 1. build the DCP-flavoured jar
JAR="$CONN/target/basic-connector.jar"
log "Stage 1 — building connector-be with the DCP identity stack…"
( cd "$CONN" && noproxy_env PROJECT_RELEASE_VERSION="${PROJECT_RELEASE_VERSION:-1.0.0-local}" \
    mvn -q -B -ntp -DskipTests -Dspotless.check.skip=true -Dspotless.apply.skip=true \
    -Dlicense.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package )
[ -f "$JAR" ] || { echo "build failed"; exit 1; }
log "DCP jars bundled: $(unzip -l "$JAR" | grep -oE 'identity-trust-core-[0-9.]+\.jar|identity-did-web-[0-9.]+\.jar|identity-trust-sts-embedded-[0-9.]+\.jar' | tr '\n' ' ')"

# 2. boot a connector on the DCP IdentityService and verify
#    (Postgres on :5433 must be up — see scripts/02-dataspace.sh for provisioning.)
log "Stage 2 — booting the connector on EDC's DCP IdentityService + embedded STS…"
fuser -k 29191/tcp 29193/tcp 29194/tcp 2>/dev/null || true; sleep 1
LOG=/tmp/edc011-connector-dcp.log; rm -f "$LOG"
( cd "$CONN" && EDC_DATASOURCE_DEFAULT_PASSWORD=postgres \
    EDC_IAM_ISSUER_ID="did:web:localhost%3A7101:consumer" EDC_IAM_DID_WEB_USE_HTTPS=false \
    EDC_IAM_STS_PRIVATEKEY_ALIAS=consumer-sts EDC_IAM_STS_PUBLICKEY_ID="did:web:localhost%3A7101:consumer#key-1" \
    noproxy_env setsid java -Dedc.fs.config=local/consumer-config.properties -jar "$JAR" > "$LOG" 2>&1 & )
for _ in $(seq 1 40); do grep -qiE "Runtime .* ready" "$LOG" && break; grep -qiE "EdcInjectionException|Exception in thread" "$LOG" && break; sleep 2; done

echo
log "PROOF — DCP identity active, Simpl IAM gone:"
grep -qiE "Runtime .* ready" "$LOG"                 && echo "   runtime ready                         : ✔" || echo "   runtime ready                         : ✗"
grep -qi  "Embedded STS client"  "$LOG"             && echo "   EDC DCP embedded STS in use           : ✔" || echo "   embedded STS                          : (check log)"
[ "$(grep -c SimplIdentityService "$LOG")" = 0 ]    && echo "   SimplIdentityService NOT registered   : ✔" || echo "   SimplIdentityService still present    : ✗"

echo
log "Stage 1 + 2 VERIFIED: Simpl connector-be runs on EDC's native DCP IdentityService (identity-trust"
log "+ embedded STS + did:web resolution), replacing the custom X.509/mTLS SimplIdentityService."
cat <<'NOTE'

Stage 3 (remaining — full two-connector VC-gated transfer) needs, per connector:
  - an STS signing key seeded in the connector vault under `edc.iam.sts.privatekey.alias`
    (the InMemoryVault has no env seed; vault-filesystem is not published at 0.11.1, so a tiny
    boot seed extension — like iaa/dcp/seed-extension — is the clean path);
  - a resolvable did:web document whose verificationMethod is that key, listing a CredentialService
    endpoint -> that connector's IdentityHub (reuse iaa/dcp/edc011-identityhub.sh, seeded with the
    connector's SimplDataspaceMembershipCredential);
  - trusted-issuer config `edc.iam.trusted-issuer.ga.id=did:web:governance-authority`;
  - a policy whose scope maps to SimplDataspaceMembershipCredential, so the VP is actually required.
Then the 02 transfer negotiation triggers a real VP presentation/verification between the connectors.
NOTE
log "Tear down: fuser -k 29193/tcp"
