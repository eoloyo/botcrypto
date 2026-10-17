#!/usr/bin/env bash
# Resource footprint of the running mesh: per service RSS, PSS, anonymous (dirty) memory, CPU time, threads, startup time,
# loaded classes and artifact size. Works for JVM and native processes (PID is found from the
# listening port). Run it after 07 (and the tests you want included in the CPU figure).
#   Usage: ./14-footprint.sh [label]      -> also writes $LAB_ROOT/run/footprint-<label>.tsv
source "$(dirname "$0")/env.sh"; set +e
RUN="$LAB_ROOT/run"; LABEL="${1:-now}"
python3 -I - "$RUN/mesh.log" "$RUN/catalogue.log" "$RUN/footprint-$LABEL.tsv" "$LAB_ROOT" <<'EOF'
import os, re, sys, glob, subprocess
meshlog, catlog, out, lab = sys.argv[1:5]
SVCS = [("identity-provider", 8103, "IdentityProviderApplication"),
        ("auth-provider GA", 8105, "AuthenticationProviderApplication"),
        ("auth-provider participant", 8104, "AuthenticationProviderApplication"),
        ("security-attributes-provider", 8102, "SecurityAttributesProviderApplication"),
        ("tier2-gateway", 8443, "Tier2GatewayApplication"), ("sd-tooling-be", 8090, "SdToolingBeApplication"),
        ("fc-service (catalogue)", 8081, "CatalogueServerApplication")]
def listen_inodes():
    m = {}
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            for line in open(f).readlines()[1:]:
                p = line.split()
                if p[3] == "0A": m.setdefault(int(p[1].rsplit(":", 1)[1], 16), set()).add(p[9])
        except OSError: pass
    return m
def pid_for(inodes):
    for d in glob.glob("/proc/[0-9]*/fd"):
        try:
            for fd in os.listdir(d):
                l = os.readlink(f"{d}/{fd}")
                if l.startswith("socket:[") and l[8:-1] in inodes: return int(d.split("/")[2])
        except OSError: pass
def status(pid, key):
    for l in open(f"/proc/{pid}/status"):
        if l.startswith(key + ":"): return int(l.split()[1])
def rollup(pid, key):
    try:
        for l in open(f"/proc/{pid}/smaps_rollup"):
            if l.startswith(key + ":"): return int(l.split()[1]) // 1024
    except OSError: return None
def cpu(pid):
    f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK")
def cmdline(pid): return open(f"/proc/{pid}/cmdline").read().split("\0")
def started(pid, main):
    # seconds from process start to "Started": the line carrying this PID, else (JSON / logback
    # formats without a PID) the last "Started <main class>" line in the logs
    rx = re.compile(r"Started %s in [0-9.]+ seconds \(process running for ([0-9.]+)\)" % main)
    last = None
    for f in (meshlog, catlog):
        try:
            for l in open(f, errors="replace"):
                m = rx.search(l)
                if not m: continue
                if re.search(r"\b%d --- " % pid, l): return float(m.group(1))
                if " --- " not in l: last = float(m.group(1))
        except OSError: pass
    return last
def classes(pid, exe):
    if not exe.endswith("java"): return None
    try:
        o = subprocess.run(["jcmd", str(pid), "PerfCounter.print"], capture_output=True, text=True, timeout=20).stdout
        v = dict(re.findall(r"^(java\.cls\.(?:loadedClasses|sharedLoadedClasses|unloadedClasses))=(\d+)", o, re.M))
        return int(v.get("java.cls.loadedClasses", 0)) + int(v.get("java.cls.sharedLoadedClasses", 0)) - int(v.get("java.cls.unloadedClasses", 0))
    except Exception: return None
def artifact(cl):
    if "-jar" in cl:
        j = cl[cl.index("-jar") + 1]
        d = os.path.dirname(j); libs = glob.glob(f"{d}/lib/*.jar") or []
        src = open(f"{d}/.src").read().strip() if os.path.exists(f"{d}/.src") else j
        return os.path.getsize(src) // 2**20 if os.path.exists(src) else None, len(libs) or None
    return (os.path.getsize(cl[0]) // 2**20, None) if os.path.exists(cl[0]) else (None, None)
lis = listen_inodes(); rows = []
for name, port, main in SVCS:
    pid = pid_for(lis.get(port, set()))
    if not pid: rows.append((name, port) + (None,) * 11); continue
    cl = cmdline(pid); kind = "jvm" if cl[0].endswith("java") else "native"
    size, libs = artifact(cl)
    rows.append((name, port, pid, kind, started(pid, main), status(pid, "VmRSS") // 1024, rollup(pid, "Pss"),
                 rollup(pid, "Pss_Anon"), round(cpu(pid), 1),
                 status(pid, "Threads"), classes(pid, cl[0]), size, libs))
hdr = ("service", "port", "pid", "kind", "ready_s", "rss_mb", "pss_mb", "anon_mb", "cpu_s", "threads", "classes", "artifact_mb", "lib_jars")
fmt = lambda v: "-" if v is None else str(v)
with open(out, "w") as f:
    f.write("\t".join(hdr) + "\n")
    for r in rows: f.write("\t".join(fmt(v) for v in r) + "\n")
w = [28, 5, 7, 6, 8, 6, 6, 7, 6, 7, 7, 11, 8]
print(" ".join(h.ljust(x) for h, x in zip(hdr, w)))
for r in rows: print(" ".join(fmt(v).ljust(x) for v, x in zip(r, w)))
tot = lambda i: sum(r[i] for r in rows if isinstance(r[i], (int, float)))
print(f"TOTAL  RSS {tot(5)} MB   PSS {tot(6)} MB   anon {tot(7)} MB   CPU {tot(8):.1f} s   threads {tot(9)}   (written to {out})")
EOF
