# EOSC researcher → DestinE data through Simpl (pilot step 1)

A researcher from an EOSC institution logs in with their institutional identity, finds DestinE
Data Lake datasets in a Simpl provider's catalogue, gets them under a contract, receives them in
their EU Node workspace and analyses them. Run it with:

```bash
cd simpl-open-lab/scripts
./16-destine-eosc.sh      # → ends with "EOSC → DESTINE VIA SIMPL: all cases behaved as expected"
```

Prerequisites: `01-setup.sh` once (Keycloak, Postgres, the `connector-be` jar), and internet access
to `hda.data.destination-earth.eu` and `ec.europa.eu`. A re-run takes about two minutes.

## What runs

| Side | Piece | Role |
|---|---|---|
| DestinE | `destine_bridge.py` | Reads the HDA STAC catalogue (public) and puts selected collections on the provider connector: an `HttpData` asset, a contract policy and a contract definition each, plus a Simpl self-description per offer |
| DestinE | provider connector (`connector-be`) | Publishes the offers over DSP, checks the consumer organisation's attributes, pushes the data |
| DestinE | `dedl_access.py` | The provider's access layer to the Data Lake; the data plane fetches from it |
| EOSC | Keycloak realm `eosc-aai` | Stand-in for the EOSC federated AAI: a university researcher with an eduPersonEntitlement for a climate research group, and a student without it |
| EOSC | Keycloak realm `consumer-agent` | The Simpl consumer agent's Tier-1 Keycloak; brokers logins to `eosc-aai` over OIDC and carries the entitlement into its own token |
| EOSC | consumer connector | The university's Simpl consumer agent |
| EOSC | `notebook.py` | What the researcher runs in an EU Node notebook: identity check, discovery, contract, transfer, analysis |
| EOSC | `eu_node_storage.py` | The researcher's EU Node workspace (stand-in for File Sync & Share), where the data plane pushes the data |

## Offers and policies

| DestinE collection | DestinE tier | Simpl contract policy | Data in the lab |
|---|---|---|---|
| `STAT.EUSTAT.DAT.POP_DENSITY_NUTS3` | general public | organisation holds `CONSUMER` | Eurostat stand-in |
| `STAT.EUSTAT.DAT.SHARE_ENERGY_FROM_RENEWABLE` | general public | organisation holds `CONSUMER` | Eurostat stand-in |
| `EO.ECMWF.DAT.DT_CLIMATE_ADAPTATION` | upgraded access | organisation holds `DESTINE_UPGRADED_ACCESS` | HDA only (needs `DESTINE_TOKEN`) |

The policies use the attribute check the Simpl connector already ships
(`ConsumptionConstraintFunction`): no connector code was changed.

## The cases the script checks

| Case | Who | Result |
|---|---|---|
| A1, A2 | researcher, open data | contract, data in EU Node storage, analysis (densest NUTS 3 regions; largest rise in renewable share 2015–2021) |
| B | student, same university, no entitlement | stopped by the consumer agent before any contract |
| C | researcher, Climate DT, organisation without upgraded access | contract refused by DestinE's policy |
| D | same, after the organisation is granted upgraded access | contract agreed; the transfer fails at the access layer because the lab has no DestinE credentials (with `DESTINE_TOKEN` set, the data would come from HDA) |

## Stand-ins and what is not proven

- **Data source.** HDA's catalogue is public, but reading items or data needs a DestinE account
  (HTTP 403 "access denied to read … items" without one). The two Eurostat collections are
  DestinE's hosted copies of Eurostat datasets, so `dedl_access.py` fetches the same datasets from
  Eurostat's public API instead. The HDA path (`DESTINE_TOKEN`) is written against the HDA STAC API
  but has not been run.
- **EOSC AAI.** A local Keycloak realm, not the real EOSC AAI proxy. The brokering itself (OIDC
  identity provider, claim mapping) is the same configuration a real deployment would use.
- **Organisation attributes.** Mocked on the consumer connector, as in `09-consumption-abac.sh`.
  In Simpl they come from the governance authority over Tier-2; between two data spaces they would
  come from the BP02D attribute mapping (EOSC's research-organisation attribute mapped to DestinE's
  categories).
- **Subsets are fixed per offer.** The basic connector pushes; consumer pull (an EDR token and
  per-request queries) is not enabled in Simpl's connector, so the researcher can't choose the
  region or period at transfer time.
- **Catalogue.** The offers are discovered through the provider connector's DSP catalogue. The
  self-descriptions the bridge writes are not yet published to the federated catalogue.

## What the pilot shows about the design

- **Per-user rules stay on the consumer side.** The entitlement check (case B) is the consumer
  agent's own rule. The provider only ever sees the university, never the researcher.
- **DestinE's access tiers map onto organisation attributes** (cases C and D). That only matches
  DestinE's per-user policy if DestinE accepts an organisation-level agreement.
- **Getting the data needs DestinE credentials on the provider side** (case D). Whose account the
  provider agent uses, and whether DestinE's terms allow re-offering the data through Simpl
  contracts, has to be agreed with DestinE.

## Next steps

1. Run case D against HDA with a DestinE account (`DESTINE_TOKEN`).
2. Publish the self-descriptions to the federated catalogue (`06`/`07`) and discover from there.
3. Two governance authorities with BP02D attribute mapping instead of mocked attributes.
4. Consumer pull, so the researcher's notebook chooses the subset.
