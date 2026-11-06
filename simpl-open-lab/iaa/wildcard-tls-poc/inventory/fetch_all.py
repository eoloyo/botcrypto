import json, os, re, subprocess, sys, urllib.parse, urllib.request
API = "https://code.europa.eu/api/v4"; INV = os.environ.get("INV", "/root/simpl-open-lab-work/wildcard-poc/inv"); OUT = f"{INV}/charts"
CHARTS = [  # (project id, name, role)
 (2271,"consumer-agent-chart","umbrella"),(2279,"data-provider-agent-chart","umbrella"),(2272,"governance-authority-agent-chart","umbrella"),
 (2280,"application-provider-agent-chart","umbrella"),(2281,"infrastructure-provider-agent-chart","umbrella"),
 (2233,"authority-iaa-chart","bundle"),
 (2234,"consumer-iaa","bundle"),(2103,"consumer-gaia-x-edc","bundle"),(2063,"consumer-data1","bundle"),(2040,"consumer-contract-billing","bundle"),(1955,"consumer-infrastructure","bundle"),(2060,"consumer-monitoring","bundle"),
 (2236,"dataprovider-iaa","bundle"),(2105,"dataprovider-gaia-x-edc","bundle"),(2064,"dataprovider-data1","bundle"),(2041,"dataprovider-contract-billing","bundle"),(2126,"dataprovider-infrastructure","bundle"),(2061,"dataprovider-monitoring","bundle"),(2075,"dataprovider-orchestration-platform","bundle"),
 (2270,"common-components-chart","common")]
def get(u, raw=False):
    with urllib.request.urlopen(u, timeout=60) as r:
        b = r.read().decode(); return b if raw else json.loads(b)
meta = {}
for pid, name, role in CHARTS:
    try:
        sha = get(f"{API}/projects/{pid}/repository/commits/main")["id"]
        tree = get(f"{API}/projects/{pid}/repository/tree?path=charts&recursive=true&per_page=100&ref={sha}")
        page = 2
        while len(tree) % 100 == 0 and len(tree) > 0 and page < 6:   # paginate
            more = get(f"{API}/projects/{pid}/repository/tree?path=charts&recursive=true&per_page=100&ref={sha}&page={page}")
            if not more: break
            tree += more; page += 1
        n = 0
        for t in tree:
            if t["type"] != "blob": continue
            dst = f"{OUT}/{name}/{t['path']}"; os.makedirs(os.path.dirname(dst), exist_ok=True)
            open(dst, "w").write(get(f"{API}/projects/{pid}/repository/files/{urllib.parse.quote(t['path'], safe='')}/raw?ref={sha}", raw=True)); n += 1
        meta[name] = {"id": pid, "role": role, "sha": sha, "files": n}
        print(f"{name:40s} {role:9s} {sha[:10]} {n} files", flush=True)
    except Exception as e:
        print(f"{name:40s} FAILED {e}", flush=True)
json.dump(meta, open(f"{INV}/meta.json", "w"), indent=1)
