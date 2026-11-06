import json, os, re, subprocess, yaml, collections
import os; INV = os.environ.get("INV", "/root/simpl-open-lab-work/wildcard-poc/inv"); R = f"{INV}/charts"; meta = json.load(open(f"{INV}/meta.json"))
SETS = []
for k in ("participant","consumer","dataprovider","authority","common","infrastructureprovider","applicationprovider"):
    SETS += ["--set", f"namespaceTag.{k}=ns{k[:4]}"]
SETS += ["--set", "cluster.namespace=nsx", "--set", "cluster.commonToolsNamespace=nscommon", "--set", "domainSuffix=example.test", "--set", "authorityDomainSuffix=example.test"]
def norm(d):
    p = f"{d}/Chart.yaml"
    if os.path.exists(p):
        txt = open(p).read()   # read BEFORE opening for write (opening for write truncates the file)
        open(p, "w").write(re.sub(r"^(version|appVersion): .*PROJECT_RELEASE_VERSION.*$", r'\1: "0.0.0-poc"', txt, flags=re.M))
rows = []; unrendered = []
for name, m in meta.items():
    d = f"{R}/{name}/charts"
    if not os.path.isdir(d): d = f"{R}/{name}"
    norm(d)
    extra = ["--set", "type=data-provider"] if "provider" in name else []
    p = subprocess.run(["helm", "template", "x", d, "--namespace", "nsx", *SETS, *extra], capture_output=True, text=True)
    if p.returncode != 0: unrendered.append((name, p.stderr.strip().splitlines()[-1][:150])); continue
    docs = [x for x in yaml.safe_load_all(p.stdout) if x]
    ing = [x for x in docs if x.get("kind") == "Ingress"]
    for a in [x for x in docs if x.get("kind") == "Application"]:
        for s in (a["spec"].get("sources") or [a["spec"].get("source")]):
            if not s or "chart" not in s: continue
            v = yaml.safe_load((s.get("helm") or {}).get("values") or "{}") or {}
            rows.append({"parent": name, "chart": s["chart"], "version": s.get("targetRevision"), "repo": s.get("repoURL"), "values": v})
    print(f"{name:38s} rendered: {len(docs):3d} objects, {len(ing)} inline Ingress, {sum(1 for r in rows if r['parent']==name)} chart sources")
json.dump(rows, open(f"{INV}/sources.json", "w"), indent=1, default=str)
print("\nNOT RENDERED:", *(f"\n  {n}: {e}" for n, e in unrendered)) if unrendered else print("\nall rendered")
uniq = collections.OrderedDict(); [uniq.setdefault((r["chart"], str(r["version"]), r["repo"]), []).append(r["parent"]) for r in rows]
print(f"\n{len(rows)} chart sources, {len(uniq)} distinct (chart, version, repo)")
