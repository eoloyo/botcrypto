#!/usr/bin/env bash
# fullchain.sh — wildcard-TLS switch across ALL Simpl agent charts (umbrellas, bundles, components). No cluster needed, only helm + python3 (+ pyyaml)
# and, for the first step, network access to code.europa.eu and the chart repositories. Work area: $INV (default /root/simpl-open-lab-work/wildcard-poc/inv).
#   1 inventory   fetch the 18 umbrella/bundle charts at their current main commit, list every chart they deploy (inventory/sources.py), helm pull them
#   2 patch       wildcard_all.py (umbrellas + bundles -> bundles-wildcard.patch), components_wildcard.py (component charts -> components-wildcard.patch)
#   3 check       components_check.py (leaf charts), bundles_check.py (18 umbrella/bundle charts), leaves_check.py (every leaf with the values its bundle passes)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; export INV="${INV:-/root/simpl-open-lab-work/wildcard-poc/inv}"; mkdir -p "$INV"; cd "$HERE"
if [ ! -d "$INV/pulled" ]; then
  echo "### 1. inventory"; ( cd "$INV" && cp "$HERE"/inventory/*.py . && python3 fetch_all.py && python3 sources.py && python3 pull_all.py ) || { echo "inventory failed"; exit 1; }
fi
echo "### 2. patch"; python3 wildcard_all.py | tail -n +1 | sed -n '1p;/UNCLAIMED/,$p'; python3 components_wildcard.py | tail -1
RC=0
echo "### 3. check"
for c in components_check.py bundles_check.py leaves_check.py; do echo "--- $c"; python3 $c | tail -4; [ ${PIPESTATUS[0]} = 0 ] || RC=1; done
echo "--- control: leaves_check on the UNPATCHED charts must find gaps"; CONTROL=1 python3 leaves_check.py | tail -1; [ ${PIPESTATUS[0]} = 0 ] || RC=1
[ $RC = 0 ] && echo "FULLCHAIN: ALL CHECKS PASSED" || echo "FULLCHAIN: FAILURES ABOVE"; exit $RC
