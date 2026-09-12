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
- **Auth**: the GA enrollment uses `identity-provider`'s unauthenticated applicant path (`NotAuthenticated`), which already drives the full CSR→CA→credential loop. The *authenticated* Tier‑1 endpoints (e.g. reading a credential) are **RSA-signature-verified** — see "Authenticated Tier‑1 flow" below.

## Authenticated Tier-1 flow (the next increment)

The Tier‑1 auth is handled by `AuthServiceImpl` in `simpl-spring-boot-starter` (pkg `eu.europa.ec.simpl.common.security`). It reads the `Authorization: Bearer` token and verifies it with `TierOneAuthInfoRSAVerifier` — i.e. it **checks the RSA signature**, not just the claims. A hand-crafted token is rejected with `401 "Invalid JWT token"` (verified).

In the real topology the token is produced by the **tier1-gateway**: it validates the external **Keycloak** OIDC token, then issues an internal Tier‑1 token signed with a key the backends trust. So to exercise the authenticated endpoints locally you need either:
1. run `tier1-gateway` with a signing keypair and configure `identity-provider`'s verifier to trust its public key, and a Keycloak realm/user the gateway accepts; or
2. locate/override the verifier's trusted public key to one you control and sign tokens with the matching private key.

**Gateway layer (`04-gateways.sh`):** `tier1-gateway` (Spring Cloud Gateway) **builds and runs** here — it proxies `/auth/**` → Keycloak (verified: `/auth/realms/master` → 200) and **enforces OIDC auth on the backend routes** (`/identityApplicantApi/**` → 401 without a token, as designed). `tier2-gateway` builds. What remains for a *fully authenticated* call: Keycloak realms `authority`+`onboarding` with a client/user/roles, the Keycloak issuer aligned to the gateway's `/auth` path, and the backend verifier trusting the token's RS256 key (Tier‑2 additionally needs CA-issued X.509 client certs for mTLS). Everything below the auth layer — enrollment, the CA, persistence — is proven via the applicant path.

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
| Federated Catalogue (Gaia-X XFSC) | deployed | code present/built; not run in the transfer path |

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
