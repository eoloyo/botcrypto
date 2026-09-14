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

## From discovery to a data transfer (the point of publishing)

Publishing an SD is only half the dataspace story — the other half is a **consumer
discovering it and pulling the data**. A dataspace has two discovery layers, and the SD is
what joins them:

- **Gaia-X Federated Catalogue** (`fc-service`) = *semantic* discovery: who offers what, and
  **where is their connector**. The connector address is the SD's
  `credentialSubject.simpl:generalServiceProperties.simpl:serviceAccessPoint` — in this lab
  it names the provider EDC connector's DSP endpoint (`http://localhost:19194/protocol`).
- **EDC DSP catalog** (the connector at that endpoint) = *technical* negotiation: the offer,
  the concrete `asset`, the policy, the contract, the transfer.

`scripts/08-discover-and-transfer.sh` runs the full path: the consumer reads the endpoint out
of the catalogue SD (never hardcoded), then negotiates + transfers against it, ending with the
file in `consumer-bucket`. So `serviceAccessPoint` is the **discovery→transfer bridge**.

### Consumption is gated too (the design ≠ what the lab enforces)

The Tier-2 machine-identity perimeter governs the **consume/read** path, not just publish —
consumption is **not open** in the real design:

- **Inter-agent traffic is mTLS-only through the gateway.** `tier2-gateway/README.md`: *"a
  gateway for inbound Tier 2 API operation **between agents** and work only in https on
  mTLS."* A consumer reaching a provider's catalogue/connector goes through that perimeter;
  `fc-service` has no app-level security precisely *because* the gateway is the perimeter.
- **Identity attributes authorize consumption actions (ABAC).** The Tier-2 identity a
  connector presents carries attributes that gate *what a consumer may do*. Straight from the
  connector config (`connector-be/local/*-config.properties` → `mocked.agent.identity.attributes`):
  - `DATA_SEARCHER` — *"act only as a searcher in the catalogue, **but can't start a contract
    negotiation or transfer process**"*
  - `CONSUMER` — act as a data-consumer participant user.
  So a machine identity can be allowed to **discover** yet denied **negotiate/transfer**.

**What this lab enforces — the authorization gate (`scripts/09-consumption-abac.sh`).** The
ABAC decision that a `DATA_SEARCHER` cannot transact is now demonstrated end to end against the
connector's **own shipped policy engine** — no connector code change. The provider registers a
two-policy offer (access policy **open**, so a searcher still *sees* it; contract policy
`consumption eq CONSUMER`), and the consumer negotiates twice under different identities:

| identity | catalogue offer visible? | contract negotiation | result |
|---|---|---|---|
| `CONSUMER` | yes | `FINALIZED` (agreement) | **ALLOWED** |
| `DATA_SEARCHER` | yes (can browse) | `TERMINATED` (no agreement) | **DENIED** |

The enforcement is the connector's `policy/function/ConsumptionConstraintFunction`, bound to
`NEGOTIATION_SCOPE` by `policy/service/PolicyFunctionsExtension`; it reads the caller's
`identity_attributes` claim and allows the negotiation only if the required attribute code is
present. Run `09` ends with `CONSUMPTION ABAC ENFORCED`. (JSON-LD detail: the contract policy's
constraint uses the **full IRI** `https://w3id.org/edc/v0.0.1/ns/consumption` as `leftOperand` on
both sides so EDC's offer-equivalence check passes and the function actually fires.)

**The honest limit — authorization, not authenticity.** `09` proves the *authorization* decision
(ABAC on attributes) with the real shipped policy function, but the attributes it decides on are
still **self-asserted**: it flips the consumer identity via `mocked.agent.identity.attributes`,
and the reference `basic-connector`'s `SimplIdentityService.verifyJwtToken` is a **non-verifying
stub** (deserializes + trusts the token — no signature, no OCSP, no mTLS). Sourcing those
attributes *authentically* — the agent fetching its **own** governed attributes over the Tier-2
mesh — is the upgrade on top, captured in `iaa/patches/connector-tier2-identity.patch`
(`SimplIdentityService` fetches from the authentication-provider's
`/participant/identityAttributes`, filtered by `assignedToParticipant`).

**The gated discovery read (`scripts/10-gated-discovery.sh`).** `08`'s *discovery* queries
`fc-service` **directly** on `:8081` (the shortcut). `10` shows the faithful path: a catalogue
**read** through the Tier-2 gateway with a real machine identity, using the connector library's
own credential-backed client (`FederatedCatalogueTier2Client.getSelfDescription`, driven via a
thin sd-tooling-be endpoint added in `iaa/patches/sdtooling-fc-read.patch`; the sealed key never
leaves the auth-provider). Verified live:

| request | outcome |
|---|---|
| credential-backed read via `sd-tooling-be` → gateway `/fc/self-descriptions/{id}` | **HTTP 200** — gateway log: `Proof check required true` → `Ephemeral proof is valid, proceeding` → routed to fc-service |
| same read straight at `:8443` with **no client certificate** | **rejected at the TLS handshake** (`tlsv13 alert certificate required`, curl `000`) |
| direct `GET :8081/self-descriptions/{id}` (the `08` shortcut) | **HTTP 200** — fc-service has no app security |

So the read is gated by the same perimeter as publish: **mTLS (required) + a valid ephemeral
proof** bound to the credential's key. The gateway's `AbacFilter` also runs on `/fc` reads and
decides on the ephemeral-proof's SAP-issued `identityAttributes`; in this lab the provider's proof
carries **none** (an empty attribute set — the same reason publish passes `/fc` today), so no
identity-attribute rule is set on `/fc` (one would need SAP-seeded attributes). The
attribute-level allow/deny is exactly what `09` demonstrates at the connector.

## Status in this lab

> **ACHIEVED — a provider agent published a Self-Description through the full Tier-2
> mTLS mesh.** `POST /v1/selfDescriptions/publications` on `sd-tooling-be` →
> `FederatedCatalogueTier2Client` → **tier2-gateway (mTLS, client identity resolved
> from the provider's CA-issued credential, ABAC)** → `/fc` → `fc-service`, ending with
> the SD `active` in `fc-service` (`GET :8081/self-descriptions` → `totalCount: 1`).
> Reproduced by `scripts/07-tier2-provider-publish.sh` + `iaa/enroll.sh` +
> `iaa/{jwks-tier1.py,ocsp-responder.py}` + the two local patches
> (`iaa/patches/tier2-gateway-local-trust.patch`, `catalogue/patches/catalogue-local.patch`)
> + the enhanced `ejbca-shim`.

| Piece | State |
|---|---|
| `sd-tooling-be` (real publisher) | **builds + boots**; drives publish to `{tier2-gateway}/fc/self-descriptions` via the Tier-2 client (verified — fails only at Tier-2 client creation, no IAA present) |
| VC Issuer / signer | container-only image upstream; substitutable by a local issuer stub (signature verify is off in fc-service) |
| `fc-service` (catalogue) | **runs**; publishes a Tier-A SD, graph + query working (see `06-federated-catalogue.sh`) |
| `authentication_provider` (participant side) | **builds + BOOTS** (Redis + Postgres/Liquibase; profile `local-consumer`=participant; Kafka autoconfig kept, broker lazy) |
| Tier-1 OIDC signing authority | **`iaa/jwks-tier1.py`** — local JWKS + RS256 tokens **accepted** by auth-provider (`TierOneAuthInfoRSAVerifier`) |
| provider keypair + CSR | **created** via `POST /tier1/v2/keypairs` + `/csr` |
| CA enrollment (AIA + caIssuers + OCSP) | **works** — the Go shim now issues certs with AIA, serves the CA cert at the caIssuers URL, and runs an OCSP responder (`iaa/ocsp-responder.py`, GOOD + verbatim critical nonce + SHA256 certID) |
| provider credential local validation | **passes** (chain build + OCSP GOOD + nonce all green) |
| security-attributes-provider (SAP token) | **builds + runs** (:8102) — needed by the GA's ephemeral-proof generation |
| tier2-gateway (mTLS termination) | **runs (:8443), mTLS working** — server identity from the GA credential; trusts the shim CA via `tier2-gateway-local-trust.patch` (upstream `loadTrustedCertificates()` is a TODO stub); routes `/authApi`,`/identityApi`,`/sapApi`,`/fc` |
| Governance Authority (authority-side IAA) | **runs (:8105, authority profile) with its own active credential** — the root of trust; participant credential registers with it through the gateway mTLS |
| **provider-agent publish through the mesh** | **GREEN** — SD `active` in fc-service via the full Tier-2 path |

### How far the Tier-2 machine-identity path goes locally (verified, step by step)

The participant side is reproduced end to end:

1. `authentication_provider` boots against local Redis + PostgreSQL (Liquibase-migrated),
   under the `participant` profile (`--spring.profiles.active=local-consumer`).
2. A **local Tier-1 OIDC authority** (`iaa/jwks-tier1.py`) serves a JWKS and mints
   RS256 tokens; auth-provider RS256-verifies them and authenticates the caller.
3. `POST /tier1/v2/keypairs` creates the provider keypair (ECDSA); `POST .../{id}/csr`
   generates a CSR (CN = the participant UUID — the install parses CN as the participant id).
4. The **Go CA shim** signs the CSR. To satisfy Simpl's credential validation the shim
   now: adds an **AIA** extension, serves its **CA cert at the caIssuers URL**, and runs
   an **OCSP responder** that returns `GOOD`, echoes the request's **critical nonce
   verbatim**, and uses a **SHA-256 certID** (all three were required, discovered in order).
5. `POST /tier1/v2/credentials` then passes local validation completely
   (chain → CA cert via AIA → OCSP GOOD + nonce match).

**The final blocker** is not the participant side: after local validation succeeds,
`CredentialControllerTier1V2` calls the **Governance Authority** over Tier-2 mTLS to
register the credential ("Unable to communicate the new credential to Governance
Authority", HTTP 503). The install is transactional, so with no GA online it rolls
back and no credential is stored. Completing it therefore requires the **authority-side
IAA** (a second `authentication_provider` in the `authority` profile, the GA's own
CA-issued identity) reachable through the **tier2-gateway with real mTLS** — i.e. the
full two-sided trust fabric, plus SAP for `/sapApi/tier2/v2/token`. That is the
platform/trust-hardening layer the lab otherwise substitutes; everything up to the
GA handshake is real and reproducible via `07-tier2-provider-publish.sh` +
`iaa/jwks-tier1.py` + `iaa/ocsp-responder.py` + the enhanced `ejbca-shim`.
