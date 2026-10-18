# Are the official Simpl-Open sizing figures reasonable?

The official installation guide (`simpl/simpl-open/cross-cutting/documentation/installation-guide`,
`Prerequisites.md`) asks for 2 worker nodes of 4 CPU / 16 GB just to *experiment* with one agent plus
common components, and 3 × 8 CPU / 32 GB (common) + 1–3 × 4 CPU / 16 GB (authority) for a
production-like set-up. This directory checks where those figures come from and how they compare with
what the components actually use.

## 1. What the official charts declare

`render_apps.py` renders an ArgoCD app-of-apps the way ArgoCD does (multi-source Applications,
`$values` value files from the agent's git repo, nested apps, Bitnami's move to OCI) and sums the
requests/limits of every workload. Operator custom resources (ECK Elasticsearch/Kibana/Logstash/Beats,
Confluent Kafka/KRaftController, Zalando `postgresql`) were read from the rendered CRs.

| (rendered 2026-10-18) | requests | limits | disk |
|---|---|---|---|
| Common components, `resourcePreset: default` | ~10 CPU / 12.7 GiB | ~32 CPU / 71 GiB | ~300 GB |
| Governance authority, `default` (27 containers) | 10.1 CPU / 27.7 GiB | 13.4 CPU / 30.7 GiB | |
| Governance authority, `low` | 1.8 CPU / **12.1 GiB** — memory is not zeroed | | |

Notable settings: every Simpl Java backend 1 GiB (request = limit) and 0.4–1 CPU; each of the five
front-ends (nginx serving static files) **512 MiB / 0.4 CPU**; schema/vocabulary managers 2 GiB per
pod; Kafka brokers and controllers 4 GiB limit with **`-Xmx4g`** (heap = whole container limit: an
OOM-kill risk); Elasticsearch 3 nodes requesting 1 GiB but limited to 4 GiB; probes with a fixed
`initialDelaySeconds: 120` and no startupProbe; no NetworkPolicy for the Simpl services.

## 2. What the components actually use

Plain Docker (runc enforces `--cpus/--memory`), the official CPU/memory limits, the official
`application.yml` rendered from the agent chart. Memory = cgroup working set after start-up.

| identity-provider (1 GiB limit) | ready at 1 CPU | ready at 0.4 CPU | CPU-s to start | memory |
|---|---|---|---|---|
| upstream image (official Dockerfile: JDK, `java -jar`) | 33 s | **88 s** | 33–36 | 333 MB |
| `images/jvm-tuned` (JRE, extracted jar, CDS, C1, SerialGC) | 8.5 s | 21 s | 8.2 | 251 MB |
| `images/native` (GraalVM, `../scripts/15-native-build.sh`) | **1.4 s** | **2.9 s** | 1.1 | 140 MB |

(unlimited CPU, upstream: 15 s using ~2.5 cores. The upstream image also starts three nested Spring
applications from its Liquibase migrations, see `../iaa/patches/identity-provider-liquibase-no-nested-app.patch`.)

| component | declared | measured (official limits, idle) |
|---|---|---|
| front-end (nginx, static files) | 512 MiB / 0.4 CPU each | **4 MB**, ~0 CPU, ready in 1 s |
| Keycloak 26 (`start-dev`) | req 954 MiB, lim 1.9 GiB / 1 CPU | 500 MB, ready in 57 s |
| Elasticsearch 8 node | req **1 GiB**, lim 4 GiB / 1.5 CPU | **2.5 GB** (heap auto-sized to half the limit) |

## 3. Conclusions

- The guide's node sizes follow from what the charts *declare*, not from measured usage.
- **Over-reserved:** the Simpl Java backends reserve ~3× what they use (7× vs native), the front-ends
  ~128×. Across one authority agent that is ~9 GiB of the 27.7 GiB requested.
- **Under-requested:** Elasticsearch requests 1 GiB but needs ~2.5 GB per node, so the scheduler can
  pack it onto a node that cannot hold it. ELK (3 ES nodes, 2 Kibana, Logstash, APM, Beats) and Kafka
  (6 JVMs with 4 GiB heaps) are the real reason common components need large nodes.
- **"Up to 30 minutes" to deploy:** a Simpl backend under its official 0.4 CPU limit needs ~90 s to
  start, then waits for the fixed 120 s probe delay; services start in dependency order (Kafka,
  Keycloak, EJBCA, then the authority chain), and every image is a full JDK (~1 GB unpacked).
  A startupProbe instead of the fixed delay, and the tuned or native images, cut the per-service
  part from ~3.5 min to seconds.

## Lab limits (be careful when reusing the numbers)

- The official images (`code.europa.eu:4567`) cannot be pulled through this sandbox's proxy (non-443
  port); the upstream image here is built from the same source tag with the official Dockerfile.
- `../k8s-gvisor` runs real pods on gVisor, but in this nested set-up **CPU limits are not enforced**
  and gVisor inflates the memory working set (~500 MB vs 333 MB for the same pod), so the comparison
  tables use plain Docker. The full agent was not deployed: it needs ArgoCD, OpenBao, ECK, Confluent
  and Zalando operators and ~25 images, beyond one 4-CPU / 15 GB sandbox.
- Keycloak was measured in `start-dev` mode (it re-augments at start); production `start --optimized`
  starts faster.

## Files

- `render_apps.py` — render an app-of-apps tree and tabulate resources (`--out x.json`).
- `measure.sh`, `mkip.py`, `infra.yaml` — the official identity-provider objects on `../k8s-gvisor`.
- `dmeasure.sh` — identity-provider on plain Docker with the official config; `gmeasure.sh` — any image.
- `images/jvm-tuned`, `images/native` — the improved images.
