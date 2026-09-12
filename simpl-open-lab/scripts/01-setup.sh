#!/usr/bin/env bash
# One-time setup: install infra, download Keycloak, build the CA shim, clone+build Simpl services.
# Idempotent-ish: safe to re-run.
source "$(dirname "$0")/env.sh"

# ---- 1. system deps: PostgreSQL 16 + build tooling --------------------------
if ! command -v initdb >/dev/null 2>&1 && ! ls /usr/lib/postgresql/*/bin/initdb >/dev/null 2>&1; then
  log "Installing PostgreSQL..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq postgresql postgresql-contrib
fi
command -v java >/dev/null || { echo "Need Java 21"; exit 1; }
command -v mvn  >/dev/null || { echo "Need Maven 3.9+"; exit 1; }
command -v go   >/dev/null || { echo "Need Go 1.24+"; exit 1; }

# ---- 2. Python venv with moto (S3 mock; stands in for MinIO) -----------------
if [ ! -x "$LAB_ROOT/motoenv/bin/moto_server" ]; then
  log "Creating moto venv..."
  python3 -m venv "$LAB_ROOT/motoenv"
  "$LAB_ROOT/motoenv/bin/pip" install -q "moto[server]" boto3
fi

# ---- 3. Keycloak (identity provider, dev mode uses embedded H2) --------------
if [ ! -x "$LAB_ROOT/keycloak/bin/kc.sh" ]; then
  log "Downloading Keycloak 26.0.7..."
  curl -fsSL -o "$LAB_ROOT/keycloak.tar.gz" \
    https://github.com/keycloak/keycloak/releases/download/26.0.7/keycloak-26.0.7.tar.gz
  tar xzf "$LAB_ROOT/keycloak.tar.gz" -C "$LAB_ROOT"
  ln -sfn "$LAB_ROOT/keycloak-26.0.7" "$LAB_ROOT/keycloak"
fi

# ---- 4. build the lightweight EJBCA-compatible CA shim (Go, stdlib only) -----
log "Building EJBCA-shim..."
( cd "$REPO_LAB_DIR/ejbca-shim" && GOPROXY=off noproxy_env go build -o "$LAB_ROOT/ejbca-shim" . )

# ---- 5. clone + build the Simpl-Open services we run -------------------------
# repo path (under $GL) -> local dir name -> maven vs edc-runtime handled in build
declare -A REPOS=(
  [integration/resource-discovery/resource-catalogue/federated-catalogue/catalogue-be]=catalogue-be
  [integration/resource-sharing/resource-sharing-runtime/connector/connector-be]=connector-be
  [integration/resource-sharing/resource-sharing-runtime/connector/edc-connector-adapter-be]=edc-adapter
  [integration/resource-sharing/resource-sharing-runtime/resource-consumption/contract-consumption-adapter-be]=contract-consumption
  [governance/resource-management/metadata-description/validation/validation-be]=validation-be
  [development/iaa/identity-provider]=identity-provider
)
mkdir -p "$LAB_ROOT/src"
for path in "${!REPOS[@]}"; do
  dir="$LAB_ROOT/src/${REPOS[$path]}"
  [ -d "$dir/.git" ] || { log "Cloning ${REPOS[$path]}..."; GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$GL/$path.git" "$dir"; }
done

# Maven build helper (skips style/license/lint plugins; needs the two CI env vars).
mvnbuild() { # mvnbuild <dir> [package|test]
  local d="$1" goal="${2:-package}"
  log "Building $(basename "$d") ($goal)..."
  ( cd "$d" && noproxy_env mvn -q -B -ntp -DskipTests \
      -Dspotless.check.skip=true -Dspotless.apply.skip=true -Dlicense.skip=true \
      -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true "$goal" )
}
mvnbuild "$LAB_ROOT/src/catalogue-be"          package
mvnbuild "$LAB_ROOT/src/connector-be"          package   # produces target/basic-connector.jar (EDC runtime)
mvnbuild "$LAB_ROOT/src/edc-adapter"           package
mvnbuild "$LAB_ROOT/src/contract-consumption"  package
mvnbuild "$LAB_ROOT/src/validation-be"         package
mvnbuild "$LAB_ROOT/src/identity-provider"     package

log "Setup complete. Next: ./02-dataspace.sh   then   ./03-ga-iaa.sh"
