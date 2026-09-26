#!/usr/bin/env bash
# ============================================================================
# edc011-connector.sh — bump Simpl connector-be to native EDC 0.11.1 and prove
# a real provider->consumer transfer runs on it.
#
# The DCP work (increments A/B/C) proved the DCP Presentation Flow on the EDC 0.11
# IdentityHub. Wiring DCP into Simpl's connector needs connector-be off EDC 0.10.1
# and onto the 0.11 line first. This script does that bump and verifies it end to end.
#
# What it does:
#   1. clones connector-be (if absent) into src/connector-be;
#   2. applies iaa/patches/connector-edc-0.11.patch — the ENTIRE bump is pom.xml:
#        - <edc>0.10.1</edc> -> <edc>0.11.1</edc>
#        - remove the legacy data-plane-control-api (0.8.1) dep (superseded by the
#          data-plane signaling API, already declared)
#        - force org.eclipse.edc:runtime-metamodel to ${edc} in dependencyManagement
#          (the gxfs/ionos extensions drag in runtime-metamodel 0.10.1, which lacks the
#          new @Configuration annotation and makes 0.11 core fail at boot);
#      NO Java changes are needed — all 53 custom classes compile clean on 0.11.1.
#   3. builds the fat jar (Maven);
#   4. runs the canonical 02 transfer (asset -> policy -> contract-def -> catalog ->
#      negotiate -> transfer -> verify) on the freshly built 0.11.1 jar and checks the
#      file lands in the consumer bucket.
#
# Prereqs handled by scripts/01-setup.sh style provisioning: Postgres (:5433),
# moto S3 (:9000) via $LAB_ROOT/motoenv, JDK for the build. The Simpl EDC Maven
# registries at code.europa.eu (projects 958/1259) are anonymously readable.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd "$HERE/../.." && pwd)"                       # simpl-open-lab/
source "$LAB/scripts/env.sh"
export LAB_ROOT="${LAB_ROOT:-$LAB}"                    # keep clone+jars under the repo lab
CONN="$LAB_ROOT/src/connector-be"
PATCH="$LAB/iaa/patches/connector-edc-0.11.patch"
log(){ echo -e "\033[1;34m[edc011-connector]\033[0m $*"; }

# 1. clone connector-be
if [ ! -d "$CONN/.git" ]; then
  log "cloning connector-be…"; mkdir -p "$(dirname "$CONN")"
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 \
    "$GL/integration/resource-sharing/resource-sharing-runtime/connector/connector-be.git" "$CONN"
fi

# 2. apply the 0.11 bump patch (idempotent: skip if already at 0.11.1)
if grep -q "<edc>0.11.1</edc>" "$CONN/pom.xml"; then
  log "pom already at EDC 0.11.1"
else
  log "applying connector-edc-0.11.patch…"
  ( cd "$CONN" && git apply --whitespace=nowarn "$PATCH" )
fi

# 3. build the fat jar on 0.11.1
JAR="$CONN/target/basic-connector.jar"
log "building connector-be on EDC 0.11.1 (Maven)…"
( cd "$CONN" && noproxy_env mvn -q -B -ntp -DskipTests \
    -Dspotless.check.skip=true -Dspotless.apply.skip=true -Dlicense.skip=true \
    -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true package )
[ -f "$JAR" ] || { echo "build failed: no jar"; exit 1; }
log "jar: $JAR ($(du -h "$JAR" | cut -f1))"
log "bundled metamodel: $(unzip -l "$JAR" | grep -oE 'runtime-metamodel-[0-9.]+\.jar' | head -1)"

# 4. run the canonical provider->consumer transfer on the 0.11.1 jar
log "running the 02 transfer flow on native EDC 0.11.1…"
bash "$LAB/scripts/02-dataspace.sh"

echo
log "DONE — Simpl connector-be runs on native EDC 0.11.1 and completes a real"
log "provider->consumer (MinioS3-PUSH) transfer. Tear down: fuser -k 19193/tcp 29193/tcp; pkill -f moto_server"
