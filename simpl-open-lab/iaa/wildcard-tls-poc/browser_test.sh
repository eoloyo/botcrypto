#!/usr/bin/env bash
# browser_test.sh — a REAL browser (Playwright's Chromium) against the 11 hosts served by ingress-nginx with the wildcard.
#
# The lab CA is imported into the browser's NSS trust store (and removed again afterwards), so Chromium verifies chain AND
# hostname like a user's browser. Each covered host must load a real page over HTTPS. Hosts the wildcard does not cover must be
# REJECTED: two of them are served the wildcard anyway (the sharp case: a mis-configured, uncovered host), one has no Ingress at all.
# Needs cert-manager + ingress-nginx in the lab cluster; certutil; Playwright (npm -g).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
N=$(norm "$W/patched"); IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' k3s-gvisor); PORT=30443
T=$(mktemp -d); NSSDB="sql:$HOME/.pki/nssdb"; CAHOSTS=$T/ok.txt; BADHOSTS=$T/bad.txt
HELLO_IMG=$($K -n authority01 get deploy lab-edge -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null); HELLO_IMG=${HELLO_IMG:-nginxinc/nginx-unprivileged:alpine3.22-perl}
cleanup() { certutil -d "$NSSDB" -D -n simpl-lab-ca >/dev/null 2>&1; rm -rf "$T"; }; trap cleanup EXIT

echo "### 0. lab issuer, a tiny backend, and the lab CA in the browser's trust store"
issuers || exit 1; reset_ns
cat <<YAML | $KI apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: hello, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: hello}}
  template:
    metadata: {labels: {app: hello}}
    spec:
      runtimeClassName: runsc
      containers: [{name: web, image: $HELLO_IMG, imagePullPolicy: IfNotPresent, ports: [{containerPort: 8080}]}]
---
apiVersion: v1
kind: Service
metadata: {name: tier1-gateway, namespace: $NS}
spec: {selector: {app: hello}, ports: [{port: 9000, targetPort: 8080}]}
YAML
for _ in $(seq 1 60); do [ "$($K -n $NS get deploy hello -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && break; sleep 4; done
[ "$($K -n $NS get deploy hello -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && ok "backend is running" || { bad "backend did not start"; exit 1; }
$K -n cert-manager get secret lab-ca-secret -o jsonpath='{.data.tls\.crt}' | base64 -d > $T/ca.pem
mkdir -p "$HOME/.pki/nssdb"; [ -f "$HOME/.pki/nssdb/cert9.db" ] || certutil -d "$NSSDB" -N --empty-password
certutil -d "$NSSDB" -D -n simpl-lab-ca >/dev/null 2>&1; certutil -d "$NSSDB" -A -t "C,," -n simpl-lab-ca -i $T/ca.pem && ok "lab CA imported into the browser trust store (removed again at the end)"

echo; echo "### 1. wildcard certificate and Ingresses"
agent_tls() { helm template agent "$HERE/agent-tls" --namespace $NS --set cluster.issuer=lab-ca --set namespaceTag=$TAG --set domainSuffix=$D | $KI apply -f - >/dev/null; }
agent_tls; i=0; while read -r h; do i=$((i+1)); gw_ingress "$N" "$h" "$i" "--set ingress.existingTlsSecret=$TAG-wildcard-tls" | $KI apply -f - >/dev/null; done < <(hosts "$HERE/hosts-consumer.txt")
# two UNCOVERED hosts that are nevertheless configured with the wildcard secret, and one with no Ingress at all
gw_ingress "$N" "tls.participant.$TAG.$D" 90 "--set ingress.existingTlsSecret=$TAG-wildcard-tls" | $KI apply -f - >/dev/null
gw_ingress "$N" "gitea.crossplane.$TAG.$D" 91 "--set ingress.existingTlsSecret=$TAG-wildcard-tls" | $KI apply -f - >/dev/null
wait_ready $NS 1; sleep 20
hosts "$HERE/hosts-consumer.txt" > $CAHOSTS
printf 'tls.participant.%s.%s\ngitea.crossplane.%s.%s\nnoingress.%s.%s\n' $TAG $D $TAG $D $TAG $D > $BADHOSTS

echo; echo "### 2. Chromium"
RES=$(cd "$HERE" && NODE_PATH=$(npm root -g) node browser_check.js "$IP:$PORT" - $CAHOSTS $BADHOSTS 2>&1 | tail -1)
python3 - "$RES" <<'PY'
import sys, json
try: r = json.loads(sys.argv[1])
except Exception: print("  [FAIL] browser output not understood:", sys.argv[1][:200]); sys.exit(1)
fail = 0
okr = [x for x in r if x["kind"] == "ok"]; bad = [x for x in r if x["kind"] == "bad"]
# the issuer must be the lab CA: anything else (e.g. a proxy answering) is not the path under test
good = [x for x in okr if x.get("status") == 200 and "nginx" in (x.get("title") or "").lower() and "lab-ca" in (x.get("issuer") or "")]
print(f"  [{'PASS' if len(good) == len(okr) else 'FAIL'}] {len(good)}/{len(okr)} covered hosts loaded a real page over HTTPS with normal certificate verification" + (f" (TLS {good[0]['protocol']})" if good else ""))
fail += len(good) != len(okr)
for x in okr:
    if x not in good: print("      ", x["host"], x.get("error") or x)
# ingress-nginx checks the host against the certificate itself: for an uncovered host it falls back to its FAKE certificate,
# so the browser reports an untrusted authority (not a name mismatch). The controller log is where the real reason is.
expect = {"tls.participant": "ERR_CERT_AUTHORITY_INVALID", "gitea.crossplane": "ERR_CERT_AUTHORITY_INVALID", "noingress": "ERR_CERT_AUTHORITY_INVALID"}
for x in bad:
    key = x["host"].split(".consumer1")[0]; want = expect[key]; got = (x.get("error") or "").replace("net::", "")
    ok = got == want; fail += not ok
    print(f"  [{'PASS' if ok else 'FAIL'}] {x['host']}: browser refuses it with {got or 'NO ERROR (loaded!)'}" + ("" if ok else f" (expected {want})"))
sys.exit(1 if fail else 0)
PY
PYRC=$?
LOGS=$($K -n ingress-nginx logs deploy/ingress-nginx-controller --since=30m 2>&1)
for h in tls.participant gitea.crossplane; do
  grep -q "does not contain a Common Name or Subject Alternative Name for server \"$h.$TAG.$D\"" <<< "$LOGS" \
    && ok "ingress-nginx refused the wildcard for $h.$TAG.$D, logged why, and fell back to its fake certificate" || bad "no ingress-nginx log line for $h"
done
echo; [ $PYRC = 0 ] && [ $FAIL = 0 ] && echo "BROWSER TEST: ALL CHECKS PASSED" || echo "BROWSER TEST: FAILURES ABOVE"; [ $PYRC = 0 ] && [ $FAIL = 0 ]
