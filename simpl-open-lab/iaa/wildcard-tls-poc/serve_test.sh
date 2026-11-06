#!/usr/bin/env bash
# serve_test.sh — what a CLIENT actually receives from ingress-nginx: per-host vs wildcard, renewal, rollback.
#
# Needs the lab cluster with cert-manager (./cert_manager.sh install) and ingress-nginx (./ingress_nginx.sh install).
# For every hostname it does a real TLS handshake to the controller (SNI = the hostname) and checks the certificate it
# is served: not nginx's fake default, chains to the lab CA, and matches the hostname (openssl verify -verify_hostname).
# The issuer is a LAB CA: this proves serving and renewal, not a real ACME wildcard order (see README).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
O=$(norm "$W/orig"); N=$(norm "$W/patched")
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' k3s-gvisor); PORT=30443
T=$(mktemp -d); CA=$T/ca.pem; CRT=$T/served.pem

served()  { echo | timeout 15 openssl s_client -connect "$IP:$PORT" -servername "$1" 2>/dev/null | openssl x509 > "$CRT" 2>/dev/null; [ -s "$CRT" ]; }
is_fake() { openssl x509 -in "$CRT" -noout -subject 2>/dev/null | grep -q "Fake Certificate"; }
serial()  { openssl x509 -in "$CRT" -noout -serial | cut -d= -f2; }
sans()    { openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n'; }
verifies(){ openssl verify -CAfile "$CA" -verify_hostname "$1" "$CRT" >/dev/null 2>&1; }
# The Kubernetes Secret is the ground truth; nginx may lag behind it (and may still hold the previous test's certificate).
secret_serial() { $K -n "$1" get secret "$2" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; }
# expect_sans HOST SANS [timeout]: poll until nginx serves a certificate whose SANs are exactly SANS and that verifies for HOST.
# Prints the seconds it took (the secret-to-served propagation delay); returns non-zero on timeout. Sets LAST_WAIT.
expect_sans() { local t0; t0=$(date +%s); for _ in $(seq 1 $(( ${3:-120} / 3 ))); do served "$1" && ! is_fake && verifies "$1" && [ "$(sans)" = "$2" ] && { LAST_WAIT=$(( $(date +%s) - t0 )); return 0; }; sleep 3; done; LAST_WAIT=$(( $(date +%s) - t0 )); return 1; }
nginx_id() { $K -n ingress-nginx get pod -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name} restarts={.items[0].status.containerStatuses[0].restartCount}'; }
apply_perhost() { local i=0 h; while read -r h; do i=$((i+1)); gw_ingress "$O" "$h" "$i" "" | $KI apply -f - >/dev/null; done < <(hosts "$HERE/hosts-consumer.txt"); }
apply_wildcard() { local i=0 h; while read -r h; do i=$((i+1)); gw_ingress "$N" "$h" "$i" "--set ingress.existingTlsSecret=$TAG-wildcard-tls" | $KI apply -f - >/dev/null; done < <(hosts "$HERE/hosts-consumer.txt"); }
agent_tls() { helm template agent "$HERE/agent-tls" --namespace $NS --set cluster.issuer=lab-ca --set namespaceTag=$TAG --set domainSuffix=$D "$@" | $KI apply -f - >/dev/null; }
WANT_WILD="DNS:*.$TAG.$D,DNS:*.fe.$TAG.$D,DNS:*.be.$TAG.$D"

$K -n ingress-nginx get pods --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running"' | grep -q . || { echo "ingress-nginx is not running (./ingress_nginx.sh install)"; exit 1; }
echo "ingress-nginx: $(nginx_id) at $IP:$PORT"
echo "### 0. lab issuer"; issuers || exit 1
$K -n cert-manager get secret lab-ca-secret -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CA"; reset_ns

echo; echo "### S0. CONTROL: an Ingress whose TLS secret does not exist must be seen as the fake certificate"
gw_ingress "$N" control.$TAG.$D 99 "--set ingress.existingTlsSecret=does-not-exist" | $KI apply -f - >/dev/null; sleep 10
if served control.$TAG.$D && is_fake && ! verifies control.$TAG.$D; then ok "the test sees nginx's fake certificate and rejects it (it can detect a wrong certificate)"; else bad "control did not behave as expected"; fi
reset_ns

echo; echo "### S1. TODAY (per-host): each of the 11 hosts must be served its OWN certificate (the one in its Secret)"
apply_perhost; wait_ready $NS 11
n_ok=0; serials=""; maxw=0
while read -r h; do
  if expect_sans "$h" "DNS:$h" && [ "$(serial)" = "$(secret_serial $NS "$h-cert")" ]; then n_ok=$((n_ok+1)); serials="$serials $(serial)"; [ "$LAST_WAIT" -gt "$maxw" ] && maxw=$LAST_WAIT
  else bad "$h: never served the certificate from its Secret (last served SANs: $(sans))"; fi
done < <(hosts "$HERE/hosts-consumer.txt")
[ $n_ok = 11 ] && ok "11/11 hosts served the certificate in their Secret, valid and matching the hostname (slowest: ${maxw}s after issue)" || bad "only $n_ok/11 hosts served correctly"
[ "$(echo $serials | tr ' ' '\n' | sort -u | wc -l)" = 11 ] && ok "11 distinct certificates (distinct serials)" || bad "serials not distinct"

echo; echo "### S2. WILDCARD: every host must be served the ONE wildcard certificate (the one in its Secret)"
reset_ns; agent_tls; apply_wildcard; wait_ready $NS 1
WSER=$(secret_serial $NS $TAG-wildcard-tls)
n_ok=0; maxw=0
while read -r h; do
  if expect_sans "$h" "$WANT_WILD" && [ "$(serial)" = "$WSER" ]; then n_ok=$((n_ok+1)); [ "$LAST_WAIT" -gt "$maxw" ] && maxw=$LAST_WAIT
  else bad "$h: did not converge to the wildcard (last served: $(sans))"; fi
done < <(hosts "$HERE/hosts-consumer.txt")
[ $n_ok = 11 ] && ok "11/11 hosts served the one wildcard certificate (serial $WSER), valid and matching each hostname (slowest: ${maxw}s after issue)" || bad "only $n_ok/11 hosts converged to the wildcard"
echo "  -- hosts NOT covered by the wildcard must not be served it"
while read -r h; do
  served "$h" && ! verifies "$h" && [ "$(serial)" != "$WSER" ] && ok "not served the wildcard / does not verify: $h" || bad "$h wrongly verifies or got the wildcard"
done < <(hosts "$HERE/hosts-must-not-match.txt")

echo; echo "### S3. RENEWAL: duration=1h, renewBefore=58m -> cert-manager renews after ~2 min; nginx must then serve the NEW certificate without a restart"
reset_ns; agent_tls --set tls.wildcard.duration=1h --set tls.wildcard.renewBefore=58m; apply_wildcard; wait_ready $NS 1
H1=$(hosts "$HERE/hosts-consumer.txt" | head -1)
SEC0=$(secret_serial $NS $TAG-wildcard-tls); REV0=$($K -n $NS get certificate $TAG-wildcard-tls -o jsonpath='{.status.revision}')
expect_sans "$H1" "$WANT_WILD" && [ "$(serial)" = "$SEC0" ] && ok "before renewal nginx serves the issued certificate (serial $SEC0, revision $REV0)" || bad "nginx never served the issued certificate"
P0=$(nginx_id); t0=$(date +%s); SEC1=$SEC0
for _ in $(seq 1 120); do SEC1=$(secret_serial $NS $TAG-wildcard-tls); [ -n "$SEC1" ] && [ "$SEC1" != "$SEC0" ] && break; sleep 5; done
REV1=$($K -n $NS get certificate $TAG-wildcard-tls -o jsonpath='{.status.revision}')
if [ "$SEC1" != "$SEC0" ] && [ "${REV1:-0}" -gt "${REV0:-0}" ]; then ok "cert-manager renewed it after $(( $(date +%s) - t0 ))s: revision $REV0 -> $REV1, serial $SEC0 -> $SEC1"; else bad "cert-manager did not renew within 10 minutes (revision $REV0 -> $REV1)"; fi
t1=$(date +%s); gotnew=0; for _ in $(seq 1 40); do served "$H1" && [ "$(serial)" = "$SEC1" ] && { gotnew=1; break; }; sleep 3; done
[ $gotnew = 1 ] && ok "nginx served the renewed certificate $(( $(date +%s) - t1 ))s after the Secret changed, still valid for the host" || bad "nginx never served the renewed certificate"
verifies "$H1" && ok "the renewed certificate chains to the CA and matches the host" || bad "renewed certificate does not verify"
all_new=0; while read -r h; do served "$h" && [ "$(serial)" = "$SEC1" ] && all_new=$((all_new+1)); done < <(hosts "$HERE/hosts-consumer.txt")
[ $all_new = 11 ] && ok "all 11 hosts serve the renewed certificate" || bad "only $all_new/11 hosts serve the renewed certificate"
[ "$(nginx_id)" = "$P0" ] && ok "nginx was not restarted ($P0)" || bad "nginx pod changed: $P0 -> $(nginx_id)"

echo; echo "### S4. ROLLBACK: switch the same 11 Ingresses back to per-host mode"
$K -n $NS delete certificate $TAG-wildcard-tls >/dev/null 2>&1; apply_perhost; wait_ready $NS 11
n_ok=0; while read -r h; do expect_sans "$h" "DNS:$h" && [ "$(serial)" = "$(secret_serial $NS "$h-cert")" ] && n_ok=$((n_ok+1)) || bad "$h: not served its own certificate after rollback (last: $(sans))"; done < <(hosts "$HERE/hosts-consumer.txt")
[ $n_ok = 11 ] && ok "after rollback 11/11 hosts are served their own valid certificate again" || bad "only $n_ok/11 after rollback"
[ "$($K -n $NS get ingress -o jsonpath='{range .items[*]}{.spec.tls[0].secretName}{"\n"}{end}' | grep -c wildcard)" = 0 ] && ok "no Ingress references the wildcard secret any more" || bad "an Ingress still references the wildcard secret"

rm -rf "$T"; echo; [ $FAIL = 0 ] && echo "SERVE TEST: ALL CHECKS PASSED" || echo "SERVE TEST: FAILURES ABOVE"; exit $FAIL
