#!/usr/bin/env python3
"""leaves_check.py — full chain, render level. For each of the 18 umbrella/bundle charts (patched), render in wildcard mode, take every
Application source (chart + the values the bundle passes), render that leaf chart (patched version when we patch it) with those values and
look at what its Ingress objects serve:
   covered   every TLS secretName of every Ingress is the shared Secret and no cert-manager annotation remains
   no-ingress the chart renders no Ingress with these values (disabled / absent)
   GAP       an Ingress still names another secret or still asks cert-manager for a certificate
Values the bundle keeps in ArgoCD valueFiles ($values repo) are not visible here: that is a limit of this check."""
import os, re, subprocess, sys, shutil, tempfile, yaml, json, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "bundles_check.py")).read().split("OUT_OF_SCOPE =")[0].split("import yaml")[0])
from components_wildcard import FAMILY
BUNDLES_ALL = set()
for _n in os.listdir(f"{BASE}/charts"):
    for _x in os.listdir(f"{BASE}/charts/{_n}"):
        if os.path.exists(f"{BASE}/charts/{_n}/{_x}/Chart.yaml"): BUNDLES_ALL.add(re.search(r"^name:\s*(\S+)", open(f"{BASE}/charts/{_n}/{_x}/Chart.yaml").read(), re.M).group(1).strip("\"'"))
BUNDLES_ALL |= {"authority-gaia-x-edc", "authority-monitoring"}
CONTROL = os.environ.get("CONTROL") == "1"   # CONTROL=1: run the same check on the UNPATCHED charts; it must report gaps
PB, PL = ("charts", "pulled") if CONTROL else ("patched", "pulled-patched")
SEC = "wild-tls"; W = ["tls.mode=wildcard", "tls.wildcardSecretName=wild-tls", "tls.wildcard.secretName=wild-tls"]
def find_chart(name, ver):
    for root in (f"{BASE}/{PL}", f"{BASE}/pulled"):
        for cand in (f"{name}-{ver}", ):
            if os.path.isdir(f"{root}/{cand}/{name}"): return f"{root}/{cand}/{name}"
        for d in sorted(os.listdir(root)):
            if d.startswith(name + "-") and os.path.isdir(f"{root}/{d}/{name}") and re.fullmatch(re.escape(name) + r"-\d.*", d): return f"{root}/{d}/{name}"
def leaf(chart_dir, values):
    tmp = tempfile.mkdtemp(); c = f"{tmp}/c"; shutil.copytree(chart_dir, c)
    p = f"{c}/Chart.yaml"; y = open(p).read().replace("${PROJECT_RELEASE_VERSION}", "0.0.0"); open(p, "w").write(y)
    try: yaml.safe_load(values)
    except Exception: shutil.rmtree(tmp); return None, "values do not parse"
    open(f"{tmp}/v.yaml", "w").write(values)
    r = subprocess.run(["helm", "dependency", "build", c], capture_output=True, text=True) if os.path.exists(f"{c}/Chart.lock") and not os.path.isdir(f"{c}/charts") else None
    r = subprocess.run(["helm", "template", "rel", c, "-n", "ns", "-f", f"{tmp}/v.yaml", "--skip-schema-validation"], capture_output=True, text=True)
    shutil.rmtree(tmp, ignore_errors=True); return r.stdout if r.returncode == 0 else None, r.stderr[:160].replace("\n", " ")
def judge(out):
    """covered: every Ingress that requests a certificate now uses the shared Secret and has no cert-manager annotation.
    Not a certificate request (cert-manager's ingress-shim only acts on an Ingress with a `tls:` secretName AND the annotation):
      no-tls      the Ingress has no tls secretName (annotation without tls does nothing)
      own-secret  a tls secret but no cert-manager annotation (pre-provisioned or internal CA): not touched, listed separately"""
    ing = [d for d in re.split(r"\n---\n", out) if re.search(r"^kind:\s*Ingress\b", d, re.M)]
    if not ing: return "no-ingress", ""
    bad = []; kinds = set()
    for d in ing:
        live = "\n".join(l for l in d.split("\n") if not l.lstrip().startswith("#"))
        secs = [s.strip("\"'") for s in re.findall(r"secretName:\s*(\S+)", live)]
        cm = bool(re.search(r"cert-manager\.io/cluster-issuer", live)) and not re.search(r"cert-manager\.io/cluster-issuer:\s*null", live)
        nm = re.search(r"^  name:\s*(\S+)", live, re.M).group(1)
        if re.search(r"cert-manager\.io/cluster-issuer:\s*null", live): bad.append(f"{nm}: renders a literal null annotation")
        elif not secs: kinds.add("no-tls")
        elif cm or (any(x != SEC for x in secs) and cm): bad.append(f"{nm} secrets={secs} cm={cm}")
        elif any(x != SEC for x in secs): kinds.add("own-secret:" + nm)
        else: kinds.add("covered")
    if bad: return "GAP", "; ".join(bad)
    return ("covered" if "covered" in kinds else sorted(kinds)[0].split(":")[0]), ", ".join(sorted(k for k in kinds if k != "covered"))
tally = collections.Counter(); gaps = []; notes = []; skipped_names = []; skipped = collections.Counter(); seen = set()
for name in sorted(os.listdir(f"{BASE}/{PB}")):
    d = f"{BASE}/{PB}/{name}"; sub = [x for x in os.listdir(d) if os.path.exists(f"{d}/{x}/Chart.yaml")][0]
    rc, out, _ = render(f"{d}/{sub}", W)
    if rc != 0: continue
    for doc in yaml.safe_load_all(out):
        if not doc or doc.get("kind") != "Application": continue
        for s in (doc["spec"].get("sources") or [doc["spec"].get("source")]):
            ch = s.get("chart"); vals = (s.get("helm") or {}).get("values")
            if not ch or vals is None or ch in BUNDLES_ALL: continue
            key = (ch, s.get("targetRevision"), vals)
            if key in seen: continue
            seen.add(key); cd = find_chart(ch, s.get("targetRevision"))
            if not cd: skipped["chart not pulled"] += 1; skipped_names.append(f"{name} -> {ch} {s.get('targetRevision')}: chart not pulled"); continue
            o, why = leaf(cd, vals)
            if o is None: skipped[why[:60]] += 1; skipped_names.append(f"{name} -> {ch}: {why[:110]}"); continue
            k, w = judge(o); tally[k] += 1
            if k in ("own-secret", "no-tls") or (k == "covered" and w): notes.append(f"{name} -> {ch}: {w}")
            if k == "GAP": gaps.append(f"{name} -> {ch}: {w}")
print("leaf renders:", dict(tally), "| not rendered:", dict(skipped))
for n_ in skipped_names: print("  not rendered", n_)
for n_ in notes: print("  note", n_[:300])
for g in gaps: print("  GAP", g[:300])
print("OK" if not gaps else f"{len(gaps)} GAP(s)"); sys.exit((0 if gaps else 1) if CONTROL else (1 if gaps else 0))
