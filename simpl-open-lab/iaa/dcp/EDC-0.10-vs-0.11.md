# EDC 0.10 → 0.11: what actually changed, and what it meant for Simpl `connector-be`

This is the companion writeup to the real bump of Simpl-Open's `connector-be` from
**Eclipse EDC 0.10.1 → 0.11.1** (`iaa/patches/connector-edc-0.11.patch`,
`iaa/dcp/edc011-connector.sh`). It separates the *meaningful* differences from the noise, and
records the empirical result of running the bumped connector end to end.

## TL;DR — the bump itself

The entire migration is **three lines of `pom.xml`** — **no Java changes**. All 53 of
connector-be's custom classes (custom `IdentityService`, policy functions, data-plane
source/sink factories, transfer/contract guards) compile unchanged against 0.11.1.

```
1. <edc>0.10.1</edc>  ->  <edc>0.11.1</edc>
2. remove  org.eclipse.edc:data-plane-control-api : 0.8.1   (legacy; gone in the 0.11 line)
3. force   org.eclipse.edc:runtime-metamodel : ${edc}       (in <dependencyManagement>)
```

Empirically verified on native EDC 0.11.1:

```
build            : basic-connector.jar (69 MB) builds clean, bundling runtime-metamodel-0.11.1
provider+consumer: both boot "Runtime … ready" on 0.11.1 (all gxfs/ionos/aws + custom
                   extensions link on 0.11.1 core — no AbstractMethodError/NoClassDefFoundError)
transfer         : INITIAL -> REQUESTED -> STARTED -> COMPLETED   (MinioS3-PUSH)
verify           : example-s3.txt present in consumer-bucket   >>> TRANSFER VERIFIED
```

So the DSP contract negotiation **and** the (gxfs MinioS3) data-plane transfer both work on 0.11.1
with the Simpl connector stack intact.

## The one non-obvious trap: `runtime-metamodel` version skew

EDC 0.11 introduces a **configuration-injection mechanism** — the `@Configuration` / `@Settings`
annotations, which live in `org.eclipse.edc:runtime-metamodel`. Simpl pulls two third-party EDC
extension sets that predate 0.11:

- `fr.gxfs.edc:minio-s3-*` (`0.0.1`) — the Gaia-X MinIO S3 data plane, and
- `com.ionoscloud.edc:*-simpl-infrastructure` (`1.0.1`, system-scoped jars in `libs/`).

The gxfs jars are declared **first** in the pom and drag in `runtime-metamodel:0.10.1`
transitively, which — by Maven's nearest/first-declared mediation — **wins** over the `0.11.1`
metamodel that 0.11 core brings. The 0.10.1 metamodel has no `@Configuration`, so 0.11 core
explodes at boot:

```
java.lang.NoClassDefFoundError: org/eclipse/edc/runtime/metamodel/annotation/Configuration
    at org.eclipse.edc.boot.system.injection.InjectionPointScanner…
```

Fix: pin `runtime-metamodel` to `${edc}` in `dependencyManagement` so the whole extension set links
against one metamodel. This is the kind of skew any 0.11 bump that keeps older third-party EDC
extensions will hit.

## Meaningful 0.10 → 0.11 differences (and the Simpl impact)

| Area | 0.10 → 0.11 change | Impact on Simpl `connector-be` |
|---|---|---|
| **DSP protocol** | Introduces the **`dspace` 2024/1 namespace** with protocol **version negotiation** (a `/…/.well-known/dspace-version`-style endpoint; the endpoint is present — returns 401 under the protocol auth filter). | The default `dataspace-protocol-http` binding still negotiates and transfers (proven). **Watch item:** the federated **catalogue-be** crawler and `sd-tooling`/`08-discover` path — if they pin the older DSP dialect, confirm negotiation keeps discovery working, else align them next. |
| **Config injection** | New `@Configuration` / `@Settings` annotations in `runtime-metamodel`; config can be injected into extensions. | Root cause of the metamodel skew above. Once forced to `${edc}`, connector-be's own extensions keep using `context.getSetting(...)` unchanged. |
| **Module reorg** | `token-core` → **`token-lib`**; `sql-lib` / `sql-testfixtures` extracted; **`data-plane-iam` extracted** from `data-plane-core`. | Transitive only for Simpl — connector-be names none of the moved artifacts directly, so nothing to re-declare. `data-plane-core` still pulls the IAM pieces it needs. |
| **Policy engine** | **`ParticipantAgentPolicyContext`** redefined; policy validation + **evaluation-plan** APIs added. | Simpl's `ConsumptionConstraintFunction` / `LocationConstraintFunction` compile unchanged; the ABAC evaluation still runs (the 02 policy allows `use`). If Simpl later reworks its policy context, the new evaluation-plan API is available for debugging ABAC. |
| **Legacy data-plane control API** | `data-plane-control-api` dropped from the line (data plane is fully **signaling**-based). | Removed the `0.8.1` pin. `data-plane-signaling-api` + `transfer-data-plane-signaling` (already present) carry it. Transfer still `COMPLETED`. |
| **Tokens / DCP** | **JTI validation** for self-issued tokens (`edc.iam.accesstoken.jti.validation`); **VC DataModel 2.0** support; bi-directional transfers. | Not exercised by connector-be yet (it still uses the Simpl X.509/mTLS Tier-2 `IdentityService`). These are exactly the primitives the **DCP-in-connector** step needs — same `jti.validation` switch used in the IdentityHub increment. |
| **Dependency / security bumps** | Nimbus JOSE 9.40→10.0.1, Jackson 2.17.2→2.18.2, Micrometer 1.13.2→1.14.2, Gradle wrapper 8.10. | Simpl already overrides Nimbus (`10.9.1`), protobuf and jersey-client for CVEs; the pom comment "*Once EDC ≥ 0.11.0 … jersey-client override can be removed*" confirms 0.11 was the sanctioned target. |
| **Java baseline** | **Stays Java 17.** | No JDK bump for Simpl — `maven.compiler.{source,target}=17` unchanged. |
| **Config groups** | `web.http.default` group reintroduced as **deprecated**; management API gains an optional JSON-LD context. | No change to Simpl's explicit `web.http.*` port/path config. |

## What is *not* solved by this bump (the actual DCP-in-connector step)

Being on 0.11.1 is the **prerequisite**, not the DCP wiring itself. connector-be still authenticates
Tier-2 with the custom Simpl `IdentityService` (X.509/mTLS + governed attributes from the auth
provider). Turning on **DCP** in the connector additionally means adding the EDC identity modules
now available on the 0.11 line — `identity-did-core`/`identity-did-web`, `identity-trust-*`
(the DCP client), and pointing the connector at a **CredentialService / IdentityHub** — so that
during the DSP handshake the connector *presents and verifies Verifiable Credentials* instead of the
ephemeral proof. That IdentityHub + Presentation Flow is exactly what increments B/C already proved
runs on native EDC 0.11; the connector bump here lets those two halves finally meet.

## Reproduce

```bash
cd simpl-open-lab/iaa/dcp
./edc011-connector.sh      # clone → apply patch → build on 0.11.1 → run + verify the transfer
```
