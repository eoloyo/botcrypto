#!/usr/bin/env bash
# run.sh — end-user wallet login (OpenID4VP) to a Simpl agent's Keycloak, end to end.
#
# Builds Simpl's ssi-verifier-keycloak-extension (code.europa.eu, branch $BRANCH), runs Keycloak 26.4
# with it, the walt.id verifier2 and wallet2, and a Users and Roles stand-in serving the trusted
# issuer, puts a membership credential in the wallet, and logs a user in through a headless browser.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/root/simpl-open-lab-work}"; RUN="$WORK/ssi-run"; SRC="$WORK/src-ssi/ssi-verifier"
BRANCH="${BRANCH:-feature/prepare-sprint-36}"
SHOTS="${SHOTS:-$RUN/shots}"; mkdir -p "$RUN" "$SHOTS"
log(){ echo "[$(date +%T)] $*"; }
up(){ until curl -s -o /dev/null "$1"; do sleep 2; done; }

# 1. extension from source
if [ ! -f "$SRC/target/deploy/credential-verifier-keycloak-extension-1.0.0-lab.jar" ]; then
  [ -d "$SRC" ] || git clone -q https://code.europa.eu/simpl/simpl-open/development/iaa/ssi-verifier-keycloak-extension.git "$SRC"
  git -C "$SRC" fetch -q origin && git -C "$SRC" checkout -q "origin/$BRANCH"
  ( cd "$SRC" && PROJECT_RELEASE_VERSION=1.0.0-lab /opt/maven/bin/mvn -q -s "$WORK/src-fed/maven-settings.xml" \
      -DskipTests -Dspotless.check.skip=true -Dlicense.skip=true package )
fi
log "extension $(git -C "$SRC" log -1 --format='%h %cd' --date=short) ($BRANCH)"

# 2. walt.id wallet2 (:7006) and verifier2 (:7004); verifier image from mirror.gcr.io if Docker Hub rate-limits
docker info >/dev/null 2>&1 || { (dockerd >/tmp/dockerd.log 2>&1 &); until docker info >/dev/null 2>&1; do sleep 1; done; }
VERIFIER_IMG="${VERIFIER_IMG:-mirror.gcr.io/waltid/verifier-api2:latest}"
mkdir -p "$RUN/wallet-config"; cp "$SRC"/local/waltid/wallet/config/*.conf "$RUN/wallet-config/"
docker rm -f waltid-wallet2 waltid-verifier2 keycloak-ssi >/dev/null 2>&1 || true
docker run -d --name waltid-wallet2 --network host -v "$RUN/wallet-config:/waltid-wallet-api2/config" waltid/wallet-api2:latest >/dev/null
docker run -d --name waltid-verifier2 --network host "$VERIFIER_IMG" >/dev/null
up http://localhost:7006/livez; up http://localhost:7004/; log "wallet2 :7006, verifier2 :7004"

# 3. the user's wallet: key, did:key, and a membership credential from the (lab) trusted issuer
WID=$(curl -s -X POST -H 'Content-Type: application/json' -d '{}' localhost:7006/wallet | python3 -c 'import sys,json;print(json.load(sys.stdin)["walletId"])')
curl -s -X POST -H 'Content-Type: application/json' -d '{"keyType":"secp256r1","backend":"jwk"}' localhost:7006/wallet/$WID/keys/generate >/dev/null
HOLDER=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"method":"key"}' localhost:7006/wallet/$WID/dids/create | python3 -c 'import sys,json;print(json.load(sys.stdin)["did"])')
JWT=$(python3 "$HERE/mint_credential.py" "$HOLDER" "$RUN")
python3 -c 'import json,sys;print(json.dumps({"rawCredential":sys.argv[1],"label":"Simpl membership"}))' "$JWT" |
  curl -s -X POST -H 'Content-Type: application/json' -d @- localhost:7006/wallet/$WID/credentials/import >/dev/null
log "wallet $WID holds a jwt_vc_json SimplDataspaceMembershipCredential for $HOLDER"

# 4. Users and Roles stand-in (trusted issuers) and Keycloak with the extension
pkill -f trusted_issuers_stub.py 2>/dev/null || true
nohup python3 "$HERE/trusted_issuers_stub.py" 8082 "$RUN/issuer.did" > "$RUN/users-roles.log" 2>&1 &
mkdir -p "$RUN/kc-import" "$RUN/kc-providers"; cp "$SRC"/target/deploy/*.jar "$RUN/kc-providers/"
python3 "$HERE/make_realm.py" "$SRC/local/keycloak/import/realm-authority.json" "$RUN/kc-import/realm-authority.json" \
  http://localhost:7004 http://localhost:8082
docker run -d --name keycloak-ssi --network host -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -e KC_HTTP_PORT=8180 -e KC_HOSTNAME_STRICT=false -v "$RUN/kc-providers:/opt/keycloak/providers" \
  -v "$RUN/kc-import:/opt/keycloak/data/import" quay.io/keycloak/keycloak:26.4 start-dev --import-realm >/dev/null
up http://localhost:8180/realms/authority/.well-known/openid-configuration; log "keycloak :8180 realm authority"

# 5. the login
NODE_PATH=$(npm root -g) node "$HERE/login.js" "$WID" "$SHOTS"
