#!/usr/bin/env bash
# ============================================================================
# run.sh — DCP / SSI credential-exchange demo for Simpl-Open.
#
# Pulls and runs walt.id (the stack Simpl-Open selected in architecture ADR 007
# for its SSI verifier), then drives an end-to-end credential issuance +
# OID4VP presentation-verification with real crypto (see dcp-demo.py).
#
# Prereqs: a working Docker daemon, python3 with the `cryptography` package,
# outbound access to Docker Hub. No Simpl mesh required — this is self-contained.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUER_IMG="${ISSUER_IMG:-waltid/issuer-api:latest}"
VERIFIER_IMG="${VERIFIER_IMG:-waltid/verifier-api:latest}"

log(){ echo -e "\033[1;34m[dcp]\033[0m $*"; }

# 0. docker up
if ! docker info >/dev/null 2>&1; then
  log "starting dockerd…"; (dockerd >/tmp/dockerd.log 2>&1 &) ; \
  for _ in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable"; exit 1; }

# 1. pull + run walt.id issuer (:7002) and verifier (:7003) — default config, no setup files
log "pulling walt.id images…"
docker pull "$ISSUER_IMG"   >/dev/null
docker pull "$VERIFIER_IMG" >/dev/null
docker rm -f waltid-issuer waltid-verifier >/dev/null 2>&1 || true
log "starting issuer :7002 and verifier :7003…"
docker run -d --name waltid-issuer   --network host "$ISSUER_IMG"   >/dev/null
docker run -d --name waltid-verifier --network host "$VERIFIER_IMG" >/dev/null

# 2. wait until both answer
for svc in 7002 7003; do
  for _ in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://localhost:$svc/" 2>/dev/null || echo 000)
    [ "$code" != "000" ] && break; sleep 2
  done
done
log "issuer $(curl -s -o /dev/null -w '%{http_code}' http://localhost:7002/) · verifier $(curl -s -o /dev/null -w '%{http_code}' http://localhost:7003/) (302 = up)"

# 3. run the credential-exchange demo
log "running DCP-style issue -> present -> verify …"
python3 "$HERE/dcp-demo.py"

echo
log "DONE. Tear down with:  docker rm -f waltid-issuer waltid-verifier"
