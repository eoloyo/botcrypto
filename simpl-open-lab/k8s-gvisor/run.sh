#!/usr/bin/env bash
# ============================================================================
# run.sh — reproduce "real Kubernetes pods on gVisor" inside a locked-down,
# cgroup-v1, no-KVM, no-CAP_SYS_RESOURCE sandbox.
#
# It: installs gVisor (runsc), patches out the OOM-score self-protection writes
# that this environment cannot perform, launches k3s inside a privileged Docker
# container using runsc as a RuntimeClass, and schedules a demo nginx pod.
#
# Prereqs: a working Docker daemon, Go (for `go tool objdump`), python3, apt.
# Pinned to k3s v1.30.6 on purpose: newer kubelet hard-rejects cgroup v1.
#
# See README.md for the full story and the security caveat (this disables an
# OOM-killer hardening measure — lab/CI only, never a real node).
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/tmp/k8s-gvisor}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.30.6-k3s1}"
CONTAINER="${CONTAINER:-k3s-gvisor}"
mkdir -p "$WORK"

log() { echo -e "\033[1;34m[k8s-gvisor]\033[0m $*"; }

# --- 0. prerequisites -------------------------------------------------------
command -v docker  >/dev/null || { echo "docker is required"; exit 1; }
docker info >/dev/null 2>&1   || { echo "the Docker daemon is not reachable (start dockerd first)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
if ! command -v go >/dev/null; then
  for d in /usr/local/go/bin /usr/lib/go/bin; do [ -x "$d/go" ] && export PATH="$PATH:$d"; done
fi
command -v go >/dev/null || { echo "Go is required (for 'go tool objdump')"; exit 1; }

# --- 1. install gVisor (runsc + shim + gvisor-bin sidecars) ------------------
if ! command -v runsc >/dev/null; then
  log "installing gVisor via apt (storage.googleapis.com/gvisor/releases)…"
  curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" \
    > /etc/apt/sources.list.d/gvisor.list
  apt-get update -o Dir::Etc::sourcelist="sources.list.d/gvisor.list" -o Dir::Etc::sourceparts="-"
  apt-get install -y runsc
fi
RUNSC_BIN="$(command -v runsc)"
SHIM_BIN="$(command -v containerd-shim-runsc-v1)"
SIDECAR_DIR="$(dirname "$RUNSC_BIN")/gvisor-bin"   # apt installs sidecars next to runsc
[ -d "$SIDECAR_DIR" ] || { echo "gvisor-bin sidecars not found next to runsc"; exit 1; }
log "runsc:   $RUNSC_BIN"
log "shim:    $SHIM_BIN"
log "sidecar: $SIDECAR_DIR"

# --- 2. patch out the OOM-score writes (copies only) -------------------------
cp -f "$RUNSC_BIN" "$WORK/runsc.patched"
cp -f "$SHIM_BIN"  "$WORK/containerd-shim-runsc-v1.patched"
log "patching runsc setOOMScoreAdj …"
python3 "$HERE/patch-gvisor-oom.py" "$WORK/runsc.patched"                    container.setOOMScoreAdj
log "patching shim SetOOMScore …"
python3 "$HERE/patch-gvisor-oom.py" "$WORK/containerd-shim-runsc-v1.patched" sys.SetOOMScore
chmod +x "$WORK/runsc.patched" "$WORK/containerd-shim-runsc-v1.patched"

# --- 3. launch k3s-in-privileged-Docker with runsc as a runtime --------------
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
log "starting k3s ($K3S_IMAGE) with gVisor runtime …"
docker run -d --name "$CONTAINER" --privileged --tmpfs /run --tmpfs /var/run \
  -p 6443:6443 -e K3S_TOKEN=gvisor-lab \
  -v "$HERE/config/registries.yaml:/etc/rancher/k3s/registries.yaml:ro" \
  -v "$HERE/config/config.toml.tmpl:/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl:ro" \
  -v "$HERE/config/runsc.toml:/etc/containerd/runsc.toml:ro" \
  -v "$WORK/runsc.patched:/usr/local/bin/runsc:ro" \
  -v "$SIDECAR_DIR:/usr/local/bin/gvisor-bin:ro" \
  -v "$WORK/containerd-shim-runsc-v1.patched:/usr/local/bin/containerd-shim-runsc-v1:ro" \
  "$K3S_IMAGE" server --disable traefik,servicelb,metrics-server >/dev/null

K() { docker exec "$CONTAINER" kubectl "$@"; }

log "waiting for node Ready …"
for _ in $(seq 1 40); do K get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 3; done
K get nodes
log "waiting for the default ServiceAccount …"
for _ in $(seq 1 30); do K get sa default >/dev/null 2>&1 && break; sleep 2; done

# --- 4. deploy the demo pod via gVisor ---------------------------------------
log "applying RuntimeClass + demo pod …"
docker exec -i "$CONTAINER" kubectl apply -f - < "$HERE/manifests/gvisor-web.yaml"

log "waiting for gvisor-web to reach Running …"
for _ in $(seq 1 40); do
  st="$(K get pod gvisor-web -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$st" = "Running" ] && break
  sleep 3
done
K get pod gvisor-web -o wide

# --- 5. verify it is really gVisor and really serving ------------------------
echo
log "PROOF 1 — synthetic gVisor kernel (host is 6.x, sandbox reports 4.19.0-gvisor):"
K exec gvisor-web -- uname -a
log "PROOF 2 — gVisor boot log:"
K exec gvisor-web -- sh -c 'dmesg 2>/dev/null | head -3 || true'
log "PROOF 3 — nginx serves inside the sandbox:"
K exec gvisor-web -- sh -c 'wget -qO- http://localhost/ | grep -o "<title>.*</title>"'

echo
log "DONE. A real Kubernetes pod is Running on gVisor."
log "Tear down with:  docker rm -f $CONTAINER"
