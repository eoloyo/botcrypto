#!/usr/bin/env bash
# render_check.sh <orig-dir> <patched-dir> — helm-template regression checks for wildcard-tls.patch.
# Each dir holds the six chart directories. No cluster needed.
set -uo pipefail
O="$1"; N="$2"; NS=poc-agent; FAIL=0
# Chart.yaml carries the CI placeholder ${PROJECT_RELEASE_VERSION}, which helm rejects: use normalised temp copies.
norm() { D=$(mktemp -d); cp -r "$1"/. "$D"/; for c in "$D"/*/; do sed -i -E 's/^(version|appVersion): .*PROJECT_RELEASE_VERSION.*/\1: "0.0.0-poc"/' "$c/Chart.yaml"; done; echo "$D"; }
O=$(norm "$O"); N=$(norm "$N")
FE=participant.fe.consumer1.dataspace.example.eu; BE=participant.be.consumer1.dataspace.example.eu
args() { case "$1" in
  tier1-gateway) echo "--set hostT1=$BE --set ingress.issuer=lab-ca --set cors.allowOrigin=https://$FE";;
  *)             echo "--set hostFe=$FE --set ingress.issuer=lab-ca --set cors.allowOrigin=https://$FE";; esac; }
r() { local out; out=$(helm template rel "$1" --namespace $NS --show-only templates/ingress.yaml $2 2>&1); echo "$out"; }
isingress() { echo "$1" | grep -q "^kind: Ingress"; }
ok()  { printf "  [PASS] %s\n" "$1"; }
bad() { printf "  [FAIL] %s\n" "$1"; FAIL=1; }
for c in tier1-gateway authentication-provider-fe identity-provider-fe onboarding-fe security-attribute-provider-fe users-roles-fe; do
  echo "== $c"; A=$(args $c)
  base=$(r "$O/$c" "$A"); isingress "$base" && ok "original renders a real Ingress" || { bad "original did not render: $(echo "$base" | head -2)"; continue; }
  # 1. default values: patched templates must render exactly what the original renders
  [ "$base" = "$(r "$N/$c" "$A")" ] && ok "default mode renders byte-identical to the original" || bad "default mode differs from the original"
  # 2. an OLD values.yaml (key absent) with the NEW template must still render identically
  T=$(mktemp -d); cp -r "$N/$c" "$T/c"; cp "$O/$c/values.yaml" "$T/c/values.yaml"
  [ "$base" = "$(r "$T/c" "$A")" ] && ok "old values.yaml without the new key renders identically" || bad "old values.yaml breaks"; rm -rf "$T"
  # 3. wildcard mode: no cert-manager annotations, shared secret, host untouched
  w=$(r "$N/$c" "$A --set ingress.existingTlsSecret=consumer1-wildcard-tls"); isingress "$w" || { bad "wildcard mode did not render: $(echo "$w" | head -2)"; continue; }
  echo "$w" | grep -q "cert-manager.io" && bad "wildcard mode still carries cert-manager annotations" || ok "wildcard mode: no cert-manager annotations"
  echo "$w" | grep -q "secretName: consumer1-wildcard-tls" && ok "wildcard mode: uses the shared secret" || bad "wildcard mode: wrong secretName"
  [ "$(echo "$base" | grep -E '^\s+(- )?host:|^\s+- (participant)' | sort)" = "$(echo "$w" | grep -E '^\s+(- )?host:|^\s+- (participant)' | sort)" ] && ok "wildcard mode: hostnames unchanged" || bad "wildcard mode changed hostnames"
done
echo; [ $FAIL = 0 ] && echo "ALL RENDER CHECKS PASSED" || echo "RENDER CHECKS FAILED"; exit $FAIL
