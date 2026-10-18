#!/usr/bin/env python3
"""cpu-report.py <samples.tsv> <threads.tsv> <t0 epoch> [cores] — where the start-up CPU went.

samples.tsv / threads.tsv come from cpu-profile.sh (sample during the deploy, threads at the end).
Prints Markdown tables:
  1. CPU-seconds per component from t0 to the last sample, and k3s/containerd's own share;
  2. the same per time window, against what the node could give (cores x seconds);
  3. inside each JVM: JIT compiler threads, GC threads, application threads, and threads that have
     exited (process total minus live threads), from /proc inside the sandbox;
  4. gVisor's own cost: the pod's cgroup CPU minus the CPU its processes report inside the sandbox.
"""
import csv
import re
import sys
from collections import defaultdict

samples, threads, t0 = sys.argv[1], sys.argv[2], int(sys.argv[3])
cores = int(sys.argv[4]) if len(sys.argv) > 4 else 4
HZ = 100   # clock ticks per second in /proc/*/stat (gVisor and Linux)


def component(pod):
    """keycloak-0, users-roles-67864cd654-z9xvw -> users-roles, initialization-authority-x-y -> init-authority"""
    if pod.startswith("initialization-authority"):
        return "init-authority (Job)"
    if pod.startswith("authentication-provider-create-secret"):
        return "create-secret (Job)"
    if pod.startswith("fe-"):               # fe-<service>-...: long names get cut at 63 characters
        return "fe-" + pod.split("-")[1]
    pod = re.sub(r"(-[a-z0-9]{8,10})?-[a-z0-9]{5}$", "", pod)
    return re.sub(r"-0$", "", pod)


# --- 1/2: cgroup samples ---------------------------------------------------------------------
series = defaultdict(dict)      # key -> {t: cpu_ns}
for r in csv.DictReader(open(samples), delimiter="\t"):
    t = int(r["t"])
    if t < t0:
        continue
    key = r["pod"] if r["kind"] == "total" else f'{r["ns"]}/{r["pod"]}'
    series[key][t] = int(r["cpu_ns"] or 0)
times = sorted({t for s in series.values() for t in s})
end = times[-1]
# series present in the first sample existed before t0 (old pods of a restart, Postgres, Kafka, the
# totals): count them from that sample, not from zero
base = {k: s[min(s)] for k, s in series.items() if min(s) == times[0]}


def used(key, a, b):
    """CPU-seconds of a series between times a and b (pods created after a start from zero)."""
    s = series[key]
    ts = sorted(s)
    va = next((s[t] for t in reversed(ts) if t <= a), 0 if key not in base else s[ts[0]])
    vb = next((s[t] for t in reversed(ts) if t <= b), 0)
    return max(0, vb - va) / 1e9


per_comp = defaultdict(float)
pods = [k for k in series if "/" in k]
for k in pods:
    per_comp[component(k.split("/", 1)[1]) if k.startswith("authority01") else k.split("/", 1)[1].rsplit("-", 2)[0]] += used(k, t0, end)
total_node = used("k3s-container", t0, end)
total_pods = used("kubepods", t0, end)
wall = end - t0

print(f"## CPU from apply to the last sample ({wall} s, node capacity {cores * wall} CPU-s)\n")
print("| Component | CPU-s | Share |\n|---|---|---|")
for c, v in sorted(per_comp.items(), key=lambda x: -x[1]):
    print(f"| {c} | {v:.0f} | {100 * v / total_node:.1f}% |")
print(f"| _k3s, containerd, runsc shims (outside pods)_ | {total_node - total_pods:.0f} | {100 * (total_node - total_pods) / total_node:.1f}% |")
print(f"| **Total** | **{total_node:.0f}** | node busy {100 * total_node / (cores * wall):.0f}% of the time |\n")

# per window
edges = [0, 60, 120, 240, 360, 480, 600, 780, 960, 1200, 1800, 3600]
edges = [e for e in edges if e < wall] + [wall]
top = [c for c, _ in sorted(per_comp.items(), key=lambda x: -x[1])[:8]]
print("## When it was spent (CPU-s per window; the node can give "
      f"{cores} CPU-s per second)\n")
print("| Window (s) | Node busy | " + " | ".join(top) + " | other |")
print("|---" * (len(top) + 3) + "|")
for a, b in zip(edges, edges[1:]):
    row = defaultdict(float)
    for k in pods:
        c = component(k.split("/", 1)[1]) if k.startswith("authority01") else k.split("/", 1)[1].rsplit("-", 2)[0]
        row[c if c in top else "other"] += used(k, t0 + a, t0 + b)
    node = used("k3s-container", t0 + a, t0 + b)
    print(f"| {a}–{b} | {100 * node / (cores * (b - a)):.0f}% | " +
          " | ".join(f"{row[c]:.0f}" for c in top) + f" | {row['other']:.0f} |")
print()

# --- 3/4: JVM threads ------------------------------------------------------------------------
CATS = [("JIT compiler", re.compile(r"^(C1|C2) CompilerThre")),
        ("GC", re.compile(r"^(GC Thread|G1 |VM Thread|ParGC|Parallel GC|GC task)")),
        ("JVM other", re.compile(r"^(VM Periodic|Signal Disp|Service Thre|Reference Han|Finalizer|Common-Clean|Notification|Monitor Defl|Sweeper|Attach Listener)"))]
jvm = defaultdict(lambda: defaultdict(float))
for r in csv.reader(open(threads), delimiter="\t"):
    if r[0] == "ns":
        continue
    ns, pod, pid, line = r[0], r[1], r[2], r[3]
    proc = line.startswith("PROCESS ")
    line = line[len("PROCESS "):] if proc else line
    if "(" not in line:                     # a thread that exited while it was being read
        continue
    name = line[line.index("(") + 1:line.rindex(")")]
    f = line[line.rindex(")") + 2:].split()
    secs = (int(f[11]) + int(f[12])) / HZ
    comp = component(pod) if ns == "authority01" else pod.rsplit("-", 2)[0]
    if proc:
        jvm[comp]["_process"] += secs
        continue
    cat = next((c for c, rx in CATS if rx.match(name)), "application")
    jvm[comp][cat] += secs

print("## Inside the JVMs (CPU-s since each JVM started, from /proc in the sandbox)\n")
print("| JVM | Process total | JIT compiler | GC | JVM other | Application (live threads) | Exited threads | Pod cgroup | gVisor + rest of pod |")
print("|---|---|---|---|---|---|---|---|---|")
for comp, d in sorted(jvm.items(), key=lambda x: -x[1]["_process"]):
    live = sum(v for k, v in d.items() if not k.startswith("_"))
    pod_cg = per_comp.get(comp, 0)
    print(f"| {comp} | {d['_process']:.0f} | {d['JIT compiler']:.0f} ({100 * d['JIT compiler'] / max(d['_process'], 1):.0f}%) "
          f"| {d['GC']:.0f} | {d['JVM other']:.0f} | {d['application']:.0f} | {max(0, d['_process'] - live):.0f} "
          f"| {pod_cg:.0f} | {pod_cg - d['_process']:.0f} |")
print("\n_Pod cgroup_ counts everything the pod ran since apply (init containers, restarts, gVisor's "
      "Sentry and gofer); _process total_ only the JVM running at the end. For a pod that never "
      "restarted and has no init container, the difference is gVisor's own cost.")
