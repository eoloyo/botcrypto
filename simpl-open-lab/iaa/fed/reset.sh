#!/usr/bin/env bash
# reset.sh — stop both authorities (services, CAs, OCSP responders, tier-1 routers) and delete
# their databases, Redis databases and state, so authority.sh starts from scratch.
source "$(dirname "$0")/../../scripts/env.sh"
set +e
# bracketed patterns so pkill never matches this script's own command line
pkill -f '[l]ocal\.jar --spring\.profiles\.active=local'
pkill -f '[e]jbca-shim/ejbca-shim'
pkill -f '[o]csp-responder\.py'
pkill -f '[t]ier1_router\.py'
sleep 3
for x in a b; do for s in idp sap authp; do
  runuser -u postgres -- psql -p "$PG_PORT" -d postgres -qc "DROP DATABASE IF EXISTS fed${x}_$s;" 2>/dev/null
done; done
for n in 1 2; do redis-cli -p 30379 -a admin -n $n flushdb >/dev/null 2>&1; done
rm -rf "$LAB_ROOT/fed/A" "$LAB_ROOT/fed/B"
log "federation lab reset"
