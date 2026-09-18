/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL provider-agent content-query guard.
 */
package eu.simpl.lab.sparql;

/**
 * The reusable heart of the capability: guard a query, then (only if allowed) run it against
 * the backend SPARQL endpoint. The EDC data-plane extension is a thin wrapper over this class,
 * and so is any sidecar variant — keeping the security logic in one tested place.
 */
public final class GuardedSparqlSource {

    private final SparqlQueryGuard guard;
    private final SparqlClient client;
    private final String endpoint;

    public GuardedSparqlSource(String endpoint, SparqlGuardConfig config) {
        this(endpoint, new SparqlQueryGuard(config), new SparqlClient());
    }

    public GuardedSparqlSource(String endpoint, SparqlQueryGuard guard, SparqlClient client) {
        this.endpoint = endpoint;
        this.guard = guard;
        this.client = client;
    }

    /**
     * @throws SparqlAccessException if the guard rejects the query (never reaches the backend)
     */
    public SparqlResult query(String rawQuery) {
        GuardResult decision = guard.check(rawQuery);
        if (!decision.allowed()) {
            throw new SparqlAccessException(decision.reason());
        }
        return client.run(endpoint, decision.effectiveQuery());
    }

    /** Exposed for callers that want to inspect the decision without executing. */
    public GuardResult guardOnly(String rawQuery) {
        return guard.check(rawQuery);
    }
}
