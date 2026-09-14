#!/usr/bin/env bash
# GATED DISCOVERY: a catalogue READ that traverses the Tier-2 gateway perimeter with a real
# machine identity — the hardening 08 deliberately skips (08 reads fc-service directly on :8081).
#
# In real Simpl-Open, fc-service has no app-level security *because the Tier-2 gateway is its
# perimeter*: inter-agent calls are mTLS-only and carry a machine identity whose ephemeral proof
# (SAP-issued identity attributes) authorizes the action. This script exercises that on the READ
# path, exactly as 07 already does for the WRITE (publish) path:
#
#   sd-tooling-be  GET /v1/selfDescriptions/discover/{id}
#     -> FederatedCatalogueTier2Client.getSelfDescription(id)   (credential-backed, sealed key
#        never leaves the auth-provider — iaa/patches/sdtooling-fc-read.patch)
#       -> tier2-gateway :8443/fc/self-descriptions/{id}  (EphemeralProof -> OCSP -> Headers ->
#          ABAC filters, mTLS)  -> StripPrefix -> fc-service :8081  -> SD content
#
# It proves three things:
#   (1) POSITIVE — the credential-backed read succeeds THROUGH the gateway (HTTP 200).
#   (2) NEGATIVE — the same read straight at the gateway with NO client identity is rejected
#       (403 "No Certificate found in request") — the perimeter blocks un-credentialed discovery.
#   (3) CONTRAST — a direct GET :8081/self-descriptions/{id} returns 200 (fc-service itself has no
#       app security), which is the shortcut 08 uses — proving the gateway is the real gate.
#
# Prereq (idempotent): if the mesh/catalogue isn't up it runs 07 (which clones+builds the mesh,
# applies the patches — including sdtooling-fc-read — enrolls the provider, caches its ephemeral
# proof, and publishes an SD through the Tier-2 mTLS path).
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
HERE="$(cd "$(dirname "$0")" && pwd)"
CAT="http://localhost:8081"; GW="https://localhost:8443"; SDT="http://localhost:8090"
MESHLOG="$RUN/07.log"

up(){ curl -s -o /dev/null "$1" 2>/dev/null; }
total(){ curl -s "$CAT/self-descriptions" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo 0; }

# ── 1. ensure the Tier-2 mesh is up with an SD published (runs 07 if not) ──────────────
if ! up "$SDT/status" || ! up "$CAT/self-descriptions" || [ "$(total)" -lt 1 ]; then
  log "mesh/catalogue not ready — running 07 to bring up the Tier-2 mesh + publish"
  bash "$HERE/07-tier2-provider-publish.sh"
fi
up "$SDT/status"          || { log "sd-tooling-be (:8090) not up — cannot drive a gated read"; exit 1; }
curl -sk -o /dev/null "$GW/actuator/health" || { log "tier2-gateway (:8443) not up"; exit 1; }
[ "$(total)" -ge 1 ]      || { log "no SD in the catalogue to read"; exit 1; }

# ── 2. pick a published self-description id (the fc-service sdHash) ────────────────────
SDID=$(curl -s "$CAT/self-descriptions" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d.get('items',[]):
    m=it.get('meta',it)
    h=m.get('sdHash') or m.get('id')
    if h: print(h); break
")
[ -n "$SDID" ] || { log "could not read an sdHash from the catalogue"; exit 1; }
log "target self-description (sdHash) = $SDID"

# ── 3. POSITIVE: credential-backed READ through the gateway (mTLS + ephemeral proof [+ ABAC]) ──
log "── POSITIVE: GET $SDT/v1/selfDescriptions/discover/{id}  (credential-backed, via gateway /fc) ──"
POS=$(curl -s -o "$RUN/10-discover-body.json" -w '%{http_code}' "$SDT/v1/selfDescriptions/discover/$SDID" || echo 000)
BODYLEN=$(wc -c < "$RUN/10-discover-body.json" 2>/dev/null || echo 0)
log "   sd-tooling-be discover -> HTTP $POS  (body ${BODYLEN} bytes)"
POS_OK=0
if [ "$POS" = 200 ] && [ "$BODYLEN" -gt 2 ]; then POS_OK=1; log "   ✓ read succeeded THROUGH the Tier-2 gateway"; fi
# show the gateway admitted it past the ephemeral-proof (+ABAC) filters for this path
grep -aE "/fc/self-descriptions/$SDID|Ephemeral proof is valid|Abac Filter|No ABAC privilege|checkPrivilege" "$MESHLOG" 2>/dev/null | tail -4 | sed 's/^/   gw| /' || true

# ── 4. NEGATIVE: same read straight at the gateway with NO client identity ─────────────
log "── NEGATIVE: GET $GW/fc/self-descriptions/{id}  with NO client certificate ──"
NEG=$(curl -sk -o /dev/null -w '%{http_code}' "$GW/fc/self-descriptions/$SDID" || echo 000)
log "   gateway (no cert) -> HTTP $NEG  (expect 403: the perimeter blocks un-credentialed discovery)"
NEG_OK=0; [ "$NEG" = 403 ] && { NEG_OK=1; log "   ✓ gateway rejected the un-credentialed read"; }

# ── 5. CONTRAST: direct fc-service read (the 08 shortcut — no perimeter) ───────────────
DIR=$(curl -s -o /dev/null -w '%{http_code}' "$CAT/self-descriptions/$SDID" || echo 000)
log "── CONTRAST: GET $CAT/self-descriptions/{id} direct -> HTTP $DIR  (fc-service has no app security) ──"

# ── 6. ABAC-on-discovery status (identity-attribute layer, on the proof's SAP-issued attrs) ───
if grep -aqE "id:[[:space:]]*/fc|/fc/self-descriptions" "$LAB_ROOT/src/tier2-gateway/src/main/resources/config/routes-authority.yml" 2>/dev/null; then
  log "   ABAC: gateway routes.abac carries a /fc read rule — the 200 above also passed identity-attribute ABAC"
else
  log "   ABAC: /fc reads are gated by mTLS + ephemeral proof (identity-attribute ABAC rule not configured)"
fi

# ── verdict ───────────────────────────────────────────────────────────────────────────
if [ "$POS_OK" = 1 ] && [ "$NEG_OK" = 1 ]; then
  log "GATED DISCOVERY VERIFIED — catalogue read succeeds only through the Tier-2 perimeter (200 with identity, 403 without); direct fc-service is the 08 shortcut."
else
  log "GATED DISCOVERY INCOMPLETE — POSITIVE(200)=$POS_OK NEGATIVE(403)=$NEG_OK ; see $RUN/07.log"
  exit 1
fi
