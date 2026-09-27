# DCP / SSI credential exchange for Simpl-Open (lab)

This proves — with real crypto, no mocks — the **credential core that a Simpl-Open
DCP (Decentralized Claims Protocol) identity would rely on**, using **walt.id**: the
exact stack Simpl-Open selected for its SSI verifier in architecture **ADR 007**
("OpenID4VP verifier for SSI Tier 1 authentication — walt.id", *Accepted*).

## What it does

```
issuer (GA)  --issue-->  SimplDataspaceMembershipCredential { identityAttributes:[CONSUMER,DATA_SEARCHER] }
                              │ (held by)
holder (agent) ────────────► verifier opens an OID4VP session (nonce, presentation_definition)
holder signs a Verifiable Presentation (ES256, bound to nonce + client_id) ── direct_post ──► verifier
verifier validates  signature + holder-binding + credential type  ──►  verified = true
```

`./run.sh` pulls and starts the walt.id **issuer-api** (:7002) and **verifier-api**
(:7003) on their default config (no setup files), then runs `dcp-demo.py`, which:

1. onboards a **Governance-Authority-style issuer** identity (key + DID);
2. onboards a **participant-agent holder** identity (key + DID);
3. issues a **`SimplDataspaceMembershipCredential`** carrying the same governed
   identity attributes Simpl's Security Attributes Provider assigns today
   (`CONSUMER`, `DATA_SEARCHER`);
4. runs a full **OID4VP presentation exchange** and reads the verifier's verdict.

Expected tail:

```
6) VERIFIER VERDICT   : verified = True
DCP-STYLE PRESENTATION EXCHANGE VERIFIED — ...
```

## Why this matters for Simpl-Open

Simpl-Open already builds the VC ingredients as real services — `issuer-service-be`,
`wallet-service-be`, the `ssi-verifier/keycloak-extension` (walt.id), `signer-service-be`.
But those are wired for **Tier-1** (human end-user login via OID4VP) and contract
signing. **Tier-2 machine identity between connectors is still X.509 + mTLS +
ephemeral proof** — it does **not** use DCP.

This demo exercises the same credential + presentation mechanics that **DCP** defines
for Tier-2, at the credential/verifier layer, so the trust model can be evaluated
independently of the connector.

## Honest scope

- **Proven here (Tier-1 / credential core):** issue → hold → present → verify a
  governed Verifiable Credential over OID4VP, on Simpl's chosen stack. Green.
- **Not here (Tier-2 / DCP-in-the-connector):** binding this into the EDC connector's
  DSP handshake — i.e. connectors presenting/verifying VCs during contract
  negotiation instead of the ephemeral proof — needs the connector on an EDC version
  that ships the **DCP IdentityHub / CredentialService**. Simpl's `connector-be` was on
  EDC 0.10.1; **increment D bumps it to native EDC 0.11.1** and proves a real
  provider→consumer transfer on it (see below). Adding the DCP identity modules on top
  of that 0.11 base is the remaining wiring.
- **GA-as-issuer wiring:** here the issuer is a standalone walt.id identity. In Simpl
  the Governance Authority's `issuer-service-be` would issue these credentials and the
  SAP identity attributes would become VC claims.

## Increment B — native EDC 0.11 IdentityHub (`edc011-identityhub.sh`)

Where increment A proves the DCP *mechanics* on walt.id, increment B builds and runs the
**real Eclipse EDC IdentityHub v0.11.1 from source** — the actual **DCP CredentialService +
embedded SecureTokenService (STS)** — on the EDC 0.11 line (the line LDS / sovity EDC-CE
sit on, and the target for Simpl's Tier-2).

`./edc011-identityhub.sh` clones IdentityHub v0.11.1, builds the launcher shadow jar, boots
it, and verifies:

- **health** → `isSystemHealthy: true` (42 service extensions, embedded STS);
- **the DCP Presentation API is live and auth-guarded** —
  `POST /api/resolution/v1/participants/{id}/presentations/query` → **HTTP 401** without a
  valid self-issued (SI) token.

Walls the script clears (found the hard way): EDC needs a **JDK 17** toolchain; Maven Central
**rate-limits (429)** the shared egress IP (routed via the Google Maven mirror); EDC's
env-config loader **rejects duplicate `HTTPS_PROXY`/`https_proxy`** keys (proxy env unset for
the JVM).

A small **seed extension** (`seed-extension/`, compiled straight against the fat jar and loaded
on the classpath at boot) then puts a **`SimplDataspaceMembershipCredential`** — holding the same
`rawVc` JWT issued by walt.id in increment A — into the IdentityHub for a `simpl-provider`
participant context (this version seeds the super-user **in-process**, as there is no HTTP
bootstrap). The script reads it back through the authenticated DCP Identity API:

```
participant : simpl-provider
credential  : ['VerifiableCredential', 'SimplDataspaceMembershipCredential']
state       : 500 (ISSUED)
```

**Fully-verified presentation** (`edc011-present.py`): the orchestrator generates a provider +
verifier EC key, hosts both DID documents as **did:web over http** (:7100), boots the IdentityHub
seeded with the provider key + resolvable DID, builds the DCP **self-issued token** exactly as
EDC's `JwtCreationUtil.generateSiToken` (an SI token signed by the verifier key wrapping a scoped
access token signed by the provider key), and POSTs the `PresentationQueryMessage`. Result:

```
presentation query -> 200
VP signed by      : did:web:localhost%3A7100:simpl-provider
credentials in VP : ['VerifiableCredential', 'SimplDataspaceMembershipCredential']
contains SimplDataspaceMembershipCredential: True
```

So on **native EDC 0.11** the IdentityHub validated the self-issued token (verifier DID + scoped
access token, DIDs resolved via did:web), resolved the credential by scope, and returned a signed
**Verifiable Presentation of the Simpl membership credential** — the real DCP Tier-2
machine-identity presentation flow, not a mock. (One dev switch: `accesstoken.jti.validation` is
turned **off** so a self-crafted access token is accepted on signature alone; in production the
holder's STS issues that token and its jti is tracked.)

**Proven end to end:** DCP mechanics on Simpl's chosen walt.id stack (increment A) **and** the
full DCP Presentation Flow on the native EDC 0.11 IdentityHub (increments B/C).

## Increment D — bump Simpl `connector-be` to native EDC 0.11.1 (`edc011-connector.sh`)

Wiring DCP into the connector needs `connector-be` off EDC 0.10.1 and onto the 0.11 line first.
`./edc011-connector.sh` clones connector-be, applies `../patches/connector-edc-0.11.patch`, builds,
and runs the canonical provider→consumer transfer on the freshly built 0.11.1 jar. The **entire
bump is three lines of `pom.xml`, no Java changes** — all 53 custom classes compile clean on 0.11.1:

```
1. <edc>0.10.1</edc> -> <edc>0.11.1</edc>
2. remove legacy data-plane-control-api (0.8.1)   3. force runtime-metamodel to ${edc}
```

Verified on native EDC 0.11.1:

```
provider + consumer boot "Runtime … ready"  (gxfs MinioS3 + ionos infra + aws + custom all link)
transfer: INITIAL -> REQUESTED -> STARTED -> COMPLETED   >>> TRANSFER VERIFIED (example-s3.txt)
```

The full 0.10 → 0.11 diff and its Simpl impact — including the one non-obvious trap (the gxfs/ionos
extensions drag in `runtime-metamodel:0.10.1`, which lacks 0.11's `@Configuration`, so the metamodel
must be force-aligned) — is written up in **[`EDC-0.10-vs-0.11.md`](./EDC-0.10-vs-0.11.md)**.

## Increment E — swap the connector's identity to native DCP (`edc011-connector-dcp.sh`)

On the 0.11.1 base, this replaces Simpl's custom Tier-2 `SimplIdentityService` (X.509/mTLS +
ephemeral proof) with **EDC's native DCP `IdentityService`** — so the connector uses the
Decentralized Claims Protocol for machine identity. Again the change is tiny
(`../patches/connector-dcp-0.11.patch`):

```
pom.xml : + identity-trust-core, token-core, identity-did-core, identity-did-web,
            identity-trust-issuers-configuration  (sts-embedded, transforms, VC verification
            come transitively via identity-trust-core)
SPI     : - eu.europa.ec.simpl.iam.service.IamExtension   (so EDC's DCP IdentityService wins;
            two IdentityService providers would conflict)
```

**Stages 1 + 2 — VERIFIED.** The connector builds with the DCP stack bundled and boots on it:

```
Using the Embedded STS client, as no other implementation was provided.
Runtime … ready
SimplIdentityService NOT registered : ✔   (grep count 0)
management + DSP APIs live
```

So `connector-be` now runs EDC's **DCP `IdentityService` + embedded STS + did:web resolution**,
not the custom X.509 IAM. Config keys discovered/used: `edc.iam.issuer.id`,
`edc.iam.sts.privatekey.alias`, `edc.iam.sts.publickey.id`, `edc.iam.did.web.use.https`,
`edc.iam.trusted-issuer.*` (the DCP default services extension supplies the AudienceResolver +
scope extractor, so no shim was needed).

Run: `./edc011-connector-dcp.sh` · tear down: `fuser -k 29193/tcp`.

### Stage 3 — credential-gated transfer between two connectors (`edc011-dcp-transfer.py`) — VERIFIED

Two Simpl connectors complete a DSP transfer that is gated by a **DCP-verified
`SimplDataspaceMembershipCredential`**. The IdentityHub from B/C and the connector from D/E now work together.

What the EDC 0.11.1 jars showed, and how Stage 3 uses it:

- **The STS key needs no vault seeding.** `AbstractPrivateKeyResolver` falls back to configuration, so
  each connector gets its private JWK as a config value named after `edc.iam.sts.privatekey.alias`.
- **0.11.1 has no default DCP scope.** Without one, a handshake asks for no credential at all. A small
  **`SimplDcpExtension`** (now part of `connector-dcp-0.11.patch`) adds the scope
  `org.eclipse.edc.vc.type:SimplDataspaceMembershipCredential:read` to every DSP request
  (catalog, negotiation, transfer, version).
- **Claims bridge.** The same extension replaces the default claim-token function. It keeps the rule
  "no credential on the presentation → reject", and turns the verified credential into `client_id`
  (the subject DID) and Simpl's own `identity_attributes`. **Simpl's existing ABAC rule
  (`edc:consumption`, `ConsumptionConstraintFunction`) runs unchanged, on DCP-verified credential data.**
- One IdentityHub hosts both participants (`seed-extension/` has a new multi-participant mode,
  `SIMPL_SEED_JSON`). did:web documents for the Governance Authority, the provider and the consumer are
  served over http; each connector's document lists a CredentialService endpoint on the IdentityHub.
  The GA signs JWT credentials whose subject is the connector's DID.

`../../motoenv/bin/python edc011-dcp-transfer.py` runs four scenarios, each on fresh databases and
freshly booted runtimes:

```
scenario           reached       outcome      result
positive           transfer      COMPLETED    PASS   file delivered to consumer-bucket
abac-deny          negotiation   TERMINATED   PASS   "Policy in scope contract.negotiation not fulfilled … consumption"
untrusted-issuer   catalog       REJECTED     PASS   401 "Credential types [… SimplDataspaceMembershipCredential]
                                                      are not supported for issuer did:web:…:ga"
no-credential      catalog       REJECTED     PASS   401 "No VerifiableCredentials were found on VP"
```

In the positive run each connector verified the other's credential four times over the exchange
(`[SIMPL-DCP] verified … issued by did:web:…:ga to did:web:…:consumer -> identity_attributes=[CONSUMER,
DATA_SEARCHER]`), and the provider logged `Evaluating constraint: consumption EQ CONSUMER`. The
rejection reasons above come from a run with `EDC_LOG_LEVEL=DEBUG`.

Two dev settings remain: did:web over http, and access-token jti validation off (the embedded STS of
one process issues tokens the IdentityHub of another process validates). Everything else is native
EDC 0.11.1 behaviour.

---

Run: `./edc011-identityhub.sh` · tear down: `pkill -f identity-hub.jar`.

## Prerequisites

- A working **Docker daemon** (the script starts `dockerd` if needed).
- **python3** with the **`cryptography`** package (used for the ES256 VP signature).
- Outbound access to Docker Hub (`waltid/issuer-api`, `waltid/verifier-api`).

No Simpl mesh is required — this is self-contained.

## Usage

```bash
cd simpl-open-lab/iaa/dcp
./run.sh
```

Tear down: `docker rm -f waltid-issuer waltid-verifier`.

## Files

| File | Purpose |
|---|---|
| `run.sh` | pull + start walt.id issuer/verifier, then run the demo |
| `dcp-demo.py` | onboard issuer+holder → issue Simpl VC → OID4VP present → verify |
| `edc011-identityhub.sh` | build + boot the native **EDC 0.11 IdentityHub**, seed a Simpl credential, read it back via the DCP API |
| `seed-extension/` | tiny EDC `ServiceExtension` that seeds `simpl-provider` (+ injectable key) + a `SimplDataspaceMembershipCredential` at boot; `SIMPL_SEED_JSON` seeds several participants with their own keys and credentials |
| `edc011-present.py` | end-to-end **verified DCP presentation** on native EDC 0.11 (did:web hosting + SI token + `/presentations/query` → VP) |
| `edc011-connector.sh` | bump Simpl **connector-be to native EDC 0.11.1**, build, and run a verified provider→consumer transfer on it |
| `connector-edc-0.11.patch` | *(in `../patches/`)* the pom-only 0.10.1→0.11.1 bump (edc property, drop legacy control-api, force runtime-metamodel) |
| `EDC-0.10-vs-0.11.md` | the meaningful 0.10 → 0.11 differences and their impact on Simpl `connector-be` |
| `edc011-connector-dcp.sh` | swap connector-be's identity to EDC's native **DCP `IdentityService`**; build + boot-verify (increment E, stages 1–2) |
| `connector-dcp-0.11.patch` | *(in `../patches/`)* add the DCP module set, drop Simpl's `IamExtension`, add `SimplDcpExtension` (membership scope + claims bridge to Simpl ABAC) |
| `edc011-dcp-transfer.py` | increment E stage 3: credential-gated transfer between two DCP connectors, four scenarios (positive, ABAC deny, untrusted issuer, no credential) |
