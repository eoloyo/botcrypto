/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL provider-agent content-query guard.
 */
package eu.simpl.lab.sparql;

import java.util.Set;

/**
 * Policy the guard enforces on every incoming query, per offering.
 *
 * @param maxLimit      hard cap on returned solutions (injected/clamped)
 * @param allowedForms  permitted query forms, e.g. {@code SELECT, ASK, CONSTRUCT, DESCRIBE}
 * @param allowService  whether SPARQL {@code SERVICE} (federated call-out) is permitted
 * @param allowedGraphs if non-empty, the query is confined to these named graphs
 *                      (injected when the query names none; rejected if it names others)
 * @param timeoutMs     advisory query timeout
 */
public record SparqlGuardConfig(
        int maxLimit,
        Set<String> allowedForms,
        boolean allowService,
        Set<String> allowedGraphs,
        long timeoutMs) {

    public static SparqlGuardConfig defaults() {
        return new SparqlGuardConfig(
                1000,
                Set.of("SELECT", "ASK", "CONSTRUCT", "DESCRIBE"),
                false,
                Set.of(),
                30_000L);
    }

    public SparqlGuardConfig withMaxLimit(int limit) {
        return new SparqlGuardConfig(limit, allowedForms, allowService, allowedGraphs, timeoutMs);
    }

    public SparqlGuardConfig withAllowedGraphs(Set<String> graphs) {
        return new SparqlGuardConfig(maxLimit, allowedForms, allowService, graphs, timeoutMs);
    }
}
