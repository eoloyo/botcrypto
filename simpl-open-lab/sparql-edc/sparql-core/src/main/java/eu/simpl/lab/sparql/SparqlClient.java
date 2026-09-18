/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL provider-agent content-query guard.
 */
package eu.simpl.lab.sparql;

import org.apache.jena.query.Query;
import org.apache.jena.query.QueryExecution;
import org.apache.jena.query.QueryFactory;
import org.apache.jena.query.ResultSetFactory;
import org.apache.jena.query.ResultSetFormatter;
import org.apache.jena.query.ResultSetRewindable;
import org.apache.jena.rdf.model.Model;
import org.apache.jena.riot.Lang;
import org.apache.jena.riot.RDFDataMgr;
import org.apache.jena.sparql.exec.http.QueryExecutionHTTP;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Executes an already-guarded query against a remote SPARQL endpoint (a Fuseki HTTP endpoint,
 * or — in production — TED Open Data / a materialised slice). This is the "backend call": the
 * connector never reaches the store directly, only through this client behind the guard.
 */
public final class SparqlClient {

    public SparqlResult run(String endpoint, String guardedQuery) {
        final Query q = QueryFactory.create(guardedQuery);
        try (QueryExecution qe = QueryExecutionHTTP.service(endpoint).query(q).build()) {
            if (q.isAskType()) {
                boolean answer = qe.execAsk();
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                ResultSetFormatter.outputAsJSON(out, answer);
                return new SparqlResult("ASK", 1, out.toByteArray(), "application/sparql-results+json");
            }
            if (q.isSelectType()) {
                ResultSetRewindable rs = ResultSetFactory.copyResults(qe.execSelect());
                long count = rs.size();
                rs.reset();
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                ResultSetFormatter.outputAsJSON(out, rs);
                return new SparqlResult("SELECT", count, out.toByteArray(), "application/sparql-results+json");
            }
            // CONSTRUCT / DESCRIBE
            Model model = q.isConstructType() ? qe.execConstruct() : qe.execDescribe();
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            RDFDataMgr.write(out, model, Lang.TURTLE);
            String form = q.isConstructType() ? "CONSTRUCT" : "DESCRIBE";
            return new SparqlResult(form, model.size(), out.toByteArray(), "text/turtle");
        }
    }

    static String utf8(byte[] b) {
        return new String(b, StandardCharsets.UTF_8);
    }
}
