import json, os, subprocess, collections, re, sys
rows = json.load(open("sources.json"))
uniq = collections.OrderedDict()
for r in rows: uniq.setdefault((r["chart"], str(r["version"]), r["repo"]), []).append(r["parent"])
ok = fail = 0; res = {}
for (chart, ver, repo), parents in uniq.items():
    d = f"pulled/{chart}-{ver}"
    if os.path.isdir(d) and os.listdir(d): res[f"{chart}|{ver}|{repo}"] = "ok"; ok += 1; continue
    os.makedirs(d, exist_ok=True)
    cmd = ["helm", "pull", chart, "--version", ver, "--untar", "--untardir", d]
    cmd += (["--repo", repo] if repo.startswith("http") else [repo + "/" + chart] if False else [])
    if repo.startswith("oci://"): cmd = ["helm", "pull", f"{repo}/{chart}", "--version", ver, "--untar", "--untardir", d]
    elif not repo.startswith("http"): cmd = ["helm", "pull", f"oci://{repo}/{chart}", "--version", ver, "--untar", "--untardir", d]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if p.returncode == 0: ok += 1; res[f"{chart}|{ver}|{repo}"] = "ok"
    else: fail += 1; res[f"{chart}|{ver}|{repo}"] = "FAIL " + (p.stderr.strip().splitlines() or ["?"])[-1][:120]
    print(f"{'ok  ' if p.returncode == 0 else 'FAIL'} {chart}-{ver}  <- {repo[:60]}" + ("" if p.returncode == 0 else "   " + res[f'{chart}|{ver}|{repo}'][5:]), flush=True)
json.dump(res, open("pulled.json", "w"), indent=1)
print(f"\npulled {ok}, failed {fail}")
