/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL provider-agent content-query guard.
 */
package eu.simpl.lab.sparql;

/** Thrown when the guard rejects a query. Maps to an HTTP 403 at the data-plane edge. */
public class SparqlAccessException extends RuntimeException {
    public SparqlAccessException(String message) {
        super(message);
    }
}
