# EU LDT Toolbox — does it actually federate data spaces? (code-level findings)

**Question asked:** the EU LDT Toolbox documentation claims it does "federated data
spaces" / "cross-domain federation". Is that actually *implemented in code*, or is it
architectural/roadmap language? And how does it relate to Simpl-Open?

**Method:** cloned the public source from the EU's own GitLab
(`https://code.europa.eu/ldt-toolbox`) and read the code — not the marketing pages. The
namespace has 20 repositories; the federation-relevant ones inspected here are:

| Repo | Role |
| --- | --- |
| `eu_ldt_data_space_ready` | The **data-space connector facade** — the tool that makes an LDT deployment "data-space ready". This is where the federation logic lives. |
| `EU_LDT_Marketplace` | The **central marketplace** + per-deployment Marketplace Agent (hub-and-spoke). |
| `eu_ldt_identity_management` | Keycloak-based Identity Manager (DIDs/VCs + OIDC brokering). |
| `eu_ldt_data_modeller` | Data-model authoring tool (Fastify/TS CRUD). |
| `eu_ldt_data_platform` | Data platform / storage. |
| `eu_ldt_automation_deployment` | Bash+Helm installer that deploys each tool to a local K8s cluster. |

> Cloned at commit tips of `main` as of 2026-09-15. Nothing from these repos is
> committed here (they are multi-GB and EUPL-1.2 licensed); this file records what the
> code shows. Paths below are inside `eu_ldt_data_space_ready` unless stated otherwise.

---

## TL;DR verdict

The federation claim is **partly real code, partly not what "cross-data-space
federation" usually means.** Three distinct things are called "federation", and only two
of them are actually implemented:

1. **Participation in one data space via a pluggable connector** — ✅ **implemented**,
   and genuinely so for **EDC** (Eclipse Dataspace Components / Tractus-X), which brings
   real IDS/Dataspace-Protocol catalogue, contract negotiation and data transfer. FIWARE
   (NGSI-LD / TMForum) is a second, partially-covered backend.
2. **Hub-and-spoke federation *among LDT deployments*** — ✅ **implemented** in the
   Marketplace: identity federation (Keycloak OIDC brokering) plus publishing to a single
   central catalogue.
3. **Cross-*ecosystem* mediation between heterogeneous data spaces** (e.g. an EDC/DSP
   space ↔ a FIWARE space ↔ a Simpl space, with DCAT-AP ↔ XFSC semantic mapping, policy
   translation and contract translation) — ❌ **not implemented.** Each connector speaks
   exactly one backend; contract negotiation is EDC-only; there is no cross-backend
   semantic/policy/contract translation layer in the code.

So the Toolbox **federates within a single connector technology and within the LDT
ecosystem**, but it does **not** bridge two different data-space technologies at runtime.
That is exactly the interoperability gap the research thread flagged.

---

## 1. Data Space Ready is a *facade over external connectors*, not its own protocol

`eu_ldt_data_space_ready` does **not** implement a data-space protocol itself. It is an
abstraction layer that delegates to an underlying connector, selected per registered
connector instance. The recognised connector types are an enum
(`backend-py/src/models/ds_connector/dto/ds_connector_base_dto.py`):

```python
class ConnectorType(str, Enum):
    EDC     = "edc"       # Eclipse Dataspace Connector (IDS)
    NGSI_LD = "ngsi-ld"   # FIWARE Data Space Connector (NGSI-LD)
    SIMPL   = "simpl"     # Lightweight data space connector
    CUSTOM  = "custom"    # Generic/proprietary connector
```

The delegation happens through **adapter factories** in
`backend-py/src/services/adapters/`. The important consequence is that *capability
support is per-connector and uneven*:

| Capability | EDC | FIWARE / NGSI-LD | SIMPL | CUSTOM |
| --- | :---: | :---: | :---: | :---: |
| Catalogue create/update/list (`catalogue_adapter_factory.py`) | ❌ *(explicitly rejected)* | ✅ (TMF620) | ❌ | ✅ (TMF620) |
| Search (`search_adapter_factory.py`) | ✅ | ✅ (FDSC) | ❌ | ✅ (FDSC) |
| Policy (`policy_adapter_factory.py`) | ✅ (ODRL) | ✅ | ❌ | ❌ |
| Contract negotiation (`contract_management/contract_negotiation_service.py`) | ✅ | ❌ | ❌ | ❌ |
| Data transfer (`adapters/edc_transfer_adapter.py`) | ✅ | ✅ (fiware) | ❌ | — |

Two facts from the code make the "one backend at a time" design explicit:

- **Catalogue management is FIWARE-only.** `catalogue_adapter_factory.py` returns a
  `TMF620CatalogueAdapter` for `ngsi-ld`/`custom` and **raises
  `UnsupportedConnectorError` for `edc` and `simpl`**:

  ```python
  if connector_type in ["edc", "simpl"]:
      raise UnsupportedConnectorError(
          f"Connector type '{connector_type}' does not support catalogue management. "
          f"Only 'ngsi-ld' and 'custom' connectors with TMF620 API support are currently supported.")
  ```

- **Contract negotiation is EDC-only.**
  `contract_management/contract_negotiation_service.py` hard-codes
  `EDCContractNegotiationAdapter` and defines
  `ONLY_EDC_CONNECTORS_ERROR = "Only EDC connectors support contract negotiations"`.

There is **no code path that bridges two connectors within a single exchange.** A grep of
the backend for mediation/ontology/RML/XFSC turns up nothing but `dcat:mediaType`
formatting constants — i.e. the tool emits DCAT-AP-shaped metadata, but does not
*translate between* DCAT-AP and another ecosystem's model.

### Where the "real" federation actually is: EDC

IDS/DSP compliance is delegated wholesale to EDC. ADR-0016
(`documentation/architecture/0016-ids-standards-compliance.md`) states it plainly:

> "IDS compliance is achieved through the Eclipse Tractus-X Data Space Connector (EDC),
> which implements the IDS specifications natively. Other connector types
> (FIWARE/NGSI-LD, SIMPL, CUSTOM) do not natively support IDS standards."

And ADR-0015 (DSBA convergence) frames the whole tool as:

> "a unified facade that abstracts connector-specific implementations … each with
> different levels of compliance with DSBA recommendations."

So the genuinely federated, contract-negotiating, sovereign data exchange in the LDT
Toolbox **is EDC's**, wrapped by LDT's API. LDT's own contribution is the unified
UI/API, ODRL policy administration + enforcement, DID/VC identity, an EBSI Trusted
Issuers list, and Gaia-X compliance credential signing
(`gaiax-validation/scripts/sign_vp.mjs`).

---

## 2. The Marketplace "cross-domain federation" is hub-and-spoke identity + catalogue

`EU_LDT_Marketplace/documentation/guides/AGENT_FEDERATION_SETUP.md` documents what
"federation" means for the Marketplace, and it is **not** cross-data-space:

- A **hub-and-spoke** model: one central EU LDT Marketplace (hub); each Toolbox
  deployment runs a **Marketplace Agent + its own Keycloak Identity Manager** (spoke).
- "Federation" = (a) **identity federation** — the central Marketplace IdP brokers login
  to each deployment's Keycloak via an OIDC `marketplace-federation-broker` client and
  maps `central-marketplace:*` roles to local `marketplace:*` roles; and (b) **catalogue
  publishing** — after activation, a deployment's sellers publish assets *up to the
  central catalogue*, and buyers download through the Agent.

This federates **LDT deployments to a central LDT marketplace**. It does not connect an
LDT catalogue to a *foreign* (Gaia-X/XFSC, IDS/EDC-native, or Simpl) data space's
catalogue.

---

## 3. Simpl-Open is a *recognised connector type — but a stub*

This is the most directly relevant finding for this lab. LDT Data Space Ready already
knows about Simpl, but only at the connection/health-check layer:

- `SIMPL = "simpl"` is in the `ConnectorType` enum.
- `ds_connector_validation_service.py` defines endpoint requirements
  (`ConnectorType.SIMPL: {"required": ["control"], "optional": ["nativeConsoleUrl"]}`).
- `ds_connector_verification_service.py` has `_verify_simpl(...)`, which **pings the
  `control` endpoint and appends a `simpl-api` capability** — nothing more.
- **There are no `simpl_*` adapter files** in `services/adapters/` (only `edc_*`,
  `fiware_*`, `fdsc_*`, `tmf*`). So SIMPL has **no catalogue / asset / search / policy /
  contract / transfer adapter** — an LDT deployment can *register and health-check* a
  Simpl connector, but cannot yet publish, discover, negotiate or transfer over it.

ADR-0017 (`documentation/architecture/0017-simpl-connector-support.md`) confirms this is
deliberate and unfinished. It lists as **done**: enum entry, verification logic, endpoint
requirements, "basic adapter structure"; and as **still-to-do extension points**: the
catalogue/asset/search adapters. Its own context note:

> "During the initial development phase, SIMPL's development status made it challenging to
> consider as the primary connector option."

**Implication for this lab:** Simpl-Open's natural place in the LDT world is *as another
connector backend behind the Data Space Ready facade*, sitting beside EDC and FIWARE. The
missing piece is precisely the set of SIMPL adapters (catalogue via the catalogue API,
contract/transfer via the provider/consumer agent path this lab already exercises in
`scripts/07-tier2-provider-publish.sh`). That is a concrete, bounded integration target,
not a rewrite.

---

## 4. What this means for the Simpl-Open positioning question

- The LDT Toolbox is **complementary, not a competitor, at the connector layer.** Its
  federation is *"pick one connector, participate in one space"* plus *"federate LDT
  deployments to a central marketplace"*. It leans on **EDC** for the hard part (IDS/DSP
  contract + transfer).
- The **cross-ecosystem interoperability gap is real and unclosed in code**: neither LDT
  nor (per the earlier analysis) Simpl-Open performs runtime DCAT-AP↔XFSC semantic
  mediation, policy-language translation, or contract-model translation between two
  *different* data-space technologies. LDT's "federation" stops at the boundary of a
  single connector technology.
- Because LDT already ships a `SIMPL` connector type with health-check plumbing, the
  cleanest demonstration of Simpl-Open value inside the LDT ecosystem would be to
  **implement the missing SIMPL adapters** against this lab's running Simpl mesh — turning
  Simpl-Open into a first-class, catalogue-and-contract-capable backend for Data Space
  Ready.

---

## Appendix — repositories and key files

- Namespace: `https://code.europa.eu/ldt-toolbox` (20 repos, public, EUPL-1.2).
- `eu_ldt_data_space_ready`
  - `backend-py/src/models/ds_connector/dto/ds_connector_base_dto.py` — `ConnectorType` enum.
  - `backend-py/src/services/adapters/` — `catalogue_adapter_factory.py`,
    `search_adapter_factory.py`, `policy_adapter_factory.py`, and the `edc_*` / `fiware_*`
    / `fdsc_*` / `tmf*` adapters (no `simpl_*`).
  - `backend-py/src/services/contract_management/contract_negotiation_service.py` — EDC-only.
  - `backend-py/src/services/ds_connector/ds_connector_verification_service.py` — `_verify_simpl`.
  - `documentation/architecture/0015…`, `0016…`, `0017-simpl-connector-support.md`.
  - `gaiax-validation/scripts/sign_vp.mjs` — Gaia-X compliance credential signing.
- `EU_LDT_Marketplace/documentation/guides/AGENT_FEDERATION_SETUP.md` — hub-and-spoke federation.
