# Catalogue load / scale test (Gaia-X XFSC Federated Catalogue)

Publishes Self-Descriptions into Simpl's `catalogue-be` and measures how publish, search and storage
behave as the catalogue grows, up to the breakpoint.

```bash
# catalogue must be up (scripts/06-federated-catalogue.sh), Postgres + Neo4j + qs-stub running
python3 catalogue_load.py --checkpoints 5000,10000,25000,50000,100000 --pub-conc 24 --rebuild-at 10000,50000
```

- `sdgen.py` — makes unique, SHACL-conformant DataOffering SDs (only free-text fields vary; the
  SHACL-pinned enums stay at the default). Signature verification is **off** in this catalogue config
  (`federated-catalogue.verification.vc-signature=false`), so publish exercises RDF extraction + SHACL +
  semantics + quality scoring + the Postgres write — not the crypto signature.
- Quality scoring is the **local stub** (`qs-stub.py`); real scoring adds latency on top of the publish
  numbers below.

## Results (this sandbox: 4 cores, ~5.5 GB free disk)

| Catalogue size | Publish (conc 24) | List search (GET, conc 20) | catalogue DB | cat RSS |
|---|---|---|---|---|
| 1 000 | **10.1 SD/s**, p50 1.6s | 682 qps, p50 24ms, p99 75ms | 25 MB | 758 MB |
| 5 000 | **10.2 SD/s**, p50 2.4s | 417 qps, p50 44ms, p99 123ms | 74 MB | 942 MB |
| 10 000 | — | 330 qps, p50 55ms, p90 86ms, p99 129ms | 137 MB | ~950 MB |

Deep pagination (offset 9000) stayed at p50 24ms — no deep-page penalty.

## What it shows

1. **Publish is the ingestion bottleneck, and it does not parallelise.** Throughput is **~10 SD/s flat**
   at concurrency 16 and 24 — each publish takes 1.6–2.4 s and rises with catalogue size. The cost is
   CPU-bound in **SHACL + semantics validation + RDF extraction**, *even with quality scoring stubbed*.
   Real quality scoring would make it slower. 10 SD/s means ~17 min per 10k, ~3 h per 100k — bulk
   onboarding of a large catalogue is slow.
2. **Postgres storage and the list/metadata search scale well.** ~**14 KB per SD** (137 MB at 10k, linear);
   `GET /self-descriptions` stays fast (p50 24→55 ms from 1k→10k, still hundreds of qps) with no
   deep-pagination penalty. The Postgres-backed read path is healthy.
3. **The breakpoint is the Neo4j graph (semantic search), not publish or Postgres.** The one-shot
   `POST /graph-rebuild` re-imports **all** SD claims into Neo4j via neosemantics. Rebuilding at **10 000
   SDs consumed ~5 GB** (Neo4j store + transaction logs) and **filled the disk**, crashing the box — while
   the same 10k SDs were only 137 MB in Postgres. The graph import is ~**an order of magnitude more
   disk-hungry** than the source, and `/graph-rebuild` is a full O(N) re-import (10 s for *3* SDs), so it
   scales badly in both disk and time.

## Real-usage implications

- The catalogue is **write-rarely / read-often**; the Postgres list/search path is fine for that and
  scales. The **openCypher semantic search (Neo4j)** is the expensive part to operate.
- To run a growing catalogue you must size the **Neo4j** volume generously, enable **transaction-log
  rotation**, and avoid the full `/graph-rebuild` — incremental graph import on publish is what production
  needs (in this fork graph population is only the one-shot rebuild).
- Bulk provider onboarding is gated by the **~10 SD/s** validation path; plan ingestion windows, or
  parallelise across catalogue replicas (publish is CPU-bound, so more cores/replicas is the lever).

## Caveats

Single node, loopback, quality-scoring stubbed (publish numbers optimistic), one catalogue instance,
~5.5 GB free disk (the disk ceiling is a property of this sandbox — the *shape* of the finding, Neo4j
import dominating storage, holds regardless). The run stopped at 10k when the graph-rebuild filled the
disk; Postgres + the 10k SDs survived, Neo4j's derived store was dropped to recover.
