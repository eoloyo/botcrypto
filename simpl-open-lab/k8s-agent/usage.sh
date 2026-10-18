#!/usr/bin/env bash
# usage.sh [namespace...] — memory and CPU each pod actually uses, next to what it requests. Prints TSV.
#
# metrics-server is off in this k3s, so this asks containerd (`crictl stats`) for each container's
# working set (the figure Kubernetes holds against memory limits) and cumulative CPU time, summed per
# pod. Under gVisor the RSS of a pod's runsc processes is NOT a usable substitute: the application's
# memory lives in a shared memory file outside them, and that RSS misses most of it.
# `crictl stats` times out while the node is saturated (e.g. during start-up), so it is retried.
set -uo pipefail
NSS=("${@:-authority01}")
C=k3s-gvisor
for _ in $(seq 1 10); do
  stats=$(timeout 90 docker exec $C crictl stats -o json 2>/dev/null) && [ -n "$stats" ] && break
  sleep 15
done
[ -n "${stats:-}" ] || { echo "crictl stats did not answer" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%s' "$stats" > "$tmp/stats.json"
for ns in "${NSS[@]}"; do docker exec $C kubectl -n "$ns" get pods -o json > "$tmp/pods-$ns.json"; done
python3 - "$tmp" <<'EOF'
import glob, json, os, sys
from collections import defaultdict

def mem(v):
    v = str(v)
    for k, m in {"Ki": 1/1024, "Mi": 1, "Gi": 1024, "M": 1, "G": 1000}.items():
        if v.endswith(k): return float(v[:-len(k)]) * m
    return float(v) / 2**20 if v else 0

def cpu(v):
    v = str(v); return float(v[:-1]) if v.endswith("m") else float(v or 0) * 1000

used = defaultdict(lambda: [0, 0])          # (ns, pod) -> [working set bytes, cpu ns]
for s in json.load(open(os.path.join(sys.argv[1], "stats.json")))["stats"]:
    lab = s["attributes"]["labels"]
    key = (lab.get("io.kubernetes.pod.namespace"), lab.get("io.kubernetes.pod.name"))
    used[key][0] += int(((s.get("memory") or {}).get("workingSetBytes") or {}).get("value", 0))
    used[key][1] += int(((s.get("cpu") or {}).get("usageCoreNanoSeconds") or {}).get("value", 0))

print("namespace\tpod\tworking_set_MiB\tcpu_s\treq_mem_MiB\tlim_mem_MiB\treq_cpu_m")
tot = [0, 0, 0]
for f in sorted(glob.glob(os.path.join(sys.argv[1], "pods-*.json"))):
    for p in json.load(open(f))["items"]:
        if p["status"].get("phase") != "Running": continue
        rq = rl = c = 0
        for ct in p["spec"]["containers"]:
            r = ct.get("resources") or {}
            rq += mem((r.get("requests") or {}).get("memory", 0))
            rl += mem((r.get("limits") or {}).get("memory", 0))
            c += cpu((r.get("requests") or {}).get("cpu", 0))
        ws, ns_cpu = used[(p["metadata"]["namespace"], p["metadata"]["name"])]
        tot[0] += ws // 2**20; tot[1] += rq; tot[2] += rl
        print(f'{p["metadata"]["namespace"]}\t{p["metadata"]["name"]}\t{ws // 2**20}\t{ns_cpu / 1e9:.1f}\t{int(rq)}\t{int(rl)}\t{int(c)}')
print(f"TOTAL\t\t{tot[0]}\t\t{int(tot[1])}\t{int(tot[2])}\t")
EOF
