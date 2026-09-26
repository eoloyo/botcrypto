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
  that ships the **DCP IdentityHub / CredentialService** (Simpl's `connector-be` is on
  EDC 0.10.1; a bump toward EDC 0.16/0.11+ is required, and there is an
  `update-edc-to-0-16-0` branch upstream). That is the next increment.
- **GA-as-issuer wiring:** here the issuer is a standalone walt.id identity. In Simpl
  the Governance Authority's `issuer-service-be` would issue these credentials and the
  SAP identity attributes would become VC claims.

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
