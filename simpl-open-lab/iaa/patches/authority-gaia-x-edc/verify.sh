#!/usr/bin/env bash
# verify.sh — fetch authority-gaia-x-edc at the pinned commit, apply vocabulary-ui-ingress.patch, check with helm template. Needs helm, python3 + pyyaml, network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
API=https://code.europa.eu/api/v4/projects/1399; SHA=e92db52e3acbe68d1152d87f01fc8cab91f0835f; FAIL=0
ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; FAIL=1; }
python3 - "$T/o" "$API" "$SHA" <<'PY'
import json, os, sys, urllib.parse, urllib.request
out, api, sha = sys.argv[1:]
get = lambda u: urllib.request.urlopen(u, timeout=60).read().decode()
for t in json.loads(get(f"{api}/repository/tree?path=charts&recursive=true&per_page=100&ref={sha}")):
    if t["type"] == "blob":
        d = f"{out}/{t['path']}"; os.makedirs(os.path.dirname(d), exist_ok=True)
        open(d, "w").write(get(f"{api}/repository/files/{urllib.parse.quote(t['path'], safe='')}/raw?ref={sha}"))
PY
cp -r "$T/o" "$T/p"; (cd "$T/p" && patch -p1 -s < "$HERE/vocabulary-ui-ingress.patch") && ok "patch applies" || { bad "patch does not apply"; exit 1; }
for d in o p; do sed -i 's/\${PROJECT_RELEASE_VERSION}/0.0.0/' "$T/$d/charts/Chart.yaml"; done
S="namespaceTag.authority=authority01,namespaceTag.common=common01,domainSuffix=x.example,cluster.namespace=authority01,cluster.issuer=dev-prod,secrets.role=r,secrets.secretEngine=e"
r() { helm template rel "$T/$1/charts" --set "$S,resourcePreset=$2$3"; }
for p in low normal; do r o $p "" > $T/o.$p; r p $p "" > $T/p.$p; cmp -s $T/o.$p $T/p.$p && ok "default render byte-identical (resourcePreset=$p)" || bad "default render differs ($p)"; done
r p normal ",simpl_vocabulary_manager_ui.ingress.enabled=true" > $T/p.on; r o normal ",simpl_vocabulary_manager_ui.ingress.enabled=true" > $T/o.on
cmp -s $T/o.normal $T/o.on && ok "control: the ORIGINAL chart ignores the value (the ticket)" || bad "original chart reacts to the value?"
[ "$(diff $T/o.normal $T/p.on | grep -c '^[<>]')" = 3 ] && ok "patched, enabled: exactly 3 diff lines (enabled false->true, +1 annotation line)" || bad "unexpected diff size"
helm pull simpl-vocabulary-ui --version 1.0.0 --repo https://code.europa.eu/api/v4/projects/1585/packages/helm/stable --untar --untardir $T/ui >/dev/null 2>&1 || { bad "cannot pull simpl-vocabulary-ui 1.0.0"; exit 1; }
python3 - "$T/p.on" "$T/ui-values.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "Application":
        for s in d["spec"].get("sources", []):
            if s.get("chart") == "simpl-vocabulary-ui": open(sys.argv[2], "w").write(s["helm"]["values"])
PY
helm template simpl-vocabulary-manager-ui $T/ui/simpl-vocabulary-ui -f $T/ui-values.yaml -n authority01 > $T/ui.on
python3 - $T/ui.on <<'PY' && ok "UI chart renders an Ingress without rewrite-target and without a literal null annotation" || bad "rendered Ingress wrong"
import sys, yaml
ing = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Ingress"]
a = ing[0]["metadata"]["annotations"]
sys.exit(0 if len(ing) == 1 and "nginx.ingress.kubernetes.io/rewrite-target" not in a and None not in a.values() and "null" not in a.values() and ing[0]["spec"]["rules"][0]["host"].startswith("vocabulary-manager-fe.") else 1)
PY
sed '/rewrite-target: null/d' $T/ui-values.yaml > $T/ui-values-nonull.yaml
helm template simpl-vocabulary-manager-ui $T/ui/simpl-vocabulary-ui -f $T/ui-values-nonull.yaml -n authority01 | grep -q 'rewrite-target: /\$2' && ok "control: without the null the Ingress would rewrite every request to /" || bad "control did not show the rewrite"
[ $FAIL = 0 ] && echo "VERIFY: ALL CHECKS PASSED" || echo "VERIFY: FAILURES ABOVE"; exit $FAIL
