/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL provider-agent content-query guard.
 *
 * Boots a REAL Apache Jena Fuseki server in-process, loads a small ePO/procurement graph,
 * and drives the guard + client end-to-end over HTTP — the exact shape of the provider-agent
 * content-query path (connector -> guard -> remote SPARQL endpoint), minus the DSP handshake.
 */
package eu.simpl.lab.sparql;

import org.apache.jena.fuseki.main.FusekiServer;
import org.apache.jena.query.Dataset;
import org.apache.jena.query.DatasetFactory;
import org.apache.jena.query.QueryExecution;
import org.apache.jena.rdf.model.Model;
import org.apache.jena.rdf.model.ModelFactory;
import org.apache.jena.riot.Lang;
import org.apache.jena.riot.RDFDataMgr;
import org.apache.jena.riot.RDFParser;
import org.apache.jena.sparql.exec.http.QueryExecutionHTTP;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SparqlGuardFusekiTest {

    private static final String NOTICES =
            "PREFIX epo:<http://data.europa.eu/a4g/ontology#> "
            + "PREFIX dct:<http://purl.org/dc/terms/> ";

    private static FusekiServer server;
    private static String endpoint;

    @BeforeAll
    static void startFuseki() {
        Model publicG = ModelFactory.createDefaultModel();
        RDFDataMgr.read(publicG, SparqlGuardFusekiTest.class.getResourceAsStream("/procurement.ttl"), Lang.TURTLE);

        Model restrictedG = ModelFactory.createDefaultModel();
        RDFParser.create().fromString(
                        "@prefix epo:<http://data.europa.eu/a4g/ontology#> ."
                        + "@prefix dct:<http://purl.org/dc/terms/> ."
                        + "@prefix ex:<https://example.eu/notice/> ."
                        + "ex:R1 a epo:Notice ; dct:title \"CLASSIFIED defence procurement\" ; epo:hasCountry \"EU\" .")
                .lang(Lang.TURTLE).parse(restrictedG);

        Dataset ds = DatasetFactory.createTxnMem();
        ds.setDefaultModel(publicG);
        ds.addNamedModel("urn:graph:public", publicG);
        ds.addNamedModel("urn:graph:restricted", restrictedG);

        server = FusekiServer.create().port(0).add("/ds", ds.asDatasetGraph()).build().start();
        endpoint = resolveQueryEndpoint("http://localhost:" + server.getHttpPort());
    }

    @AfterAll
    static void stopFuseki() {
        if (server != null) server.stop();
    }

    /** Fuseki registers its query op under a name; probe the usual paths so the test is robust. */
    private static String resolveQueryEndpoint(String base) {
        for (String p : new String[]{"/ds/sparql", "/ds/query", "/ds"}) {
            String url = base + p;
            try (QueryExecution qe = QueryExecutionHTTP.service(url).query("ASK{}").build()) {
                qe.execAsk();
                return url;
            } catch (RuntimeException ignore) {
                // try next
            }
        }
        throw new IllegalStateException("no working SPARQL query endpoint under " + base);
    }

    @Test
    void allowedSelectReturnsAllPublicNotices() {
        GuardedSparqlSource src = new GuardedSparqlSource(endpoint, SparqlGuardConfig.defaults());
        SparqlResult r = src.query(NOTICES + "SELECT ?s ?t WHERE { ?s a epo:Notice ; dct:title ?t }");
        assertEquals("SELECT", r.form());
        assertEquals(5, r.count());
    }

    @Test
    void limitIsClampedToPolicyMax() {
        GuardedSparqlSource src = new GuardedSparqlSource(
                endpoint, SparqlGuardConfig.defaults().withMaxLimit(2));
        SparqlResult r = src.query(NOTICES + "SELECT ?s WHERE { ?s a epo:Notice } LIMIT 100");
        assertEquals(2, r.count(), "policy max of 2 must override the requested LIMIT 100");
    }

    @Test
    void serviceCalloutIsRejectedBeforeHittingTheBackend() {
        GuardedSparqlSource src = new GuardedSparqlSource(endpoint, SparqlGuardConfig.defaults());
        String q = NOTICES + "SELECT ?x WHERE { SERVICE <http://evil.example/sparql> { ?x ?p ?o } }";
        GuardResult g = src.guardOnly(q);
        assertFalse(g.allowed());
        assertTrue(g.reason().contains("SERVICE"));
        assertThrows(SparqlAccessException.class, () -> src.query(q));
    }

    @Test
    void updatesAreRejected() {
        SparqlQueryGuard guard = new SparqlQueryGuard(SparqlGuardConfig.defaults());
        GuardResult g = guard.check("INSERT DATA { <urn:a> <urn:b> <urn:c> }");
        assertFalse(g.allowed());
    }

    @Test
    void askIsAllowed() {
        GuardedSparqlSource src = new GuardedSparqlSource(endpoint, SparqlGuardConfig.defaults());
        SparqlResult r = src.query(NOTICES + "ASK { ?s a epo:Notice }");
        assertEquals("ASK", r.form());
        assertTrue(r.bodyAsString().contains("true"));
    }

    @Test
    void graphScopeConfinesTheQueryToTheAllowedGraph() {
        // Restricted scope: injected FROM <urn:graph:restricted> => only the classified notice is visible.
        GuardedSparqlSource restricted = new GuardedSparqlSource(
                endpoint, SparqlGuardConfig.defaults().withAllowedGraphs(Set.of("urn:graph:restricted")));
        SparqlResult r = restricted.query(NOTICES + "SELECT ?t WHERE { ?s dct:title ?t }");
        assertEquals(1, r.count());
        assertTrue(r.bodyAsString().contains("CLASSIFIED"));

        // Public scope over the same query sees the 5 public notices and never the classified one.
        GuardedSparqlSource publicOnly = new GuardedSparqlSource(
                endpoint, SparqlGuardConfig.defaults().withAllowedGraphs(Set.of("urn:graph:public")));
        SparqlResult r2 = publicOnly.query(NOTICES + "SELECT ?t WHERE { ?s dct:title ?t }");
        assertEquals(5, r2.count());
        assertFalse(r2.bodyAsString().contains("CLASSIFIED"));
    }

    @Test
    void queryNamingAForbiddenGraphIsRejected() {
        SparqlQueryGuard guard = new SparqlQueryGuard(
                SparqlGuardConfig.defaults().withAllowedGraphs(Set.of("urn:graph:public")));
        GuardResult g = guard.check(
                NOTICES + "SELECT ?t FROM <urn:graph:restricted> WHERE { ?s dct:title ?t }");
        assertFalse(g.allowed());
        assertTrue(g.reason().contains("restricted"));
    }
}
