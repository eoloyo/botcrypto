/*
 * SPDX-License-Identifier: EUPL-1.2
 * Simpl-Open lab — SPARQL provider-agent content-query guard.
 */
package eu.simpl.lab.sparql;

import org.apache.jena.query.Query;
import org.apache.jena.query.QueryException;
import org.apache.jena.query.QueryFactory;
import org.apache.jena.sparql.syntax.ElementService;
import org.apache.jena.sparql.syntax.ElementVisitorBase;
import org.apache.jena.sparql.syntax.ElementWalker;

import java.util.List;

/**
 * The "brain" of the content-query capability: it inspects a consumer's SPARQL text and
 * decides whether it may run, rewriting it to stay within policy.
 *
 * <p>Enforced, in order:
 * <ol>
 *   <li>parseable and a <em>query</em> (updates/DELETE/INSERT never parse here → rejected);</li>
 *   <li>query form is on the allow-list (default: SELECT/ASK/CONSTRUCT/DESCRIBE);</li>
 *   <li>no {@code SERVICE} federated call-out (unless explicitly allowed);</li>
 *   <li>named-graph scope: if the offering pins allowed graphs, the query is confined to them
 *       (injected when it names none, rejected when it names others);</li>
 *   <li>a hard result {@code LIMIT} is injected/clamped.</li>
 * </ol>
 */
public final class SparqlQueryGuard {

    private final SparqlGuardConfig config;

    public SparqlQueryGuard(SparqlGuardConfig config) {
        this.config = config;
    }

    public GuardResult check(String queryText) {
        final Query query;
        try {
            query = QueryFactory.create(queryText);
        } catch (QueryException e) {
            return GuardResult.deny("not a readable SPARQL query (updates are not allowed): " + e.getMessage());
        }

        final String form = formOf(query);
        if (form == null || !config.allowedForms().contains(form)) {
            return GuardResult.deny("query form '" + form + "' is not permitted for this offering");
        }

        if (!config.allowService() && usesService(query)) {
            return GuardResult.deny("SPARQL SERVICE (federated call-out) is not permitted");
        }

        final GuardResult scopeError = applyGraphScope(query);
        if (scopeError != null) {
            return scopeError;
        }

        clampLimit(query);

        return GuardResult.allow(query.serialize());
    }

    private static String formOf(Query q) {
        if (q.isSelectType()) return "SELECT";
        if (q.isAskType()) return "ASK";
        if (q.isConstructType()) return "CONSTRUCT";
        if (q.isDescribeType()) return "DESCRIBE";
        return null;
    }

    private static boolean usesService(Query q) {
        if (q.getQueryPattern() == null) {
            return false;
        }
        final boolean[] found = {false};
        ElementWalker.walk(q.getQueryPattern(), new ElementVisitorBase() {
            @Override
            public void visit(ElementService el) {
                found[0] = true;
            }
        });
        return found[0];
    }

    /** Returns a deny result if the query escapes the allowed graphs, otherwise null (and injects scope). */
    private GuardResult applyGraphScope(Query q) {
        if (config.allowedGraphs().isEmpty()) {
            return null; // no graph restriction for this offering
        }
        final List<String> from = q.getGraphURIs();
        final List<String> named = q.getNamedGraphURIs();

        if (from.isEmpty() && named.isEmpty()) {
            // Query names no dataset → confine it to the allowed graphs.
            config.allowedGraphs().forEach(q::addGraphURI);
            return null;
        }
        for (String g : from) {
            if (!config.allowedGraphs().contains(g)) {
                return GuardResult.deny("graph <" + g + "> is outside the permitted scope");
            }
        }
        for (String g : named) {
            if (!config.allowedGraphs().contains(g)) {
                return GuardResult.deny("named graph <" + g + "> is outside the permitted scope");
            }
        }
        return null;
    }

    private void clampLimit(Query q) {
        if (q.isAskType()) {
            return; // ASK returns a single boolean
        }
        long limit = q.getLimit();
        if (limit == Query.NOLIMIT || limit > config.maxLimit()) {
            q.setLimit(config.maxLimit());
        }
    }
}
