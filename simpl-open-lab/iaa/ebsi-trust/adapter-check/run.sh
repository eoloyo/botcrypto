#!/usr/bin/env bash
# run.sh <authp-be checkout with authp-be-develop-ebsi-gate.patch applied>
# Compiles and tests the Java EBSI adapter WITHOUT the full authp-be build (develop needs simpl-parent
# 3.3.0-SNAPSHOT and a large dependency graph): the adapter, its properties and its tests depend only on Spring,
# Jackson and Lombok. Runs EbsiTrustAdapterImplTest, then LiveSidecarCheck against the real Python sidecar
# (demo_stack.py: stub EBSI + a did:web host). The Tier2SessionServiceImpl change is NOT covered here: it needs
# the simpl-util VC/VP classes of 3.3.0-SNAPSHOT.
set -euo pipefail
SRC="$(cd "${1:?authp-be checkout}" && pwd)"; HERE="$(cd "$(dirname "$0")" && pwd)"
D="${D:-/root/simpl-open-lab-work/ebsi-adapter-check}"; P=eu/europa/ec/simpl/authenticationprovider
SETTINGS="${SETTINGS:-/root/simpl-open-lab-work/src-fed/maven-settings.xml}"
rm -rf "$D"; mkdir -p "$D/src/main/java/$P/clients/impl" "$D/src/main/java/$P/properties" "$D/src/test/java/$P/clients/impl"
cp "$SRC/src/main/java/$P/clients/EbsiTrustAdapter.java" "$D/src/main/java/$P/clients/"
cp "$SRC/src/main/java/$P/clients/impl/EbsiTrustAdapterImpl.java" "$D/src/main/java/$P/clients/impl/"
cp "$SRC/src/main/java/$P/properties/EbsiProperties.java" "$D/src/main/java/$P/properties/"
cp "$SRC/src/test/java/$P/clients/impl/EbsiTrustAdapterImplTest.java" "$D/src/test/java/$P/clients/impl/"
cp "$HERE/pom.xml" "$D/pom.xml"; cp "$HERE/LiveSidecarCheck.java" "$D/src/test/java/$P/clients/impl/"
cd "$D" && mvn -o -q -s "$SETTINGS" test -Dtest=EbsiTrustAdapterImplTest
VMS="$D/vms.json"; rm -f "$VMS"; ( cd "$HERE/.." && python3 demo_stack.py "$VMS" >"$D/demo.log" 2>&1 & echo $! >"$D/demo.pid" )
for _ in $(seq 20); do [ -s "$VMS" ] && break; sleep 1; done
read -r OK UNL THI EBSI < <(python3 -c "import json;d=json.load(open('$VMS'));print(d['vm_ok'],d['vm_unlinked'],d['vm_thief'],d['ebsi_did'])")
mvn -o -q -s "$SETTINGS" test -Dtest=LiveSidecarCheck -Dsidecar=http://127.0.0.1:18097 "-Dvm.ok=$OK" \
  "-Dvm.unlinked=$UNL" "-Dvm.thief=$THI" "-Debsi.did=$EBSI"; kill "$(cat "$D/demo.pid")" 2>/dev/null || true
echo "adapter tests + live sidecar check passed"
