rootProject.name = "sparql-edc"

// The tested core: SPARQL query-guard + Fuseki client, proven against an embedded real Fuseki.
include("sparql-core")

// The EDC data-plane extension (plugin) that wraps the core. Built against the Eclipse EDC SPI.
include("sparql-dataplane-edc")
