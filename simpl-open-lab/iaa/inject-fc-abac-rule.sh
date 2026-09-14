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
CODE="${2:-CATALOGUE_SEARCHER}"
ENTRY="BOOT-INF/classes/config/routes-authority.yml"
[ -f "$JAR" ] || { echo "jar not found: $JAR" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$(dirname "$ENTRY")"
( cd "$WORK" && unzip -oq "$JAR" "$ENTRY" )
CFG="$WORK/$ENTRY"

if grep -q "fc/self-descriptions" "$CFG"; then
  echo "[inject-fc-abac] rule already present in $(basename "$JAR")"; exit 0
fi
cat >> "$CFG" <<YAML
    - method: "GET"
      path: "/fc/self-descriptions/**"
      identity-attributes:
        - $CODE
YAML
JARBIN="jar"; [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/jar" ] && JARBIN="$JAVA_HOME/bin/jar"
( cd "$WORK" && "$JARBIN" uf "$JAR" "$ENTRY" 2>/dev/null || zip -q "$JAR" "$ENTRY" )
echo "[inject-fc-abac] added GET /fc/self-descriptions/** requiring $CODE to $(basename "$JAR")"
