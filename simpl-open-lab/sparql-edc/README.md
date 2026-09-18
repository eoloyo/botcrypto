# SPARQL content-query for a Simpl-Open provider agent — EDC data-plane plugin

A working, tested **EDC data-plane extension** that lets a Simpl-Open **provider agent** expose a
knowledge graph as a **governed SPARQL query service** — the "content query" half of the
[data-space search design](../research/) (discovery search stays in the catalogue; *content*
query lives behind the provider agent).

It is deliberately **not** a modification of the connector core: it is a plugin (an EDC
`ServiceExtension` loaded via the Java ServiceLoader), the same mechanism Simpl's own
`ConsumptionConstraintFunction` uses. The graph never leaves the provider — only the bounded,
policy-filtered result of a query does.

## What's here

| Module | What it is | Depends on |
|---|---|---|
| `sparql-core` | The **guard + SPARQL client** — the reusable brain. Pure Java + Apache Jena. **Tested against a real embedded Fuseki.** | jena-arq |
| `sparql-dataplane-edc` | The **EDC plugin**: `DataSourceFactory` + `DataSource` + `ServiceExtension` that wrap the core. Built against the **Eclipse EDC SPI** (compileOnly — provided by the connector at runtime). | `sparql-core`, EDC `data-plane-spi`/`core-spi`/`boot-spi`/`runtime-metamodel` |

The same `sparql-core` is what a **sidecar** deployment would wrap too — so this code is not
locked to the plugin choice.

## The guard (what makes exposing a graph safe)

`SparqlQueryGuard` inspects every incoming query and rewrites or rejects it:

- **read-only** — only `SELECT/ASK/CONSTRUCT/DESCRIBE`; `INSERT/DELETE/UPDATE` never parse → rejected;
- **no call-out** — SPARQL `SERVICE` (federated call-out) is blocked;
- **result cap** — a hard `LIMIT` is injected/clamped to the offering's `maxLimit`;
- **graph scope** — if the offering pins `allowedGraphs`, the query is confined to them (injected
  when it names none, rejected when it names others).

These are proven end-to-end in `SparqlGuardFusekiTest`, which boots a real Fuseki, loads a small
ePO/procurement graph, and asserts each rule over HTTP (allowed SELECT → 5 rows; `LIMIT 100` →
clamped to 2; `SERVICE` rejected before the backend; update rejected; ASK works; a restricted
graph scope returns only the classified notice while the public scope never does).

## How the offering wires it (the DataAddress contract)

The provider's Self-Description advertises a source of type **`SparqlQuery`**; the EDC
`DataAddress` carries:

| property | meaning |
|---|---|
| `endpoint` | backend SPARQL endpoint (a Fuseki, TED Open Data, or a materialised slice) |
| `query` | the consumer-supplied SPARQL (arrives via the data-plane pull request) |
| `maxLimit` | result cap (optional; default 1000) |
| `allowedGraphs` | comma-separated named graphs the offering permits (optional) |

At runtime: consumer discovers the offering → DSP contract (Simpl's `ConsumptionConstraintFunction`
admits only `CONSUMER`) → EDR/ticket → consumer POSTs a query → **this plugin** guards it, runs it
against `endpoint`, streams back the bounded result.

## Build & test

Prereqs: JDK 21 (this lab's toolchain), network to Maven Central.

```bash
cd simpl-open-lab/sparql-edc
./run-demo.sh            # runs the Fuseki-backed guard test + builds the EDC plugin jar
# or individually:
gradle :sparql-core:test            # guard proven against a real embedded Fuseki
gradle :sparql-dataplane-edc:jar    # the EDC extension jar
```

## Deploying into a Simpl provider agent

1. Build `sparql-dataplane-edc` as a fat/normal jar and place it on the **provider connector's
   data-plane runtime** classpath (alongside Simpl's own extensions).
2. Register an asset/Self-Description whose source `DataAddress` is `type=SparqlQuery` with the
   properties above; attach the ODRL/consumption policy as usual.
3. The ServiceLoader picks up `SparqlDataPlaneExtension`, which registers the factory for the
   `SparqlQuery` source type — no connector code changes.

## Caveats / provenance

- **EDC version.** Built against EDC SPI `0.18.0` (see `gradle.properties`). The data-plane SPI
  used here (`DataSource`, `DataSourceFactory`, `PipelineService`, `StreamResult`,
  `DataFlowStartMessage`) is stable across recent versions, but **align `edcVersion` to the exact
  EDC the Simpl `basic-connector` builds against** before dropping the jar in.
- This is a lab reference implementation. For a production-grade SPARQL validator, mine
  Eclipse **Tractus-X Knowledge Agents (KA-EDC / CX-0084)** — its SPARQL static-analysis is the
  place to harden the guard.
- Not wired: async/streaming for very large result sets, and passing per-request identity
  attributes into `allowedGraphs` (here the scope is per-offering). Both are noted in the design.
