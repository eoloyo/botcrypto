#!/usr/bin/env bash
# restart.sh — warm restart of an installed agent: delete every authority01 pod, keep Postgres, Kafka
# and all persisted state, and time how long until everything is Ready again (observe.sh).
# This is a day-2 start (node reboot, upgrade): EJBCA finds its CAs already in the database and its
# set-up exits early, and the authority is already initialized.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C=k3s-gvisor
K() { docker exec -i $C kubectl "$@"; }
echo "[$(date +%T)] deleting all agent pods"
K -n authority01 delete pod --all --wait=true --timeout=300s >/dev/null
t0=$(date +%s)
echo "[$(date +%T)] all pods deleted; timing the restart"
"$HERE/observe.sh" "$t0"
