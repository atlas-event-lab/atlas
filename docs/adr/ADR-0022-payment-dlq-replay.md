---
adr_id: ADR-0022
title: Manual DLQ replay for payment triggers via a deliberately-started DLT handler
service: Payment
status: COMPLETED
date: 2026-07-20
depends_on:
  - ADR-0020
  - ADR-0021
---

# ADR-0022 — Payment DLQ replay (manual, idempotent re-drive of parked triggers)

# Status

`COMPLETED` (created 2026-07-20, implemented in the same change-set). Origin:
[experiments/06-dlq-recovery/dlq-replay-payment.md](../../experiments/06-dlq-recovery/dlq-replay-payment.md).

# Context

`dlq-strategy.md` (SPEC-KAFKA-DLQ) requires two things: unprocessable messages **park** in a
Dead Letter Topic, and parked messages **can be manually replayed** with their payload preserved
("DLQ consumers SHALL NOT automatically retry. Manual replay is allowed."). Atlas implements
only the first. Every consumer uses
`@RetryableTopic(dltTopicSuffix=".dlq", dltStrategy=FAIL_ON_ERROR, autoStartDltHandler="false")`,
so non-retryable failures park immediately and retryable ones park after the 4-attempt ladder
(`retry-strategy.md`); but there is **no `@DltHandler`, no control surface and no tooling** that
ever reads a `.dlq` back. A parked message stays parked forever.

For payment-service this is a concrete liveness gap, distinct from the W2 orphan ADR-0021 closed
and one step earlier in the pipeline. If `inventory.reserved` fails **before TX1 commits** — e.g.
`payment_db` is briefly unreachable, a *retryable* error — all four attempts fail during the
outage and the event parks in `inventory.reserved-payment.dlq`. **No `Payment` row is ever created**, so
the ADR-0021 sweeper (which re-drives payments already in `PROCESSING`) cannot help; booking's
15 m reservation TTL then expires the booking and the customer silently loses it, even though the
failure was transient and has since cleared. The only correct resolution is to replay the parked
trigger once the dependency is healthy — the idempotency machinery (`eventId` dedupe + provider
`Idempotency-Key = paymentId`, EVT-005/008/010) then produces exactly one charge and the Saga
completes normally.

Scope is deliberately **payment-service only** for now: it is where a parked message means lost
revenue and where the existing meters (ADR-0020) let us prove *exactly-once* on replay. The same
pattern for booking/inventory/search is a later, separate ADR per service (`DR-002`).

# Decision

Add a **manually-started DLT handler** to payment-service, plus two DLQ meters. Nothing
auto-runs; `payment.*` topics and message schemas are untouched (no AsyncAPI/OpenAPI change).

1. **Register the DLT handler stopped; start it on demand via an actuator endpoint (no
   redeploy).** Keep `autoStartDltHandler = "false"` on the trigger consumer — the DLT listener
   container is registered but **stopped** (messages park, nothing replays). Add
   `PaymentDlqReplayer`, which locates the DLT container(s) by their topic (`*.dlq`) through
   `KafkaListenerEndpointRegistry` and starts/stops them at runtime, and expose it as a custom
   Actuator endpoint `dlqreplay`:
   - `GET /actuator/dlqreplay` — report whether replay is running;
   - `POST /actuator/dlqreplay` with `{"action":"start"|"stop"}` (default `start`) — `start` drains
     `inventory.reserved-payment.dlq` and **auto-stops when the queue is empty**; `stop` explicitly aborts an
     in-progress drain. Idempotent.

   **Redrive semantics (auto-stop).** `start` arms the DLT container with an `idleEventInterval`
   (`atlas.payment.dlq.idle-timeout-ms`, default 10 s); when the DLQ is fully drained the container
   goes quiet, Spring Kafka publishes a `ListenerContainerIdleEvent`, and the replayer stops the
   container asynchronously (`stop(Runnable)` — the idle event fires on the consumer thread, so a
   synchronous stop there would deadlock). A single `start` therefore drains and halts itself, like
   an SQS redrive — the operator need not remember to stop it.

   This is the idiomatic Spring Kafka control surface for manual DLT processing and the standard
   production pattern (deliberate, observable, **no redeploy**), replacing the earlier env-flag +
   rollout idea (which coupled an operational action to a deployment and drained the DLQ only via a
   pod restart).

2. **`@DltHandler` with classify → reprocess / quarantine logic.** Add
   `onInventoryReservedDlt(envelope, exceptionFqcn header)` to `PaymentEventConsumer`. It
   classifies why the record parked from the `kafka_dlt-exception-fqcn` header:
   - **poison** (`ConstraintViolationException` / `IllegalArgumentException` →
     `reason=validation`; `InvalidPaymentStateTransitionException` →
     `reason=forbidden_transition`): the same bytes would just re-fail — **quarantine** (log with
     the DLQ headers, do not reprocess). Makes the point that replay is *not* unconditional.
   - **recoverable** (anything else → `reason=retries_exhausted`): re-invoke
     `paymentService.onInventoryReserved(eventId, command)` — safe by construction, the guard
     absorbs an already-processed record and the provider `Idempotency-Key` prevents a double
     charge; the Saga then completes (SUCCEEDED → confirm, FAILED → compensation, TIMED_OUT →
     `PaymentTimedOut` → expiry). A null/undeserializable envelope is treated as poison.

3. **Two low-cardinality Micrometer counters** (ADR-0018/19/20 style):

   | Meter (Prometheus name) | Tags | Incremented when |
   |--------------------------|------|------------------|
   | `atlas_payment_dlq_parked_total` | `reason=validation\|forbidden_transition\|retries_exhausted`, `event=inventory_reserved` | the handler observes a parked record on the DLT, classified from the exception header |
   | `atlas_payment_dlq_replayed_total` | `outcome=reprocessed\|quarantined`, `event=inventory_reserved` | the handler dispositions a drained record |

   Corroborated (no new code) by `atlas_payment_provider_calls_total` (proves the replayed charge
   happened exactly once), `atlas_payment_events_skipped_total{reason="duplicate"}` (a replayed
   already-processed record), and `atlas_payment_recoveries_total` (**stays 0** — replay, not the
   sweeper, settled these). **Real-time** DLQ growth while the handler is stopped is observed via
   the existing infra gauge `kafka_topic_partition_current_offset{topic=~".*\.dlq"}` (Kafka
   dashboard); the two service counters characterize the **replay drain** and, like all ADR-0020
   meters, are per-process (read from the pod running the handler across the replay window).

# Resolved sub-decisions

- **Control surface:** a runtime Actuator endpoint (`dlqreplay`) that starts/stops the DLT
  container via `KafkaListenerEndpointRegistry` — the idiomatic Spring Kafka pattern for manual
  DLT processing, and the production-standard "no redeploy" control. The earlier env-flag +
  rollout option was rejected: it couples replay to a deployment and only toggles at pod startup.
- **Security posture:** `dlqreplay` is exposed on the **internal management port** (9090) only,
  which is not published via ingress; access is network- and RBAC-gated through the Kubernetes API
  proxy (`pods/proxy` subresource), consistent with how the existing actuator surface
  (`prometheus`, `metrics`) is already reached. If the management port were ever exposed beyond the
  cluster, this write endpoint MUST be moved behind authentication.
- **Parked-count source:** incremented handler-side (findings doc §5.3 option A) — simplest,
  MVP. A park-time `DeadLetterPublishingRecoverer` hook (truer real-time count) is deferred; the
  infra gauge already covers real-time parking.
- **Quarantine durability:** log-only for MVP (with full DLQ headers); a `payment_dlq_parked`
  audit table is deferred.

# Consequences

**Positive.** The Saga's liveness no longer depends on the payment trigger never hitting a
transient outage before TX1: parked-but-valid triggers are recoverable instead of lost to the
TTL, demonstrably and idempotently (Experiment 06 asserts it). Replay is observable
(`dlq_replayed_total`) and provably exactly-once (`provider_calls_total`, no `booking_id` with
>1 payment). **Negative / assumption.** Replay inherits ADR-0021's `Idempotency-Key` assumption
(the WireMock fake does not enforce it; a real provider MUST). Starting the handler drains *every*
parked record indiscriminately, so replay MUST only be started after the root cause is cleared
(the endpoint is a deliberate operator action, not automatic). A DLT-handler failure under
`FAIL_ON_ERROR` re-parks the record (no loss) but can hot-loop if replay is started while the
fault persists — operationally gated. The endpoint is unauthenticated at the app layer, relying on
management-port isolation + k8s RBAC (see §Security); acceptable while 9090 is cluster-internal.

# Documents to update at implementation

- `payment-service` — `PaymentEventConsumer` (`@DltHandler` + `autoStartDltHandler="false"` + DLQ
  meters), `PaymentDlqReplayer` + `PaymentDlqReplayEndpoint` + `DlqReplayStatus` (runtime replay
  control), `application.yml` (expose the `dlqreplay` actuator endpoint), tests
  (`PaymentEventConsumerTest`, `PaymentDlqReplayerTest`, `PaymentDlqReplayEndpointTest`).
- Experiment 06 README/runbook — replay driven via `POST /actuator/dlqreplay`; success criteria
  assert the parked/replayed meters and exactly-once on replay.
- ADR index (`docs/adr/README.md`) — add the row.
- No AsyncAPI/OpenAPI change.
