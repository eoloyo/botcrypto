#!/usr/bin/env python3
"""Render ArgoCD Applications the way ArgoCD would and tabulate workload resources.

usage: render_apps.py <rendered-parent.yaml> <workdir> [--out out.json]
For every Application (single or multi-source): helm-pull each chart source, collect its values
(inline values / valuesObject / valueFiles resolved from the `ref` git source at its revision),
`helm template` it into the Application's namespace and record, per workload container:
kind, name, replicas, requests/limits (cpu, memory)."""
import json, os, re, subprocess, sys, yaml

parent, work = sys.argv[1], sys.argv[2]
out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
os.makedirs(work, exist_ok=True)

def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def git_ref(url, rev):
    d = os.path.join(work, "git", re.sub(r"[^A-Za-z0-9]+", "_", url + "@" + rev))
    if not os.path.isdir(d):
        r = run(["git", "clone", "-q", "--depth", "1", "--branch", rev, url, d], env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
        if r.returncode:
            print(f"  ! git clone {url}@{rev}: {r.stderr.strip()[:200]}", file=sys.stderr)
    return d

def pull(repo, chart, ver):
    d = os.path.join(work, "charts", f"{chart}-{ver}")
    if not os.path.isdir(os.path.join(d, chart)):
        os.makedirs(d, exist_ok=True)
        cmd = ["helm", "pull", "--untar", "-d", d, "--version", str(ver)]
        cmd += [f"{repo}/{chart}"] if repo.startswith("oci://") else ["--repo", repo, chart]
        r = run(cmd)
        if r.returncode and "charts.bitnami.com" in repo:   # Bitnami moved its charts to OCI
            r = run(["helm", "pull", "--untar", "-d", d, "--version", str(ver), f"oci://registry-1.docker.io/bitnamicharts/{chart}"])
        if r.returncode:
            print(f"  ! helm pull {chart} {ver} from {repo}: {r.stderr.strip()[:200]}", file=sys.stderr)
            return None
    return os.path.join(d, chart)

def qty_cpu(v):
    if v in (None, ""): return None
    v = str(v)
    return float(v[:-1]) / 1000 if v.endswith("m") else float(v)

def qty_mem(v):
    if v in (None, ""): return None
    v = str(v); units = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}
    for u, f in units.items():
        if v.endswith(u): return float(v[: -len(u)]) * f / 2**20
    return float(v) / 2**20

rows = []
kinds = {}
apps = [d for d in yaml.safe_load_all(open(parent)) if d and d.get("kind") == "Application"]
seen = set()
while apps:
    app = apps.pop(0)
    key = json.dumps(app.get("spec"), sort_keys=True, default=str)
    if key in seen: continue
    seen.add(key)
    spec = app["spec"]; ns = (spec.get("destination") or {}).get("namespace") or "default"
    sources = spec.get("sources") or [spec.get("source")]
    refs = {s["ref"]: git_ref(s["repoURL"], s.get("targetRevision", "HEAD")) for s in sources if s and s.get("ref")}
    for s in sources:
        if not s or not s.get("chart"):
            continue
        name = s.get("chart"); helm = s.get("helm") or {}
        rel = helm.get("releaseName") or name
        cdir = pull(s["repoURL"], name, s.get("targetRevision"))
        if not cdir:
            rows.append({"app": app["metadata"].get("name"), "chart": name, "error": "pull failed"}); continue
        args = ["helm", "template", rel, cdir, "-n", ns]
        for vf in helm.get("valueFiles", []):
            m = re.match(r"\$(\w+)/(.*)", vf)
            p = os.path.join(refs.get(m.group(1), ""), m.group(2)) if m else os.path.join(cdir, vf)
            if os.path.isfile(p): args += ["-f", p]
            else: print(f"  ! {name}: missing values file {vf}", file=sys.stderr)
        if helm.get("values"):
            p = os.path.join(work, f"v-{rel}-inline.yaml"); open(p, "w").write(helm["values"]); args += ["-f", p]
        if helm.get("valuesObject"):
            p = os.path.join(work, f"v-{rel}-obj.yaml"); yaml.safe_dump(helm["valuesObject"], open(p, "w")); args += ["-f", p]
        for prm in helm.get("parameters", []):
            args += ["--set-string", f"{prm['name']}={prm['value']}"]
        r = run(args)
        if r.returncode:
            print(f"  ! helm template {name}: {r.stderr.strip()[:300]}", file=sys.stderr)
            rows.append({"app": app["metadata"].get("name"), "chart": name, "error": "template failed"}); continue
        docs = [d for d in yaml.safe_load_all(r.stdout) if d]
        open(os.path.join(work, f"out-{rel}.yaml"), "w").write(r.stdout)
        for d in docs: kinds[(name, d.get("kind"))] = kinds.get((name, d.get("kind")), 0) + 1
        apps += [d for d in docs if d.get("kind") == "Application"]   # nested app-of-apps
        for d in docs:
            if not d or d.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"): continue
            pod = d["spec"]["jobTemplate"]["spec"]["template"] if d["kind"] == "CronJob" else d["spec"].get("template", {})
            replicas = d["spec"].get("replicas", 1) if d["kind"] in ("Deployment", "StatefulSet") else 1
            for c in (pod.get("spec", {}).get("containers") or []):
                res = c.get("resources") or {}
                rq, lm = res.get("requests") or {}, res.get("limits") or {}
                env = {e.get("name"): e.get("value") for e in (c.get("env") or [])}
                rows.append({"app": app["metadata"].get("name"), "chart": name, "kind": d["kind"],
                             "workload": d["metadata"]["name"], "container": c["name"], "replicas": replicas,
                             "image": c.get("image"),
                             "req_cpu": qty_cpu(rq.get("cpu")), "req_mem": qty_mem(rq.get("memory")),
                             "lim_cpu": qty_cpu(lm.get("cpu")), "lim_mem": qty_mem(lm.get("memory")),
                             "java_opts": env.get("JAVA_OPTS") or env.get("JAVA_TOOL_OPTIONS"),
                             "probe_delay": ((c.get("readinessProbe") or {}).get("initialDelaySeconds")),
                             "startup_probe": bool(c.get("startupProbe"))})
if out:
    json.dump(rows, open(out, "w"), indent=1)
    json.dump({f"{c}|{k}": n for (c, k), n in kinds.items()}, open(out + ".kinds", "w"), indent=1)
f = lambda v, d=0: "-" if v is None else f"{v:.{d}f}"
print(f"{'chart/workload':52} {'kind':11} {'rep':>3} {'reqCPU':>6} {'reqMiB':>7} {'limCPU':>6} {'limMiB':>7} {'delay':>5}")
for r in rows:
    if "error" in r: print(f"{r['chart'][:52]:52} {r['error']}"); continue
    if r["kind"] in ("Job", "CronJob"): continue
    print(f"{(r['chart'] + '/' + r['workload'] + '/' + r['container'])[:52]:52} {r['kind']:11} {r['replicas']:>3} "
          f"{f(r['req_cpu'],2):>6} {f(r['req_mem']):>7} {f(r['lim_cpu'],2):>6} {f(r['lim_mem']):>7} {str(r['probe_delay'] or '-'):>5}")
ok = [r for r in rows if "error" not in r and r["kind"] not in ("Job", "CronJob")]
tot = lambda k: sum((r[k] or 0) * r["replicas"] for r in ok)
print(f"TOTAL long-running containers: {len(ok)}  requests {tot('req_cpu'):.2f} CPU / {tot('req_mem')/1024:.1f} GiB"
      f"   limits {tot('lim_cpu'):.2f} CPU / {tot('lim_mem')/1024:.1f} GiB")
