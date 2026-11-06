#!/usr/bin/env bash
# letsencrypt_probe.sh [teardown] — a LOCAL DNS server against the REAL Let's Encrypt STAGING server.
#
# cert-manager (in the lab cluster) registers with Let's Encrypt staging and orders the three wildcard names for a random,
# unregistered .eu domain. Its DNS-01 solver publishes the challenge TXT records in a local BIND that is authoritative for that
# zone (exactly as in acme_test.sh, where Pebble was told to ask that BIND). Let's Encrypt does NOT ask our BIND: its validators
# query the public DNS, which knows nothing about the zone. This script records what Let's Encrypt says.
#
# SANDBOX ONLY: needs ./cert_manager.sh install and ./cert_manager.sh proxy-ca (the sandbox re-signs egress TLS).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
NSA=le-probe; BIND_IMG=mirror.gcr.io/internetsystemsconsortium/bind9:9.20
if [ "${1:-}" = teardown ]; then
  $K delete ns $NSA --ignore-not-found --wait=false >/dev/null 2>&1; $K delete clusterissuer le-staging le-staging-dns01 --ignore-not-found >/dev/null 2>&1
  $K -n cert-manager delete secret tsig-secret --ignore-not-found >/dev/null 2>&1; echo "le-probe removed"; exit 0
fi
ZONE="simpl-lab-$(openssl rand -hex 4).eu"; T=$(mktemp -d)
wait_deploy() { for _ in $(seq 1 80); do [ "$($K -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && return 0; sleep 4; done; return 1; }

echo "### 0. zone $ZONE (random, not registered), local BIND for it"
docker image inspect $BIND_IMG >/dev/null 2>&1 || docker pull -q $BIND_IMG >/dev/null || exit 1
docker save --platform linux/amd64 $BIND_IMG | docker exec -i k3s-gvisor ctr -n k8s.io images import --platform linux/amd64 - >/dev/null || exit 1
$K create ns $NSA >/dev/null 2>&1; KEY=$(openssl rand -base64 32)
$K -n cert-manager delete secret tsig-secret >/dev/null 2>&1; $K -n cert-manager create secret generic tsig-secret --from-literal=secret="$KEY" >/dev/null
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
wait_deploy $NSA bind && ok "local BIND is running, authoritative for $ZONE" || { bad "BIND did not start"; exit 1; }
BINDIP=$($K -n $NSA get svc bind -o jsonpath='{.spec.clusterIP}')
cur=$($K -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}')
if ! grep -q "dns01-recursive-nameservers=$BINDIP" <<< "$cur"; then
  # drop any earlier --dns01-recursive-nameservers* args (from acme_test.sh), then point the self-check at this BIND
  ARGS=$(python3 - "$cur" "$BINDIP" <<'PY'
import sys, json
a = [x for x in json.loads(sys.argv[1]) if not x.startswith("--dns01-recursive-nameservers")]
a += [f"--dns01-recursive-nameservers={sys.argv[2]}:53", "--dns01-recursive-nameservers-only"]
print(json.dumps([{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": a}]))
PY
)
  $K -n cert-manager patch deploy cert-manager --type json -p "$ARGS" >/dev/null; sleep 5; $K -n cert-manager rollout status deploy/cert-manager --timeout=240s >/dev/null 2>&1
fi
[ "$($K -n cert-manager get deploy cert-manager -o jsonpath='{.status.readyReplicas}')" = 1 ] && ok "cert-manager's DNS-01 self-check resolver is the local BIND" || { bad "cert-manager not ready"; exit 1; }

echo; echo "### 1. real Let's Encrypt STAGING: account + wildcard order, DNS-01 solved through the local BIND"
cat <<EOF > $T/issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: le-staging-dns01}
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef: {name: le-staging-dns01-account}
    solvers:
    - dns01:
        rfc2136: {nameserver: "$BINDIP:53", tsigKeyName: tsig-key, tsigAlgorithm: HMACSHA256, tsigSecretSecretRef: {name: tsig-secret, key: secret}}
EOF
for _ in $(seq 1 20); do $KI apply -f - < $T/issuer.yaml >/dev/null 2>&1 && break; sleep 3; done
for _ in $(seq 1 40); do [ "$($K get clusterissuer le-staging-dns01 -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && break; sleep 3; done
[ "$($K get clusterissuer le-staging-dns01 -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] \
  && ok "registered an account with Let's Encrypt staging: $($K get clusterissuer le-staging-dns01 -o jsonpath='{.status.acme.uri}')" \
  || { bad "no account at Let's Encrypt: $($K get clusterissuer le-staging-dns01 -o jsonpath='{.status.conditions[0].message}' | cut -c1-200)"; exit 1; }
reset_ns
helm template agent "$HERE/agent-tls" --namespace $NS --set cluster.issuer=le-staging-dns01 --set namespaceTag=$TAG --set domainSuffix=$ZONE | $KI apply -f - >/dev/null
echo "  waiting for Let's Encrypt to try to validate (up to 4 minutes)..."
for _ in $(seq 1 60); do
  st=$($K -n $NS get challenges -o jsonpath='{range .items[*]}{.status.state}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ')
  case "$st" in *invalid*) break;; esac; sleep 4
done
$K -n $NS get orders,challenges -o json > $T/state.json 2>/dev/null
python3 - "$T/state.json" <<'PY'
import sys, json
items = json.load(open(sys.argv[1]))["items"]
orders = [i for i in items if i["kind"] == "Order"]; chs = [i for i in items if i["kind"] == "Challenge"]
for o in orders:
    az = o.get("status", {}).get("authorizations", [])
    print(f"  order state={o.get('status',{}).get('state')}; {len(az)} authorizations; wildcard={sum(1 for a in az if a.get('wildcard'))}; "
          f"challenge types offered by Let's Encrypt: {sorted({c['type'] for a in az for c in a.get('challenges', [])})}")
for c in chs:
    s = c.get("status", {})
    print(f"  challenge {c['spec']['dnsName']:42s} type={c['spec']['type']} presented={s.get('presented')} state={s.get('state')}")
    if s.get("reason"): print("     Let's Encrypt/cert-manager reason:", s["reason"][:330])
json.dump({"orders": len(orders), "wild": sum(1 for o in orders for a in o.get("status", {}).get("authorizations", []) if a.get("wildcard")),
           "types": sorted({c["type"] for o in orders for a in o.get("status", {}).get("authorizations", []) for c in a.get("challenges", [])}),
           "presented": sum(1 for c in chs if c.get("status", {}).get("presented")), "invalid": sum(1 for c in chs if c.get("status", {}).get("state") == "invalid"),
           "reasons": " ".join(c.get("status", {}).get("reason", "") for c in chs)}, open(sys.argv[1] + ".sum", "w"))
PY
S=$T/state.json.sum
py() { python3 -c "import json;d=json.load(open('$S'));print($1)"; }
[ "$(py "d['wild']")" = 3 ] && ok "Let's Encrypt accepted an order with 3 wildcard names" || bad "expected 3 wildcard authorizations"
# Let's Encrypt staging also advertises a newer 'dns-persist-01'; what matters is that http-01 is NOT offered for wildcard names
py "d['types']" | grep -q "dns-01" && ! py "d['types']" | grep -q "http-01" && ok "for wildcard names Let's Encrypt offered no http-01 (offered: $(py "d['types']")): a default HTTP-01 issuer can never get one" || bad "unexpected challenge types: $(py "d['types']")"
# cert-manager removes the records again once the challenge fails, so 'presented' is already false here: BIND's log is the evidence
ADDS=$($K -n $NSA logs deploy/bind 2>/dev/null | grep -c "adding an RR at '_acme-challenge"); DELS=$($K -n $NSA logs deploy/bind 2>/dev/null | grep -c "deleting an RR at _acme-challenge")
[ "$ADDS" = 3 ] && ok "cert-manager published all 3 challenge TXT records in the local BIND, TSIG-signed ($ADDS added, $DELS removed again after the failure)" || bad "BIND saw $ADDS challenge records, expected 3"
if [ "$(py "d['invalid']")" -ge 1 ] && grep -qiE "nxdomain|dns problem|no valid|looking up TXT" <<< "$(py "d['reasons']")"; then
  ok "Let's Encrypt REJECTED the validation with a DNS error: it looked in the public DNS, not in our local BIND"
else bad "no DNS-related rejection from Let's Encrypt within 4 minutes (state: $(py "d['reasons']" | cut -c1-200))"; fi
[ "$(count_ready $NS)" = 0 ] && ok "no certificate was issued" || bad "a certificate was issued?!"
rm -rf "$T"; echo; [ $FAIL = 0 ] && echo "LET'S ENCRYPT PROBE: ALL CHECKS PASSED" || echo "LET'S ENCRYPT PROBE: FAILURES ABOVE"; exit $FAIL
