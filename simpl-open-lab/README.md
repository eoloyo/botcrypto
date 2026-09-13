# Simpl-Open local lab

Reproducible scripts + notes for **running Simpl-Open (EU data-space middleware) from source on a single machine — no Kubernetes** — and the findings from investigating its architecture, federation model, and consumption code.

Simpl-Open lives at <https://code.europa.eu/simpl/simpl-open>. It is normally deployed via Helm/ArgoCD on Kubernetes. This lab boots the pieces as plain processes and replaces the two Kubernetes-only dependencies (EJBCA, MinIO) with lightweight, API-compatible substitutes.

---

## TL;DR — what this reproduces

```bash
cd simpl-open-lab/scripts
./01-setup.sh       # install Postgres, moto, Keycloak; build the CA shim + Simpl services
./02-dataspace.sh   # Postgres + S3 + 2 EDC connectors -> real provider→consumer data transfer
./03-ga-iaa.sh      # Keycloak + CA shim + identity-provider -> issue a verified participant X.509 identity
```

Outcomes proven on a stock Linux box (Java 21, Maven 3.9, Go 1.24):

| Result | How it's shown |
|---|---|
| Services compile + unit-test clean | `mvn test` (429 tests green across consumption stack) |
| A **real data transfer** between two EDC connectors | file copied `provider-bucket → consumer-bucket`, transfer state `COMPLETED` |
| The **Governance Authority issues a real X.509 credential** | `identity-provider` calls the CA, `openssl verify` OK, persisted in Postgres |
| **EJBCA replaced** by a ~180-line Go CA | issues certs via the exact EJBCA REST contract Simpl calls |

---

## Architecture in one screen

- **Agents per participant role**: Data Provider, Application Provider, Infrastructure Provider, Consumer, **Governance Authority** (the trust anchor of a data space).
- **Two-tier IAA**: Tier‑1 = human/member identity (EU Login / OIDC / **Keycloak**) with RBAC; Tier‑2 = machine-to-machine org identity via **X.509 + mTLS** (certs from a CA — **EJBCA** in production) with ABAC.
- **Six dimensions**: Integration, Data, Infrastructure, Administration, Governance, Security (see the `foundations/architecture` repo: `capability-map.md`, `functional-architecture.md`, `deployment-view.md`, and the `adr/` folder).
- **Dataspace protocol**: agent-to-agent via **Eclipse EDC** (DSP) — catalogue → contract negotiation → transfer.
- **Federated Catalogue** = the **Gaia-X XFSC** Federation Catalogue (Java pkg `eu.xfsc.fc`): self-description publish + verification + GraphDB + search.
- **Tech**: Kubernetes, PostgreSQL (db-per-service), Kafka, Apache Fuseki, Dagster, OpenTofu, ArgoCD, Vault.

### Federation state (as of the reviewed code)
- **Within one data space**: real — GA-anchored IAA federation, Federated Catalogue + search, DSP/EDC transfers.
- **Between Simpl data spaces (inter-DS)**: *architected but not implemented* — the `integration/federation` subgroup contains only a profile README; "Federation orchestration" (cross-space trust-anchor federation + catalogue sync) is defined in the capability map but has no code. The Federated Catalogue glossary describes cross-space discovery as the intent.
- **External / non-Simpl EDC federation**: explicitly **out of scope** (`interoperability-of-the-edc-connector.md`); only point-to-point interop with matched DSP/policy/identity.

### Consumption findings (R4.x)
- The consumption service is `contract-consumption-adapter-be` (service name `contract-consumption-be`); the transfer path is **consumer BE → validation-be → edc-connector-adapter → EDC connector → (Kafka for async status)**.
- **Hotfix traceability gap**: tag `v1.22.2` (2026-07-03) fixed `SIMPL-29526` (BULK_S3 region list) on a `release-1.22.2` branch **not merged to `main`** and **absent from `main`'s CHANGELOG** — invisible unless you inspect the tag directly.
- To check whether a specific bug is fixed in a given release: `git log --all --grep=SIMPL-XXXXX`, then `git tag --contains <fix>` and compare against the deployed tag (fixed-in-code ≠ fixed-in-your-release).

---

## What runs, and on which ports

| Component | Port(s) | Notes |
|---|---|---|
| PostgreSQL 16 | 5433 | dbs: `postgres` (consumer EDC), `providerdb` (provider EDC), `authority_identityprovider` |
| S3 (moto, ~MinIO) | 9000 | buckets `provider-bucket`, `consumer-bucket` |
| Provider EDC connector | 19191–19194, 19291 | `basic-connector.jar` + `local/provider-config.properties` |
| Consumer EDC connector | 29191–29194, 29291 | `basic-connector.jar` + `local/consumer-config.properties` |
| contract-consumption-be | 8080 | consumer BE (optional; not needed for the raw EDC transfer) |
| validation-be | 8083 | SHACL/JSON-schema validation |
| edc-connector-adapter | 8084 | Spring↔EDC adapter (needs Kafka for async status; boots without it) |
| Keycloak 26 | 8180 | OIDC identity core (dev mode, embedded H2) |
| **EJBCA-shim (CA)** | 30080 (HTTP), 30443 (HTTPS) | Go, stdlib only — see below |
| identity-provider | 8103 | Governance Authority credential issuance |

---

## The EJBCA replacement (`ejbca-shim/`)

EJBCA (the production X.509 CA) ships only as a Docker/Kubernetes container, so it can't run in a plain sandbox. Instead of building it, we implemented **only the REST surface Simpl's `identity-provider` actually calls** (from `EjbcaExchangeV1`):

- `POST /ejbca/ejbca-rest-api/v1/certificate/pkcs10enroll` — CSR → signed cert + chain (base64-DER, snake_case JSON: `certificate`, `serial_number`, `response_format`, `certificate_chain`)
- `GET /ejbca/ejbca-rest-api/v1/ca/{dn}/certificate/download`
- revoke / revocationstatus (stubbed)

It's a ~180-line Go program (`ejbca-shim/main.go`, stdlib only) that generates a local `OnBoardingCA` and signs CSRs. `identity-provider` uses it transparently by pointing `ejbca.url` at it. Not implemented: the v2 auto-renewal API (disabled at boot via `--simpl.automatic-renewal.default-initialization.use-api=false`), OCSP/CRL.

---

## Honest limitations

- **Substitutes**: EJBCA → the Go shim; MinIO → `moto` (mock S3, real GET/PUT). Both faithful to the APIs Simpl uses, but not the production software.
- **Identity mock**: the EDC connectors use Simpl's *own* built-in dev identity mock (`mocked.agent.identity.attributes`) for the transfer — the full Tier‑2 mTLS trust between agents is not exercised there.
- **Auth**: the GA enrollment uses `identity-provider`'s unauthenticated applicant path; the *authenticated* Tier‑1 endpoints also work here — see below.

## Authenticated Tier-1 flow (WORKING — `05-tier1-auth.sh`)

Verified: an authenticated Tier‑1 call to `identity-provider` returns **HTTP 200** with real data (a participant's credentials page). Traced through `simpl-spring-boot-starter` + `simpl-util` bytecode:

- `AuthServiceImpl.getTierOneAuth()` reads the `Authorization: Bearer` token via `TierOneAuthInfoJwtPersister`, whose `loadFromString` **only parses the claims** (`SignedJWT.parse` → `loadFromSignedJWT`) — it does **not** verify the RS256 signature. The **tier1-gateway is the trusted OIDC validator** upstream; the backend just reads the forwarded claims. (`TierOneAuthInfoRSAVerifier` exists but is not on this read path.)
- So a token with the correct **claim shape** is accepted regardless of signature. Required claims: `sub`, `idp` (`SIMPL_AUTH`/`EIDAS`), `client-roles` (array of `Roles.*`), `identity_attributes` (array), `credential_id`, `email`, `given_name`, `family_name`, `preferred_username`, `sid`.

`05-tier1-auth.sh` mints such a token and does an authenticated `GET …/credentials` → 200. In production the gateway forwards a real Keycloak token carrying these claims (from Keycloak protocol mappers); this reproduces the shape to exercise the backend directly.

**Gateway layer (`04-gateways.sh`):** `tier1-gateway` **runs** — proxies `/auth/**` → Keycloak (`/auth/realms/master` → 200) and **enforces OIDC on backend routes** (`/identityApplicantApi/**` → 401 without a token). `tier2-gateway` builds.

**Still to wire for the fully end-to-end official path**: (1) Keycloak realms `authority`/`onboarding` with protocol mappers emitting the claims above + issuer aligned to the gateway `/auth`, so a login *through* the gateway yields an accepted token; (2) **Tier‑2 mTLS** — `tier2-gateway`/`tier2-proxy` enforcing mutual TLS with CA-issued X.509 identities.

## Gaia-X Federated Catalogue — Tier-A SD PUBLISHED FULLY LOCALLY (`06-federated-catalogue.sh`)

The GA-hosted rich catalog (`catalogue-be`, Java pkg `eu.xfsc.fc`, the Gaia-X **XFSC** Federation Catalogue) now **publishes a Tier-A conformant Self-Description end-to-end, offline, with no external services** — publish → quality-scoring → store → graph → query:

- **Neo4j 5.26 + neosemantics (n10s) + APOC** (bolt :7687) — the RDF graph store, **auth disabled** for the lab (the autowired Spring driver connects with scheme `none`), n10s graph config initialised.
- **catalogue-be up on :8081** against Neo4j + PostgreSQL (Liquibase-migrated).
- **`POST /self-descriptions` → `201`** with `qualityAssessment.overall.classification = "A"`, score `1.0`, `PASSED`. ✓
- **`GET /self-descriptions` → `totalCount: 1`**, status `active`. ✓
- **`POST /graph-rebuild` → 10 `Resource` nodes** imported into Neo4j (the DataOffering + its 8 blank-node property groups + the named schema). ✓
- **`POST /query` (openCypher)** returns the offering `did:web:registry.gaia-x.eu:DataOffering:…` and its properties (`offeringType: "data"`, name, price, etc.). ✓

### The real blocker was a hard-coded link (not JSON-LD/DNS)

The publish path makes a **mandatory synchronous** call to the quality-scoring service at a **hard-coded Kubernetes hostname**:

```
QUALITY_SCORING_URL default = https://quality-scoring-service.authority01.svc.cluster.local:8080
```

Off-cluster that is `NXDOMAIN` → HTTP 500, and the SD is aborted **before** it is stored. The fix is a tiny local stub (`catalogue/qs-stub.py`) returning a valid **MQR** quality report (`sh:ValidationReport` → `mqr:hasProfileScore` with `weightedScore ≥ thresholdValue`, `classificationLabel "A"`, statuses `PASSED`), pointed at via `--quality-scoring.url=http://localhost:8085`. (JSON-LD `@context` / trust-registry dereferencing is handled separately by booting with `--…doc-loader.enable-http=false --…enable-local-cache=true`.)

The script drives every stage:
1. **Named-schema resolution.** The SD's `credentialSubject.dct:conformsTo → dct:schemaName "DataSchema"` must resolve via `schemasDao.selectByName(...)` from the `schemas` table (normally a **schema-manager** artifact). Registered directly: `INSERT INTO schemas(name='DataSchema', resource_type='data', status='PUBLISHED', schema_body=<test-schema.ttl>, …)`. ✓
2. **SHACL validation** runs for real against the loaded `simpl#` ontology + `test-schema.ttl` shape (the pairing the catalogue's own `SelfDescriptionControllerTest` uses). ✓
3. **Quality scoring** → local stub → Tier **A**. ✓
4. **Store** (PostgreSQL) + **graph import** (Neo4j via n10s). ✓

### Two source tweaks captured in `catalogue/patches/catalogue-local.patch`

In this fork `graphStore.addClaims()` is reachable **only** through `GraphRebuilder` (publish itself writes just to PostgreSQL; graph population is a separate operator/NATS step). Its endpoint ships annotated `@Component` — never registered as an MVC handler — and its worker pool interrupts the n10s import after a 100 ms grace. The patch (against `catalogue-be @ 0e8f7a9`) makes the endpoint a real `@RestController("/graph-rebuild")` and lengthens the grace to 5 s, so a one-shot rebuild reliably populates the graph. Everything else is stock configuration.

> Note: **publish → search → consume is already demonstrated end-to-end at the Eclipse EDC / Dataspace-Protocol level** (`02-dataspace.sh`: provider publishes an asset+contract-definition, consumer queries the catalog and negotiates, a file is transferred). The Federated Catalogue above is the *richer Gaia-X SD catalog* layered on top.

## How this differs from the official Simpl-Open deployment

Official Simpl-Open runs on **Kubernetes via Helm/ArgoCD**, one agent per namespace. This lab runs the **same service jars** as plain processes on one host. What's identical vs substituted:

| Aspect | Official | This lab |
|---|---|---|
| Orchestration | Kubernetes (Helm/ArgoCD), per-agent namespaces | plain JVM processes on one host |
| Service code | the Simpl jars | **same jars, built from source** ✅ |
| Data-space connector | Eclipse EDC (Simpl fork) | **same** ✅ |
| Contract negotiation + transfer (DSP) | real | **same, real** ✅ |
| Databases | PostgreSQL, one per service | **real Postgres**, shared instance, multiple DBs |
| Object storage | MinIO / S3 | **moto** (mock S3, real GET/PUT) |
| X.509 CA | **EJBCA** (container) | **~180-line Go shim** (same `pkcs10enroll` REST contract) |
| OIDC identity | Keycloak (behind gateway, EU Login/eID upstream) | **Keycloak 26** dev-mode (embedded H2) |
| Tier-1 / Tier-2 gateways | enforce OIDC + mTLS | tier1 **runs + enforces auth**; tier2 built (mTLS not wired) |
| Inter-agent trust | Tier-2 mTLS with CA-issued certs | connectors use Simpl's **built-in dev identity mock** |
| Async messaging | Kafka | not run (adapter boots without it) |
| Secrets | HashiCorp Vault | not used (dev config) |
| Federated Catalogue (Gaia-X XFSC) | deployed, quality-scoring + schema-manager as services | **runs; publishes a Tier-A SD end-to-end** with a local quality-scoring stub + directly-registered named schema |

**Bottom line:** the *application and data-space layers are the real thing* (real jars, real EDC/DSP, real Postgres, real transfer, real X.509 issuance). The *platform/trust hardening* — EJBCA PKI, full mTLS between agents, Vault, Kafka, and the Helm-orchestrated multi-namespace topology — is substituted or simplified. Functionally equivalent for exercising and debugging the code; not a production-grade secure deployment.

## Resource footprint (this whole lab, at rest)

~3 GB RAM total, near-zero CPU when idle (event-driven services). Per component (RSS): identity-provider ~540 MB, Keycloak ~530 MB, edc-connector-adapter ~380 MB, validation-be ~370 MB, contract-consumption-be ~320 MB, each EDC connector ~270–300 MB, Postgres ~400 MB (all backends), moto ~75 MB, the Go CA shim **~10 MB**. Fits comfortably on a 4-core / 8 GB box; add the gateways (~2× ~350 MB) for the full IAA edge.
- **Not wired into one mesh**: tier1/tier2 gateways, tier2-proxy, onboarding UI, and the authority's own connector+catalogue all *compile* but aren't composed here.
- **Kafka** is not started; `edc-connector-adapter` boots without it (async transfer-status polling is inert).

## Prerequisites

- Linux, Java 21, Maven 3.9+, Go 1.24+, Python 3, `openssl`, and `apt-get` (to install PostgreSQL 16) or a pre-installed Postgres 16.
- Outbound HTTPS to `code.europa.eu` (git + Maven package registry), Maven Central, GitHub releases (Keycloak), and PyPI (moto).
- Simpl POMs require two env vars at build time (set by the scripts): `CI_API_V4_URL=https://code.europa.eu/api/v4` and `PROJECT_RELEASE_VERSION=<any>`.

## Layout

```
simpl-open-lab/
├── README.md            # this file
├── ejbca-shim/          # Go EJBCA-compatible CA (main.go, go.mod)
└── scripts/
    ├── env.sh           # shared config (ports, paths, helpers)
    ├── 01-setup.sh      # install infra + build shim + clone/build Simpl services
    ├── 02-dataspace.sh  # Postgres + S3 + 2 EDC connectors + run/verify a transfer
    ├── 03-ga-iaa.sh     # Keycloak + CA shim + identity-provider + issue/verify a credential
    └── 99-stop.sh       # stop everything started by the lab
```

Work (clones, jars, runtime logs/pids, Postgres data) lives under `$LAB_ROOT` (default `~/simpl-open-lab-work`), not in this repo.
