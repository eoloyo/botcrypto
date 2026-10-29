# End-user wallet login (OpenID4VP) to a Simpl agent

How an end user logs in to a Simpl agent with a wallet instead of a password, run end to end against
Simpl's own code: the **ssi-verifier-keycloak-extension** from code.europa.eu (branch
`feature/prepare-sprint-36`, 2026-09-08, the newest; `main` is from May), built from source and loaded
into **Keycloak 26.4**, which is the version the extension targets.

```bash
./run.sh      # build + start everything, issue a credential into the wallet, log in; ~1 min after images are cached
```

| Part | What runs | Port |
|---|---|---|
| Agent login | Keycloak 26.4 + the extension, realm `authority` (the extension's own realm export), test client `lab-app` | 8180 |
| Verifier | walt.id **verifier2** (the only verifier type the extension supports, `Walt-id`) | 7004 |
| User's wallet | walt.id **wallet2** (headless; the extension's own local set-up uses it) | 7006 |
| Users and Roles | `trusted_issuers_stub.py` — serves `GET /trustedIssuers`, the one call the extension makes | 8082 |
| Trusted issuer | `mint_credential.py` — signs the user's credential (see "Lab shortcut") | — |
| The user | `login.js` — headless Chromium driving the login pages; the wallet API answers the request | — |

## What happens (verified run)

1. The user opens the agent and is sent to its Keycloak login page, which offers **"Verifiable Credentials"**.
2. On that click the extension asks **Users and Roles** for the enabled **trusted issuers**
   (`GET /trustedIssuers?status=ENABLED&unpaged=true`). Each one carries a **`credentialQuery`**: a walt.id
   verifier session request with a **DCQL** query (here: a `jwt_vc_json` `SimplDataspaceMembershipCredential`).
   With one issuer configured the credential-type selection page is skipped.
3. The extension creates a session at the verifier (`POST /verification-session/create`) and shows the
   returned `openid4vp://authorize?…` request as a QR code and a copyable link
   (page "Authorization Request — log in with your verifiable credentials using a wallet application").
4. The wallet resolves the request and sends a **verifiable presentation** to the verifier (OpenID4VP 1.0,
   cross-device, `direct_post`). The verifier checks the presentation (audience, nonce, holder signature,
   exp/nbf) and the credential (issuer signature) → session `SUCCESSFUL`.
5. The login page polls Keycloak (`/broker/oid4vp/endpoint/verificationStatus`); Keycloak reads the
   session result from the verifier and completes a **brokered login**, redirecting to the application
   with an authorization code. Tokens carry `preferred_username=wallet_user_<holder DID>`, name and email
   taken from the credential.

## What it tells us about Simpl in practice

- **The user needs an OpenID4VP wallet and a credential from an issuer the agent trusts.** The agent's list
  of accepted credentials is not in Keycloak: it is the **trusted issuers in Users and Roles**, fetched at
  every login. Any OpenID4VP wallet that holds a matching `jwt_vc_json` credential works.
- **No account has to exist beforehand.** The first wallet login creates the Keycloak user automatically
  (username from the holder DID, first/last name and email from the credential, email *not* verified) and
  links it to the identity provider by the **SHA-256 of the whole `credentialSubject`**. The second login
  with the same credential lands on the same user. A re-issued credential with any changed subject claim
  hashes differently, so Keycloak would treat it as a new identity (inferred from the code, not run).
- **The login gives no Simpl roles or attributes.** The token holds only Keycloak's default roles. The
  `identityAttributes` inside the credential (`CONSUMER`, `DATA_SEARCHER`) are not mapped; the extension
  maps only subject id, name and email. Simpl roles/attributes come from the separate **Attribute
  Authenticator** post-login flow (keycloak-authenticator), which this run did not configure.
- **Issuer trust depends on the query.** The extension forwards the trusted issuer's `credentialQuery` to
  the verifier and does not use the record's `issuerUri` / `keyIdentifier`. The verifier's default
  policies check signatures, holder binding, nonce and validity, but no issuer allow-list; restricting
  which issuers may log users in has to be written into the query.
- **EUDI.** The protocol is the EUDI one (OpenID4VP 1.0 + DCQL), the walt.id verifier has policy sets
  for `dc+sd-jwt` and `mso_mdoc`, and the wallet2 config shipped with the extension points at the EUDI
  wallet provider (`wallet-provider.eudiw.dev`) for wallet attestation. What keeps an EUDI PID out is the
  configured query format (`jwt_vc_json`), not the protocol.
- **The QR code needs internet.** The page loads `qrcodejs` from `cdnjs.cloudflare.com`; without it (as
  in this sandbox) only the link is shown.

## Lab shortcut

The credential is signed by `mint_credential.py` (ES256, issuer `did:jwk`, W3C VC 1.1 as `jwt_vc_json`)
and imported into the wallet (`POST /wallet/{id}/credentials/import`) instead of being issued over
OpenID4VCI by walt.id issuer2: Docker Hub rate-limited that image (`429`). Everything from the login page
onwards — the extension, the verifier, the wallet's presentation — is the real flow. The verifier2 image
comes from `mirror.gcr.io` for the same reason.
