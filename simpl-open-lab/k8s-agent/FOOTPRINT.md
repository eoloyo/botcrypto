# Reducing the authority-iaa footprint, staying close to the official deployment

The lab has 4 CPU cores, ~16 GB RAM and ~40 GB of writable disk. This file tracks where the official
agent spends those resources and which reductions keep it faithful: the same application code,
configuration and topology, packaged or scheduled differently. Each entry says what it costs in fidelity.

## Images

Seven of the eight back-end Dockerfiles are the same four lines:

```dockerfile
FROM eclipse-temurin:21-jdk-alpine          # tier2-proxy: amazoncorretto:24-alpine3.22-jdk
RUN adduser -S -u 1001 1001
COPY target/*.jar app.jar
RUN chown 1001 /app.jar                     # rewrites the jar into a second layer
```

| Change | Expected saving | Fidelity cost |
|---|---|---|
| `COPY --chown=1001 target/*.jar app.jar` instead of `COPY` + `RUN chown` | one jar copy per image (the jar is stored twice today) | none: same files, same owner |
| `-jre-alpine` instead of `-jdk-alpine` (same vendor and Java version) | ~360 MB of base, shared by all services | none for a `java -jar` service; loses `jcmd`/`jstack`/`javac` inside the container |

Both are opt-in in `build-images.sh` (`LEAN=1`), and the images keep their official names so the
charts are unchanged. Measured results go in the table below.

| Image | Official | LEAN |
|---|---|---|
| _to be measured_ | | |

## Scheduling

| Change | Why | Fidelity cost |
|---|---|---|
| CPU requests × 0.5 (`CPU_REQUEST_SCALE`) | the agent requests 6.3 cores; the node has 4 | requests are scheduling reservations only; limits and memory are unchanged |
| startup probes (`STARTUP_GRACE`, 900 s) | Keycloak needs ~410 s here, and the chart's liveness probe kills it after 120 s | the charts' own probes are unchanged; they start once the container is up |

## Ideas not yet tried

- **Class data sharing (AppCDS) for the Spring services.** Shorter JVM start, lower memory, same code.
  Needs a training run per image.
- **One JVM heap ceiling per service** (`-XX:MaxRAMPercentage`) matched to the memory limit, so the
  JVM doesn't size its heap from the node's 16 GB.
- **The front-ends** are nginx serving static files (~220 MB images, ~86 s to Ready); they could share
  a single nginx. That changes the topology, so only as a separate, clearly labelled variant.
