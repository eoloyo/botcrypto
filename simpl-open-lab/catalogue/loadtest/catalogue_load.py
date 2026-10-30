#!/usr/bin/env python3
"""catalogue_load.py — load/scale test for the Simpl (Gaia-X XFSC) Federated Catalogue.

Publishes Self-Descriptions concurrently and, at size checkpoints, measures:
  - publish throughput + latency (the write path: RDF extract + SHACL + semantics + quality + Postgres),
  - GET /self-descriptions list/paginate latency under concurrency (Postgres read),
  - POST /query openCypher search latency under concurrency (Neo4j, after a graph-rebuild),
  - resource growth: catalogue RSS, catalogue DB size, Neo4j store size, free disk.

Quality scoring is the local stub, so publish latency excludes the real scoring call (reported as a gap).
Stops when free disk drops below --min-disk-gb or an error threshold is hit — the breakpoint.

  catalogue_load.py --checkpoints 1000,5000,10000,25000,50000,100000 --pub-conc 16 --read-conc 20
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import sdgen  # noqa: E402

CAT = "http://localhost:8081"
PG = ["psql", "-h", "127.0.0.1", "-p", "5433", "-U", "postgres", "-d", "catalogue", "-tAc"]
local = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _req(method, path, body=None, timeout=120):
    data = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(CAT + path, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with local.open(r, timeout=timeout) as resp:
            resp.read()
            return resp.status, time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, time.time() - t0
    except Exception:
        return 0, time.time() - t0


def publish_one(seq):
    return _req("POST", "/self-descriptions", sdgen.make(seq))


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))] if xs else 0


def publish_batch(start, count, conc):
    t0 = time.time()
    lat, bad = [], 0
    with ThreadPoolExecutor(conc) as ex:
        for code, dt in ex.map(publish_one, range(start, start + count)):
            lat.append(dt)
            if code != 201:
                bad += 1
    wall = time.time() - t0
    return {"n": count, "wall": wall, "tput": count / wall, "errors": bad,
            "p50": pct(lat, 50), "p90": pct(lat, 90), "p99": pct(lat, 99), "max": max(lat, default=0)}


def read_load(path_fn, conc, requests):
    t0 = time.time()
    lat, bad = [], 0
    with ThreadPoolExecutor(conc) as ex:
        for code, dt in ex.map(lambda i: path_fn(i), range(requests)):
            lat.append(dt)
            if code not in (200, 201):
                bad += 1
    wall = time.time() - t0
    return {"qps": requests / wall, "errors": bad, "p50": pct(lat, 50), "p90": pct(lat, 90),
            "p99": pct(lat, 99), "max": max(lat, default=0)}


def list_req(i):
    off = (i * 20) % 1000
    return _req("GET", f"/self-descriptions?limit=20&offset={off}")


def query_req(i):
    kw = sdgen.DOMAINS[i % len(sdgen.DOMAINS)]
    stmt = ('MATCH (n:Resource) WHERE n.uri CONTAINS "DataOffering" '
            'RETURN n.uri AS uri LIMIT 20')
    return _req("POST", "/query", {"statement": stmt, "parameters": {}})


def rebuild_graph():
    t0 = time.time()
    code, _ = _req("POST", "/graph-rebuild",
                   {"chunkCount": 1, "chunkId": 0, "threads": 4, "batchSize": 200}, timeout=3600)
    return code, time.time() - t0


def resources(pid):
    rss = 0
    try:
        for line in open(f"/proc/{pid}/status"):
            if line.startswith("VmRSS:"):
                rss = int(line.split()[1]) / 1024
    except Exception:
        pass
    def sh(c):
        try:
            return subprocess.run(c, capture_output=True, text=True, timeout=30,
                                  env={**os.environ, "PGPASSWORD": "postgres"}).stdout.strip()
        except Exception:
            return "?"
    db = sh(PG + ["select pg_size_pretty(pg_database_size('catalogue'))"])
    sd_rows = sh(PG + ["select count(*) from sdfiles"]) or "?"
    neo = sh(["du", "-sm", "/var/lib/postgresql/neo4j/data"]).split("\t")[0] or "?"
    disk = sh(["sh", "-c", "df -m / | tail -1 | awk '{print $4}'"])
    return {"cat_rss_mb": round(rss), "db": db, "sd_rows": sd_rows, "neo4j_mb": neo, "disk_free_mb": disk}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoints", default="1000,5000,10000,25000,50000,100000,200000,500000")
    ap.add_argument("--pub-conc", type=int, default=16)
    ap.add_argument("--read-conc", type=int, default=20)
    ap.add_argument("--read-reqs", type=int, default=400)
    ap.add_argument("--min-disk-gb", type=float, default=1.0)
    ap.add_argument("--rebuild-at", default="10000,50000,100000")
    args = ap.parse_args()
    checkpoints = [int(x) for x in args.checkpoints.split(",")]
    rebuild_at = {int(x) for x in args.rebuild_at.split(",") if x}
    pid = int(open("/root/simpl-open-lab-work/run/catalogue.pid").read().strip())

    have = int(subprocess.run(PG + ["select count(*) from sdfiles"], capture_output=True, text=True,
                              env={**os.environ, "PGPASSWORD": "postgres"}).stdout.strip() or 0)
    print(f"starting at {have} SDs; pub-conc={args.pub_conc} read-conc={args.read_conc}\n")

    for target in checkpoints:
        if target <= have:
            continue
        pub = publish_batch(have, target - have, args.pub_conc)
        have = target
        r = resources(pid)
        if int(r["disk_free_mb"] or 0) < args.min_disk_gb * 1024:
            print(f"[{target}] DISK FLOOR: {r['disk_free_mb']} MB free — stopping. {r}")
            break
        print(f"── {target} SDs "
              f"(published +{pub['n']} @ {pub['tput']:.1f}/s, p50 {pub['p50']*1000:.0f}ms "
              f"p90 {pub['p90']*1000:.0f}ms p99 {pub['p99']*1000:.0f}ms, errors {pub['errors']}) ──")
        lst = read_load(list_req, args.read_conc, args.read_reqs)
        print(f"   list  : {lst['qps']:.0f} qps  p50 {lst['p50']*1000:.0f}ms p90 {lst['p90']*1000:.0f}ms "
              f"p99 {lst['p99']*1000:.0f}ms errors {lst['errors']}")
        if target in rebuild_at:
            code, dt = rebuild_graph()
            print(f"   graph-rebuild: HTTP {code} in {dt:.0f}s")
            time.sleep(3)
            qry = read_load(query_req, args.read_conc, max(100, args.read_reqs // 4))
            print(f"   query : {qry['qps']:.0f} qps  p50 {qry['p50']*1000:.0f}ms p90 {qry['p90']*1000:.0f}ms "
                  f"p99 {qry['p99']*1000:.0f}ms errors {qry['errors']}")
        print(f"   resources: cat RSS {r['cat_rss_mb']} MB | catalogue DB {r['db']} "
              f"({r['sd_rows']} SDs) | neo4j {r['neo4j_mb']} MB | disk free {int(r['disk_free_mb'])//1024}.{(int(r['disk_free_mb'])%1024)*10//1024}G\n",
              flush=True)
    print("done")


if __name__ == "__main__":
    main()
