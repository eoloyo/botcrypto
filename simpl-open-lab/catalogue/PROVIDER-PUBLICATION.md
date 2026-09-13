# The intended provider-agent publication path (and how it's enforced)

Publishing to the Federated Catalogue is **not** a human `POST`-ing to `fc-service`.
It is an action of a **provider agent**, performed by a specific chain of services.
This document records the exact intended architecture (traced from the code) and how
"only a provider agent can publish" is actually enforced.

## The chain

```
simpl-sd-ui  (Resource Offering Editor / "creation wizard" — Vue)
  │   3 steps on Submit: 1) enrichAndValidate  2) sign  3) publish
  ▼
sd-tooling-be  (Creation Wizard API — Spring Boot, the provider-side publisher)
  ├─ enrich/validate ....... validation-be (+ schema-sync, asset-orchestrator, connector-adapter)
  ├─ sign .................. VC Issuer / simpl-signer   POST {vc-issuer.url}/v1/credentials/issue  (X-API-KEY)
  │                          → wraps the offering as a signed VerifiableCredential (did:jwk proof)
  └─ publish ............... FederatedCatalogueTier2Client.createSelfDescription(signedVC)
                                → POST {federated-catalogue.tier2-gateway.url}/fc/self-descriptions
                                   over a TIER-2 mTLS channel (see below)
                                → tier2-gateway terminates mTLS, routes /fc/* → fc-service
                                → fc-service POST /self-descriptions   (the API this lab drove directly)
```

Evidence (class / property references):
- `ResourceDescriptionServiceImpl.publishSignedResourceDescription()` →
  `federatedCatalogueTier2Client.createSelfDescription(signedPayload)`
- `SignerServiceImpl.sign()` → `VCIssuerClient.credentialIssue(apiKey, {clientId,type,credentialSubject,expirationDate,contextURI})`
  (`POST {vc-issuer.service.url}/v1/credentials/issue`)
- `sd-ui` `services/sdtooling.ts`: `publishSelfDescription = {base}/v1/selfDescriptions/publications`,
  `services/signer.ts`: `{PUBLIC_SIGNER_URL}/v1/credential`
- Target at runtime (observed): `POST http://{tier2-gateway}/fc/self-descriptions`

## Where "only a provider agent can publish" is enforced

**Not in the catalogue.** `fc-service` has:
- no Spring Security (no `spring-boot-starter-security` dependency, no `@PreAuthorize`
  on `addSelfDescription`), and
- signature verification OFF by default (`verification.vp-signature: false`,
  `vc-signature: false`) — it does not even check the signer's proof unless enabled.

The control is the **Tier-2 machine-identity perimeter**. `sd-tooling-be` reaches the
catalogue only through `FederatedCatalogueTier2Client`, whose transport (in
`simpl-data1-common-tier2` → `simpl-http-client-core`) performs a preflight
**ephemeral-proof** protocol against the provider's IAA before the mTLS call:

```
POST /authApi/tier2/v2/ephemeralProof   (authentication-provider)  → short-lived proof
POST /sapApi/tier2/v2/token             (security-attributes-provider) → Tier-2 token
GET  /identityApi/tier2/v2/participant  (identity/auth provider)  → participant identity
     + SslInfo (keystore/truststore)    from AuthenticationProviderKeyStoreSupplier
     + CertificateRevocationTrustManager (CRL)
→ mTLS POST to the tier2-gateway, which verifies the client cert and routes to fc-service
```

So a caller can publish **iff** it holds a valid provider **Tier-2 X.509 identity**
(issued by the authority CA and served by the provider's authentication-provider).
A direct `POST /self-descriptions` (what `06-federated-catalogue.sh` does) is
equivalent to a call that is **already inside** that perimeter — the same bytes
`fc-service` receives once the Tier-2 client is past the gateway — but it skips the
wizard, the signer, and the mTLS gate that make it a *provider-agent* action.

## Status in this lab

| Piece | State |
|---|---|
| `sd-tooling-be` (real publisher) | **builds + boots**; drives publish to `{tier2-gateway}/fc/self-descriptions` via the Tier-2 client (verified — fails only at Tier-2 client creation, no IAA present) |
| VC Issuer / signer | container-only image upstream; substitutable by a local issuer stub (signature verify is off in fc-service) |
| `fc-service` (catalogue) | **runs**; publishes a Tier-A SD, graph + query working (see `06-federated-catalogue.sh`) |
| authentication-provider (Tier-2 ephemeral-proof) | source present; needs Redis + Postgres(migrated) + Kafka/Vault config + CA |
| security-attributes-provider (SAP token) | source present |
| tier2-gateway (mTLS termination + CRL) | source present; mTLS not yet wired |
| provider Tier-2 X.509 identity | issuable via the Go CA shim |

The remaining work to publish **the exact intended way** is standing up the Tier-2
machine-identity subsystem (authentication-provider + SAP + tier2-gateway with real
mTLS and a CA-issued provider cert) — the deepest, most interconnected part of Simpl,
and the same trust-hardening layer the lab otherwise substitutes.
