#!/usr/bin/env bash
# cert_manager.sh install|uninstall — cert-manager in the ../../k8s-gvisor lab cluster (container k3s-gvisor).
#
# install:   pull the three images on the host, import them into the cluster's containerd (the cluster itself cannot reach
#            quay.io), apply the release manifest, and run the pods under gVisor. Without runtimeClassName=runsc the
#            sandboxes fail with "runc create failed ... can't get final child's PID from pipe: EOF" (see ../../k8s-gvisor).
# uninstall: remove the prototype namespaces and cert-manager, and the Certificates cert-manager made for the lab's
#            existing authority01 Ingresses (their issuer annotation is the unresolved placeholder ${CLUSTERISSUER}).
#
# NOTE: while cert-manager is installed it reacts to EVERY Ingress annotated cert-manager.io/cluster-issuer, including the
# lab's authority01 ones. That is harmless there (no ingress controller, no valid issuer) but it does create objects.
set -uo pipefail
V="${CERT_MANAGER_VERSION:-v1.19.1}"; K="docker exec k3s-gvisor kubectl"
MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/$V/cert-manager.yaml"
log() { echo "[cert-manager] $*"; }
case "${1:-}" in
install)
  for i in controller webhook cainjector; do
    docker image inspect "quay.io/jetstack/cert-manager-$i:$V" >/dev/null 2>&1 || docker pull -q "quay.io/jetstack/cert-manager-$i:$V" >/dev/null || { log "pull of $i failed"; exit 1; }
  done
  docker save --platform linux/amd64 $(for i in controller webhook cainjector; do echo "quay.io/jetstack/cert-manager-$i:$V"; done) \
    | docker exec -i k3s-gvisor ctr -n k8s.io images import --platform linux/amd64 - >/dev/null || { log "image import failed"; exit 1; }
  curl -sfL -m 120 "$MANIFEST" | docker exec -i k3s-gvisor kubectl apply -f - >/dev/null || { log "apply failed"; exit 1; }
  for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
    $K -n cert-manager patch deploy $d --type merge -p '{"spec":{"template":{"spec":{"runtimeClassName":"runsc"}}}}' >/dev/null
  done
  for _ in $(seq 1 120); do
    r=$($K -n cert-manager get pods --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running"' | wc -l)
    ip=$($K -n cert-manager get endpoints cert-manager-webhook -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
    # pods Ready and an endpoint are not enough: cainjector must also have injected its CA into the webhook, or the API
    # server rejects every Certificate with "x509: certificate signed by unknown authority". Ask for a real admission.
    if [ "$r" = 3 ] && [ -n "$ip" ] && cat <<'PROBE' | docker exec -i k3s-gvisor kubectl apply --dry-run=server -f - >/dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: readiness-probe}
spec: {selfSigned: {}}
PROBE
    then log "cert-manager $V is ready (3/3 pods, and its webhook admits a ClusterIssuer)"; exit 0; fi
    sleep 5
  done
  log "not ready in time"; $K -n cert-manager get pods; exit 1 ;;
uninstall)
  $K delete ns poc-agent poc-real --ignore-not-found --wait=false >/dev/null 2>&1
  $K delete certificate --all -n authority01 --ignore-not-found >/dev/null 2>&1
  curl -sfL -m 120 "$MANIFEST" | docker exec -i k3s-gvisor kubectl delete -f - --ignore-not-found --wait=true >/dev/null 2>&1
  # secrets cert-manager may have left for the authority01 Ingresses (they did not exist before cert-manager was installed)
  $K -n authority01 get secrets -o name 2>/dev/null | grep -E 'example\.com-cert|-[a-z0-9]{5,}$' | grep -E 'example\.com-cert' | xargs -r $K -n authority01 delete >/dev/null 2>&1
  log "removed. certificates CRD present? $($K get crd certificates.cert-manager.io >/dev/null 2>&1 && echo YES || echo no); cert-manager ns present? $($K get ns cert-manager >/dev/null 2>&1 && echo YES || echo no)" ;;
*) sed -n 2,13p "$0"; exit 2 ;;
esac
