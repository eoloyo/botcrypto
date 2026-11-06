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
| 4a | `letsencrypt_probe.sh` | the **real Let's Encrypt staging** server, with a **local BIND** serving the challenge records: cert-manager registers an account, orders the three wildcard names, gets only `dns-01` / `dns-persist-01` challenges (no `http-01`), publishes all 3 TXT records in the local BIND (TSIG-signed, BIND's log confirms) and then **Let's Encrypt rejects it**: *"DNS problem: NXDOMAIN looking up TXT for _acme-challenge.…"* — it queried the public DNS, never our BIND | pass (opt-in: `WITH_LE=1 ./run_all.sh`) |
| 2/5 | `browser_test.sh` | **real Chromium**, lab CA in its trust store (normal chain + hostname verification): all 11 covered hosts load a real page over HTTPS; uncovered hosts are refused | pass |

(Results are those of the last `./run_all.sh`; see `RESULTS.md` for the log excerpt.)

## The whole agent, not just six charts (`fullchain.sh`, no cluster needed)

The first prototype switched six component charts and the IAA bundle. `fullchain.sh` takes it to every umbrella, bundle and component chart that
can request a certificate (inventory and decisions per chart: `INVENTORY.md`). It needs only `helm` and `python3` (+ pyyaml).

| Script | What it proves | Result |
|---|---|---|
| `components_wildcard.py` -> `components-wildcard.patch` | 16 component charts (17 pinned versions) get `existingTlsSecret`; 22 Ingress templates, 36 annotation lines gated | `{charts: 17, templates: 22, annotations_gated: 36, secretnames: 22}` |
| `components_check.py` | each patched chart renders the **same output as the original by default** (random passwords and the chart's own values hash normalised), and with the value set every cert-requesting Ingress uses the shared Secret with no annotation; the same check on the unpatched chart fails | 52 / 52 (a deliberately broken default is caught: 51 / 52) |
| `wildcard_all.py` -> `bundles-wildcard.patch` | the switch carried through 16 umbrella/bundle charts: 16 hand-downs, 18+6+5 `existingTlsSecret`, 24 annotation edits, 22 secretNames, 2 `tls: true` charts, 3 inline Ingresses; any `cluster.issuer` use no rule claims fails the run | 0 unclaimed |
| `bundles_check.py` | all 18 umbrella/bundle charts: default render byte-identical; in wildcard mode every Application source that mentions an issuer is a patched leaf with the Secret set, a bundle that receives `tls.mode: wildcard`, hard-disabled, or a known unused key | 48 / 48 |
| `leaves_check.py` | **render level**: every leaf chart rendered with the values its bundle really passes: 26 cover all their Ingresses with the shared Secret, 60 have no Ingress, 1 has no TLS block | 0 gaps; the same check on the unpatched charts finds **26 leaves still requesting per-host certificates** (`CONTROL=1`) |

What this found that the six-chart prototype could not have:
- **Helm map merge.** Four values-only charts (catalogue-ui, sd-ui, superset, gitea) ship `cert-manager.io/cluster-issuer: dev-prod` in their own `values.yaml`.
  The bundle's `annotations: {}` does not remove it, so the Ingress kept the annotation *and* named the shared Secret: cert-manager would then try to issue into
  the same Secret as the wildcard `Certificate`. Fix: an explicit `null`, but only where that chart *version* ships the default (a `null` for a key that
  is not in the defaults renders a literal `key: null`; a first, version-blind attempt showed this on gitea 10.4.1).
- **monitoring-proxy pods roll once.** The chart hashes `values.yaml` into a pod annotation, so adding the new key changes the hash on the first upgrade. Nothing else changes.
- **A wildcard cannot cover everything.** The Logstash beats host is two labels deep (`logstash.beats.<ns>...`) and uses a pre-provisioned secret.
- Charts are not uniform: the same bundle mixes `issuer`, `clusterIssuer`, annotations, `tls: true`; one chart version has no Ingress at all.

Limits of this level: it is `helm template`, not an ArgoCD deployment; values kept in ArgoCD `valueFiles` (the separate values repository) are not visible,
so a value file that re-adds an issuer annotation would not be caught; six leaves could not be rendered (keycloak 25.2.0 tag not pullable, eck-operator,
edc, and monitoring-proxy through its bundle needs valueFiles; monitoring-proxy is covered by `components_check.py`); `authority-gaia-x-edc` and `authority-monitoring` are not inventoried.

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

- **Level 4: a real certificate from Let's Encrypt needs a domain whose DNS is public.** Let's Encrypt *is* reachable, and the lab's
  cert-manager now registers an account with its staging server (`letsencrypt_probe.sh`). Two things were in the way, neither is "no internet":
  (1) this sandbox re-signs egress TLS with its own CA, which cert-manager's pod did not trust (`x509: certificate signed by unknown authority`);
  `./cert_manager.sh proxy-ca` gives the controller that CA bundle (sandbox only); (2) Let's Encrypt validates DNS-01 against the **public**
  DNS, so a local DNS server (BIND works fine, see level 3 with Pebble) cannot satisfy it: the probe shows the real NXDOMAIN rejection.
  What would complete it: a registered domain whose nameservers are reachable from the internet and that cert-manager can update through an API.
  Not this sandbox, which has no inbound reachability. A throwaway domain plus API credentials at any DNS provider (or a free deSEC `dedyn.io`
  subdomain) and Let's Encrypt **staging** would do; it still would not test the OVH solver unless the domain is at OVH.
- **Level 5: no ArgoCD install of the official charts.** The chain umbrella -> bundles -> component charts is proved by `helm template`
  on the real charts (`fullchain.sh`), not by a deployment. Done since the first version: all consumer and provider bundles, both umbrellas, the
  inline Ingresses, the third-party charts that have an Ingress; `global.ingress.issuer` is read by nothing. Not done: the authority bundles
  `authority-gaia-x-edc` / `authority-monitoring`, ArgoCD valueFiles; the `agent-tls` chart as an ArgoCD Application (the umbrella needs somewhere to host it) and Certificate-before-Ingress
  sync-wave ordering.
- **No login flow through the wildcard.** Hostnames do not change, so CORS and Keycloak redirect settings should not either, but a Keycloak/OIDC login through the wildcard was not run. The browser test loads a placeholder nginx page, not a Simpl UI.
- **Issuers are a lab CA and Pebble.** Simpl's guide says a private CA is unsupported for the platform; the lab CA is only a test device. The ACME test trusts Pebble's CA as a partial chain.
- **Secrets are per-namespace.** Two namespaces were exercised; a real agent spans several, each needing its own Certificate (or a secret replicator).
- The 11 consumer hostnames are read from the charts; three billing names are placeholders for chart overrides.
- Tier-2 identity certificates are not involved and were not touched.
