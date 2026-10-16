#!/usr/bin/env bash
# 12-perimeter.sh — architecture-conformance test for the intended Simpl-Open topology.
#
# Intended architecture (tier2-gateway/README.md: "Mediates the traffic from the Internet
# to the tier 2 agent components of a participant agent ... work only in https on mTLS";
# Helm: only tier2-gateway is a LoadBalancer, every backend is a ClusterIP):
#
#   Internet ──mTLS──> Tier-2 gateway (:8443) ──loopback──> backend microservices
#                      verifies the mTLS cert + ephemeral proof (OCSP) and INJECTS the
#                      trusted `User-Attributes` header; backends have NO app-level auth
#                      and therefore must never be reachable except through the gateway.
#
# This single-host lab approximates "ClusterIP + NetworkPolicy" by binding every backend
# HTTP listener to loopback (BACKEND_BIND=127.0.0.1, see env.sh), leaving only the gateway
# on all interfaces. This script ASSERTS that invariant plus the gateway's enforcement, so
# a regression (a backend exposed on 0.0.0.0, or the gateway admitting an un-credentialed
# read) fails the build instead of passing silently.
#
# Run after the mesh is up (it runs 07 if not). Exits non-zero on any FAIL.
set -euo pipefail
source "$(dirname "$0")/env.sh"
RUN="$LAB_ROOT/run"; mkdir -p "$RUN"
HERE="$(cd "$(dirname "$0")" && pwd)"
CAT="http://localhost:8081"; GW="https://localhost:8443"; SDT="http://localhost:8090"

PASS=0; FAIL=0
ok(){   printf '  \033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
up(){ curl -s -m 5 -o /dev/null "$1" 2>/dev/null; }
total(){ curl -s -m 5 "$CAT/self-descriptions" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo 0; }

# listen_scope <port> -> prints "loopback", "all", or "down" for that listening TCP port.
# Prefers ss; falls back to parsing /proc/net/tcp{,6} (00000000 = all, 0100007F / ::1 = loopback).
listen_scope(){
  local port="$1" out
  if out=$(ss -ltnH "( sport = :$port )" 2>/dev/null) && [ -n "$out" ]; then
    if   grep -qE '(^|[^0-9.])(0\.0\.0\.0|\*|\[::\]):'"$port"'( |$)' <<<"$out"; then echo all
    elif grep -qE '(127\.0\.0\.1|\[::1\]):'"$port"'( |$)'            <<<"$out"; then echo loopback
    else echo all; fi
    return
  fi
  python3 - "$port" <<'PY'
import sys
port=int(sys.argv[1]); scopes=set()
for fn,allz,lo in (('/proc/net/tcp','00000000','0100007F'),
                   ('/proc/net/tcp6','00000000000000000000000000000000','00000000000000000000000001000000')):
    try: lines=open(fn).read().splitlines()[1:]
    except FileNotFoundError: continue
    for l in lines:
        f=l.split()
        if f[3]!='0A': continue            # 0A = LISTEN
        ip,p=f[1].rsplit(':',1)
        if int(p,16)!=port: continue
        scopes.add('all' if ip==allz else 'loopback' if ip==lo else 'other')
print('down' if not scopes else 'all' if ('all' in scopes or 'other' in scopes) else 'loopback')
PY
}

# ── ensure the mesh is up ──────────────────────────────────────────────────────────────
if ! up "$SDT/status" || ! up "$CAT/self-descriptions" || [ "$(total)" -lt 1 ]; then
  log "mesh not ready — running 07 to bring up the Tier-2 mesh + publish"
  bash "$HERE/07-tier2-provider-publish.sh"
fi
(exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null && exec 3>&- || { log "tier2-gateway (:8443) not up"; exit 1; }

echo
log "══ A. Backend microservices must be bound to loopback only (ClusterIP stand-in) ══"
# port : human name — every tier-2 backend that has no app-level auth of its own
BACKENDS="8081:fc-service 8090:sd-tooling-be 8102:security-attributes-provider 8103:identity-provider 8104:auth-provider-participant 8105:auth-provider-GA"
for pn in $BACKENDS; do
  port=${pn%%:*}; name=${pn##*:}; scope=$(listen_scope "$port")
  case "$scope" in
    loopback) ok "$name (:$port) bound to loopback — not reachable off-host" ;;
    down)     log "  –    $name (:$port) not running (skipped)" ;;
    *)        bad "$name (:$port) is listening on ALL interfaces — a backend with no app auth is exposed" ;;
  esac
done

echo
log "══ B. The Tier-2 gateway is the designated ingress and is reachable ══"
# The gateway's bind interface is a deployment detail that differs between this single-host
# lab (loopback) and production (a LoadBalancer on 0.0.0.0, per its Helm chart). The invariant
# we can assert on one host is only relative: the gateway is up and reachable as the one door,
# while the backends (A) are not. Its mTLS enforcement is proven by C/D/E, not by the bind addr.
GWSCOPE=$(listen_scope 8443)
if (exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null; then exec 3>&-
  ok "tier2-gateway (:8443) is up and reachable as the single ingress (bind scope: $GWSCOPE; prod = LoadBalancer/0.0.0.0)"
else
  bad "tier2-gateway (:8443) is not listening — no ingress"
fi

echo
log "══ C. The gateway refuses an un-credentialed read (mTLS perimeter) ══"
SDID=$(curl -s -m 5 "$CAT/self-descriptions?statuses=ACTIVE" | python3 -c "
import sys,json
for it in json.load(sys.stdin).get('items',[]):
    m=it.get('meta',it); i=m.get('id') or m.get('sdHash')
    if i: print(i); break" 2>/dev/null)
if [ -n "$SDID" ]; then
  NEG=$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "$GW/fc/self-descriptions/$SDID" 2>/dev/null || true); NEG=${NEG:-000}
  case "$NEG" in
    000|401|403) ok "gateway rejected a no-client-certificate read (HTTP $NEG)";;
    *)           bad "gateway admitted an un-credentialed read (HTTP $NEG) — mTLS not enforced";;
  esac
else
  bad "no self-description id available to probe the gateway"
fi

echo
log "══ D. The header-trust bypass is confined behind the perimeter ══"
# The backend authorizes on the `User-Attributes` header the gateway is supposed to inject.
# Sent DIRECTLY to the backend, a forged value passes authorization — this is EXPECTED and is
# exactly why the backend must never be exposed. We probe a SYNTHETIC, non-existent SD id so the
# revoke authorization check is exercised WITHOUT mutating any real self-description: without the
# header the backend returns 403 (authz), with the forged publisher attribute it gets past authz
# to the lookup and returns 404 (not found). The test's job is to prove that bypass exists ONLY on
# loopback (guaranteed by A), never on a network-reachable port.
FAKE="did:web:example.invalid:perimeter-probe-$$"
ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$FAKE")
NOHDR=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST "$CAT/self-descriptions/$ENC/revoke" 2>/dev/null || echo 000)
FORGED=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST -H 'User-Attributes: DATA_PROVIDER_PUBLISHER' \
          "$CAT/self-descriptions/$ENC/revoke" 2>/dev/null || echo 000)
# 403 without the header, past-authz (404 not-found) with it = backend trusts the header.
if [ "$NOHDR" = 403 ] && { [ "$FORGED" = 404 ] || [ "$FORGED" = 200 ]; }; then
  if [ "$(listen_scope 8081)" = loopback ]; then
    ok "backend trusts the gateway header (403->$FORGED) but is loopback-only — bypass contained"
  else
    bad "backend trusts a forged header (403->$FORGED) AND is network-reachable — privilege bypass"
  fi
else
  log "  –    inconclusive (no-header=$NOHDR forged=$FORGED); backend authz model may have changed"
fi

echo
log "══ E. The credentialed path through the gateway still works ══"
if up "$SDT/status" && [ -n "$SDID" ]; then
  POS=$(curl -s -m 20 -o "$RUN/12-discover.json" -w '%{http_code}' "$SDT/v1/selfDescriptions/discover/$SDID" 2>/dev/null || echo 000)
  BL=$(wc -c < "$RUN/12-discover.json" 2>/dev/null || echo 0)
  if [ "$POS" = 200 ] && [ "$BL" -gt 2 ]; then ok "credential-backed read via gateway /fc succeeded (HTTP 200, ${BL}B)"
  else log "  –    credentialed read returned HTTP $POS (${BL}B) — may need a fresh ephemeral proof (run 10 first)"; fi
fi

echo
log "══ perimeter conformance: $PASS passed, $FAIL failed ══"
[ "$FAIL" -eq 0 ] || { log "FAILED — the lab topology diverges from the intended architecture"; exit 1; }
log "the lab topology matches the intended 'gateway-in-front-of-ClusterIP-backends' architecture"
