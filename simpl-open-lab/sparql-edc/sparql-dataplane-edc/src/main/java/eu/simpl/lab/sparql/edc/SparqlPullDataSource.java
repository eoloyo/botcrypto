/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL content-query EDC data-plane extension (plugin).
 */
package eu.simpl.lab.sparql.edc;

import eu.simpl.lab.sparql.GuardedSparqlSource;
import eu.simpl.lab.sparql.SparqlAccessException;
import eu.simpl.lab.sparql.SparqlResult;
import org.eclipse.edc.connector.dataplane.spi.pipeline.DataSource;
import org.eclipse.edc.connector.dataplane.spi.pipeline.StreamResult;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.util.stream.Stream;

/**
 * The EDC {@link DataSource} for a guarded SPARQL query. It runs the query through the guard
 * (which may reject or rewrite it), then exposes the result as a single stream {@code Part}.
 * The graph is never streamed — only the bounded, policy-filtered answer leaves the provider.
 */
public class SparqlPullDataSource implements DataSource {

    private final GuardedSparqlSource source;
    private final String query;

    public SparqlPullDataSource(GuardedSparqlSource source, String query) {
        this.source = source;
        this.query = query;
    }

    @Override
    public StreamResult<Stream<Part>> openPartStream() {
        final SparqlResult result;
        try {
            result = source.query(query);
        } catch (SparqlAccessException e) {
            // Guard said no: map to "not authorized" so the data plane returns a 4xx, not a 5xx.
            return StreamResult.notAuthorized();
        } catch (RuntimeException e) {
            return StreamResult.error("SPARQL backend error: " + e.getMessage());
        }
        return StreamResult.success(Stream.of(new SparqlResultPart(result)));
    }

    @Override
    public void close() {
        // no resources held open beyond the query call
    }

    /** Wraps the materialised query result as an EDC stream part. */
    private static final class SparqlResultPart implements Part {
        private final SparqlResult result;

        SparqlResultPart(SparqlResult result) {
            this.result = result;
        }

        @Override
        public String name() {
            boolean turtle = result.contentType() != null && result.contentType().contains("turtle");
            return "sparql-result." + (turtle ? "ttl" : "json");
        }

        @Override
        public long size() {
            return result.body().length;
        }

        @Override
        public InputStream openStream() {
            return new ByteArrayInputStream(result.body());
        }

        @Override
        public String mediaType() {
            return result.contentType();
        }
    }
}
