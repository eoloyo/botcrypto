#!/usr/bin/env bash
# run_all.sh — every test of this prototype from a clean slate, then tear down and check the lab cluster is as it was found.
#
# Needs: docker, helm, node + playwright, certutil, openssl; the ../../k8s-gvisor cluster (container k3s-gvisor) running.
# WITH_LE=1 adds the Let's Encrypt staging probe (letsencrypt_probe.sh).
# Takes about half an hour (gVisor pods start slowly; the renewal test waits two minutes for cert-manager).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
W="${W:-/root/simpl-open-lab-work/wildcard-poc}"; export W
RC=0; run() { echo; echo "################ $*"; "$@"; local r=$?; echo "=== EXIT $r: $*"; [ $r = 0 ] || RC=1; return 0; }
K="docker exec k3s-gvisor kubectl"

echo "################ chart copies: the six component charts (copied from the lab, which stays untouched) + wildcard-tls.patch"
rm -rf "$W/orig" "$W/patched"; mkdir -p "$W/orig" "$W/patched"
for c in tier1-gateway authentication-provider-fe identity-provider-fe onboarding-fe security-attribute-provider-fe users-roles-fe; do
  cp -r /root/simpl-agent-build/src/$c/charts "$W/orig/$c"; cp -r /root/simpl-agent-build/src/$c/charts "$W/patched/$c"; done
patch -p1 -d "$W/patched" -s < "$HERE/wildcard-tls.patch" && echo "patch applied" || { echo "PATCH FAILED"; exit 1; }

BEFORE_NS=$($K get ns --no-headers 2>/dev/null | awk '{print $1}' | grep -vE '^(cert-manager|ingress-nginx|poc-agent|poc-real|acme-lab)$' | tr '\n' ' ')
BEFORE_ING=$($K -n authority01 get ingress --no-headers 2>/dev/null | wc -l)
run ./acme_test.sh teardown; run ./ingress_nginx.sh uninstall; run ./cert_manager.sh uninstall    # clean slate
run ./cert_manager.sh install
run ./ingress_nginx.sh install
run ./render_check.sh "$W/orig" "$W/patched"
run python3 plumbing.py check
run ./cluster_test.sh
run ./cluster_test.sh migrate
run ./serve_test.sh
run ./acme_test.sh
run ./browser_test.sh
if [ "${WITH_LE:-0}" = 1 ]; then   # opt-in: needs internet access to Let's Encrypt staging; sandbox only (proxy-ca)
  run ./cert_manager.sh proxy-ca; run ./letsencrypt_probe.sh; run ./letsencrypt_probe.sh teardown
fi
run ./acme_test.sh teardown; run ./ingress_nginx.sh uninstall; run ./cert_manager.sh uninstall

echo; echo "################ lab restored?"
AFTER_NS=$($K get ns --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' '); AFTER_ING=$($K -n authority01 get ingress --no-headers 2>/dev/null | wc -l)
[ "$BEFORE_NS" = "$AFTER_NS" ] && echo "  [PASS] namespaces unchanged: $AFTER_NS" || { echo "  [FAIL] namespaces: before [$BEFORE_NS] after [$AFTER_NS]"; RC=1; }
[ "$BEFORE_ING" = "$AFTER_ING" ] && echo "  [PASS] authority01 Ingresses unchanged ($AFTER_ING)" || { echo "  [FAIL] authority01 Ingresses $BEFORE_ING -> $AFTER_ING"; RC=1; }
$K get crd certificates.cert-manager.io >/dev/null 2>&1 && { echo "  [FAIL] cert-manager CRDs still present"; RC=1; } || echo "  [PASS] no cert-manager CRDs left"
[ "$($K -n authority01 get pods --no-headers 2>/dev/null | awk '$2!="1/1"' | wc -l)" = 0 ] && echo "  [PASS] all authority01 pods 1/1" || echo "  [INFO] some authority01 pods are not 1/1 (they were not all 1/1 before the lab was restarted either)"
certutil -d "sql:$HOME/.pki/nssdb" -L 2>/dev/null | grep -q simpl-lab-ca && { echo "  [FAIL] lab CA left in the browser trust store"; RC=1; } || echo "  [PASS] lab CA not left in the browser trust store"
echo; [ $RC = 0 ] && echo "RUN ALL: EVERYTHING PASSED" || echo "RUN ALL: FAILURES ABOVE"; exit $RC
