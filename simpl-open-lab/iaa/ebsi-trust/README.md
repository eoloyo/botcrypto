# EBSI issuer trust for the Simpl Tier-1 wallet login

Adds "the credential's issuer must be an EBSI-accredited Trusted Issuer" to the wallet login we built in
`../ssi-login`, using walt.id's verifier2 (the verifier Simpl's `ssi-verifier-keycloak-extension` pins) and a
small sidecar. No Simpl code is changed.

```bash
./run.sh tests              # 14 accept/reject tests against a stub EBSI, ~2 s, no network
./run.sh live did:ebsi:...  # check one issuer against the live EBSI pilot registries
./run.sh verifier           # same credential through the real verifier2, with / without the policy
./run.sh login              # the full Keycloak login with the policy on
```

## Premise corrected: verifier2 has no EBSI trust policy

walt.id's documented EBSI trusted-registry check belongs to the old Verifier v1 (community stack,
`openId4VPProfile=EBSIV3`, EBSI v3). **Verifier2 — the one Simpl uses — ships 11 policies and none is EBSI**:
`signature, expiration, not-before, allowed-issuer, schema, regex, credential-status, revoked-status-list,
vical, etsi-trust-list, webhook`. So EBSI issuer trust is not a switch to flip; this is built on the one
extension point verifier2 offers, the **`webhook`** policy.

## How it plugs in

verifier2's `webhook` VC policy POSTs the credential to a URL and treats **2xx as pass, anything else as
fail** (request shape captured by running it: the credential object with top-level `issuer` and `subject`,
plus the signed JWT). The policy is part of the session request, which Simpl's Keycloak extension forwards
verbatim from the trusted issuer's `credentialQuery` in Users and Roles — so it is configured per trusted
issuer, with no extension change:

```json
"core_flow": { "dcql_query": {...},
  "policies": { "vc_policies": [ {"policy":"signature"},
                                 {"policy":"webhook","url":"http://ebsi-trust:8091/verify"} ] } }
```

`ebsi_trust_webhook.py` then requires, for the credential's issuer DID:

1. it is a `did:ebsi` that resolves in the EBSI **DID Registry** (response bound to the requested DID);
2. it is in the **Trusted Issuers Registry** (response bound to the requested DID);
3. its accreditation JWT is unexpired and its **signature verifies against the accrediting authority's key from
   the DID Registry** (ES256 / ES256K; the `jwk` embedded in the JWT header is never trusted), recursively up
   `TI → TAO → Root TAO`;
4. the chain ends at a Root TAO in `EBSI_ROOTS` (**pin it**; unset accepts any root and reports it).

Only a `TI` may issue credentials by default (`EBSI_LEAF_TYPES`). Any EBSI API failure is a **503, never a pass**.

## Results

| Check | Result |
|---|---|
| Stub-EBSI tests (valid chains; forged TI/TAO/root signatures; expired; wrong TAO; unpinned root; registry answering with another DID's record — the openvc #267 class; unregistered; TAO as issuer; `did:jwk`; EBSI down) | **14 / 14** |
| **Live pilot**, TI `did:ebsi:zng59…` (3 real hops, real signatures) | **TRUSTED** `TI → TAO → RootTAO`, anchored at `zZeKy…` |
| Live pilot, same TI, pinned to its real root / to a different root | trusted / rejected |
| Live pilot, TI `zgnh3…` (chain is `TI → RootTAO zmiRzp…`) | rejected under pin `zhpVqk…` (*"not a pinned EBSI root"*), trusted under pin `zmiRzp…` |
| Live pilot, Root TAO or unregistered DID as issuer | rejected |
| **Real verifier2**, lab credential (`did:jwk` issuer), `[signature]` | session SUCCESSFUL (today's behaviour) |
| Real verifier2, same credential, `[signature, webhook]` | session **FAILED**, `vc policy webhook FAIL` |
| **Real Keycloak login**, EBSI policy on | wallet refused: *"Credential policy verification failed. Failed VC policies: webhook"*, no code issued |
| Same login, policy off (control) | tokens issued |

The last four rows close the gap found in `../ssi-login/README.md` (extra test 1): a correctly signed
credential from **any** issuer used to log a user in.

## What the live registry taught

- **The real Root TAO is not self-accredited.** Its attribute is a `VerifiableAuthorisationForTrustChain`
  issued by a separate anchor DID. The first version modelled a self-issued root and failed on real data;
  the synthetic tests were corrected to the real shape and still cover the self-accredited variant.
- **Latency is the operational problem.** Cold chain walk: **66–80 s** against the pilot (~10 sequential
  registry calls, single calls up to ~6 s observed; a shorter 2-hop chain took 20 s); warm cache: **< 1 ms**. A login that hits a cold cache would stall,
  so production needs a pre-warmed/refreshed cache or a periodic sync of accredited issuers (the
  `allowed-issuer` policy, which is static) rather than resolving at login. The pilot also timed out under
  load; the service retries once and then fails closed.
- Pilot ≠ production: several demo Root TAOs exist; the pin must be EBSI's designated root for the
  environment you target.

## Not done / not shown — read before relying on this

- **No positive login with an EBSI-issued credential.** We hold no key of an EBSI-registered issuer, so
  "trusted issuer → login succeeds" is shown at the webhook (live data) but **not** through verifier2.
- **verifier2's own `did:ebsi` resolution is unverified.** Its `signature` policy resolves `did:ebsi` through
  `https://api-conformance.ebsi.eu/...` (hard-wired to the *conformance* environment, seen in its log); in this
  sandbox the call fails with `PKIX path building failed` (the egress proxy's TLS interception is not trusted
  by the container's JVM), so whether it verifies a real EBSI signature, and whether that endpoint is
  configurable, is open. A credential claiming a real pilot TI but signed with a foreign key therefore failed
  with `Could not resolve issuer key`, which does not distinguish "no support" from "sandbox TLS".
- Not covered: credential **revocation/status**, matching `accreditedFor` to the credential type (an EBSI TI
  accredited for diplomas is accepted for a Simpl membership credential), Tier-2 (`authp-be`, X.509/mTLS
  — untouched), and mapping an EBSI credential to Simpl roles (the wallet login still grants none, see
  `../ssi-login`).
- The webhook is a sidecar, not Simpl-native; it is a lab implementation, not hardened for production.
