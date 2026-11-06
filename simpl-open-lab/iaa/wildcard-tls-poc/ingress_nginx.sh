#!/usr/bin/env bash
# ingress_nginx.sh install|uninstall — ingress-nginx 1.13.x (the version Simpl's prerequisites pin) in the lab cluster.
#
# The image is pulled on the host and imported into the cluster's containerd (the cluster cannot reach registry.k8s.io);
# the pod runs under gVisor (runtimeClassName runsc); the admission webhook is off (it needs an extra helper image);
# TLS is exposed as NodePort 30443 so the host can reach it at the k3s container's IP.
set -uo pipefail
CHART_VERSION="${INGRESS_NGINX_CHART:-4.13.7}"; IMG="registry.k8s.io/ingress-nginx/controller:v${INGRESS_NGINX_APP:-1.13.7}"
K="docker exec k3s-gvisor kubectl"
render() { helm template ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --version "$CHART_VERSION" \
  --namespace ingress-nginx --set controller.admissionWebhooks.enabled=false --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 --set controller.service.nodePorts.https=30443 \
  --set controller.image.digest="" --set controller.runtimeClassName=runsc --set controller.replicaCount=1; }
case "${1:-}" in
install)
  docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG" >/dev/null || { echo "pull failed"; exit 1; }
  docker save --platform linux/amd64 "$IMG" | docker exec -i k3s-gvisor ctr -n k8s.io images import --platform linux/amd64 - >/dev/null || exit 1
  $K create ns ingress-nginx >/dev/null 2>&1; render | docker exec -i k3s-gvisor kubectl apply -f - >/dev/null || exit 1
  for _ in $(seq 1 60); do $K -n ingress-nginx get pods --no-headers 2>/dev/null | awk '$2=="1/1" && $3=="Running"' | grep -q . && { echo "[ingress-nginx] ready ($IMG)"; exit 0; }; sleep 5; done
  echo "[ingress-nginx] not ready in time"; $K -n ingress-nginx get pods; exit 1 ;;
uninstall)
  render | docker exec -i k3s-gvisor kubectl delete -f - --ignore-not-found >/dev/null 2>&1
  $K delete ns ingress-nginx --ignore-not-found >/dev/null 2>&1; $K delete ingressclass nginx --ignore-not-found >/dev/null 2>&1
  echo "[ingress-nginx] removed (namespace present? $($K get ns ingress-nginx >/dev/null 2>&1 && echo YES || echo no))" ;;
*) sed -n 2,7p "$0"; exit 2 ;;
esac
