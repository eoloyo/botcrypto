package simpl.dcp;

import org.eclipse.edc.runtime.metamodel.annotation.Inject;
import org.eclipse.edc.spi.system.ServiceExtension;
import org.eclipse.edc.spi.system.ServiceExtensionContext;
import org.eclipse.edc.spi.monitor.Monitor;
import org.eclipse.edc.spi.security.Vault;

import org.eclipse.edc.identityhub.spi.participantcontext.ParticipantContextService;
import org.eclipse.edc.identityhub.spi.participantcontext.model.ParticipantManifest;
import org.eclipse.edc.identityhub.spi.participantcontext.model.KeyDescriptor;
import org.eclipse.edc.identityhub.spi.authentication.ServicePrincipal;
import org.eclipse.edc.identityhub.spi.store.CredentialStore;
import org.eclipse.edc.identityhub.spi.verifiablecredentials.model.VerifiableCredentialResource;
import org.eclipse.edc.identityhub.spi.verifiablecredentials.model.VcStatus;

import org.eclipse.edc.iam.did.spi.document.Service;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.VerifiableCredential;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.VerifiableCredentialContainer;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.CredentialFormat;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.CredentialSubject;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.Issuer;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * Seeds the native EDC 0.11 IdentityHub with a Simpl provider participant that holds a
 * SimplDataspaceMembershipCredential, and (if SIMPL_VERIFIER_* env is provided) a verifier
 * participant whose key material is injected so an external caller can mint a valid
 * self-issued token for the DCP Presentation Flow.
 *
 * Runs in-process at boot (there is no HTTP super-user bootstrap in this IdentityHub version).
 */
public class SimplSeedExtension implements ServiceExtension {

    @Inject private ParticipantContextService participants;
    @Inject private CredentialStore credentials;
    @Inject private Vault vault;

    private Monitor monitor;

    @Override
    public String name() { return "Simpl DCP Seed"; }

    @Override
    public void initialize(ServiceExtensionContext context) { monitor = context.getMonitor(); }

    @Override
    public void start() {
        var providerId = "simpl-provider";
        var providerDid = env("SIMPL_PROVIDER_DID", "did:web:localhost%3A8182:simpl-provider");

        // 1) provider participant (super-user role so the whole thing is self-contained)
        var manifest = ParticipantManifest.Builder.newInstance()
                .participantId(providerId)
                .active(true)
                .did(providerDid)
                .serviceEndpoint(new Service("credential-service", "CredentialService",
                        "http://localhost:8182/api/resolution/v1/participants/simpl-provider/presentations"))
                .roles(List.of(ServicePrincipal.ROLE_ADMIN))
                .key(KeyDescriptor.Builder.newInstance()
                        .keyId(providerDid + "#key-1")
                        .privateKeyAlias("simpl-provider-alias")
                        .resourceId("simpl-provider-resource")
                        .keyGeneratorParams(Map.of("algorithm", "EC", "curve", "secp256r1"))
                        .build())
                .build();
        var pr = participants.createParticipantContext(manifest);
        if (pr.failed()) {
            monitor.warning("[SIMPL-SEED] provider participant create failed: " + pr.getFailureDetail());
        } else {
            monitor.info("[SIMPL-SEED] provider participant '" + providerId + "' created, apiKey=" + pr.getContent().apiKey());
        }

        // 2) the Simpl membership credential (raw VC from env, or a placeholder)
        var rawVc = env("SIMPL_RAW_VC", "eyPLACEHOLDER.simpl.jwt");
        var subject = CredentialSubject.Builder.newInstance()
                .id(providerDid)
                .claim("legalName", "Acme Data BV")
                .claim("participantId", "urn:simpl:participant:acme-data-bv")
                .claim("identityAttributes", List.of("CONSUMER", "DATA_SEARCHER"))
                .build();
        @SuppressWarnings({"unchecked", "rawtypes"})
        VerifiableCredential vc = (VerifiableCredential) ((VerifiableCredential.Builder) VerifiableCredential.Builder.newInstance())
                .id("urn:uuid:simpl-vc-1")
                .type("VerifiableCredential")
                .type("SimplDataspaceMembershipCredential")
                .issuer(new Issuer("did:web:governance-authority"))
                .issuanceDate(Instant.now())
                .credentialSubject(subject)
                .build();
        var container = new VerifiableCredentialContainer(rawVc, CredentialFormat.VC1_0_JWT, vc);
        var resource = VerifiableCredentialResource.Builder.newInstance()
                .id("urn:uuid:simpl-vc-resource-1")
                .participantId(providerId)
                .issuerId("did:web:governance-authority")
                .holderId(providerDid)
                .state(VcStatus.ISSUED)
                .credential(container)
                .build();
        var cr = credentials.create(resource);
        monitor.info("[SIMPL-SEED] credential store SimplDataspaceMembershipCredential: "
                + (cr.succeeded() ? "OK" : cr.getFailureDetail()));

        // 3) optional verifier participant with injected key, so a caller can sign a valid SI token
        var verifierDid = System.getenv("SIMPL_VERIFIER_DID");
        var verifierPriv = System.getenv("SIMPL_VERIFIER_PRIVATE_JWK");
        var verifierPub = System.getenv("SIMPL_VERIFIER_PUBLIC_JWK");
        if (verifierDid != null && verifierPriv != null && verifierPub != null) {
            var alias = "verifier-alias";
            vault.storeSecret(alias, verifierPriv);
            var vm = ParticipantManifest.Builder.newInstance()
                    .participantId("verifier")
                    .active(true)
                    .did(verifierDid)
                    .serviceEndpoint(new Service("vsvc", "CredentialService", "http://localhost:8182/verifier"))
                    .roles(List.of())
                    .key(KeyDescriptor.Builder.newInstance()
                            .keyId(verifierDid + "#key-1")
                            .privateKeyAlias(alias)
                            .resourceId("verifier-resource")
                            .publicKeyJwk(parseJwk(verifierPub))
                            .build())
                    .build();
            var vr = participants.createParticipantContext(vm);
            monitor.info("[SIMPL-SEED] verifier participant: " + (vr.succeeded() ? "created " + verifierDid : vr.getFailureDetail()));
        }
        monitor.info("[SIMPL-SEED] done.");
    }

    private static String env(String k, String dflt) {
        var v = System.getenv(k);
        return (v == null || v.isBlank()) ? dflt : v;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> parseJwk(String json) {
        try {
            return (Map<String, Object>) new com.fasterxml.jackson.databind.ObjectMapper().readValue(json, Map.class);
        } catch (Exception e) {
            throw new RuntimeException("bad verifier public JWK: " + e.getMessage());
        }
    }
}
