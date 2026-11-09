# authority-gaia-x-edc: make the Vocabulary Manager UI Ingress switchable

Ticket: the UI has no Ingress because `charts/templates/application.yaml` writes `ingress.enabled: false` as a literal for the
`simpl-vocabulary-ui` source; Argo CD applies inline `helm.values` after `valueFiles`, so nothing can turn it on.

`vocabulary-ui-ingress.patch` (against `main` at e92db52e, GitLab project 1399; `./verify.sh` re-checks it):
1. the literal becomes `{{ dig "ingress" "enabled" false .Values.simpl_vocabulary_manager_ui }}`; new value
   `simpl_vocabulary_manager_ui.ingress.enabled`, **default false: rendered output is byte-identical to today**.
2. when on, `nginx.ingress.kubernetes.io/rewrite-target: null`. The UI chart (1.0.0) ships `rewrite-target: /$2` for its path-based default; Helm
   merges annotation maps, so with the bundle's host-based path `/` every request would be rewritten to `/`. `null` is only valid while the
   chart ships that default (otherwise a literal `null` annotation is rendered): re-check when the UI chart version changes.

Not in this patch, but needed when the Ingress is turned on:
- add `https://vocabulary-manager-fe.<authority ns>.<domain>` to the Tier-1 gateway's CORS `allowOrigin` (chart `authority-iaa`) and to the Keycloak
  client `frontend-cli` redirect URIs / web origins (realm configuration, not visible in the charts);
- it is an admin UI (upload / activate / deprecate vocabularies): restrict it (roles, IP allowlist / VPN).

Seen while reading, not changed: the UI source reads `simpl_schema_manager_ui.resources` instead of `simpl_vocabulary_manager_ui.resources`
(copy-paste, `application.yaml` ~line 231); and the authority gateway route `/vocabulary-ui/**` targets a Service `vocabulary-manager-ui`, while the
UI chart creates `simpl-vocabulary-ui`. Not sent upstream.
