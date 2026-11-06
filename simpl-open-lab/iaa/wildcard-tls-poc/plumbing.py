#!/usr/bin/env python3
"""plumbing.py make|check — the wildcard switch passed down the REAL umbrella -> bundle -> component chart chain.

The consumer agent is an ArgoCD app-of-apps: consumer-agent-chart (umbrella) -> six bundle charts (consumer-iaa, ...)
-> component charts (tier1-gateway, the frontends). Each layer hands `cluster.issuer` to the next. This adds a gated
`tls.mode` at the umbrella, carries it through the consumer-iaa bundle and turns it into `ingress.existingTlsSecret`
for the component charts patched by wildcard-tls.patch. Only the IAA bundle is done (the other five bundles repeat the
same edit); the other bundles and the third-party charts are not covered.

  plumbing.py make     fetch the two charts at the pinned commits, apply the edits, write umbrella-plumbing.patch
  plumbing.py check    fetch them again, apply the SAVED patch, and run the checks (helm template only; no cluster)
"""
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://code.europa.eu/api/v4"
PINS = {"consumer-agent-chart": (2271, "cdaa1d395a2338cea64111f85d5add6063d1be37"),
        "consumer-iaa": (2234, "30c8b4c4dc5077db97835af945085039029475cc")}
PATCH = os.environ.get("PLUMBING_PATCH", os.path.join(HERE, "umbrella-plumbing.patch"))
WORK = os.environ.get("W", "/root/simpl-open-lab-work/wildcard-poc")
GATE = '(.Values.tls | default dict).mode | default "perHost"'


def get(url, raw=False):
    with urllib.request.urlopen(url, timeout=60) as r:
        body = r.read().decode()
    return body if raw else json.loads(body)


def fetch(dest):
    for name, (pid, sha) in PINS.items():
        tree = get(f"{API}/projects/{pid}/repository/tree?path=charts&recursive=true&per_page=100&ref={sha}")
        for t in tree:
            if t["type"] != "blob":
                continue
            out = os.path.join(dest, name, t["path"]); os.makedirs(os.path.dirname(out), exist_ok=True)
            enc = urllib.parse.quote(t["path"], safe="")
            open(out, "w").write(get(f"{API}/projects/{pid}/repository/files/{enc}/raw?ref={sha}", raw=True))


def edit(path, fn):
    s = open(path).read(); n = fn(s); assert n != s, f"no change in {path}"; open(path, "w").write(n)


def make_edits(root):
    # --- umbrella: pass the switch to every bundle, only in wildcard mode ---------------------------------
    u = f"{root}/consumer-agent-chart/charts"
    def umb(s):
        pat = re.compile(r"^( +)issuer: \{\{ \.Values\.cluster\.issuer \}\}\n", re.M)
        def add(m):
            b = " " * (len(m.group(1)) - 2)
            return (m.group(0) +
                    f'{b}{{{{- if eq (.Values.tls.mode | default "perHost") "wildcard" }}}}\n{b}tls:\n{b}  mode: wildcard\n'
                    f'{b}  wildcardSecretName: {{{{ .Values.tls.wildcard.secretName | default (printf "%s-wildcard-tls" .Values.namespaceTag.consumer) }}}}\n{b}{{{{- end }}}}\n')
        r, n = pat.subn(add, s); assert n == 6, n; return r
    edit(f"{u}/templates/application.yaml", umb)
    edit(f"{u}/values.yaml", lambda s: s.rstrip("\n") + "\n\n# Optional shared (wildcard) certificate: perHost = today's behaviour\ntls:\n  mode: perHost\n  wildcard:\n    secretName: \"\"   # default: <namespaceTag>-wildcard-tls\n")
    # --- bundle: turn it into ingress.existingTlsSecret for each component app ----------------------------
    b = f"{root}/consumer-iaa/charts"
    edit(f"{b}/values.yaml", lambda s: s.rstrip("\n") + "\n\n# Set by the umbrella chart. perHost = today's behaviour\ntls:\n  mode: perHost\n  wildcardSecretName: \"\"\n")
    apps = [f for f in os.listdir(f"{b}/templates/applications") if f.endswith("-application.yaml")]
    hits = 0
    for f in apps:
        def app(s):
            nonlocal hits
            pat = re.compile(r"^( +)issuer: \{\{ \.Values\.cluster\.issuer \}\}\n", re.M)
            def add(m):
                i = m.group(1)
                return (m.group(0) + f'{i}{{{{- if eq ({GATE}) "wildcard" }}}}\n{i}existingTlsSecret: {{{{ .Values.tls.wildcardSecretName | quote }}}}\n{i}{{{{- end }}}}\n')
            r, n = pat.subn(add, s); hits += n; return r if n else s
        p = f"{b}/templates/applications/{f}"; s = open(p).read(); n = app(s)
        if n != s: open(p, "w").write(n)
    assert hits == 5, hits   # consent-management-fe, tier1-gateway, authentication-provider-fe, users-roles-fe, users-roles
    def ing(s):
        a = re.compile(r"^    cert-manager\.io/cluster-issuer: \{\{ \.Values\.cluster\.issuer \}\}\n    cert-manager\.io/renew-before: 720h\n", re.M)
        assert a.search(s)
        s = a.sub(f'    {{{{- if not (eq ({GATE}) "wildcard") }}}}\n    cert-manager.io/cluster-issuer: {{{{ .Values.cluster.issuer }}}}\n    cert-manager.io/renew-before: 720h\n    {{{{- end }}}}\n', s)
        c = re.compile(r"^(      secretName: )(participant\.fe\.\{\{ tpl \.Values\.namespaceTag\.participant \. \}\}\.\{\{ \.Values\.domainSuffix \}\}-cert)\n", re.M)
        assert c.search(s)
        return c.sub(lambda m: f'{m.group(1)}{{{{ if eq ({GATE}) "wildcard" }}}}{{{{ .Values.tls.wildcardSecretName }}}}{{{{ else }}}}{m.group(2)}{{{{ end }}}}\n', s)
    edit(f"{b}/templates/frontend/root/ingress.yaml", ing)


def helm(chart, *args):
    p = subprocess.run(["helm", "template", "x", chart, "--namespace", "consumer1", *args], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def norm(chart_dir):   # Chart.yaml has the CI placeholder ${PROJECT_RELEASE_VERSION}, which helm rejects
    p = f"{chart_dir}/Chart.yaml"; s = open(p).read()
    open(p, "w").write(re.sub(r"^(version|appVersion): .*PROJECT_RELEASE_VERSION.*$", r'\1: "0.0.0-poc"', s, flags=re.M))


FAILS = []
def check(cond, msg):
    print(f"  [{'PASS' if cond else 'FAIL'}] {msg}")
    if not cond: FAILS.append(msg)


def docs(text): return [d for d in yaml.safe_load_all(text) if d]
def app_sources(text):
    app = [d for d in docs(text) if d.get("kind") == "Application"][0]
    return [(s.get("chart") or s.get("path"), yaml.safe_load(s.get("helm", {}).get("values") or "{}") or {}) for s in (app["spec"].get("sources") or [app["spec"]["source"]])]


def run_checks():
    t = tempfile.mkdtemp(); fetch(f"{t}/a"); shutil.copytree(f"{t}/a", f"{t}/b")
    subprocess.run(["patch", "-p1", "-d", f"{t}/b", "-s", "-i", PATCH], check=True)
    for side in ("a", "b"):
        for n in PINS: norm(f"{t}/{side}/{n}/charts")
    U = "charts"; common = ["--set", "namespaceTag.consumer=consumer1", "--set", "namespaceTag.authority=authority01", "--set", "namespaceTag.common=common01"]
    bcommon = ["--set", "namespaceTag.participant=consumer1", "--set", "namespaceTag.authority=authority01", "--set", "namespaceTag.common=common01"]
    WILD = "consumer1-wildcard-tls"
    print("== umbrella (consumer-agent-chart)")
    rc, a = helm(f"{t}/a/consumer-agent-chart/{U}", *common); rc2, b = helm(f"{t}/b/consumer-agent-chart/{U}", *common)
    check(rc == 0 and "kind: Application" in a, "original umbrella renders a real Application")
    check(a == b, "default (perHost): patched output is byte-identical to the original")
    rc, w = helm(f"{t}/b/consumer-agent-chart/{U}", *common, "--set", "tls.mode=wildcard")
    srcs = app_sources(w) if rc == 0 else []
    check(len(srcs) == 6 and all((v.get("tls") or {}).get("mode") == "wildcard" and v["tls"].get("wildcardSecretName") == WILD for _, v in srcs),
          f"wildcard mode: all 6 bundles receive tls.mode=wildcard and secret {WILD}")
    print("== bundle (consumer-iaa)")
    rc, ba = helm(f"{t}/a/consumer-iaa/{U}", *bcommon); rc2, bb = helm(f"{t}/b/consumer-iaa/{U}", *bcommon)
    check(rc == 0 and "kind: Ingress" in ba, "original bundle renders (incl. its own Ingress)")
    check(ba == bb, "default (perHost): patched output is byte-identical to the original")
    old = f"{t}/old"; shutil.copytree(f"{t}/b/consumer-iaa/{U}", old); shutil.copy(f"{t}/a/consumer-iaa/{U}/values.yaml", f"{old}/values.yaml")
    check(helm(old, *bcommon)[1] == ba, "patched templates + OLD values.yaml (no tls key, i.e. an old umbrella) render identically")
    rc, bw = helm(f"{t}/b/consumer-iaa/{U}", *bcommon, "--set", "tls.mode=wildcard", "--set", f"tls.wildcardSecretName={WILD}")
    check(rc == 0, "wildcard mode renders")
    ing = [d for d in docs(bw) if d.get("kind") == "Ingress"][0]
    check("cert-manager.io/cluster-issuer" not in ing["metadata"]["annotations"] and ing["spec"]["tls"][0]["secretName"] == WILD,
          "the bundle's own Ingress: no cert-manager annotation, uses the shared secret")
    def secrets_by_app(text):
        out = {}
        for chart, v in app_sources(text):
            out[chart] = ((v.get("ingress") or {}).get("existingTlsSecret")) or (((v.get("global") or {}).get("ingress") or {}).get("existingTlsSecret"))
        return out
    byname = {c: v for c, v in app_sources(bw)}
    got = secrets_by_app(bw); applied = sorted(c for c, x in got.items() if x == WILD)
    # consent-management-fe is only rendered for type=data-provider, so a consumer gets 4 of the 5 edited apps
    check(len(applied) == 4, f"consumer bundle, wildcard mode: {len(applied)}/4 rendered component apps get the shared secret ({', '.join(applied)})")
    rc, bd = helm(f"{t}/b/consumer-iaa/{U}", *bcommon, "--set", "type=data-provider", "--set", "tls.mode=wildcard", "--set", f"tls.wildcardSecretName={WILD}")
    gd = secrets_by_app(bd); ad = sorted(c for c, x in gd.items() if x == WILD)
    check(rc == 0 and len(ad) == 5, f"data-provider bundle, wildcard mode: {len(ad)}/5 rendered component apps get the shared secret (adds {', '.join(sorted(set(ad) - set(applied)))})")
    rc, bda = helm(f"{t}/a/consumer-iaa/{U}", *bcommon, "--set", "type=data-provider"); rc2, bdb = helm(f"{t}/b/consumer-iaa/{U}", *bcommon, "--set", "type=data-provider")
    check(rc == 0 and bda == bdb, "data-provider bundle, default (perHost): patched output is byte-identical to the original")
    print("== bundle -> real component chart (the keys must match)")
    W_ = os.path.join(WORK, "patched"); n_checked = 0
    for src, chart in (("tier1-gateway", "tier1-gateway"), ("fe-authentication-provider", "authentication-provider-fe"), ("users-roles-fe", "users-roles-fe")):
        vals = [v for c, v in byname.items() if c == src]
        if not vals: check(False, f"bundle has no source named {src}"); continue
        vf = f"{t}/{chart}-values.yaml"; yaml.safe_dump(vals[0], open(vf, "w"))
        comp = f"{t}/comp-{chart}"; shutil.copytree(f"{W_}/{chart}", comp)
        cs = open(f"{comp}/Chart.yaml").read(); open(f"{comp}/Chart.yaml", "w").write(re.sub(r"^(version|appVersion): .*PROJECT_RELEASE_VERSION.*$", r'\1: "0.0.0-poc"', cs, flags=re.M))
        rc, out = helm(comp, "--show-only", "templates/ingress.yaml", "-f", vf)
        i = [d for d in docs(out) if d.get("kind") == "Ingress"]
        ok_ = bool(i) and i[0]["spec"]["tls"][0]["secretName"] == WILD and "cert-manager.io/cluster-issuer" not in i[0]["metadata"]["annotations"]
        check(ok_, f"bundle source {src} -> chart {chart}: the rendered values make it use the shared secret and drop the issuer annotation" + ("" if ok_ else f"  [{out[:140]}]"))
        n_checked += 1
    check(n_checked == 3, "all three component charts were exercised")
    shutil.rmtree(t, ignore_errors=True)
    print(); print("PLUMBING: ALL CHECKS PASSED" if not FAILS else f"PLUMBING: {len(FAILS)} FAILURE(S)")
    return 0 if not FAILS else 1


def make():
    t = tempfile.mkdtemp(); fetch(f"{t}/a"); shutil.copytree(f"{t}/a", f"{t}/b"); make_edits(f"{t}/b")
    diff = subprocess.run(["diff", "-ruN", "a", "b"], cwd=t, capture_output=True, text=True).stdout
    open(PATCH, "w").write(diff); print(f"wrote {PATCH}: {diff.count(chr(10))} lines"); shutil.rmtree(t, ignore_errors=True)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "make": make()
    elif cmd == "check": sys.exit(run_checks())
    else: print(__doc__); sys.exit(2)
