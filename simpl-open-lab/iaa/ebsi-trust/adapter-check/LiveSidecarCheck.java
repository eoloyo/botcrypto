package eu.europa.ec.simpl.authenticationprovider.clients.impl;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import eu.europa.ec.simpl.authenticationprovider.clients.EbsiTrustAdapter.CheckIssuerOutcome;
import eu.europa.ec.simpl.authenticationprovider.properties.EbsiProperties;
import java.net.URI;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;

/** The real Java adapter against the real Python sidecar (demo_stack.py). Not part of authp-be. */
@EnabledIfSystemProperty(named = "sidecar", matches = ".+")
class LiveSidecarCheck {

    private final EbsiTrustAdapterImpl adapter = new EbsiTrustAdapterImpl(
            new EbsiProperties(true, URI.create(System.getProperty("sidecar")), Duration.ofSeconds(30)),
            new ObjectMapper());

    @Test
    void accreditedAuthorityIsTrusted() {
        assertThat(adapter.checkIssuer(System.getProperty("vm.ok")))
                .isEqualTo(new CheckIssuerOutcome.Trusted(System.getProperty("ebsi.did")));
    }

    @Test
    void authorityWithoutAnEbsiLinkIsNotTrusted() {
        assertThat(adapter.checkIssuer(System.getProperty("vm.unlinked")))
                .isEqualTo(new CheckIssuerOutcome.NotTrusted("did:web:localhost%3A18096:plain links no EBSI identity"));
    }

    @Test
    void authorityClaimingSomebodyElsesEbsiIdentityIsNotTrusted() {
        assertThat(adapter.checkIssuer(System.getProperty("vm.thief")))
                .isEqualTo(new CheckIssuerOutcome.NotTrusted(
                        "EBSI identity link proof signature does not verify against the registered key"));
    }

    @Test
    void sidecarThatIsDownIsUnavailable() {
        var down = new EbsiTrustAdapterImpl(
                new EbsiProperties(true, URI.create("http://127.0.0.1:1"), Duration.ofSeconds(3)), new ObjectMapper());
        assertThat(down.checkIssuer(System.getProperty("vm.ok"))).isInstanceOf(CheckIssuerOutcome.Unavailable.class);
    }
}
