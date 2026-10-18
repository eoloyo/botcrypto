# Reducing the authority-iaa footprint, staying close to the official deployment

The lab has 4 CPU cores, ~16 GB RAM and ~40 GB of writable disk. This file tracks where the official
agent spends those resources and which reductions keep it faithful: the same application code,
configuration and topology, packaged or scheduled differently. Each entry says what it costs in fidelity.

## What the official agent uses (run 2, 2026-10-18)

Fresh deploy of all 17 components plus the lab edge, then the chart's own authority initialization.
Every pod was Ready **1062 s** after apply. Working set is per pod from containerd (`usage.sh`), taken
after start-up had settled.

| Pod | Ready (s) | Restarts | Working set (MiB) | Memory request (MiB) | CPU-s to settle |
|---|---|---|---|---|---|
| 5 front-ends (each) | 70 | 0 | 11 | 512 | 4 |
| lab-edge | 70 | 0 | 21 | 32 | 4 |
| redis | 81 | 0 | 13 | – | 9 |
| tier1-gateway | 149 | 0 | 422 | 1024 | 68 |
| security-attributes-provider | 234 | 1 | 529 | 1024 | 127 |
| authentication-provider | 258 | 0 | 601 | 1024 | 114 |
| onboarding | 285 | 0 | 543 | 1024 | 100 |
| keycloak | 384 | 1 | 783 | 1000 | 285 |
| users-roles | 515 | 4 | 557 | 1024 | 281 |
| identity-provider | 873 | 0 | 524 | 1024 | 73 |
| ejbca | 907 | 0 | 714 | 1024 | 1422 |
| tier2-proxy | 1023 | 0 | 311 | 1024 | 27 |
| tier2-gateway | 1062 | 0 | 549 | 1024 | 71 |
| _common: Kafka / Postgres_ | | | 503 / 227 | 1024 / – | 113 / 122 |

With the `LEAN=1` images (run 3) each Java service used 5–13% less (e.g. identity-provider 524 → 489,
tier2-gateway 549 → 480 MiB); the agent plus common components 6386 → 6053 MiB.
| **Total (agent + common)** | | | **6386** | **13932** | |

- Requests total 13.9 GB of memory for 6.4 GB used. The front-ends request 512 MiB each and use 11.
- Most of the 1062 s is the dependency chain, not CPU: EJBCA (~15 min, 1400 CPU-s, mostly its own
  first-time CA setup) → identity-provider (needs EJBCA's client certificate) → the init Job → tier2.
- The restarts are start-order effects the charts don't express: users-roles' migration needs
  Keycloak; Keycloak timed out on its first schema migration while every JVM was starting.

## Start-up time

| Run | What changed | All Ready |
|---|---|---|
| 2 | official images, CPU requests × 0.5 | 1062 s (17.7 min) |
| 3 | `LEAN=1` images; EJBCA weighted for CPU; fast EJBCA CLI JVMs | **912 s (15.2 min)** |
| warm restart | all agent pods deleted, Postgres/Kafka and their data kept | **437 s (7.3 min)**; every service up by ~370 s, EJBCA last |

The warm-restart figure is measured from the start of the delete (controllers recreate pods while
the rest are still terminating); `restart.sh` now takes its t0 there too.

**The critical path of a first install is EJBCA**, then everything that needs its certificates:

| EJBCA phase | Run 2 | Run 3 |
|---|---|---|
| WildFly boot inside the set-up container | 4.0 min | 2.9 min |
| EJBCA creates its ManagementCA (RSA 3072) and super admin | 3.3 min | 2.75 min |
| CA configuration: ~37 `ejbca.sh` CLI calls, each a new JVM | 4.4 min | 3.4 min |
| second WildFly boot in the main container | 3.0 min | 2.8 min |
| **EJBCA total** | **15 min** | **11.8 min** |

After that (run 3): identity-provider waited 81 s for the kubelet to retry the secret EJBCA had just
written (now nudged by `deploy.sh`), booted in 126 s; the init Job's eight calls took ~60 s; tier2
started 25–83 s after the credential existed.

What helped, and what it costs:

- **CPU weighted to the critical path.** Under contention CPU is shared by `cpu.shares`, i.e. by request.
  EJBCA's request goes to its chart limit (500m), the rest are scaled by 0.3, so EJBCA gets ~3x the share of
  each other service. Only scheduling changes.
- **Faster CLI JVMs in EJBCA's set-up container** via EJBCA's own `JAVA_OPTS_EJB_CLI`: its defaults plus
  C1-only JIT, 12.2 s → 8.5 s per call. The set-up container is throwaway; the server keeps its settings.
- **Not done:** C1-only for the set-up container's *server* boot. The same server generates the
  RSA keys, which C1 would slow down; class-data sharing is already on by default.
- **Not changed:** EJBCA's two boots and its 3072-bit ManagementCA are how the official image and
  `ejbca-preconfig` work; shortening them means changing either.

**CPU limits are not enforced in this lab** (`cpu.cfs_quota_us` is -1: runsc keeps the sandbox in the
pod cgroup, where only `cpu.shares` applies). On a cluster that enforces them, the chart's 500m limit
on EJBCA caps its first-install bootstrap, which used ~1400 CPU-seconds here; that is likely a
start-up bottleneck in the official deployment too (gVisor inflates CPU time, so the real figure is lower).

## Images

Seven of the eight back-end Dockerfiles are the same four lines:

```dockerfile
FROM eclipse-temurin:21-jdk-alpine          # tier2-proxy: amazoncorretto:24-alpine3.22-jdk
RUN adduser -S -u 1001 1001
COPY target/*.jar app.jar
RUN chown 1001 /app.jar                     # rewrites the jar into a second layer
```

Measured on tier1-gateway 2.14.4 (85 MiB jar):

| Variant | Image size | Fidelity cost |
|---|---|---|
| official | 848 MiB | – |
| `COPY --chown=1001` instead of `COPY` + `RUN chown` | 687 MiB | none: same files, same owner |
| + `eclipse-temurin:21-jre-alpine` (`LEAN=1`) | **433 MiB (−49%)** | no `javac`/`jcmd`/`jstack` in the container |

The lean tier1-gateway was swapped into the running agent: Ready in 126 s, `/actuator/health` and the
`/auth` route to Keycloak both 200 through the edge, working set 361 MiB (official pod: 422 MiB, but
it had served the initialization traffic, so the difference is indicative only). It was rolled back
afterwards; the official images stay the default.

All eight back-ends with `LEAN=1`: authentication-provider 1069 → 544, identity-provider 940 → 479,
onboarding 1064 → 541, security-attributes-provider 973 → 496, tier1-gateway 848 → 433,
tier2-gateway 943 → 481, tier2-proxy 723 → 620 (`--chown` only) MiB.

`build-images.sh` does this with `LEAN=1` and keeps the official image names, so the charts are
unchanged. Corretto publishes no JRE image, so tier2-proxy only gets the `--chown` fix.

## Scheduling

| Change | Why | Fidelity cost |
|---|---|---|
| CPU requests × 0.5 (`CPU_REQUEST_SCALE`) | the agent requests 6.3 cores; the node has 4 | requests are scheduling reservations only; limits and memory are unchanged |
| startup probes (`STARTUP_GRACE`, 900 s) | Keycloak needs ~400 s here, and the chart's liveness probe kills it after 120 s | the charts' own probes are unchanged; they start once the container is up |

## Measuring under gVisor

`crictl stats` gives the real working set but times out while the node is saturated (`usage.sh`
retries it). The RSS of a pod's runsc processes is not a substitute: gVisor keeps application
memory in a shared memory file, and that RSS misses most of it (3.1 GB against 6.4 GB here).

## Ideas not yet tried

- **Memory requests that match use.** The front-ends (11 MiB used, 512 MiB requested) and the Spring
  services (~550 MiB used, 1 GiB requested) leave ~7.5 GB reserved and idle. Changing requests
  changes scheduling, not behaviour.
- **Class data sharing (AppCDS)** for the Spring services: shorter JVM start, lower memory, same code.
  Needs a training run per image.
- **A JVM heap ceiling per service** (`-XX:MaxRAMPercentage`) matched to the memory limit.
- **The front-ends** are nginx serving static files; they could share a single nginx. That changes
  the topology, so only as a separate, clearly labelled variant.
