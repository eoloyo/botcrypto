# lib.sh — helpers shared by cluster_test.sh and serve_test.sh (sourced, not executed).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${W:-/root/simpl-open-lab-work/wildcard-poc}"           # holds orig/ and patched/ chart copies (see README)
K="docker exec k3s-gvisor kubectl"; KI="docker exec -i k3s-gvisor kubectl"
NS=poc-agent; NSR=poc-real; D=dataspace.example.eu; TAG=consumer1; RTAG=real1
FAIL=0; ok() { printf "  [PASS] %s\n" "$1"; }; bad() { printf "  [FAIL] %s\n" "$1"; FAIL=1; }
# Chart.yaml carries the CI placeholder ${PROJECT_RELEASE_VERSION}, which helm rejects: use normalised temp copies.
norm() { local D2; D2=$(mktemp -d); cp -r "$1"/. "$D2"/; for c in "$D2"/*/; do sed -i -E 's/^(version|appVersion): .*PROJECT_RELEASE_VERSION.*/\1: "0.0.0-poc"/' "$c/Chart.yaml"; done; echo "$D2"; }
hosts() { sed -E 's/#.*//; s/[[:space:]]+$//; /^$/d' "$1"; }
certs_json() { $K -n "$1" get certificates -o json 2>/dev/null; }
count_certs() { certs_json "$1" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('items',[])))"; }
count_ready() { certs_json "$1" | python3 -c "
import sys,json
print(sum(1 for c in json.load(sys.stdin).get('items',[]) if any(x.get('type')=='Ready' and x.get('status')=='True' for x in c.get('status',{}).get('conditions',[]))))"; }
wait_ready() { for _ in $(seq 1 40); do [ "$(count_ready "$1")" -ge "$2" ] && return 0; sleep 3; done; return 1; }
reset_ns() { for n in "$NS" "$NSR"; do $K delete ingress,certificate --all -n $n >/dev/null 2>&1; $K delete secret --all -n $n >/dev/null 2>&1; $K create ns $n >/dev/null 2>&1; done; }
# one tier1-gateway Ingress per host (the gateway chart's real template; only the object name is made unique)
gw_ingress() { # chart-dir host index extra-args
  helm template rel "$1/tier1-gateway" --namespace "$NS" --show-only templates/ingress.yaml \
    --set hostT1="$2" --set ingress.issuer=lab-ca --set cors.allowOrigin="https://$2" $4 \
    | sed -E "s/^  name: simpl-ingress$/  name: ing-$3/"; }
# lab issuer: selfSigned -> CA (proves chart mechanics only; a real wildcard needs an ACME DNS-01 issuer)
issuers() {
  local f; f=$(mktemp); cat > "$f" <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: lab-selfsigned}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: lab-ca, namespace: cert-manager}
spec: {isCA: true, commonName: lab-ca, secretName: lab-ca-secret, privateKey: {algorithm: ECDSA, size: 256}, issuerRef: {name: lab-selfsigned, kind: ClusterIssuer}}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: lab-ca}
spec: {ca: {secretName: lab-ca-secret}}
YAML
  for _ in $(seq 1 20); do $KI apply -f - < "$f" >/dev/null 2>&1 && break; sleep 3; done   # the webhook can lag right after install
  rm -f "$f"
  for _ in $(seq 1 30); do [ "$($K get clusterissuer lab-ca -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && break; sleep 2; done
  [ "$($K get clusterissuer lab-ca -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" = True ] && ok "ClusterIssuer lab-ca is Ready" || { bad "ClusterIssuer lab-ca not Ready"; return 1; }
}
