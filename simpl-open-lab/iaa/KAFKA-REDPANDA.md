# Kafka in Simpl-Open — what it's for, and running it as Redpanda

## What Kafka is used for (traced from the code)

Kafka is the **event backbone** for two asynchronous flows. Everything else in Simpl is
request/response; these two are fire-and-forget events:

1. **Credential-lifecycle propagation (IAA).**
   `authentication_provider`'s `CredentialUpdateEventPublisher` emits an event whenever a
   machine-identity credential is installed / rotated / revoked. The **`tier2-gateway` has a
   `@KafkaListener`** on that topic and keeps a `CredentialCache`; the event tells it to
   refresh/invalidate an entry, so the gateway learns about new or revoked identities
   **without polling** the auth-provider.
   - Topic: `eu.europa.ec.simpl.authenticationprovider.events.credential.updated`
     (constant `Topics.AUTHENTICATION_PROVIDER_CREDENTIAL_UPDATED_EVENT`, prefixed by
     `simpl.kafka.topic.prefix`, empty by default).
   - Related: `…events.identity-attributes.updated` (SAP attribute changes).

2. **Quality-scoring requests (catalogue).**
   `catalogue-be`'s `ScoreRequestPublisher` emits a `score-request` CloudEvent (`SCORE_REQUEST_TOPIC`)
   that the separate **quality-scoring-service** consumes to (re)compute a Self-Description's
   MQR score asynchronously.

Payloads are **CloudEvents 1.0** JSON. Producers/consumers are standard `spring-kafka`
(`KafkaTemplate` + `@KafkaListener`), plain Kafka wire protocol — no vendor lock-in.

## Why the lab can run without a broker (and what you lose)

With no broker, both flows are **substituted**:
- Quality scoring is done **synchronously** by `catalogue/qs-stub.py` instead of via the
  `score-request` topic.
- The credential-updated event simply **fails to publish** (the harmless "post-commit
  KafkaException" in the logs — the credential still installs). Because the gateway never
  receives the event, `07-tier2-provider-publish.sh` **restarts the gateway** so it re-reads
  the GA identity, instead of the gateway hot-swapping its `CredentialCache` on the event.

So the missing broker costs exactly the *event-driven* behavior: live gateway credential
refresh and async score recomputation.

## Redpanda as the broker (recommended small footprint)

Redpanda is **Kafka-API compatible** and ships as a **single binary — no JVM, no
ZooKeeper/KRaft coordinator process**. Because the Simpl services speak the plain Kafka
protocol above, Redpanda is a **drop-in**: point them at it and nothing in the code changes.

Bring it up with the lab script (Redpanda-first, Apache-Kafka-KRaft fallback):

```bash
bash iaa/broker.sh                 # auto: Redpanda if `rpk`+broker present, else Kafka KRaft
SIMPL_BROKER=redpanda bash iaa/broker.sh
SIMPL_BROKER=kafka    bash iaa/broker.sh
```

Then start the services pointed at it and drop the no-broker workarounds:

| Service | Flags to add |
|---|---|
| `authentication_provider` (both profiles) | `--spring.kafka.bootstrap-servers=localhost:9092 --simpl.kafka.topic.prefix=` |
| `tier2-gateway` | `--spring.kafka.bootstrap-servers=localhost:9092 --simpl.kafka.topic.prefix=` |
| `catalogue-be` | `--spring.kafka.bootstrap-servers=localhost:9092` (and drop `--quality-scoring.url` stub if using the async scorer) |

With the broker live, the gateway consumes the credential-updated event and refreshes its
cache **without the restart** `07` currently does.

## Verified in this environment

This sandbox has **no Docker daemon and no apt route to the `redpanda` broker binary**
(`rpk` is only the CLI — 140 MB — and needs a separate broker install), so the Redpanda
**broker** cannot run here. To prove the drop-in claim anyway, we ran a single-node
**Apache Kafka KRaft** broker on `:9092` and drove a full round-trip on the real Simpl topic
using **`rpk` (Redpanda's own client)**:

```
$ rpk -X brokers=localhost:9092 cluster info        → 1 broker, cluster DxK663…
$ rpk … topic create eu.europa.ec.simpl.authenticationprovider.events.credential.updated → OK
$ echo '<CredentialUpdatedEvent CloudEvent>' | rpk … topic produce <topic>  → offset 0
$ rpk … topic consume <topic> -n 1                  → the same event back at offset 0
```

Redpanda's client + the Kafka wire protocol the Simpl services use interoperate on the exact
topic the gateway listens to — so on any box where the Redpanda **broker** runs (a normal
`rpk`/package install, or a container), `iaa/broker.sh` makes these event flows live with no
code change. The live "gateway consumes the credential event without a restart" demo needs
`authentication_provider` + `tier2-gateway` booted against the broker — the natural next step.
