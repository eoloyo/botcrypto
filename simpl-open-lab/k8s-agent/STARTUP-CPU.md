# What the agent's start-up spends its CPU and its time on

Measured on the lab node (k3s on gVisor, 4 cores) with `cpu-profile.sh` / `cpu-report.py`: every
pod's cgroup CPU sampled every 10 s, plus per-thread CPU inside each JVM. Run 5 = fresh install
(official EJBCA 8.2.0.1, lean images, CPU weighting, EJBCA persistent volume); "restart" = all agent
pods deleted with their data kept. Full tables: `cpu-report-run5.md` / `cpu-report-restart5.md` in the
deploy work directory.

## How to read gVisor's numbers

Inside the sandbox, `/proc` CPU times count a thread as running while it waits for a host CPU. On an
idle node they match the cgroup (6.5 s vs 7.4 s for a 7 s busy loop; the 12% difference is gVisor's own
work), but with a load average above 20 during start-up they are about double. The cgroup figures
are the reliable ones under load; the per-thread split below was taken with one JVM starting on a
quiet node.

## Fresh install: 2714 CPU-s in 879 s (the node was busy 73% of the time)

| Where | CPU-s | Share |
|---|---|---|
| EJBCA (set-up container + server) | 1074 | 40% |
| k3s, containerd, runsc shims (outside pods) | 477 | 18% |
| users-roles (4 restarts) | 259 | 10% |
| Keycloak | 173 | 6% |
| the other 7 Java services, each | 22–115 | 1–4% |
| Postgres / Kafka | 90 / 60 | 3% / 2% |
| front-ends, edge, Redis, jobs | ~30 | 1% |

| Window (s) | Node busy | What was running |
|---|---|---|
| 0–480 | 75–106% | every JVM booting at once; EJBCA gets ~170–220 CPU-s per 2 min |
| 480–780 | 58–70% | EJBCA alone: CA set-up CLI calls, then its second boot; identity-provider |
| 780–879 | 42% | the init Job's calls, tier2 waiting on its init container, then booting |

**The second half of a fresh install is not short of CPU.** From ~8 minutes the node is
30–60% idle. That is EJBCA's set-up running its ~37 `ejbca.sh` calls **one after another, each a
single-threaded JVM**, then a chain of waits (identity-provider for the secret, the Job for EJBCA,
tier2 for the credential). More cores would not shorten it; doing less serial work would.

## Restart: 1526 CPU-s in 443 s

After the EJBCA fixes (bootstrap marker + persistent TLS keystore), EJBCA restarts in 298 s instead of
437 s within the full restart, and in **121 s instead of 259 s** on its own. What is left:

| Where | CPU-s | Why it is there |
|---|---|---|
| EJBCA | 291 | one WildFly boot, plus `start.sh`'s post-boot CLI calls (truststore etc.) |
| users-roles | 186 | **3 crash-restarts**: its start-up migration reads roles from Keycloak, which isn't up yet |
| Keycloak | 180 | **rebuilds itself on every start** ("Changes detected in configuration. Updating the server image": Quarkus re-augmentation in a separate JVM, ~55 CPU-s), because the chart adds its SPI jars at runtime |
| authentication-provider | 178 | 2 crash-restarts: Postgres connections refused while ~20 sandboxes come up at once |
| k3s, containerd, runsc shims | 193 | 13% of all CPU, outside any pod |

From 360 s to the end the node is only 36% busy: tier2-gateway's init container polls
authentication-provider, then the chart's probe delays run out.

## Inside one JVM start (authentication-provider alone on a quiet node: ~100 CPU-s)

| Part | Share |
|---|---|
| JIT compiler threads (C1/C2) | 35% |
| main thread: class loading, Spring context, Hibernate, Liquibase | 34% |
| short-lived start-up threads (exited by the time of the capture) | 27% |
| GC and JVM housekeeping | 3% |

Keycloak (alone): 36% JIT, 45% application. EJBCA's server (alone): 35% JIT, 27% application, 9% GC.
**About a third of every JVM start is the JIT compiling the same code it compiled last time.**

## Time that is not CPU at all

- **Probe delays.** Spring reports authentication-provider "Started in 35 s"; the pod is Ready at
  126 s. The charts' readiness/liveness probes have `initialDelaySeconds: 120` (tier2-gateway 60).
  With the startup probes the lab adds, those delays only add waiting.
- **CrashLoopBackOff.** Each crash-restart above costs a full JVM boot *and* a growing back-off wait.
- **Serial chains.** EJBCA set-up → identity-provider → init Job → tier2, each step polling the last.

## What would cut it, by size of effect

| Change | Saves | Fidelity |
|---|---|---|
| Readiness/liveness `initialDelaySeconds: 0` when a startup probe guards the start | up to ~85 s per Java service on every start | chart values |
| users-roles waits for Keycloak (init container) instead of crashing | 3–4 JVM boots + back-off per start | chart change |
| Keycloak image built once with the SPIs (`kc.sh build`), started `--optimized` | ~55 CPU-s and ~15 s per start | Keycloak's documented production set-up; image change |
| Class-data sharing (AppCDS) archives for the Spring services | a large part of the class-loading third, plus some JIT | image change, same code |
| `ejbca-preconfig` as one CLI session / REST calls instead of ~37 JVMs | most of EJBCA's serial set-up on a fresh install | Simpl set-up change |
| Charts log at INFO instead of DEBUG (Keycloak `--log-level=DEBUG --verbose`, `LOGGING_LEVEL_EU_EUROPA_EC_SIMPL=DEBUG`) | CPU and I/O on every request, not only start-up | chart values |

The lab itself costs ~13–18% of all CPU outside the pods (k3s, containerd, runsc) and ~12% inside
them (gVisor's Sentry); a cluster on a plain container runtime would not pay most of that.
