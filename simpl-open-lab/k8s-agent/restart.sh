#!/usr/bin/env bash
# restart.sh — warm restart of an installed agent: delete every authority01 pod, keep Postgres, Kafka
# and all persisted state, and time how long until everything is Ready again (observe.sh).
# This is a day-2 start (node reboot, upgrade): EJBCA finds its CAs already in the database and its
# set-up exits early, and the authority is already initialized.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C=k3s-gvisor
K() { docker exec -i $C kubectl "$@"; }
t0=$(date +%s)   # before the delete: controllers recreate pods while the others are still terminating
echo "[$(date +%T)] deleting all agent pods; timing from now"
K -n authority01 delete pod --all --wait=false >/dev/null
"$HERE/observe.sh" "$t0"
