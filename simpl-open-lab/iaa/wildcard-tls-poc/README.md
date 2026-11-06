# Wildcard TLS for a Simpl agent — prototype

Answers "what would it take to change the charts to support a wildcard certificate?" by doing the core of it on the lab
cluster (`../../k8s-gvisor`) and measuring. **What it proves is the chart mechanics. It does not prove real wildcard
issuance** (see "Not covered").

```bash
# one-time: the six chart dirs the patch applies to (copies; the lab repos are left alone)
W=/root/simpl-open-lab-work/wildcard-poc; mkdir -p $W/orig $W/patched
for c in tier1-gateway authentication-provider-fe identity-provider-fe onboarding-fe security-attribute-provider-fe users-roles-fe; do
  cp -r /root/simpl-agent-build/src/$c/charts $W/orig/$c; cp -r /root/simpl-agent-build/src/$c/charts $W/patched/$c; done
patch -p1 -d $W/patched < wildcard-tls.patch      # run from this directory; $W/orig stays untouched

./render_check.sh $W/orig $W/patched     # helm-template regression checks, no cluster
./cert_manager.sh install                # cert-manager in the lab cluster (3 pods under gVisor)
./cluster_test.sh                        # per-host (today) vs wildcard, on a real cert-manager
./cluster_test.sh migrate                # switch an existing per-host deployment to wildcard in place
./cert_manager.sh uninstall              # restore the lab cluster
```

## The change

| File | What |
|---|---|
| `wildcard-tls.patch` | the six ingress templates (`tier1-gateway` + five frontends) and their `values.yaml` |
| `agent-tls/` | a small chart: one `Certificate` with the wildcard names, built from `domainSuffix` + `namespaceTag` |

Per Ingress template, about 6 lines:

```yaml
{{- if not .Values.ingress.existingTlsSecret }}
cert-manager.io/cluster-issuer: {{ .Values.ingress.issuer }}
cert-manager.io/renew-before: "720h"
{{- end }}
...
secretName: {{ default (printf "%s-cert" (tpl .Values.hostFe .)) .Values.ingress.existingTlsSecret }}
```

`ingress.existingTlsSecret` defaults to empty, which is today's behaviour. A wildcard matches one DNS label, so the
three entries in `agent-tls/values.yaml` are `*.<ns>.<domain>`, `*.fe.<ns>.<domain>`, `*.be.<ns>.<domain>`
(a provider also needs `*.crossplane.<ns>.<domain>` for `gitea.crossplane`).

## Results

| Check | Result |
|---|---|
| Render, 6 charts x 6 checks: default output **byte-identical** to the original; an **old values file without the new key** renders identically; wildcard mode drops the cert-manager annotations, uses the shared secret, leaves hostnames untouched | **36 / 36** |
| The same check run against *unpatched* charts (must fail) | 12 failures, as it should |
| Today, 11 consumer hosts, one Ingress each | **11 Certificates**, 11 TLS secrets |
| Today, the six real charts (5 frontends on one host + the gateway) | 6 Ingresses -> **2 Certificates**; shared secrets cause no cert-manager complaints |
| Wildcard mode, the same 11 hosts | **1 Certificate**, SANs `*.consumer1…`, `*.fe.consumer1…`, `*.be.consumer1…` |
| Coverage by `openssl x509 -checkhost` | all **11 hosts covered** |
| Must *not* match | `tls.participant.<ns>…` (the Tier-2 host, which keeps its GA-issued identity certificate), `gitea.crossplane.<ns>…`, the bare `<ns>…`, another agent's namespace, a 3-label host: **all correctly not covered** |
| Wildcard mode, six real charts | 6 Ingresses on 2 hosts -> 1 Certificate |
| **Migration** of a live per-host deployment, in place | the Ingresses switch to the wildcard secret and the wildcard certificate is issued, but the **11 old per-host Certificates stay behind** (still owned by their Ingresses). They need an explicit cleanup; after it, cert-manager does not recreate them |

## Things found on the way

- **My first render check was vacuous.** `Chart.yaml` carries the CI placeholder `version: ${PROJECT_RELEASE_VERSION}`,
  which helm rejects, so every render was an error and "identical output" compared two identical errors. The check now
  normalises the placeholder in temp copies, requires a real `kind: Ingress`, and was shown to fail on unpatched charts.
- **cert-manager acts on the lab's existing Ingresses.** The `authority01` Ingresses carry the cert-manager annotation with
  the unresolved value `${CLUSTERISSUER}`, so installing cert-manager created two never-ready Certificates there.
  `cert_manager.sh uninstall` removes them and restores the cluster (checked: same namespaces, 7 Ingresses, no stray secrets).
- **Pods need `runtimeClassName: runsc`.** Without it the sandboxes fail (`runc create failed … can't get final child's PID`).
- **"Ready" is not enough for cert-manager.** The webhook rejects every Certificate with `x509: certificate signed by
  unknown authority` until cainjector has injected its CA, even with three Ready pods and a webhook endpoint. The install
  script now waits for a server-side dry-run of a ClusterIssuer to be admitted.

## Not covered — read before relying on this

- **No real wildcard issuance.** The issuer is a lab CA (selfSigned -> CA). A real wildcard needs an ACME **DNS-01**
  issuer and a DNS provider, which this sandbox doesn't have. Simpl's guide also says a private CA is unsupported for the
  platform; the lab CA is only a test device here.
- **No ingress controller in the cluster**, so nothing was served over TLS. Coverage was checked on the issued
  certificate with `openssl`, not by a browser or nginx.
- **Only the six component templates and the `agent-tls` chart.** The umbrella agent charts and the ~15 bundle charts
  were not modified, so the `tls.mode` switch passed down through the ArgoCD `valuesObject`, and the sync-wave ordering
  (Certificate before Ingress), are untested. Third-party charts (Keycloak, Gitea, Kibana, Kafka/other UIs) are untouched
  and have their own TLS value schemas.
- **Secrets are per-namespace.** Two namespaces were exercised; a real agent spans several, each needing its own
  Certificate (or a secret replicator).
- The 11 consumer hostnames are read from the charts; three billing names are placeholders for chart overrides.
- Tier-2 identity certificates are not involved and were not touched.
