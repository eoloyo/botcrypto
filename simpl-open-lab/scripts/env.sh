#!/usr/bin/env bash
# Shared configuration for the Simpl-Open local lab.
# Source this from the other scripts:  source "$(dirname "$0")/env.sh"
set -euo pipefail

# ---- where everything lives -------------------------------------------------
LAB_ROOT="${LAB_ROOT:-$HOME/simpl-open-lab-work}"     # clones, jars, runtime state
export LAB_ROOT
mkdir -p "$LAB_ROOT"
REPO_LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # this repo's simpl-open-lab/
export REPO_LAB_DIR

# ---- Simpl GitLab -----------------------------------------------------------
export GL="https://code.europa.eu/simpl/simpl-open"
# The private-but-anonymously-readable Maven package registry group id (simpl-open):
export CI_API_V4_URL="https://code.europa.eu/api/v4"
# Simpl POMs read the version from a CI env var; any value works for a local build:
export PROJECT_RELEASE_VERSION="${PROJECT_RELEASE_VERSION:-1.0.0-local}"

# ---- ports (match Simpl's own local-dev config) -----------------------------
export PG_PORT=5433
export MOTO_PORT=9000                 # S3 (moto stands in for MinIO)
export KEYCLOAK_PORT=8180
export SHIM_HTTP=30080                 # EJBCA-shim plain HTTP (easy testing)
export SHIM_HTTPS=30443                # EJBCA-shim HTTPS (what identity-provider expects)
# EDC consumer connector: 29191/29192/29193(mgmt)/29194(dsp)/29291
# EDC provider connector: 19191/19192/19193(mgmt)/19194(dsp)/19291
export CONSUMER_MGMT=29193 CONSUMER_DSP=29194
export PROVIDER_MGMT=19193 PROVIDER_DSP=19194
export CONTRACT_CONSUMPTION_PORT=8080
export VALIDATION_PORT=8083
export EDC_ADAPTER_PORT=8084
export IDENTITY_PROVIDER_PORT=8103

# ---- toolchain checks -------------------------------------------------------
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
export PATH="/usr/lib/postgresql/16/bin:$PATH"

# The agent sandbox sets duplicate/among proxy vars that break EDC's config
# loader and aren't needed for localhost traffic. Strip them for child JVMs.
noproxy_env() {
  env -u JAVA_TOOL_OPTIONS -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
      -u NO_PROXY -u no_proxy -u ALL_PROXY -u all_proxy "$@"
}
export -f noproxy_env

log() { echo -e "\033[1;34m[lab]\033[0m $*"; }

# Wait until a URL answers (any HTTP status) or timeout.
wait_http() { # wait_http URL [timeout_s]
  local url="$1" t="${2:-120}" n=0
  until curl -s -o /dev/null "$url" 2>/dev/null || [ "$n" -ge "$t" ]; do n=$((n+1)); sleep 1; done
}
