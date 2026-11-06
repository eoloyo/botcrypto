#!/usr/bin/env python3
"""bundles_check.py — the 18 umbrella/bundle charts, original (inv/charts) vs patched (inv/patched), via helm template.
 default : rendered output byte-identical
 wildcard: tls.mode=wildcard tls.wildcardSecretName=wild-tls -> no ACTIVE per-host certificate request left in the output
           (cert-manager annotation, `clusterIssuer:`/`issuer:`/`cluster.issuer:` keys with a non-empty value); each leftover is listed
 control : the same scan on the UNPATCHED chart must find leftovers (proves the scan can fail)"""
import os, re, subprocess, sys, shutil, tempfile
BASE = os.environ.get("INV", "/root/simpl-open-lab-work/wildcard-poc/inv")
REQ = re.compile(r"cert-manager\.io/cluster-issuer|(?:^|\s)(?:cluster)?[Ii]ssuer(?:Name)?:\s*[^\s#{}]+|ingress\.cert-manager|clusterIssuer\W+\S+")
def render(d, sets):
    tmp = tempfile.mkdtemp(); c = f"{tmp}/c"; shutil.copytree(d, c, symlinks=True)
    for dp, _, fs in os.walk(c):
        for f in fs:
            if f == "Chart.yaml":
                p = os.path.join(dp, f); y = open(p).read().replace("${PROJECT_RELEASE_VERSION}", "0.0.0"); open(p, "w").write(y)
    base = ["domainSuffix=x.example", "namespaceTag.authority=authority01", "namespaceTag.common=common01", "namespaceTag.consumer=consumer1", "namespaceTag.dataprovider=provider1", "namespaceTag.participant=consumer1", "cluster.issuer=dev-prod", "global.cluster.issuer=dev-prod"]
    r = subprocess.run(["helm", "template", "rel", c, "-n", "ns", "--set", ",".join(base + sets), "--skip-schema-validation"], capture_output=True, text=True)
    shutil.rmtree(tmp, ignore_errors=True); return r.returncode, r.stdout, r.stderr[:300]
def leftovers(out): return [l.strip() for l in out.split("\n") if not l.lstrip().startswith("#") and REQ.search(l) and not re.search(r"issuer:\s*(\"\")?$|issuer:\s*\"?\"?$", l)]

import yaml
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from components_wildcard import FAMILY
UNUSED = {"users-roles-be": "takes global.ingress.issuer but has no Ingress", "kafka": "clusterIssuer value not used by the chart"}
OUT_OF_SCOPE = {"authority-gaia-x-edc": "authority bundle, not in the inventory (not a consumer/provider agent)",
                "authority-monitoring": "authority bundle, not in the inventory (not a consumer/provider agent)"}
BUNDLES = set()
for n in os.listdir(f"{BASE}/charts"):
    for x in os.listdir(f"{BASE}/charts/{n}"):
        if os.path.exists(f"{BASE}/charts/{n}/{x}/Chart.yaml"):
            m = re.search(r"^name:\s*(\S+)", open(f"{BASE}/charts/{n}/{x}/Chart.yaml").read(), re.M); BUNDLES.add(m.group(1).strip("\"'"))
W = ["tls.mode=wildcard", "tls.wildcardSecretName=wild-tls", "tls.wildcard.secretName=wild-tls"]; SEC = "wild-tls"; FAIL = 0; N = 0
def check(n, ok, why=""):
    global FAIL, N; N += 1; FAIL += (not ok); print(("  ok   " if ok else "  FAIL ") + n + ("" if ok else "  " + why[:500]))
def sources(out):
    res = []
    for d in yaml.safe_load_all(out):
        if not d or d.get("kind") != "Application": continue
        for s in (d["spec"].get("sources") or [d["spec"].get("source")]):
            if s and s.get("helm", {}).get("values") is not None: res.append((s.get("chart") or s.get("path") or "?", s["helm"]["values"]))
    return res
def active(txt): return "\n".join(l for l in txt.split("\n") if not l.lstrip().startswith("#") and not re.search(r":\s*null\s*$", l))
def classify(chart, vals):
    """None = nothing to do; (kind, text) otherwise. kind in covered / bundle / disabled / unused / GAP"""
    a = active(vals)
    if not REQ.search(a): return None
    if chart in BUNDLES:
        return ("bundle", "") if re.search(r"mode:\s*[\"']?wildcard", a) else ("GAP", f"{chart}: umbrella does not hand tls.mode=wildcard down")
    if chart in OUT_OF_SCOPE: return ("out-of-scope", OUT_OF_SCOPE[chart])
    base = chart.split("|")[0]
    if base in FAMILY:
        key = "existingTlsSecret"
        return ("covered", "") if re.search(rf"{key}:\s*[\"']?{SEC}", a) else ("GAP", f"{base}: leaf takes existingTlsSecret but the bundle did not set it")
    if re.search(r"ingress:\s*\n\s+enabled:\s*false", a): return ("disabled", "Ingress hard-disabled in the bundle")
    if base in UNUSED: return ("unused", UNUSED[base])
    return ("GAP", f"{base}: still passes an issuer and nothing in the bundle sets a shared secret for it")
def tally(out):
    t = {}; gaps = []
    for ch, v in sources(out):
        c = classify(ch, v)
        if c: t[c[0]] = t.get(c[0], 0) + 1; (c[0] == "GAP") and gaps.append(c[1])
    return t, gaps
for name in sorted(os.listdir(f"{BASE}/charts")):
    o, p = f"{BASE}/charts/{name}", f"{BASE}/patched/{name}"
    dirs = [x for x in os.listdir(o) if os.path.exists(f"{o}/{x}/Chart.yaml")]
    o2, p2 = f"{o}/{dirs[0]}", f"{p}/{dirs[0]}"
    print(name)
    ro, oo, eo = render(o2, []); rp, op, ep = render(p2, [])
    if ro != 0 and rp != 0: print("  skip:", eo[:120]); continue
    check("default render identical", (ro, oo) == (rp, op), ep or "differs")
    rw, ow, ew = render(p2, W)
    if rw != 0: check("wildcard mode renders", False, ew); continue
    t, gaps = tally(ow)
    check(f"wildcard: every source with an issuer is accounted for {t}", not gaps, "; ".join(gaps))
    ru, ou, _ = render(o2, W); tu, gu = tally(ou) if ru == 0 else ({}, [])
    n = t.get("covered", 0) + t.get("bundle", 0)
    if n: check("control: on the UNPATCHED chart those sources are GAPs", len(gu) >= n, f"only {len(gu)} gaps for {n}")
print(f"\n{N - FAIL}/{N} checks passed"); sys.exit(1 if FAIL else 0)
