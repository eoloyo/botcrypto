/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL content-query EDC data-plane extension (plugin).
 */
package eu.simpl.lab.sparql.edc;

import org.eclipse.edc.connector.dataplane.spi.pipeline.PipelineService;
import org.eclipse.edc.runtime.metamodel.annotation.Extension;
import org.eclipse.edc.runtime.metamodel.annotation.Inject;
import org.eclipse.edc.spi.system.ServiceExtension;
import org.eclipse.edc.spi.system.ServiceExtensionContext;

/**
 * The EDC plugin entry point. Loaded by the connector's data-plane runtime via the Java
 * ServiceLoader (see META-INF/services), it registers the SPARQL source factory with the
 * pipeline — the same extension mechanism Simpl's own {@code ConsumptionConstraintFunction}
 * uses. No modification to the connector core is required.
 */
@Extension(value = SparqlDataPlaneExtension.NAME)
public class SparqlDataPlaneExtension implements ServiceExtension {

    public static final String NAME = "SPARQL content-query data plane (Simpl lab)";

    @Inject
    private PipelineService pipelineService;

    public String name() {
        return NAME;
    }

    @Override
    public void initialize(ServiceExtensionContext context) {
        pipelineService.registerFactory(new SparqlDataSourceFactory());
    }
}
