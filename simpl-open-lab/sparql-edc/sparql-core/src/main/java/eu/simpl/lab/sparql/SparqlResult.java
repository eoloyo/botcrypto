/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL provider-agent content-query guard.
 */
package eu.simpl.lab.sparql;

/**
 * A materialised query result ready to stream back through the EDC data plane.
 *
 * @param form        SELECT / ASK / CONSTRUCT / DESCRIBE
 * @param count       number of solutions (SELECT) or triples (CONSTRUCT/DESCRIBE); 1 for ASK
 * @param body        serialized payload
 * @param contentType media type of {@link #body}
 */
public record SparqlResult(String form, long count, byte[] body, String contentType) {

    public String bodyAsString() {
        return new String(body, java.nio.charset.StandardCharsets.UTF_8);
    }
}
