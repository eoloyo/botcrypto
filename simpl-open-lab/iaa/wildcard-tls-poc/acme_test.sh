#!/usr/bin/env bash
# acme_test.sh [teardown] — a REAL ACME wildcard order over DNS-01, and what the guide's default HTTP-01 issuer does with it.
#
# Pebble (Let's Encrypt's ACME test server) + BIND (an authoritative DNS server that accepts TSIG-signed dynamic updates)
# run in the lab cluster. cert-manager's rfc2136 DNS-01 solver publishes the _acme-challenge TXT records in BIND, Pebble
# looks them up (-dnsserver) and issues. This tests cert-manager's ACME/DNS-01 handling of the three wildcard names, NOT any
# particular DNS provider's solver (OVH in Simpl's guide) and NOT Let's Encrypt itself.
#
# Needs: cert-manager + ingress-nginx in the lab cluster (cert_manager.sh / ingress_nginx.sh install).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
NSA=acme-lab; ZONE=dataspace.example.eu
PEBBLE_IMG=ghcr.io/letsencrypt/pebble:latest; BIND_IMG=mirror.gcr.io/internetsystemsconsortium/bind9:9.20
N=$(norm "$W/patched"); T=$(mktemp -d)
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' k3s-gvisor); PORT=30443
WANT_WILD="DNS:*.$TAG.$ZONE,DNS:*.fe.$TAG.$ZONE,DNS:*.be.$TAG.$ZONE"

if [ "${1:-}" = teardown ]; then
  $K delete ns $NSA --ignore-not-found --wait=false >/dev/null 2>&1; $K delete clusterissuer pebble-dns01 pebble-http01 --ignore-not-found >/dev/null 2>&1
  $K -n cert-manager delete secret tsig-secret --ignore-not-found >/dev/null 2>&1; echo "acme-lab removed (cert-manager's extra args go away with ./cert_manager.sh uninstall)"; exit 0
fi
wait_deploy() { for _ in $(seq 1 80); do [ "$($K -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && return 0; sleep 4; done; return 1; }

echo "### 0. images, namespace, TSIG key"
for img in $PEBBLE_IMG $BIND_IMG; do docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null || { echo "pull of $img failed"; exit 1; }; done
docker save --platform linux/amd64 $PEBBLE_IMG $BIND_IMG | docker exec -i k3s-gvisor ctr -n k8s.io images import --platform linux/amd64 - >/dev/null || exit 1
$K create ns $NSA >/dev/null 2>&1; KEY=$(openssl rand -base64 32)
$K -n cert-manager delete secret tsig-secret >/dev/null 2>&1; $K -n cert-manager create secret generic tsig-secret --from-literal=secret="$KEY" >/dev/null
ok "images imported; TSIG key created"

echo; echo "### 1. BIND: authoritative for $ZONE, accepts TSIG-signed dynamic updates"
cat <<EOF | $KI apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata: {name: bind-config, namespace: $NSA}
data:
  named.conf: |
    options { directory "/var/cache/bind"; listen-on { any; }; listen-on-v6 { none; }; allow-query { any; }; recursion no; dnssec-validation no; };
    key "tsig-key" { algorithm hmac-sha256; secret "$KEY"; };
    zone "$ZONE" { type primary; file "/var/cache/bind/$ZONE.zone"; allow-update { key "tsig-key"; }; };
  zone: |
    \$TTL 5
    @ IN SOA ns1.$ZONE. admin.$ZONE. ( 1 60 60 3600 5 )
    @ IN NS ns1.$ZONE.
    ns1 IN A 10.43.0.53
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: bind, namespace: $NSA}
spec:
  replicas: 1
  selector: {matchLabels: {app: bind}}
  template:
    metadata: {labels: {app: bind}}
    spec:
      runtimeClassName: runsc
      initContainers:
      - name: zone
        image: $BIND_IMG
        imagePullPolicy: IfNotPresent
        command: ["sh","-c","cp /cfg/zone /var/cache/bind/$ZONE.zone && chmod 666 /var/cache/bind/$ZONE.zone && chmod 777 /var/cache/bind"]
        volumeMounts: [{name: cfg, mountPath: /cfg}, {name: cache, mountPath: /var/cache/bind}]
      containers:
      - name: bind
        image: $BIND_IMG
        imagePullPolicy: IfNotPresent
        args: ["-g","-c","/etc/bind/named.conf"]
        ports: [{containerPort: 53, protocol: UDP}, {containerPort: 53, protocol: TCP}]
        volumeMounts: [{name: cfg, mountPath: /etc/bind/named.conf, subPath: named.conf}, {name: cache, mountPath: /var/cache/bind}]
      volumes: [{name: cfg, configMap: {name: bind-config}}, {name: cache, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: bind, namespace: $NSA}
spec:
  selector: {app: bind}
  ports: [{name: dns-udp, port: 53, protocol: UDP}, {name: dns-tcp, port: 53, protocol: TCP}]
EOF
wait_deploy $NSA bind && ok "BIND is running" || { bad "BIND did not start"; $K -n $NSA logs deploy/bind --tail=8; exit 1; }
BINDIP=$($K -n $NSA get svc bind -o jsonpath='{.spec.clusterIP}'); echo "  BIND service: $BINDIP:53"

echo; echo "### 2. Pebble (ACME test server) that validates DNS-01 against BIND"
cat <<EOF | $KI apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: pebble, namespace: $NSA}
spec:
  replicas: 1
  selector: {matchLabels: {app: pebble}}
  template:
    metadata: {labels: {app: pebble}}
    spec:
      runtimeClassName: runsc
      containers:
      - name: pebble
        image: $PEBBLE_IMG
        imagePullPolicy: IfNotPresent
        args: ["-config","/test/config/pebble-config.json","-dnsserver","$BINDIP:53"]
        env: [{name: PEBBLE_VA_NOSLEEP, value: "1"}, {name: PEBBLE_VA_ALWAYS_VALID, value: "0"}, {name: PEBBLE_WFE_NONCEREJECT, value: "0"}]
        ports: [{containerPort: 14000}, {containerPort: 15000}]
---
apiVersion: v1
kind: Service
metadata: {name: pebble, namespace: $NSA}
spec:
  selector: {app: pebble}
  ports: [{name: acme, port: 14000}, {name: mgmt, port: 15000}]
EOF
wait_deploy $NSA pebble && ok "Pebble is running" || { bad "Pebble did not start"; $K -n $NSA logs deploy/pebble --tail=8; exit 1; }
PEBBLEIP=$($K -n $NSA get svc pebble -o jsonpath='{.spec.clusterIP}'); echo "  ACME directory: https://$PEBBLEIP:14000/dir"

echo; echo "### 3. cert-manager: resolve DNS-01 propagation against BIND, and two ClusterIssuers (DNS-01 and the guide's default HTTP-01)"
if ! $K -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q "dns01-recursive-nameservers=$BINDIP"; then
  $K -n cert-manager patch deploy cert-manager --type json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--dns01-recursive-nameservers=$BINDIP:53\"},{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--dns01-recursive-nameservers-only\"}]" >/dev/null
  sleep 5; $K -n cert-manager rollout status deploy/cert-manager --timeout=240s >/dev/null 2>&1
fi
$K -n cert-manager get deploy cert-manager -o jsonpath='{.status.readyReplicas}' | grep -q 1 && ok "cert-manager restarted with its DNS-01 resolver pointed at BIND" || { bad "cert-manager not ready"; exit 1; }
cat <<EOF > $T/issuers.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: pebble-dns01}
spec:
  acme:
    server: https://$PEBBLEIP:14000/dir
    skipTLSVerify: true
    email: lab@example.eu
    privateKeySecretRef: {name: pebble-dns01-account}
    solvers:
    - dns01:
        rfc2136: {nameserver: "$BINDIP:53", tsigKeyName: tsig-key, tsigAlgorithm: HMACSHA256, tsigSecretSecretRef: {name: tsig-secret, key: secret}}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: pebble-http01}
spec:
  acme:
    server: https://$PEBBLEIP:14000/dir
    skipTLSVerify: true
    email: lab@example.eu
    privateKeySecretRef: {name: pebble-http01-account}
    solvers:
    - http01: {ingress: {class: nginx}}
EOF
for _ in $(seq 1 20); do $KI apply -f - < $T/issuers.yaml >/dev/null 2>&1 && break; sleep 3; done
for i in pebble-dns01 pebble-http01; do for _ in $(seq 1 40); do [ "$($K get clusterissuer $i -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && break; sleep 3; done
  [ "$($K get clusterissuer $i -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && ok "ClusterIssuer $i registered an ACME account with Pebble" || { bad "ClusterIssuer $i not Ready: $($K get clusterissuer $i -o jsonpath='{.status.conditions[0].message}' | cut -c1-200)"; }; done
reset_ns

echo; echo "### T1. DNS-01: one ACME order for the three wildcard names"
helm template agent "$HERE/agent-tls" --namespace $NS --set cluster.issuer=pebble-dns01 --set namespaceTag=$TAG --set domainSuffix=$ZONE | $KI apply -f - >/dev/null
t0=$(date +%s); wait_ready $NS 1 || true; for _ in $(seq 1 60); do [ "$(count_ready $NS)" -ge 1 ] && break; sleep 4; done
if [ "$(count_ready $NS)" = 1 ]; then ok "wildcard certificate issued by Pebble over DNS-01 in $(( $(date +%s) - t0 ))s"; else bad "not issued: $($K -n $NS get certificate $TAG-wildcard-tls -o jsonpath='{.status.conditions[0].message}' | cut -c1-250)"; $K -n $NS get orders,challenges 2>&1 | head -6; fi
$K -n $NS get secret $TAG-wildcard-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > $T/chain.pem
openssl x509 -in $T/chain.pem -noout -issuer 2>/dev/null | grep -qi pebble && ok "issuer is Pebble: $(openssl x509 -in $T/chain.pem -noout -issuer | cut -c1-80)" || bad "not issued by Pebble"
[ "$(openssl x509 -in $T/chain.pem -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n')" = "$WANT_WILD" ] && ok "SANs are exactly the three wildcard names" || bad "unexpected SANs"
$K -n $NS get orders -o json | python3 -c "
import sys, json
for o in json.load(sys.stdin)['items']:
    st = o.get('status', {}); az = st.get('authorizations', [])
    print('  order state=%s, %d authorizations: %s' % (st.get('state'), len(az), '; '.join('%s%s via %s' % ('*.' if a.get('wildcard') else '', a['identifier'], ','.join(c['type'] for c in a.get('challenges', []) if c.get('type') == 'dns-01') or '?') for a in az)))
    print('WILD_AUTHZ=%d' % sum(1 for a in az if a.get('wildcard')))" | tee $T/order.txt
grep -q "WILD_AUTHZ=3" $T/order.txt && ok "the order had 3 wildcard authorizations, each validated through a dns-01 challenge" || bad "order did not show 3 wildcard dns-01 authorizations"
echo "  BIND saw the challenge records: $($K -n $NSA logs deploy/bind 2>/dev/null | grep -c '_acme-challenge') log line(s) mentioning _acme-challenge"

echo; echo "### T2. The guide's DEFAULT issuer (HTTP-01 only) asked for the same wildcard certificate"
helm template agent "$HERE/agent-tls" --namespace $NSR --set cluster.issuer=pebble-http01 --set namespaceTag=$RTAG --set domainSuffix=$ZONE | $KI apply -f - >/dev/null
sleep 40
[ "$(count_ready $NSR)" = 0 ] && ok "NOT issued: an HTTP-01-only issuer cannot satisfy a wildcard order" || bad "an HTTP-01 issuer unexpectedly issued a wildcard"
ORD=$($K -n $NSR get orders -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
EV=$($K -n $NSR get events --field-selector involvedObject.name=$ORD,reason=Solver -o jsonpath='{.items[0].message}' 2>/dev/null)
echo "  order state: $($K -n $NSR get orders -o jsonpath='{.items[0].status.state}' 2>/dev/null) (it never becomes 'failed': it stays pending)"
echo "  the only signal is a Warning event: ${EV:-<none>}" | cut -c1-300
echo "  certificate condition meanwhile: $($K -n $NSR get certificate $RTAG-wildcard-tls -o jsonpath='{.status.conditions[0].message}' 2>/dev/null | cut -c1-120)"
[ "$($K -n $NSR get orders -o jsonpath='{.items[0].status.state}' 2>/dev/null)" = pending ] && ok "the order stays pending (not failed, not valid)" || bad "unexpected order state"
echo "$EV" | grep -qi "no configured challenge solvers" && ok "cert-manager's Warning event says it has no solver that can satisfy the challenge (what an operator would have to find)" || bad "no 'no configured challenge solvers' event"

echo; echo "### T3. Serve the Pebble-issued wildcard through ingress-nginx for the 11 hosts"
python3 - <<'PY' "$T"
import sys, re
t = sys.argv[1]; pem = open(f"{t}/chain.pem").read()
certs = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n?", pem, re.S)
open(f"{t}/inter.pem", "w").write("".join(certs[1:]))
print("  chain in the secret: leaf + %d CA certificate(s)" % (len(certs) - 1))
PY
i=0; while read -r h; do i=$((i+1)); gw_ingress "$N" "$h" "$i" "--set ingress.existingTlsSecret=$TAG-wildcard-tls" | $KI apply -f - >/dev/null; done < <(hosts "$HERE/hosts-consumer.txt")
SER=$(openssl x509 -in $T/chain.pem -noout -serial | cut -d= -f2); n_ok=0
while read -r h; do
  for _ in $(seq 1 40); do echo | timeout 15 openssl s_client -connect "$IP:$PORT" -servername "$h" 2>/dev/null | openssl x509 > $T/served.pem 2>/dev/null
    [ -s $T/served.pem ] && [ "$(openssl x509 -in $T/served.pem -noout -serial | cut -d= -f2)" = "$SER" ] && break; sleep 3; done
  [ "$(openssl x509 -in $T/served.pem -noout -serial 2>/dev/null | cut -d= -f2)" = "$SER" ] && openssl verify -partial_chain -CAfile $T/inter.pem -verify_hostname "$h" $T/served.pem >/dev/null 2>&1 && n_ok=$((n_ok+1)) || bad "$h: not served the Pebble wildcard, or it does not verify"
done < <(hosts "$HERE/hosts-consumer.txt")
[ $n_ok = 11 ] && ok "11/11 hosts served the ACME-issued wildcard; it verifies for each hostname against the Pebble CA (partial chain: Pebble's CA is the trust anchor)" || bad "only $n_ok/11 hosts served the ACME wildcard"

rm -rf "$T"; echo; [ $FAIL = 0 ] && echo "ACME TEST: ALL CHECKS PASSED" || echo "ACME TEST: FAILURES ABOVE"; exit $FAIL
