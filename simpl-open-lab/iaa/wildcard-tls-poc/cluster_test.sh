#!/usr/bin/env bash
# cluster_test.sh [migrate] — per-host certificates (today) vs one wildcard certificate (patched charts), on a real cert-manager.
#   no argument: phases A, A2, B, B2.   "migrate": switch an existing per-host deployment to wildcard in place (phase C).
#
# Needs the ../../k8s-gvisor lab cluster (container k3s-gvisor) with cert-manager installed (see README), and helm.
# The issuer is a LAB CA (selfSigned -> CA). That proves the chart mechanics only: a real wildcard needs an ACME
# DNS-01 ClusterIssuer, which cannot be tested here (no DNS provider, no Let's Encrypt).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
O=$(norm "$W/orig"); N=$(norm "$W/patched")

echo "### 0. lab issuer (selfSigned -> CA) and namespaces"
issuers || exit 1
reset_ns

if [ "${1:-}" = migrate ]; then
  echo; echo "### C. MIGRATION: an existing per-host deployment is switched to wildcard mode in place (same Ingress names)"
  i=0; while read -r h; do i=$((i+1)); gw_ingress "$O" "$h" "$i" "" | $KI apply -f - >/dev/null; done < <(hosts "$HERE/hosts-consumer.txt")
  wait_ready $NS 11; echo "  before: $(count_certs $NS) per-host Certificates, $($K -n $NS get secrets --no-headers | grep -c tls) TLS secrets"
  OWN=$($K -n $NS get certificates -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}{"/"}{.items[0].metadata.ownerReferences[0].name}')
  echo "  a per-host Certificate is owned by: $OWN"
  helm template agent "$HERE/agent-tls" --namespace $NS --set cluster.issuer=lab-ca --set namespaceTag=$TAG --set domainSuffix=$D | $KI apply -f - >/dev/null
  i=0; while read -r h; do i=$((i+1)); gw_ingress "$N" "$h" "$i" "--set ingress.existingTlsSecret=$TAG-wildcard-tls" | $KI apply -f - >/dev/null; done < <(hosts "$HERE/hosts-consumer.txt")
  sleep 45
  $K -n $NS get ingress -o jsonpath='{range .items[*]}{.spec.tls[0].secretName}{"\n"}{end}' | sort -u | grep -qx "$TAG-wildcard-tls" && ok "all Ingresses now reference the wildcard secret" || bad "Ingresses still reference per-host secrets"
  [ "$($K -n $NS get certificate $TAG-wildcard-tls -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && ok "wildcard certificate issued" || bad "wildcard certificate not issued"
  after=$(count_certs $NS); orphans=$((after-1))
  echo "  after:  $after Certificate(s) = 1 wildcard + $orphans old per-host (orphaned: no Ingress asks for them any more)"
  echo "  old per-host Certificates still owned by an Ingress? $($K -n $NS get certificates -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' | grep -v wildcard | awk '{print $2}' | sort | uniq -c | tr '\n' ' ')"
  [ "$orphans" -gt 0 ] && echo "  => migration needs an explicit cleanup step: the old per-host Certificates (and their renewals) are NOT removed by cert-manager when the annotation goes away" || echo "  => cert-manager removed the old per-host Certificates by itself"
  echo "  deleting the old per-host Certificates + secrets (what a migration script/step must do)..."
  $K -n $NS get certificates -o name | grep -v wildcard | xargs -r $K -n $NS delete >/dev/null 2>&1
  $K -n $NS get secrets -o name | grep -E 'example.eu-cert$' | xargs -r $K -n $NS delete >/dev/null 2>&1
  [ "$(count_certs $NS)" = 1 ] && ok "after cleanup: 1 Certificate left (the wildcard)" || bad "cleanup left $(count_certs $NS) certificates"
  sleep 20; [ "$(count_certs $NS)" = 1 ] && ok "cert-manager did NOT recreate the per-host Certificates (annotation is gone)" || bad "per-host Certificates came back"
  echo; [ $FAIL = 0 ] && echo "MIGRATION TEST: ALL CHECKS PASSED" || echo "MIGRATION TEST: FAILURES ABOVE"; exit $FAIL
fi

echo; echo "### A. TODAY (original charts): 11 consumer hosts, one Ingress each"
i=0; while read -r h; do i=$((i+1)); gw_ingress "$O" "$h" "$i" "" | $KI apply -f - >/dev/null; done < <(hosts "$HERE/hosts-consumer.txt")
wait_ready $NS 11
a_certs=$(count_certs $NS); a_ready=$(count_ready $NS); echo "  cert-manager created $a_certs Certificate(s), $a_ready Ready"
[ "$a_certs" = 11 ] && ok "per-host mode: 11 hosts -> 11 certificates (one ACME order each on a real issuer)" || bad "expected 11 certificates, got $a_certs"
[ "$a_ready" = 11 ] && ok "all 11 issued" || bad "only $a_ready of 11 issued"
echo "  secrets: $($K -n $NS get secrets --no-headers 2>/dev/null | grep -c 'kubernetes.io/tls') TLS secret(s), e.g. $($K -n $NS get secrets --no-headers 2>/dev/null | awk '/tls/{print $1}' | head -2 | tr '\n' ' ')"

echo; echo "### A2. TODAY, the six real charts together (5 frontends share one host + the gateway) in $NSR"
RFE=participant.fe.$RTAG.$D; RBE=participant.be.$RTAG.$D
helm template rel "$O/tier1-gateway" --namespace $NSR --show-only templates/ingress.yaml --set hostT1=$RBE --set ingress.issuer=lab-ca --set cors.allowOrigin=https://$RFE | $KI apply -f - >/dev/null
for c in authentication-provider-fe identity-provider-fe onboarding-fe security-attribute-provider-fe users-roles-fe; do
  helm template rel "$O/$c" --namespace $NSR --show-only templates/ingress.yaml --set hostFe=$RFE --set ingress.issuer=lab-ca --set cors.allowOrigin=https://$RFE | $KI apply -f - >/dev/null; done
sleep 25
echo "  ingresses: $($K -n $NSR get ingress --no-headers | wc -l)   certificates: $(count_certs $NSR) ($(count_ready $NSR) Ready)   distinct secrets: $($K -n $NSR get ingress -o jsonpath='{range .items[*]}{.spec.tls[0].secretName}{"\n"}{end}' | sort -u | wc -l)"
echo "  cert-manager complaints about shared secrets:"; $K -n $NSR get events 2>/dev/null | grep -iE "not owned|already exists|conflict|ErrInit|BadConfig" | cut -c1-200 | head -5 | sed 's/^/    /'; echo "    (none above = no complaints)"

echo; echo "### B. WILDCARD MODE (patched charts + agent-tls)"
reset_ns
helm template agent "$HERE/agent-tls" --namespace $NS --set cluster.issuer=lab-ca --set namespaceTag=$TAG --set domainSuffix=$D | $KI apply -f - >/dev/null
i=0; while read -r h; do i=$((i+1)); gw_ingress "$N" "$h" "$i" "--set ingress.existingTlsSecret=$TAG-wildcard-tls" | $KI apply -f - >/dev/null; done < <(hosts "$HERE/hosts-consumer.txt")
wait_ready $NS 1; sleep 10
b_certs=$(count_certs $NS); echo "  cert-manager has $b_certs Certificate(s) in $NS: $($K -n $NS get certificates --no-headers | awk '{print $1" ready="$2}' | tr '\n' ' ')"
[ "$b_certs" = 1 ] && ok "wildcard mode: 11 hosts -> exactly 1 certificate (no per-host certificates were requested)" || bad "expected 1 certificate, got $b_certs"
[ "$(count_ready $NS)" = 1 ] && ok "the wildcard certificate is issued" || bad "wildcard certificate not issued"
sec=$($K -n $NS get ingress -o jsonpath='{range .items[*]}{.spec.tls[0].secretName}{"\n"}{end}' | sort -u)
[ "$sec" = "$TAG-wildcard-tls" ] && ok "all 11 Ingresses reference the one shared secret" || bad "Ingresses reference: $sec"
CRT=$(mktemp); $K -n $NS get secret $TAG-wildcard-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CRT"
echo "  certificate SANs: $(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n')"
echo "  -- coverage of the 11 real consumer hosts (openssl x509 -checkhost)"
while read -r h; do openssl x509 -in "$CRT" -noout -checkhost "$h" 2>&1 | grep -q "does match" && ok "covered:     $h" || bad "NOT covered: $h"; done < <(hosts "$HERE/hosts-consumer.txt")
echo "  -- hosts that must NOT be covered"
while read -r h; do openssl x509 -in "$CRT" -noout -checkhost "$h" 2>&1 | grep -q "does NOT match" && ok "not covered: $h" || bad "WRONGLY covered: $h"; done < <(hosts "$HERE/hosts-must-not-match.txt")
rm -f "$CRT"

echo; echo "### B2. WILDCARD MODE, the six real charts in $NSR"
helm template agent "$HERE/agent-tls" --namespace $NSR --set cluster.issuer=lab-ca --set namespaceTag=$RTAG --set domainSuffix=$D | $KI apply -f - >/dev/null
helm template rel "$N/tier1-gateway" --namespace $NSR --show-only templates/ingress.yaml --set hostT1=$RBE --set ingress.issuer=lab-ca --set cors.allowOrigin=https://$RFE --set ingress.existingTlsSecret=$RTAG-wildcard-tls | $KI apply -f - >/dev/null
for c in authentication-provider-fe identity-provider-fe onboarding-fe security-attribute-provider-fe users-roles-fe; do
  helm template rel "$N/$c" --namespace $NSR --show-only templates/ingress.yaml --set hostFe=$RFE --set ingress.issuer=lab-ca --set cors.allowOrigin=https://$RFE --set ingress.existingTlsSecret=$RTAG-wildcard-tls | $KI apply -f - >/dev/null; done
wait_ready $NSR 1; sleep 8
[ "$(count_certs $NSR)" = 1 ] && ok "6 real Ingresses on 2 hosts -> 1 certificate" || bad "expected 1 certificate in $NSR, got $(count_certs $NSR)"

echo; [ $FAIL = 0 ] && echo "CLUSTER TEST: ALL CHECKS PASSED" || echo "CLUSTER TEST: FAILURES ABOVE"; exit $FAIL
