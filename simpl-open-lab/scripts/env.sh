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

# ---- perimeter model --------------------------------------------------------
# Intended architecture: only the Tier-2 gateway faces the network; every backend
# service is a ClusterIP behind it (tier2-gateway/README.md: "Mediates the traffic
# from the Internet to the tier 2 agent components"). In this single-host lab we
# approximate that by binding every backend HTTP listener to loopback, so the only
# off-host-reachable port is the gateway (:8443, left on its default 0.0.0.0). This
# makes the lab's exposure match production and is asserted by 12-perimeter.sh.
# Override BACKEND_BIND=0.0.0.0 only to deliberately reproduce the insecure setup.
export BACKEND_BIND="${BACKEND_BIND:-127.0.0.1}"

# ---- JVM startup tuning -----------------------------------------------------
# The mesh boots ~7 Spring Boot services on a 4-core host; startup is CPU-bound,
# so three booting at once stretch each from ~2s to ~40s (measured). These flags
# cut the per-JVM startup CPU without changing behaviour — the lab boots once and
# serves a handful of requests, so steady-state throughput is irrelevant:
#   TieredStopAtLevel=1  stop JIT at C1 — don't fully optimise one-shot startup code
#   UseSerialGC          one GC thread, not N parallel GC threads fighting for cores
#   Xss512k / Xmx1g      cap stack + heap (avoids the default ¼-RAM max-heap sizing)
# Override with SIMPL_JAVA_OPTS="" to reproduce the untuned baseline for comparison.
export SIMPL_JAVA_OPTS="${SIMPL_JAVA_OPTS-"-XX:TieredStopAtLevel=1 -XX:+UseSerialGC -Xss512k -Xmx1g"}"

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

# ---- Spring Boot startup: extracted jar + CDS archive ------------------------
# Measured on security-attributes-provider started alone: packed fat jar ~26s, extracted jar
# ~13s, extracted + CDS archive ~7s. Spring Boot's nested-jar launcher spends half the startup
# loading classes out of the jars inside the fat jar; Class Data Sharing then skips most of the
# remaining class loading. bootjar <instance> <fat-jar> prints the java arguments to launch it:
#   - extracts the fat jar once (Spring Boot >= 3.3 `-Djarmode=tools extract`) and again
#     whenever the jar is newer (rebuilt or re-patched);
#   - -XX:+AutoCreateSharedArchive: the JVM uses $CDS_DIR/<instance>.jsa when it matches and
#     (re)writes it at exit — a normal 99-stop (SIGTERM) is enough. The first boot after a
#     (re)build pays the full cost; later boots, including --wipe cold boots, are fast.
# SIMPL_CDS=0 launches the fat jars directly, as before.
export SIMPL_CDS="${SIMPL_CDS:-1}"
export CDS_DIR="$LAB_ROOT/cds"
bootjar(){
  local name="$1" jar="$2"
  if [ "$SIMPL_CDS" != 1 ]; then echo "-jar $jar"; return; fi
  local d="$CDS_DIR/x/$(basename "$jar" .jar)"
  if [ ! -f "$d/.src" ] || [ "$jar" -nt "$d/.src" ]; then
    rm -rf "$d"; mkdir -p "$CDS_DIR/x"
    env -u JAVA_TOOL_OPTIONS "$JAVA_HOME/bin/java" -Djarmode=tools -jar "$jar" extract --destination "$d" \
      >/dev/null 2>&1 || { echo "-jar $jar"; return; }
    echo "$jar" > "$d/.src"
  fi
  echo "-XX:SharedArchiveFile=$CDS_DIR/$name.jsa -XX:+AutoCreateSharedArchive -jar $(ls "$d"/*.jar | head -1)"
}

# Wait until a URL answers (any HTTP status) or timeout.
wait_http() { # wait_http URL [timeout_s]
  local url="$1" t="${2:-120}" n=0
  until curl -s -o /dev/null "$url" 2>/dev/null || [ "$n" -ge "$t" ]; do n=$((n+1)); sleep 1; done
}
