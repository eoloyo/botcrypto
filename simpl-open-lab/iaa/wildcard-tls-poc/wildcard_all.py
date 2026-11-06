#!/usr/bin/env python3
"""wildcard_all.py — carry the wildcard-TLS switch through ALL umbrella and bundle charts (not just consumer-iaa).

Works on copies of the real charts (fetched by fullchain.py at pinned commits) and writes bundles-wildcard.patch.
Rules, by what the chart's own templates contain (counts from the inventory in INVENTORY.md):

  U   umbrella: after `issuer: {{ .Values.cluster.issuer }}` in each bundle's values, hand down `tls.mode` + the shared secret name
      (only in wildcard mode, so default output is unchanged)
  B1  `ingress: issuer: {{ .Values.cluster.issuer }}` (also global.ingress): add `existingTlsSecret` next to it, gated
  B2  `ingress: clusterIssuer: {{ .Values.cluster.issuer }}`: same (the adapter family); a top-level `clusterIssuer` (kafka, ECK,
      monitoring-proxy: internal CAs) is deliberately left alone
  B3  `annotations: cert-manager.io/cluster-issuer: ...` + a sibling `tls: - secretName: X` list (values-only charts): in wildcard mode the
      cert-manager annotation keys are set to an explicit `null` in wildcard mode (Helm deep-merges maps, so `{}` or omitting the key would leave the chart's own default `cert-manager.io/cluster-issuer` in place; found by leaves_check.py) and secretName becomes the shared secret
  B5  `tls: true` + annotation (Argo CD, Mailpit): wildcard mode sets `tls: false` and an `extraTls` entry with the shared secret
  B6  top-level `clusterIssuer` used by eck-monitoring / monitoring-proxy for an Ingress annotation: add `existingTlsSecret` (those charts get a template edit)
  B4  inline Ingress templates in the bundle (frontend/root/ingress.yaml): gate the annotations, switch secretName

Anything with `cluster.issuer` that no rule claims is reported and fails the run: nothing is silently skipped.
"""
import difflib
import json
import os
import re
import shutil
import subprocess
import sys

BASE = os.environ.get("INV", "/root/simpl-open-lab-work/wildcard-poc/inv")
HERE = os.path.dirname(os.path.abspath(__file__))
META = json.load(open(f"{BASE}/meta.json"))
GATE = '(.Values.tls | default dict).mode | default "perHost"'
IF_WILD = '{{- if eq (' + GATE + ') "wildcard" }}'
SECRET = '{{ required "tls.wildcardSecretName is required when tls.mode=wildcard" .Values.tls.wildcardSecretName }}'
ISSUER = r"\{\{\s*\.Values\.cluster\.issuer\s*\}\}"
indent = lambda l: len(l) - len(l.lstrip(" "))
REPORT = {"U": 0, "B1": 0, "B2": 0, "B6": 0, "B3": 0, "B3_secret": 0, "B5": 0, "B4": 0, "left_alone": [], "unclaimed": []}


def charts_with_default_issuer():
    """leaf charts whose OWN values.yaml ships a cert-manager annotation: for them `{}` or omission is not enough (maps merge)"""
    res = set(); root = f"{BASE}/pulled"
    for d in os.listdir(root) if os.path.isdir(root) else []:
        for sub in os.listdir(f"{root}/{d}"):
            v = f"{root}/{d}/{sub}/values.yaml"
            if os.path.isfile(v) and any(re.search(r"cert-manager\.io/cluster-issuer", l) and not l.lstrip().startswith("#") for l in open(v, errors="ignore")): res.add((sub, d[len(sub) + 1:]))
    return res


DEFAULT_CM = None
NULLED = []


def leaf_chart_at(lines, i, values_path):
    """the chart name of the Application source that contains line i: nearest `chart: {{ .Values.K.chart_name }}` above, resolved in the bundle's values.yaml"""
    for j in range(i, -1, -1):
        m = re.match(r"\s*chart:\s*\{\{\s*\.Values\.([\w]+)\.chart_name\s*\}\}", lines[j])
        if m:
            vt = open(values_path).read() if os.path.isfile(values_path) else ""
            blk = re.search(rf"^{m.group(1)}:\n((?:[ \t].*\n|\n)*)", vt, re.M)
            c = re.search(r"chart_name:\s*[\"']?([\w.-]+)", blk.group(1)) if blk else None
            ver = None
            for k in range(j, max(-1, j - 6), -1):                      # targetRevision sits between repoURL and chart
                tm = re.match(r"\s*targetRevision:\s*\{\{\s*\.Values\.([\w]+)\.targetRevision\s*\}\}", lines[k])
                if tm:
                    b2 = re.search(rf"^{tm.group(1)}:\n((?:[ \t].*\n|\n)*)", vt, re.M)
                    v2 = re.search(r"targetRevision:\s*[\"']?([\w.+-]+)", b2.group(1)) if b2 else None
                    ver = v2.group(1) if v2 else None; break
            return (c.group(1), ver) if c else None
        if re.match(r"\s*-\s*repoURL:", lines[j]): break
    return None


def parent_key(lines, i):
    ind = indent(lines[i])
    for j in range(i - 1, -1, -1):
        l = lines[j]
        if l.strip() and not l.lstrip().startswith(("#", "{{")) and indent(l) < ind:
            m = re.match(r"\s*-?\s*([\w.-]+):\s*(\{\{.*)?$", l)
            return m.group(1) if m else None
    return None


def ns_key(text):
    for k in ("consumer", "dataprovider", "authority"):
        if f".Values.namespaceTag.{k}" in text:
            return k
    return "participant"


def patch_umbrella(path):
    lines = open(path).read().split("\n"); out = []; key = ns_key("\n".join(lines))
    for l in lines:
        out.append(l)
        if re.fullmatch(r"\s+issuer: " + ISSUER, l):
            b = " " * (indent(l) - 2)
            out += [f'{b}{{{{- if eq (.Values.tls.mode | default "perHost") "wildcard" }}}}', f"{b}tls:", f"{b}  mode: wildcard",
                    f'{b}  wildcardSecretName: {{{{ .Values.tls.wildcard.secretName | default (printf "%s-wildcard-tls" .Values.namespaceTag.{key}) }}}}', f"{b}{{{{- end }}}}"]
            REPORT["U"] += 1
    open(path, "w").write("\n".join(out))
    v = path.replace("templates/application.yaml", "values.yaml")
    t = open(v).read().rstrip("\n")
    open(v, "w").write(t + '\n\n# Optional shared (wildcard) certificate: perHost = today\'s behaviour\ntls:\n  mode: perHost\n  wildcard:\n    secretName: ""   # default: <namespaceTag>-wildcard-tls\n')


def patch_bundle_values_layer(path):
    """Two passes: (1) decide every edit from the ORIGINAL lines, (2) apply them. edits[i] = lines that replace line i."""
    lines = open(path).read().split("\n"); edits = {}; after = {}
    for i, l in enumerate(lines):
        if l.lstrip().startswith("#"): continue
        # B1 / B2 / B6: hand the shared secret to a chart that takes existingTlsSecret
        m = re.fullmatch(r"(\s+)(issuer|clusterIssuer): " + ISSUER, l)
        if m:
            pk = parent_key(lines, i); ind = m.group(1)
            nxt = next((x for x in lines[i + 1:] if x.strip()), "")
            if m.group(2) == "issuer" or pk == "ingress":
                key = "B1" if m.group(2) == "issuer" else "B2"
            elif pk is None and nxt.lstrip().startswith("kafka:"):
                REPORT["left_alone"].append(f"{os.path.relpath(path, BASE)}:{i+1}  clusterIssuer for the kafka chart: no template reads it"); continue
            elif pk is None:
                key = "B6"        # top-level clusterIssuer: eck-monitoring (Kibana Ingress) and monitoring-proxy use it for an Ingress annotation
            else:
                REPORT["left_alone"].append(f"{os.path.relpath(path, BASE)}:{i+1}  clusterIssuer under '{pk}'"); continue
            after[i] = [f"{ind}{IF_WILD}", f"{ind}existingTlsSecret: {SECRET}", f"{ind}{{{{- end }}}}"]; REPORT[key] += 1
            continue
        # B3 / B5: cert-manager annotation inside a values block
        if re.search(r"cert-manager\.io/cluster-issuer\"?:\s*\"?" + ISSUER, l) and "kind: Ingress" not in "\n".join(lines[max(0, i - 8):i]):
            a = i - 1
            only_child = (lines[a].strip() == "annotations:" and indent(l) > indent(lines[a])
                          and (i + 1 >= len(lines) or not lines[i + 1].strip() or indent(lines[i + 1]) <= indent(lines[a])))
            ing_ind = indent(lines[a]) if only_child else indent(l) - 2
            lo = i
            while lo > 0 and (not lines[lo - 1].strip() or indent(lines[lo - 1]) >= ing_ind): lo -= 1
            hi = i
            while hi + 1 < len(lines) and (not lines[hi + 1].strip() or indent(lines[hi + 1]) >= ing_ind): hi += 1
            sib = lambda rx: next((j for j in range(lo, hi + 1) if indent(lines[j]) == ing_ind and re.fullmatch(rx, lines[j])), None)
            if sib(r"\s*enabled:\s*false\s*") is not None:
                REPORT["left_alone"].append(f"{os.path.relpath(path, BASE)}:{i+1}  ingress.enabled=false: no certificate is requested"); continue
            # the annotation itself
            if only_child:
                ia = indent(lines[a])
                global DEFAULT_CM
                DEFAULT_CM = DEFAULT_CM if DEFAULT_CM is not None else charts_with_default_issuer()
                leaf = leaf_chart_at(lines, i, os.path.join(os.path.dirname(os.path.dirname(path)) if "/templates/" in path else os.path.dirname(path), "values.yaml"))
                if leaf in DEFAULT_CM:
                    # explicit null: Helm deep-merges maps, so the chart's own default annotation would survive `{}`; null deletes it
                    ci = " " * indent(l); NULLED.append(f"{os.path.relpath(path, BASE)}:{i+1} {leaf}")
                    edits[a] = [lines[a], f"{ci}{IF_WILD}", re.sub(ISSUER, "null", l), f"{ci}acme.cert-manager.io/http01-edit-in-place: null", f"{ci}{{{{- else }}}}"]
                    edits[i] = [l, f"{ci}{{{{- end }}}}"]
                else:
                    edits[a] = [f"{' ' * ia}{IF_WILD}", f"{' ' * ia}annotations: {{}}", f"{' ' * ia}{{{{- else }}}}", lines[a]]
                    edits[i] = [l, f"{' ' * ia}{{{{- end }}}}"]
            else:
                ia = indent(l); DEFAULT_CM = DEFAULT_CM if DEFAULT_CM is not None else charts_with_default_issuer()
                leaf = leaf_chart_at(lines, i, os.path.join(os.path.dirname(os.path.dirname(path)) if "/templates/" in path else os.path.dirname(path), "values.yaml"))
                if leaf in DEFAULT_CM:
                    NULLED.append(f"{os.path.relpath(path, BASE)}:{i+1} {leaf}")
                    edits[i] = [f'{" " * ia}{IF_WILD}', re.sub(ISSUER, "null", l), f'{" " * ia}{{{{- else }}}}', l, f"{' ' * ia}{{{{- end }}}}"]
                else:
                    edits[i] = [f'{" " * ia}{{{{- if not (eq ({GATE}) "wildcard") }}}}', l, f"{' ' * ia}{{{{- end }}}}"]
            REPORT["B3"] += 1
            t = sib(r"\s*tls:\s*"); tt = sib(r"\s*tls:\s*true\s*")
            if t is not None:                                  # B3: a tls list with a secretName
                sidx = None
                for j in range(t + 1, hi + 1):
                    if lines[j].strip() and indent(lines[j]) <= ing_ind: break
                    if re.match(r"\s*-?\s*secretName:", lines[j]): sidx = j; break
                if sidx is not None and sidx not in edits:
                    sl = lines[sidx]; orig = re.sub(r"^\s*-?\s*secretName:\s*", "", sl)
                    edits[sidx] = [re.sub(r"secretName:.*$", f'secretName: {{{{ if eq ({GATE}) "wildcard" }}}}{SECRET}{{{{ else }}}}{orig}{{{{ end }}}}', sl)]
                    REPORT["B3_secret"] += 1
                else: REPORT["unclaimed"].append(f"{os.path.relpath(path, BASE)}:{i+1}  tls list without a secretName")
            elif tt is not None:                               # B5: tls: true (argo-cd, mailpit): use extraTls with the shared secret
                hn = next((re.sub(r"^\s*hostname:\s*", "", lines[j]) for j in range(lo, hi + 1) if re.match(r"\s*hostname:", lines[j])), None)
                if hn is None:
                    dm = next((re.sub(r"^\s*domain:\s*", "", lines[j]) for j in range(i, -1, -1) if re.match(r"\s*domain:", lines[j])), None); hn = dm
                if hn is None: REPORT["unclaimed"].append(f"{os.path.relpath(path, BASE)}:{i+1}  tls: true without a host to put in extraTls")
                else:
                    I = " " * ing_ind
                    edits[tt] = [f"{I}{IF_WILD}", f"{I}tls: false", f"{I}extraTls:", f"{I}  - hosts:", f"{I}      - {hn}", f"{I}    secretName: {SECRET}", f"{I}{{{{- else }}}}", lines[tt], f"{I}{{{{- end }}}}"]
                    REPORT["B5"] += 1
            else:
                REPORT["unclaimed"].append(f"{os.path.relpath(path, BASE)}:{i+1}  annotation without a tls list or tls: true")
    if not (edits or after): return
    out = []
    for i, l in enumerate(lines):
        out += edits.get(i, [l]); out += after.get(i, [])
    open(path, "w").write("\n".join(out))


def patch_inline_ingress(path):
    s = open(path).read()
    a = re.compile(r"^(    )cert-manager\.io/cluster-issuer: " + ISSUER + r"\n    cert-manager\.io/renew-before: 720h\n", re.M)
    if not a.search(s): return False
    s = a.sub(f'    {{{{- if not (eq ({GATE}) "wildcard") }}}}\n    cert-manager.io/cluster-issuer: {{{{ .Values.cluster.issuer }}}}\n    cert-manager.io/renew-before: 720h\n    {{{{- end }}}}\n', s)
    c = re.compile(r"^(      secretName: )(.+-cert)\n", re.M)
    assert c.search(s), path
    s = c.sub(lambda m: f'{m.group(1)}{{{{ if eq ({GATE}) "wildcard" }}}}{{{{ required "tls.wildcardSecretName is required when tls.mode=wildcard" .Values.tls.wildcardSecretName }}}}{{{{ else }}}}{m.group(2)}{{{{ end }}}}\n', s)
    open(path, "w").write(s); REPORT["B4"] += 1; return True


def run(patched_root):
    for name, m in META.items():
        d = f"{patched_root}/{name}"; d = d + "/charts" if os.path.isdir(d + "/charts") else d
        tdir = f"{d}/templates"
        if not os.path.isdir(tdir): continue
        if m["role"] == "umbrella":
            patch_umbrella(f"{tdir}/application.yaml"); continue
        for root, _, files in os.walk(tdir):
            for f in files:
                p = os.path.join(root, f)
                if not f.endswith((".yaml", ".yml", ".tpl")): continue
                if not patch_inline_ingress(p): patch_bundle_values_layer(p)
        vp = f"{d}/values.yaml"
        t = open(vp).read().rstrip("\n")
        if name == "common-components-chart":
            extra = '\n\n# Optional shared (wildcard) certificate for the common namespace; perHost = today\'s behaviour\ntls:\n  mode: perHost\n  wildcardSecretName: ""   # e.g. <namespaceTag.common>-wildcard-tls\n'
        else:
            extra = '\n\n# Set by the umbrella chart. perHost = today\'s behaviour\ntls:\n  mode: perHost\n  wildcardSecretName: ""\n'
        open(vp, "w").write(t + extra)
    # anything that still mentions cluster.issuer outside a comment and was not rewritten
    for root, _, files in os.walk(patched_root):
        for f in files:
            if not f.endswith((".yaml", ".yml", ".tpl")) or "values" in f: continue
            p = os.path.join(root, f); L = open(p, errors="ignore").read().split("\n")
            for i, l in enumerate(L):
                if re.search(ISSUER, l) and not l.lstrip().startswith("#"):
                    ctx = "\n".join(L[max(0, i - 8):i + 5])
                    skipped = any(x.endswith(f"{os.path.relpath(p, patched_root).replace(os.sep, '/')}:{i+1}") or f"{os.path.relpath(p, patched_root)}:{i+1} " in x for x in REPORT["left_alone"])
                    claimed = skipped or ("existingTlsSecret" in ctx) or ("annotations: {}" in ctx) or ("wildcard" in ctx) or re.match(r"\s+(cluster|clusterIssuer):", l) or "issuer: {{ .Values.cluster.issuer }}" in l and "wildcard" in ctx
                    if not claimed: REPORT["unclaimed"].append(f"{os.path.relpath(p, patched_root)}:{i+1}  {l.strip()[:90]}")


if __name__ == "__main__":
    src = f"{BASE}/charts"; dst = f"{BASE}/patched"
    shutil.rmtree(dst, ignore_errors=True); shutil.copytree(src, dst); run(dst)
    diff = subprocess.run(["diff", "-ruN", "charts", "patched"], cwd=BASE, capture_output=True, text=True).stdout
    open(f"{HERE}/bundles-wildcard.patch", "w").write(diff)
    print({k: v for k, v in REPORT.items() if not isinstance(v, list)})
    print("explicit null (chart default would otherwise survive):", *NULLED, sep="\n   ")
    print("left alone (internal CAs etc.):"); [print("  ", x) for x in REPORT["left_alone"]]
    print("UNCLAIMED cluster.issuer uses:"); [print("  ", x) for x in REPORT["unclaimed"]] if REPORT["unclaimed"] else print("   none")
    print(f"patch: {diff.count(chr(10))} lines")
