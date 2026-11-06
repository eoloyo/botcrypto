#!/usr/bin/env python3
"""components_check.py — render every patched component chart (helm template) original vs patched.
 default : output identical to the original chart (random passwords and the chart's own checksum/values hash are
           normalised; for monitoring-proxy the hash legitimately changes because the chart hashes values.yaml)
 wildcard: every Ingress that requested a certificate in the default render (active cert-manager annotation, public
           host) now has no cert-manager annotation and uses the shared Secret
 control : the same check on the UNPATCHED chart must fail (proves the check can fail)"""
import os, re, subprocess, sys, shutil, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from components_wildcard import FAMILY, BASE
SRC, DST = f"{BASE}/pulled", f"{BASE}/pulled-patched"
SECRET = "wild-tls"; FAIL = 0; N = 0
EXTRA = {"eck-monitoring": ["namespaceTag=common01", "mainNamespace=common01", "kibana.count=1"]}
NORM = re.compile(r"^(\s*)(.*(?:password|authorization|checksum/[\w-]+|token|secret)\w*:).*$", re.I)
def render(cdir, sets):
    tmp = tempfile.mkdtemp(); c = f"{tmp}/c"; shutil.copytree(cdir, c)
    y = open(f"{c}/Chart.yaml").read().replace("${PROJECT_RELEASE_VERSION}", "0.0.0"); open(f"{c}/Chart.yaml", "w").write(y)
    args = ["helm", "template", "rel", c, "-n", "ns", "--set", ",".join(["domainSuffix=x.example", "ingress.enabled=true", "ingress.host=h.x.example"] + sets)]
    r = subprocess.run(args, capture_output=True, text=True); shutil.rmtree(tmp, ignore_errors=True)
    return r.returncode, r.stdout, r.stderr
def norm(out): return "\n".join(NORM.sub(r"\1\2 <norm>", l) if NORM.match(l) and "secretName" not in l else l for l in out.split("\n"))
def check(name, ok, why=""):
    global FAIL, N; N += 1; FAIL += (not ok)
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else f"  {why[:300]}"))
def ingresses(out):
    res = {}
    for d in re.split(r"\n---\n", out):
        if not re.search(r"^kind:\s*Ingress\b", d, re.M): continue
        live = "\n".join(l for l in d.split("\n") if not l.lstrip().startswith("#"))
        name = re.search(r"^  name:\s*(\S+)", live, re.M).group(1)
        res[name] = {"cm": bool(re.search(r"cert-manager\.io/cluster-issuer", live)),
                     "secrets": [s.strip("\"'") for s in re.findall(r"secretName:\s*(\S+)", live)]}
    return res
def wild_ok(base, out):
    ing = ingresses(out); need = [n for n, v in base.items() if v["cm"]]
    bad = [n for n in need if n not in ing or ing[n]["cm"] or not ing[n]["secrets"] or any(s != SECRET for s in ing[n]["secrets"])]
    return (not bad and bool(need)), f"still per-host: {bad}"
for d in sorted(os.listdir(DST)):
    for name, fam in FAMILY.items():
        if not re.fullmatch(re.escape(name) + r"-\d.*", d): continue
        o, p = f"{SRC}/{d}/{name}", f"{DST}/{d}/{name}"
        if not os.path.isdir(o): continue
        key = "ingress.existingTlsSecret" if fam == "ingress" else "existingTlsSecret"; ex = EXTRA.get(name, [])
        print(d)
        ro, oo, eo = render(o, ex); rp, op, ep = render(p, ex)
        if ro != 0 and rp != 0: print("  skip (does not render with generic values)"); continue
        check("default render identical to original", ro == rp and norm(oo) == norm(op), ep or "differs")
        base = ingresses(oo)
        if not any(v["cm"] for v in base.values()): print("  no cert-requesting Ingress in default render: wildcard check not applicable"); continue
        rw, ow, ew = render(p, ex + [f"{key}={SECRET}"])
        ok, why = wild_ok(base, ow) if rw == 0 else (False, ew)
        check(f"wildcard: all {sum(v['cm'] for v in base.values())} cert-requesting Ingress(es) use the shared Secret, no annotation", ok, why)
        ru, ou, _ = render(o, ex + [f"{key}={SECRET}"])
        check("control: same check FAILS on the unpatched chart", not (ru == 0 and wild_ok(base, ou)[0]))
print(f"\n{N - FAIL}/{N} checks passed"); sys.exit(1 if FAIL else 0)
