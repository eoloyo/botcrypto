/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL provider-agent content-query guard.
 */
package eu.simpl.lab.sparql;

/**
 * Outcome of guarding a query. When {@link #allowed()} is true, {@link #effectiveQuery()}
 * carries the possibly-rewritten SPARQL (limit clamped, graphs scoped) that is safe to run.
 */
public record GuardResult(boolean allowed, String reason, String effectiveQuery) {

    public static GuardResult deny(String reason) {
        return new GuardResult(false, reason, null);
    }

    public static GuardResult allow(String effectiveQuery) {
        return new GuardResult(true, null, effectiveQuery);
    }
}
