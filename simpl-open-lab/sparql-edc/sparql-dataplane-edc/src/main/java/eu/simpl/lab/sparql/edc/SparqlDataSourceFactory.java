/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL content-query EDC data-plane extension (plugin).
 */
package eu.simpl.lab.sparql.edc;

import eu.simpl.lab.sparql.GuardedSparqlSource;
import eu.simpl.lab.sparql.SparqlGuardConfig;
import org.eclipse.edc.connector.dataplane.spi.pipeline.DataSource;
import org.eclipse.edc.connector.dataplane.spi.pipeline.DataSourceFactory;
import org.eclipse.edc.spi.result.Result;
import org.eclipse.edc.spi.types.domain.DataAddress;
import org.eclipse.edc.spi.types.domain.transfer.DataFlowStartMessage;

import java.util.HashSet;
import java.util.Set;

/**
 * Teaches the EDC data plane a new source type, {@value #TYPE}. When a consumer's cleared
 * transfer names a {@code SparqlQuery} source, the pipeline calls this factory instead of a
 * file/HTTP source. The offering's Self-Description carries the backend endpoint + guard policy
 * as properties on the source {@link DataAddress}.
 */
public class SparqlDataSourceFactory implements DataSourceFactory {

    public static final String TYPE = "SparqlQuery";

    static final String P_ENDPOINT = "endpoint";
    static final String P_QUERY = "query";
    static final String P_MAX_LIMIT = "maxLimit";
    static final String P_ALLOWED_GRAPHS = "allowedGraphs";

    @Override
    public String supportedType() {
        return TYPE;
    }

    @Override
    public Result<Void> validateRequest(DataFlowStartMessage request) {
        DataAddress src = request.getSourceDataAddress();
        if (src == null || !TYPE.equals(src.getType())) {
            return Result.failure("source data address is not of type " + TYPE);
        }
        if (src.getStringProperty(P_ENDPOINT) == null) {
            return Result.failure("missing '" + P_ENDPOINT + "' (backend SPARQL endpoint) on source address");
        }
        if (src.getStringProperty(P_QUERY) == null) {
            return Result.failure("missing '" + P_QUERY + "' (the SPARQL query) on source address");
        }
        return Result.success();
    }

    @Override
    public DataSource createSource(DataFlowStartMessage request) {
        DataAddress src = request.getSourceDataAddress();
        String endpoint = src.getStringProperty(P_ENDPOINT);
        String query = src.getStringProperty(P_QUERY);
        return new SparqlPullDataSource(new GuardedSparqlSource(endpoint, buildConfig(src)), query);
    }

    private static SparqlGuardConfig buildConfig(DataAddress src) {
        SparqlGuardConfig cfg = SparqlGuardConfig.defaults();
        String max = src.getStringProperty(P_MAX_LIMIT);
        if (max != null && !max.isBlank()) {
            cfg = cfg.withMaxLimit(Integer.parseInt(max.trim()));
        }
        String graphs = src.getStringProperty(P_ALLOWED_GRAPHS);
        if (graphs != null && !graphs.isBlank()) {
            Set<String> allowed = new HashSet<>();
            for (String g : graphs.split(",")) {
                if (!g.isBlank()) {
                    allowed.add(g.trim());
                }
            }
            cfg = cfg.withAllowedGraphs(allowed);
        }
        return cfg;
    }
}
