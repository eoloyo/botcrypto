# Wildcard TLS for a Simpl agent — prototype and end-to-end tests

Question: *what would it take to let a Simpl agent use one shared (wildcard) certificate instead of one certificate per
hostname, and how can we be sure it works?* This directory is the change, plus tests at five levels, run on the lab
cluster (`../../k8s-gvisor`). Level 4 (a real DNS provider and Let's Encrypt) cannot be done in this sandbox: see the end.

```bash
./run_all.sh     # everything below from a clean slate (~30 min), then tears down and checks the lab is as it was found
```

## The change

| File | What |
|---|---|
| `wildcard-tls.patch` | six component charts' ingress templates (`tier1-gateway` + five frontends): new value `ingress.existingTlsSecret`, default empty = today's behaviour; when set, the cert-manager annotations are dropped and the shared Secret is used |
| `umbrella-plumbing.patch` | the switch carried down the real chain: `consumer-agent-chart` (umbrella) -> `consumer-iaa` (bundle) -> component charts. Pinned to the commits of 2026-11-06. Only the IAA bundle is done |
| `agent-tls/` | a small chart: one `Certificate` with the wildcard names from `domainSuffix` + `namespaceTag` (and optional `duration`/`renewBefore`) |

A wildcard matches **one** DNS label, so a consumer needs three entries: `*.<ns>.<domain>`, `*.fe.<ns>.<domain>`,
`*.be.<ns>.<domain>` (a provider also `*.crossplane.<ns>.<domain>`). The Tier-2 host `tls.participant.<ns>…` is two labels
deep and keeps its Governance-Authority-issued identity certificate: it is not covered, by design.

## What was tested, level by level

| Level | Script | What it proves | Result |
|---|---|---|---|
| 1a | `render_check.sh` | default render is **byte-identical** to the original; an old values file (no new key) renders identically; wildcard mode drops the annotations and uses the shared secret. Six charts x six checks | 36 / 36; the same check fails (12) on unpatched charts |
| 1b | `plumbing.py check` | on the **real** umbrella + IAA bundle: default output byte-identical; wildcard reaches 6 bundles, the bundle's own Ingress, 4 of 4 component apps (consumer) / 5 of 5 (data provider); the bundle's rendered values drive the real patched component charts | 14 / 14; an empty patch fails 7 checks |
| 1c | `cluster_test.sh` | on cert-manager v1.19.1: 11 hosts -> **11 certificates** today, **1** with the wildcard; all 11 covered and 5 must-not-match hosts not covered (`openssl -checkhost`); the six real charts: 2 certificates today, 1 with wildcard | all pass |
| 1d | `cluster_test.sh migrate` | migrating a live per-host deployment in place leaves the 11 old per-host Certificates behind (still Ingress-owned): an explicit cleanup is needed; after it they are not recreated | confirmed |
| 2 | `serve_test.sh` | with a real **ingress-nginx 1.13.7**, a TLS handshake per hostname: per-host mode serves each host its own certificate; wildcard mode serves all 11 the **one** certificate (matches the Secret, chains to the CA, matches the hostname); uncovered hosts are not served it; a control proves the test can see a wrong (fake) certificate | all pass; converges in 1–4 s |
| 2 | `serve_test.sh` (renewal) | duration 1h / renewBefore 58m: cert-manager renews after **120 s** (revision 1 -> 2) and nginx serves the new certificate at once, **without a restart**, to all 11 hosts | pass |
| 2 | `serve_test.sh` (rollback) | switching the same Ingresses back to per-host mode: 11/11 hosts served their own certificate again | pass |
| 3 | `acme_test.sh` | a real **ACME wildcard order over DNS-01** (Pebble ACME server + BIND with TSIG dynamic updates, cert-manager's rfc2136 solver): order `valid`, 3 wildcard authorizations each via `dns-01`, issued by Pebble in ~70 s, then served for all 11 hosts through ingress-nginx and verified | pass |
| 3 | `acme_test.sh` (T2) | the guide's **default HTTP-01 issuer** asked for the same wildcard: never issued; the Order stays `pending` forever and the only signal is a Warning event *"no configured challenge solvers can be used for this challenge"* | confirmed |
| 2/5 | `browser_test.sh` | **real Chromium**, lab CA in its trust store (normal chain + hostname verification): all 11 covered hosts load a real page over HTTPS; uncovered hosts are refused | pass |

(Results are those of the last `./run_all.sh`; see `RESULTS.md` for the log excerpt.)

## What the tests found along the way

**In the product / operations**
- **Migration needs a cleanup step.** Removing the annotation does not remove the per-host Certificates cert-manager already made.
- **An HTTP-01-only issuer plus a wildcard fails silently**: no `failed` state, just a pending Order and one Warning event.
- **ingress-nginx protects an uncovered host**: it refuses to serve a wildcard that does not cover the host, falls back to its
  *fake* certificate and logs `SSL certificate "…" does not contain a Common Name or Subject Alternative Name for server "…"`.
  Users see a generic untrusted-certificate error; the cause is only in the controller log.
- **Renewal is hot**: nginx swaps in the renewed certificate within seconds, no restart.
- **The charts are not uniform**: the IAA bundle has its own inline Ingress with a hard-coded per-host secret (a seventh
  template type); `consent-management-fe` is only rendered for `type=data-provider`; the users-roles app passes the issuer under
  `global.ingress.issuer` (a different key, and I could not find what consumes it in the local chart).
- **cert-manager acts on any Ingress with its annotation**, including the lab's `authority01` ones (their issuer is the unresolved
  `${CLUSTERISSUER}`), and is not usable just because its pods are Ready: the webhook rejects everything until cainjector has
  injected its CA. Pods need `runtimeClassName: runsc` in this cluster.

**In my own tests (all fixed; recorded because they would have produced false confidence)**
1. The first render check was vacuous: `Chart.yaml` has the CI placeholder `${PROJECT_RELEASE_VERSION}`, helm rejected every render and "identical output" compared two identical errors.
2. The first serving test accepted *any* non-fake certificate, so after a reset nginx's cached old certificates looked like failures, and a "renewal" that cert-manager never did (revision unchanged) looked like a pass. The Kubernetes Secret is now the ground truth and renewal is proved by the revision.
3. Chromium inside this sandbox sent traffic through the egress proxy (`--no-proxy-server` is ignored by Playwright; its `proxy.bypass` works). The test now requires the lab CA as issuer.
4. `echo "$LOGS" | grep -q` under `pipefail` fails on large logs (SIGPIPE). Here-strings are used instead.

Every check was also shown to be able to fail (sensitivity runs against unpatched charts / an empty patch / a control Ingress).

## Not covered — read before relying on this

- **Level 4: no real DNS provider and no Let's Encrypt.** Level 3 proves cert-manager's ACME/DNS-01 wildcard handling against Pebble and BIND; it says
  nothing about the OVH solver in Simpl's guide, real propagation delays, API rate limits or Let's Encrypt's certificate limits. That needs a
  throwaway domain plus DNS API credentials (Let's Encrypt **staging** is enough).
- **Level 5: no ArgoCD install of the official charts.** The chain umbrella -> IAA bundle -> component charts is proved by `helm template`
  on the real charts, not by a deployment. Not done: the other five consumer bundles and the provider umbrella (same edit, not applied);
  the authority chart's inline Ingress; third-party charts (Keycloak, Gitea, Kibana, the Kafka/other UIs); who consumes
  `global.ingress.issuer`; the `agent-tls` chart as an ArgoCD Application (the umbrella needs somewhere to host it) and Certificate-before-Ingress
  sync-wave ordering.
- **No login flow through the wildcard.** Hostnames do not change, so CORS and Keycloak redirect settings should not either, but a Keycloak/OIDC login through the wildcard was not run. The browser test loads a placeholder nginx page, not a Simpl UI.
- **Issuers are a lab CA and Pebble.** Simpl's guide says a private CA is unsupported for the platform; the lab CA is only a test device. The ACME test trusts Pebble's CA as a partial chain.
- **Secrets are per-namespace.** Two namespaces were exercised; a real agent spans several, each needing its own Certificate (or a secret replicator).
- The 11 consumer hostnames are read from the charts; three billing names are placeholders for chart overrides.
- Tier-2 identity certificates are not involved and were not touched.
