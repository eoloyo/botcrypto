# Which charts request a certificate, and what the wildcard switch does to each

Scope: every umbrella and bundle chart of a consumer / data-provider / governance-authority agent (18 charts, taken from `main` at the time of
the run) and everything they deploy (124 chart sources, 89 distinct chart+version, 88 pulled by `helm pull`). `fullchain.sh` regenerates all of it;
`inventory/` holds the scripts. The two other agent umbrellas, `application-provider-agent-chart` and `infrastructure-provider-agent-chart`,
contain only a README and a pipeline file (no `charts/` directory), so there is nothing to change.

43 of the 87 rendered chart versions contain an Ingress template. By how they get their certificate:

| Family | Charts | What it took |
|---|---|---|
| **A. component chart hard-wires the issuer annotation** (no way to say "use this Secret") | tier1-gateway, fe-authentication-provider, fe-identity-provider, fe-onboarding, fe-security-attribute-provider, users-roles-fe, consent-management-fe, gateway-oauth2-client (`ingress.existingTlsSecret`); contract-consumption-be, edc-connector-adapter, schema-sync-adapter, sd-creation-wizard, xfsc-advsearch, simpl-files (same key); monitoring-proxy, eck-monitoring (top-level `existingTlsSecret`) | a chart patch: `components-wildcard.patch` (17 chart versions, 22 Ingress templates, 36 annotation lines gated, 22 secretNames). Default = byte-identical |
| **B. bundle's own inline Ingress** (hard-coded per-host secret) | authority-iaa, consumer-iaa, provider-iaa (`frontend/root/ingress.yaml`) | bundle patch (rule B4) |
| **C. values-only charts** (`ingress.tls[].secretName` + annotations come from values) | catalogue-ui, sd-ui, superset, gitea, infrastructure-be, simpl-landing-page, argo-cd, argo-workflows, mailpit, asset-orchestrator, monitoring-reporting-fe, simpl-contract(-ui-backend), simpl-signing-service, simpl-vc-issuer-service, simpl-wallet-service, simpl-stubs, signer, ... (23 charts) | no chart change. The bundle passes the shared secret and drops the annotation (rules B3, B5). **A chart that ships its own default `cert-manager.io/cluster-issuer` in `values.yaml` needs an explicit `null`**: Helm merges maps, `{}` or omission leaves the default (catalogue-ui, sd-ui, superset, gitea 0.5.1) |
| **D. nothing to do** | everything else (no Ingress, or the Ingress is hard-disabled: signer) | |

Left alone on purpose (listed by `wildcard_all.py` / `leaves_check.py`, not hidden):
- `kafka` `clusterIssuer`, `users-roles-be` `global.ingress.issuer`: values nobody reads (no Ingress).
- `eck-monitoring`: the **internal** Elasticsearch Ingress (`*.svc` host, ECK-internal certificate) and the **Logstash beats** Ingress, which uses a
  pre-provisioned `logstash-secret-beats` and the host `logstash.beats.<ns>.<domain>`, **two labels deep: a wildcard `*.<ns>.<domain>` does not cover it**.
- `dagster`: its Ingress has no `tls:` block in the bundle (cert-manager does nothing without one).
- Tier-2 `tls.participant...` identity certificates: not involved.

Not covered: `authority-gaia-x-edc` and `authority-monitoring` (authority bundles referenced by the governance-authority umbrella but not in the
inventory), `keycloak` 25.2.0 (the pinned bitnami tag cannot be pulled; the bundles define no Keycloak Ingress), eck-operator/edc (no Ingress in these bundles).
