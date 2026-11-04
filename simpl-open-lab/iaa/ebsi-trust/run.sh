#!/usr/bin/env bash
# run.sh — EBSI issuer trust for the Simpl Tier-1 wallet login (walt.id verifier2 `webhook` policy).
#
#   ./run.sh tests     deterministic accept/reject tests against a local stub EBSI (no network, ~2 s)
#   ./run.sh live DID  check one did:ebsi issuer against the live EBSI pilot registries
#   ./run.sh verifier  same credential through the real verifier2 with / without the EBSI policy
#                      (needs the ssi-login stack: wallet2 :7006, verifier2 :7004 — see ../ssi-login/run.sh)
#   ./run.sh login     the full Keycloak wallet login with the EBSI policy on (needs ../ssi-login/run.sh up)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RUN="${RUN:-/root/simpl-open-lab-work/ssi-run}"
start_webhook() {
  curl -s -m 2 localhost:8091/healthz >/dev/null && return
  nohup python3 "$HERE/ebsi_trust_webhook.py" 8091 > "$RUN/ebsi-trust.log" 2>&1 & echo $! > "$RUN/ebsi-trust.pid"; sleep 2
}
case "${1:-tests}" in
  tests)    python3 "$HERE/test_chain.py" ;;
  live)     start_webhook; curl -s -m 300 "localhost:8091/check?did=${2:?did:ebsi:...}" | python3 -m json.tool ;;
  verifier) start_webhook; python3 "$HERE/e2e_verifier2.py" ;;
  login)    start_webhook
            EBSI_WEBHOOK=http://127.0.0.1:8091/verify \
              nohup python3 "$HERE/../ssi-login/trusted_issuers_stub.py" 8082 "$RUN/issuer.did" > "$RUN/users-roles.log" 2>&1 &
            NODE_PATH=$(npm root -g) node "$HERE/../ssi-login/login.js" "$(cat "$RUN/ebsi-wid")" "$RUN/shots-ebsi" ;;
  *) sed -n 2,9p "$0" ;;
esac
