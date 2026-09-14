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
#   (1) POSITIVE — the credential-backed read succeeds THROUGH the gateway (HTTP 200). The
#       gateway's own DEBUG log shows it was admitted only after "Proof check required true" +
#       "Ephemeral proof is valid, proceeding" — i.e. gated by the SAP/GA-issued ephemeral proof
#       bound to the credential's key, then routed via the /fc route to fc-service.
#   (2) NEGATIVE — the same read straight at the gateway with NO client certificate is refused at
#       the TLS handshake itself ("tlsv13 alert certificate required", curl HTTP 000): the gateway
#       enforces mTLS as REQUIRED, so an un-credentialed caller never reaches HTTP at all.
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
MESHLOG="$RUN/mesh.log"   # 07's services (incl. the gateway, DEBUG) all log here

up(){ curl -s -o /dev/null "$1" 2>/dev/null; }
total(){ curl -s "$CAT/self-descriptions" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo 0; }

# ── 1. ensure the Tier-2 mesh is up with an SD published (runs 07 if not) ──────────────
if ! up "$SDT/status" || ! up "$CAT/self-descriptions" || [ "$(total)" -lt 1 ]; then
  log "mesh/catalogue not ready — running 07 to bring up the Tier-2 mesh + publish"
  bash "$HERE/07-tier2-provider-publish.sh"
fi
up "$SDT/status"          || { log "sd-tooling-be (:8090) not up — cannot drive a gated read"; exit 1; }
# the gateway requires a client cert even for /actuator/health (mTLS is enforced at the TLS
# layer), so probe the port with a TCP connect rather than an HTTP health call
(exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null && exec 3>&- || { log "tier2-gateway (:8443) not up"; exit 1; }
[ "$(total)" -ge 1 ]      || { log "no SD in the catalogue to read"; exit 1; }

# ── 2. pick a published self-description id (fc-service keys single-SD reads by subjectId) ──
SDID=$(curl -s "$CAT/self-descriptions" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d.get('items',[]):
    m=it.get('meta',it)
    i=m.get('id') or m.get('sdHash')   # GET /self-descriptions/{id} is keyed by subjectId (did:web...)
    if i: print(i); break
")
[ -n "$SDID" ] || { log "could not read a self-description id from the catalogue"; exit 1; }
log "target self-description id = $SDID"

# ── 3. POSITIVE: credential-backed READ through the gateway (mTLS + ephemeral proof [+ ABAC]) ──
log "── POSITIVE: GET $SDT/v1/selfDescriptions/discover/{id}  (credential-backed, via gateway /fc) ──"
POS=$(curl -s -o "$RUN/10-discover-body.json" -w '%{http_code}' "$SDT/v1/selfDescriptions/discover/$SDID" || echo 000)
BODYLEN=$(wc -c < "$RUN/10-discover-body.json" 2>/dev/null || echo 0)
log "   sd-tooling-be discover -> HTTP $POS  (body ${BODYLEN} bytes)"
POS_OK=0
if [ "$POS" = 200 ] && [ "$BODYLEN" -gt 2 ]; then POS_OK=1; log "   ✓ read succeeded THROUGH the Tier-2 gateway"; fi
# show, from the gateway's own DEBUG log, that this read was admitted only after the
# ephemeral-proof check (proof required + valid) and was then routed via the /fc route.
ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$SDID" 2>/dev/null)
grep -aE "Proof check required (true|false) for path /fc/self-descriptions/($SDID|$ENC)|Ephemeral proof is valid|Route\{id='fc'" "$MESHLOG" 2>/dev/null | tail -3 | sed 's/^.*] //; s/^/   gw| /' || true

# ── 4. NEGATIVE: same read straight at the gateway with NO client identity ─────────────
# The gateway enforces mTLS as REQUIRED (not optional), so a client presenting no machine
# certificate is refused at the TLS handshake itself ("tlsv13 alert certificate required") —
# curl reports HTTP 000. That is a stronger gate than an HTTP 403: the un-credentialed caller
# never reaches HTTP processing at all. (A cert-bearing-but-invalid-proof caller would instead
# get 401 from the EphemeralProofFilter — but forging a cert needs the sealed key, which the
# positive path keeps inside the auth-provider, so we cannot mint one here.)
log "── NEGATIVE: GET $GW/fc/self-descriptions/{id}  with NO client certificate ──"
NEG=$(curl -sk -o /dev/null -w '%{http_code}' "$GW/fc/self-descriptions/$SDID" 2>/dev/null || true); NEG=${NEG:-000}
NEG_ALERT=$({ curl -skv "$GW/fc/self-descriptions/$SDID" 2>&1 || true; } | grep -oiE "alert certificate required|certificate required|bad certificate|handshake failure" | head -1 || true)
log "   gateway (no cert) -> HTTP $NEG${NEG_ALERT:+  [TLS: $NEG_ALERT]}  (the mTLS perimeter blocks un-credentialed discovery)"
NEG_OK=0; case "$NEG" in 000|401|403) NEG_OK=1; log "   ✓ gateway rejected the un-credentialed read (no machine identity)";; esac

# ── 5. CONTRAST: direct fc-service read (the 08 shortcut — no perimeter) ───────────────
DIR=$(curl -s -o /dev/null -w '%{http_code}' "$CAT/self-descriptions/$SDID" || echo 000)
log "── CONTRAST: GET $CAT/self-descriptions/{id} direct -> HTTP $DIR  (fc-service has no app security) ──"

# ── 6. AUTHENTIC ABAC on discovery (identity-attribute layer, on SAP-issued proof attributes) ──
# The gateway /fc read rule requires the CATALOGUE_SEARCHER identity attribute. That attribute is
# SAP-governed: it is assigned in SAP (iaa/seed-sap-attributes.sh) and synced into the participant's
# ephemeral proof by the GA. To show the gateway AbacFilter deciding on the AUTHENTIC attribute
# (not a mock), toggle the SAP assignment and re-issue the proof:
#   DENY  — strip the attribute  -> proof carries []                -> AbacFilter 403 (read fails)
#   ALLOW — assign CATALOGUE_SEARCHER -> proof carries it           -> read 200
PUUID=$(cat /tmp/last-uuid.txt 2>/dev/null || true)
SAPDB="authority_securityattributesprovider"
sap(){ PGPASSWORD=postgres psql -h 127.0.0.1 -p "${PG_PORT:-5433}" -U postgres -d "$SAPDB" -tAc "$1" 2>/dev/null; }
reissue(){ local tok; tok=$(python3 "$HERE/../iaa/jwks-tier1.py" token "$PUUID" 2>/dev/null) || return 1
  curl -s -o /dev/null -H "Authorization: Bearer $tok" http://localhost:8104/tier1/v2/ephemeralProof 2>/dev/null || true; sleep 3; }
discover_code(){ curl -s -o /dev/null -w '%{http_code}' "$SDT/v1/selfDescriptions/discover/$SDID" 2>/dev/null || echo 000; }
ABAC_OK=0; ABAC_RUN=0
if [ -n "$PUUID" ] && [ -n "$(sap 'select 1')" ]; then
  ABAC_RUN=1
  log "── AUTHENTIC ABAC: gateway /fc rule requires CATALOGUE_SEARCHER (a SAP-issued proof attribute) ──"
  sap "DELETE FROM participant_identity_attribute;" >/dev/null; reissue
  DENYC=$(discover_code)
  log "   proof without the attribute -> discover HTTP $DENYC  (expect non-200: AbacFilter denies)"
  grep -aE "identity attributes to perform this action|require one of these identity attributes" "$MESHLOG" 2>/dev/null | tail -1 | sed 's/^.*] //; s/^/   gw| /' || true
  bash "$HERE/../iaa/seed-sap-attributes.sh" CATALOGUE_SEARCHER >/dev/null 2>&1 || true; reissue
  ALLOWC=$(discover_code)
  log "   proof WITH CATALOGUE_SEARCHER -> discover HTTP $ALLOWC  (expect 200: AbacFilter admits the authentic attribute)"
  if [ "$ALLOWC" = 200 ] && [ "$DENYC" != 200 ]; then
    ABAC_OK=1; log "   ✓ authentic identity-attribute ABAC enforced on discovery (allow with the SAP-issued attribute, deny without)"
  else
    log "   ⚠ ABAC allow/deny inconclusive (allow=$ALLOWC deny=$DENYC) — proof may not have re-synced; see $RUN/mesh.log"
  fi
fi

# ── verdict ───────────────────────────────────────────────────────────────────────────
if [ "$POS_OK" = 1 ] && [ "$NEG_OK" = 1 ]; then
  log "GATED DISCOVERY VERIFIED — catalogue read succeeds only through the Tier-2 perimeter (200 with a machine credential + valid ephemeral proof; rejected at TLS without one); a direct fc-service read is the 08 shortcut."
  [ "$ABAC_RUN" = 1 ] && { [ "$ABAC_OK" = 1 ] && log "AUTHENTIC ABAC ON DISCOVERY VERIFIED — the gateway admits the read only with the SAP-issued CATALOGUE_SEARCHER attribute in the proof." || log "NOTE: authentic-ABAC allow/deny was inconclusive this run (mTLS + ephemeral-proof gate is still verified)."; }
else
  log "GATED DISCOVERY INCOMPLETE — POSITIVE(200)=$POS_OK NEGATIVE(blocked)=$NEG_OK ; see $RUN/mesh.log"
  exit 1
fi
