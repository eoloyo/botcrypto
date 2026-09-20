# Real Kubernetes pods on gVisor, in a locked-down sandbox

This directory reproduces running **real Kubernetes workloads** in an environment
that normally can't run any pod at all:

- **cgroup v1** host (controllers pinned to v1; no unified cgroup v2)
- **no `/dev/kvm`** (no hardware virtualization for a real VM)
- **`CAP_SYS_RESOURCE` stripped from the kernel capability bounding set** — so
  *nothing*, not even a `--privileged` container, can lower an `oom_score_adj`
  to a negative value.

Under those constraints:

| Runtime | Result |
|---|---|
| plain **runc** (default) | ❌ pod sandbox fails: `runc create ... can't get final child's PID from pipe: EOF` (cgroup-v1 nested-runc wall) |
| **gVisor / runsc** | ✅ pods run — after neutralising a few OOM-score self-protection writes this env can't perform |

`./run.sh` installs gVisor, patches it, launches k3s-in-Docker with runsc as a
`RuntimeClass`, and schedules an nginx pod that comes up `Running`, proven to be a
gVisor sandbox (`uname` → `4.19.0-gvisor`, `dmesg` → `Starting gVisor...`).

## Why it works — the chain of walls, and how each is cleared

Every blocker was an **OOM-killer hardening write** that needs `CAP_SYS_RESOURCE`
(to make a process *harder* to kill). gVisor treats these as fatal.

1. **cgroup-v1 nested-runc wall** → use **gVisor** as the runtime (its sandbox
   creation doesn't hit runc's cgroup-v1 nesting bug).
2. **shim writes `oom_score_adj = -999`** — `oomScoreMax` in
   [`pkg/shim/v1/manager.go`](https://github.com/google/gvisor/blob/master/pkg/shim/v1/manager.go),
   `sys.SetOOMScore(...)`, fatal on error → **patched** to `return nil`
   (`patch-gvisor-oom.py … sys.SetOOMScore`).
3. **missing `gvisor_sentry` sidecar** (`--sidecar-usage-policy=STRICT`) → mount
   the apt-installed `gvisor-bin/` dir next to the mounted `runsc` (`run.sh` does
   this automatically).
4. **shim OOM-poller: `loading cgroup for <pid>: cgroup deleted`** → do **not**
   set `ignore-cgroups`; let runsc maintain a real cgroup the shim can load
   (see `config/runsc.toml`).
5. **runsc applies kubelet's hardcoded `PodInfraOOMAdj = -998`** to the sandbox —
   `setOOMScoreAdj` in
   [`runsc/container/container.go`](https://github.com/google/gvisor/blob/master/runsc/container/container.go),
   fatal on error → **patched** to `return nil`
   (`patch-gvisor-oom.py … container.setOOMScoreAdj`).

The two patches rewrite each function's entry to `XOR AX,AX; XOR BX,BX; RET`
(return `nil` error, no write). Offsets are re-derived per binary from the Go
symbol table (`go tool objdump`) + ELF program headers, so the patch survives
gVisor version bumps. Only **copies** are patched; your real `/usr/bin/runsc`
and shim are never touched.

## ⚠️ Security caveat

The patches **disable gVisor's OOM-killer self-protection**. That's fine for a
disposable lab/CI sandbox with no real workloads, but you must **never** do this
on a real node — under memory pressure the kernel could OOM-kill the sandbox
supervisor instead of the workload. This is a reproduction aid, not a deployment
pattern.

## Prerequisites

- A working **Docker daemon** (rootful; the script uses `--privileged`).
- **Go** on `PATH` (only for `go tool objdump` during patching).
- **python3**, and Debian/Ubuntu **apt** (to install gVisor from its apt repo).
- Outbound access to Docker Hub and the gVisor apt repo.

If Docker isn't running in your sandbox but you have the privileges, start it with
`dockerd &` (this environment: root with the needed caps, cgroupfs, overlayfs).

## Usage

```bash
cd simpl-open-lab/k8s-gvisor
./run.sh
```

Expected tail:

```
gvisor-web   1/1   Running   ...   10.42.0.x
PROOF 1 — Linux gvisor-web 4.19.0-gvisor #1 SMP ... x86_64
PROOF 2 — [   0.000000] Starting gVisor...
PROOF 3 — <title>Welcome to nginx!</title>
```

Tear down: `docker rm -f k3s-gvisor`.

## Files

| File | Purpose |
|---|---|
| `run.sh` | end-to-end: install gVisor → patch → launch k3s-in-Docker → deploy → verify |
| `patch-gvisor-oom.py` | symbol-based binary patcher (no-ops the two `setOOMScoreAdj`/`SetOOMScore` funcs) |
| `config/registries.yaml` | k3s registry config (skip proxy-CA TLS verify for Docker Hub pulls) |
| `config/config.toml.tmpl` | k3s containerd template adding the `runsc` runtime (no duplicate tables; top-level `oom_score = 0`) |
| `config/runsc.toml` | runsc flags: `platform = systrap` (no KVM), cgroups left enabled |
| `manifests/gvisor-web.yaml` | `RuntimeClass runsc` + demo nginx pod |

## Known limitations

- **Only `runtimeClassName: runsc` pods schedule.** Plain-runc pods (incl. k3s
  system pods like coredns/local-path) still hit the cgroup-v1 wall and stay
  Pending. That's expected here.
- Pinned to **k3s v1.30.6** — newer kubelet hard-fails on cgroup v1.
- The cluster lives in the ephemeral container; it's gone on sandbox reclaim but
  fully reproducible via `./run.sh`.

## Why this matters for the Simpl lab

The Simpl-Open **infrastructure-provider agent** (Crossplane-based) needs a real
Kubernetes API with schedulable pods. This is the first time this lab has one —
so a future increment can point a local Crossplane/infra experiment at this
cluster (a real cloud target is still needed for actual VM provisioning). See the
top-level `simpl-open-lab/README.md` and the infra-agent notes for context.
