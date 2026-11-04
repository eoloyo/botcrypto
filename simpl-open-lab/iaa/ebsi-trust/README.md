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
  accredited for diplomas is accepted for a Simpl membership credential), and mapping an EBSI credential to
  Simpl roles (the wallet login still grants none, see `../ssi-login`). Tier 2 is the next section.
- The webhook is a sidecar, not Simpl-native; it is a lab implementation, not hardened for production.

---

# Tier 2 — agent-to-agent (`authp-be`, `develop`)

```bash
./run.sh tier2                      # 19 link tests + 3 HTTP-contract checks against a stub EBSI + did:web host
./run.sh java <authp-be checkout>   # Java adapter: 12 tests + 4 against the real sidecar (offline, see below)
git apply authp-be-develop-ebsi-gate.patch   # the Java change, against origin/develop (60bdc8e0)
```

## How Tier-2 trust works today (read from `develop`, not assumed)

A participant presents a VP whose `ParticipantCredential` is issued by a **`did:web` Authority** and signed
with an **X.509 certificate** the DID document points at (`x5u`). `VerifiablePresentationVerificationService`
checks signatures and expiry only — its Javadoc: *"no trust decision on the issuers: a Verified presentation
may still come from an untrusted issuer"*. The decision is in `Tier2SessionServiceImpl.createVerifiedSession`:
the **local** Governance Authority's issuer is trusted; any other issuer is **federated**, and the agent asks
**its own GA** for a `TrustRelationCredential` naming that issuer (directed, not transitive).

## The mismatch, and the design choice it forced

The issuer is a `did:web`; EBSI's registries only hold `did:ebsi`. So EBSI cannot judge the issuer directly:
something must **link** the two, and a bare claim of a public `did:ebsi` proves nothing. Neither Simpl nor EBSI
defines such a link, so this is **the lab's own format**, a decision to be confirmed, not a standard:

> the Authority's `did:web` document carries a `LinkedEbsiIdentity` service whose endpoint is
> `{"ebsiDid": "did:ebsi:…", "proof": "<JWS signed by a key of that did:ebsi, subject = this did:web>"}`.

The sidecar's new `GET /check-web?vm=did:web:…#key` fetches the DID document, verifies the proof against the
EBSI DID's registered key (so claiming someone else's accredited identity fails), then runs the same
`TI → TAO → Root TAO` walk as Tier 1. Alternatives not built: the Authority re-issues from a `did:ebsi`; or
EBSI is used only as admission evidence when the GA creates the trust relation.

The issuer string comes from a presentation by a **not-yet-trusted participant**, so fetching its `did:web`
host is attacker-steered: the sidecar allows only public hosts (resolved IPs checked), refuses redirects, caps
the body at 256 KiB, binds the document to the DID asked for, and validates the DID syntax.

## Where it sits in `authp-be`

In the federated branch, **after** the trust-relation check and before attributes are mapped. It is **in
addition to** the `TrustRelationCredential`, never instead of it; the local GA's own participants are not
asked; **off by default**; **fail closed** (an unavailable EBSI service is a refusal). New code: `EbsiTrustAdapter`
(+ `Impl`, a Spring `RestClient`, redirects refused, only an explicit `trusted:true` with a `did:ebsi` passes),
`EbsiProperties` (`simpl.ebsi.enabled|url|timeout`, a separate record because five tests construct
`SimplProperties` by hand), a `CreateSessionOutcome.EbsiAccreditationFailed` case, and its controller case. It
maps to the same generic 500 as `TrustRelationUnavailable` (the module's convention: no detail to the caller).

## Results

| Check | Result |
|---|---|
| Link tests: valid link; no link; **claims an accredited TI's DID but cannot sign as it**; proof replayed from another authority; proof expired; `alsoKnownAs` ≠ link; proof not from the linked DID; linked DID not accredited; forged TAO behind a valid link; DID document for another DID; redirect; oversized; localhost/private host (SSRF); path-traversal DID; not a `did:web`; EBSI down; did:web host down | **19 / 19** (Tier-1 chain tests still 14 / 14) |
| Sidecar over HTTP, called with the percent-encoding the Java client produces: 200 / 403 / 503 | 3 / 3 |
| Java `EbsiTrustAdapterImplTest` (JDK `HttpServer`): trusted, rejected + reason, `trusted:false`, `trusted:true` without a `did:ebsi`, `trusted:"true"`, 503, 500, unreadable body, redirect, nothing listening, disabled; `#` and `%3A` survive to the decoded `vm` | **12 / 12** |
| Java adapter ↔ **real Python sidecar** (stub EBSI + did:web host): accredited → trusted; unlinked and stolen-identity → not trusted with the sidecar's own reason; sidecar down → unavailable | **4 / 4** |
| Patch applies to a clean `origin/develop` | yes |

**Not run: the `Tier2SessionServiceImpl` change and its tests.** The gate itself, six new cases in
`Tier2SessionServiceImplTest` (disabled → never asked; accredited → cached; not accredited → refused;
**EBSI unavailable → refused**; **accredited issuer but no trust relation → still refused**; local issuer →
never asked) and the controller mapping case are written but **were not compiled or run**: `develop` needs
`simpl-parent:3.3.0-SNAPSHOT` and a large dependency graph from the GitLab package registry, which Maven
resolved here at about five artifacts a minute (20+ minutes, no jars), so the build never reached compilation.
Checked by reading against the module's types only. To run them where the registry is reachable:

```bash
git apply authp-be-develop-ebsi-gate.patch      # in an authp-be checkout of origin/develop
mvn test -Dtest='Tier2SessionServiceImplTest,Tier2SessionControllerTier2V2MockMvcTest,EbsiTrustAdapterImplTest'
```

## Not done / not shown — read before relying on this

- **No Tier-2 session was run end to end** with two real `develop` agents; a real EBSI-accredited authority with a
  published link cannot be produced either (we hold no key of an EBSI-registered issuer). The live-EBSI evidence
  is the Tier-1 run; Tier 2 is verified against a stub EBSI whose chains are really signed.
- **The link binds identities, not keys**: it proves the `did:web` controller also controls the accredited
  `did:ebsi`; it does not tie the X.509 issuer key to an EBSI key.
- **Sessions are cached**, so a later EBSI withdrawal of an accreditation is not seen until the session expires.
- **Latency**: a cold chain walk took 66–80 s on the pilot; `simpl.ebsi.timeout` defaults to 90 s. A Tier-2
  session creation that hits a cold cache would block that long, so pre-warm or sync in production.
- The SSRF guard checks resolved addresses before the request (DNS rebinding between check and fetch is not
  closed); the sidecar is a single extra component on the session path.
- Revocation/status, `accreditedFor` matching, and attribute mapping from EBSI are not touched.
- The Java service change is not Tier-2-run in Spring: see the line above on what was and was not compiled.
