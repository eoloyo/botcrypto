#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
#
# Demonstrates the SPARQL content-query capability for a Simpl-Open provider agent:
#   1. builds + runs the core guard against a REAL embedded Apache Jena Fuseki graph DB
#   2. compiles the EDC data-plane extension (plugin) against the real Eclipse EDC SPI
#
# No Simpl mesh, no Kubernetes, no network services needed — the test boots its own Fuseki.
set -euo pipefail
cd "$(dirname "$0")"

echo "== 1/2  core: SPARQL query-guard tested against an embedded Fuseki graph DB =="
gradle :sparql-core:test --no-daemon --console=plain

echo
echo "== 2/2  EDC plugin: SPARQL data-plane extension compiled against the Eclipse EDC SPI =="
gradle :sparql-dataplane-edc:jar --no-daemon --console=plain

echo
echo "OK — guard proven against Fuseki, and the EDC extension JAR built:"
find . -path '*/sparql-dataplane-edc/build/libs/*.jar' -printf '   %p\n' 2>/dev/null || true
echo "Drop that JAR into a Simpl provider agent's data-plane runtime (see README.md)."
