#!/usr/bin/env bash
# Inject a gateway ABAC rule for the gated catalogue READ (GET /fc/self-descriptions/**) into a
# built tier2-gateway jar's config/routes-authority.yml.
#
# Why post-build injection instead of a source patch: the tier2-gateway build regenerates
# src/main/resources/config/routes-authority.yml from the Tier-2 OpenAPI specs on every build
# (simpl-maven-plugin `generate-routes`), so any manual/patched edit to that file is overwritten.
# The /fc route is not part of those specs (it proxies fc-service), so its ABAC rule must be added
# after packaging. This rewrites the routes-authority.yml entry inside BOOT-INF/classes so the
# running gateway enforces CATALOGUE_SEARCHER on discovery reads. Idempotent.
set -euo pipefail
JAR="${1:?usage: inject-fc-abac-rule.sh <tier2-gateway jar> [ATTR_CODE]}"
CODE="${2:-CONSUMER}"   # a non-assignable machine attribute the gateway injects for M2M calls
ENTRY="BOOT-INF/classes/config/routes-authority.yml"
[ -f "$JAR" ] || { echo "jar not found: $JAR" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$(dirname "$ENTRY")"
( cd "$WORK" && unzip -oq "$JAR" "$ENTRY" )
CFG="$WORK/$ENTRY"

# Idempotent AND code-updating: if a /fc rule already carries exactly this code, keep it; otherwise
# strip any existing /fc block (always appended last) and append a fresh one for $CODE.
if grep -q "fc/self-descriptions" "$CFG" && grep -qE "^\s*-\s*$CODE\s*$" "$CFG"; then
  echo "[inject-fc-abac] /fc rule for $CODE already present in $(basename "$JAR")"; exit 0
fi
# remove any prior /fc rule (from its 'GET'/path marker to EOF) before re-appending
python3 - "$CFG" <<'PY'
import sys,re
p=sys.argv[1]; lines=open(p).read().splitlines()
out=[]; i=0; cut=None
for idx,l in enumerate(lines):
    if 'fc/self-descriptions' in l:
        # walk back to the enclosing '- method:' list item
        j=idx
        while j>0 and '- method:' not in lines[j]: j-=1
        cut=j; break
open(p,'w').write("\n".join(lines[:cut] if cut is not None else lines).rstrip()+"\n")
PY
cat >> "$CFG" <<YAML
    - method: "GET"
      path: "/fc/self-descriptions/**"
      identity-attributes:
        - $CODE
YAML
JARBIN="jar"; [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/jar" ] && JARBIN="$JAVA_HOME/bin/jar"
( cd "$WORK" && "$JARBIN" uf "$JAR" "$ENTRY" 2>/dev/null || zip -q "$JAR" "$ENTRY" )
echo "[inject-fc-abac] added GET /fc/self-descriptions/** requiring $CODE to $(basename "$JAR")"
