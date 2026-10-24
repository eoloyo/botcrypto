# Two governance authorities, federated (BP02D)

Step 3 of the EOSC → DestinE pilot: instead of mocking the DestinE side's attributes, stand up two
**real** Simpl governance authorities and federate them, so the attributes the DestinE provider
checks are produced by a governed mapping from the EOSC consumer's attributes.

This uses the federation-era IAA services from `code.europa.eu` `main`
(`identity-provider-be`, `security-attributes-provider-be`, `authentication-provider-be`), which
carry the trusted/trustor-authority and ephemeral-proof-exchange code behind BP02D — newer than the
single-authority services the rest of the lab builds.

```bash
cd simpl-open-lab/iaa/fed
./authority.sh B          # DestinE data space   : idp :8303 sap :8302 authp :8305 CA :33443 t1 :8300
./authority.sh A          # EOSC research data space: idp :8203 sap :8202 authp :8205 CA :32443 t1 :8200
python3 -I federate.py    # BP02D: B trusts A + attribute mapping, verified
python3 -I exchange.py    # LIVE: A issues a real proof -> B exchanges it -> mapped attributes
./reset.sh                # stop both and delete their state
# ../../scripts/17-federated-contract.sh  # the mapped attributes drive the provider's contract decision
```

Each `authority.sh <A|B>` brings up, for one authority: its own CA (`ejbca-shim`), a Postgres
database per service, a Redis database, the three IAA services, a Tier-1 routing stand-in
(`tier1_router.py`), and an OCSP responder; then runs the chart's init-authority sequence
(keypair → dataspace → CSR → participant → credential → install) so the authority holds a real
credential signed by its own CA. One shared Kafka broker carries the credential events the
authentication provider emits (an install fails without it).

## What `federate.py` establishes and verifies

1. **Identity attributes.** `RESEARCH_ORG` and `EOSC_DESTINE_PARTNER` at A; `DESTINE_UPGRADED_ACCESS`
   at B (`CONSUMER`, `CATALOGUE_SEARCHER` and the provider/publisher codes are built in on both).
2. **Federation (BP02D).** B discovers A (`trustedAuthorities/discover` fetches A's public profile,
   credential and public attributes through A's Tier-1 endpoints), trusts it, and sets the mapping:

   | A (EOSC) attribute | → B (DestinE) attribute |
   |---|---|
   | `CONSUMER` | `CONSUMER` |
   | `EOSC_DESTINE_PARTNER` | `DESTINE_UPGRADED_ACCESS` |
   | `RESEARCH_ORG` | *(unmapped — does not cross)* |

3. **Verify.** The trusted authority reads back `ACTIVE` from B's identity provider, and the mapping
   reads back from B's security-attributes provider. `RESEARCH_ORG` is deliberately left unmapped:
   an agent gains only the rights the mapping grants, so a purely EOSC-internal attribute does not
   leak into the DestinE data space.

Result in `$LAB_ROOT/fed/federation.json`.

## Why this matters for the pilot

`16-destine-eosc.sh` mocks the DestinE consumer's organisation attributes by hand. This shows where
those attributes legitimately come from: the DestinE authority's **mapping** of the EOSC
authority's attributes, over released BP02D code. An EOSC participant holding `CONSUMER` and
`EOSC_DESTINE_PARTNER` is seen by DestinE as `CONSUMER` + `DESTINE_UPGRADED_ACCESS` — exactly the
attributes the provider's ODRL policy checks in the pilot.

## What is real, and what the live proof exchange still needs

- **Real:** two authorities, each with its own CA and bootstrapped credential; B's trust of A;
  the attribute mapping; the discovery calls between the two Tier-1 sides. All against the services'
  own code, no stubs in the IAA path.
- **Lab stand-ins:** `tier1_router.py` for each authority's Tier-1 gateway (routing only — the
  discovery endpoints are public); one CA (`ejbca-shim`) per authority instead of EJBCA; a shared
  Kafka broker.
- **Real — the live ephemeral-proof exchange** (`exchange.py`). A consumer is onboarded at A with
  a locally-generated key (A's CA signs its CSR, the credential is activated, its Tier-1 key
  registered, EOSC attributes assigned). A's security-attributes provider issues it a real,
  A-signed ephemeral proof (`POST /tier2/v2/token`, with a proof-of-possession signed by the
  consumer key). B's security-attributes provider then exchanges it
  (`POST /tier2/v2/token/exchange`): it looks A up as a trusted authority, applies the stored
  mapping via `TokenExchangeEphemeralProofGenerator`, and issues a B-signed proof. Measured:
  `CONSUMER + EOSC_DESTINE_PARTNER` on the A proof becomes `CONSUMER + DESTINE_UPGRADED_ACCESS` on
  the B proof. **Nothing is forged** — B only ever maps a genuinely A-signed proof; the SAP exchange
  does not re-check the signature, so a real A signature is the only legitimate input.
- **Then the contract decision** (`../../scripts/17-federated-contract.sh`). The attributes that come
  out of the exchange are fed to the DestinE provider connector's `ConsumptionConstraintFunction`
  for a `DESTINE_UPGRADED_ACCESS`-gated offer: a partner consumer (`CONSUMER + EOSC_DESTINE_PARTNER`
  at EOSC → `CONSUMER + DESTINE_UPGRADED_ACCESS` at DestinE) gets a contract; a plain consumer
  (`CONSUMER` only → `CONSUMER`) is refused. This is `16-destine-eosc.sh`'s mock replaced by the
  real federated identity.
- **Lab shortcut in the exchange:** the `Credential-Id` header on the Tier-2 calls is set directly,
  which the Tier-2 gateway would otherwise set after the mTLS handshake; no gateway is run. The
  proof issuance, trust check, mapping and signing are all the services' own code.

## Ports

| | A (EOSC) | B (DestinE) |
|---|---|---|
| identity-provider | 8203 | 8303 |
| security-attributes-provider | 8202 | 8302 |
| authentication-provider | 8205 | 8305 |
| Tier-1 router | 8200 | 8300 |
| CA (ejbca-shim) HTTP / HTTPS | 32080 / 32443 | 33080 / 33443 |
| OCSP responder | 32081 | 33081 |
| Tier-2 gateway URL (issuer id; no gateway runs) | https://localhost:8243 | https://localhost:8343 |

Shared: Postgres :5433, Redis :30379 (A uses db 1, B uses db 2), Kafka :9092.
