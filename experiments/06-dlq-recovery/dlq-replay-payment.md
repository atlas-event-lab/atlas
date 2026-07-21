# DLQ Recovery — manual replay of parked payment triggers

**Origin:** Experiment 06 — DLQ Recovery · **Phase:** 7 (resilience / APM)
**Status:** implemented · **Services affected:** payment-service
**ADR:** [ADR-0022](../../docs/adr/ADR-0022-payment-dlq-replay.md) (payment-service) — COMPLETED

> Narrative + change plan for Experiment 06's replay work: what the experiment needs, why the
> current DLQ path stops half-way, the single-service scope we chose, and the code + metrics we
> propose to add. Same convention as Exp 01 (`payment-service-scaling.md` ↔ ADR-0015), Exp 04
> (`payment-idempotency-metrics.md` ↔ ADR-0020, `payment-recovery.md` ↔ ADR-0021). This doc is
> the reasoning half; the binding decision is cut to **ADR-0022** when we agree to build it.

## 1. The gap

`dlq-strategy.md` (SPEC-KAFKA-DLQ) is only half-implemented in code:

- **Parking works.** Every consumer uses `@RetryableTopic(dltTopicSuffix=".dlq",
  dltStrategy=FAIL_ON_ERROR, autoStartDltHandler="false")`. Non-retryable failures
  (`ConstraintViolationException`, `IllegalArgumentException`,
  `InvalidPaymentStateTransitionException`) go straight to `<topic>.dlq`; retryable ones exhaust
  the 4-attempt ladder (5s → 30s → 120s, `retry-strategy.md`) and then land in the DLQ. The
  Kafka dashboard already graphs DLQ backlog per topic
  (`kafka_topic_partition_current_offset{topic=~".*\.dlq"}`).
- **Replay does not exist.** `autoStartDltHandler="false"` is set everywhere, but there is **no
  `@DltHandler` method, no admin/actuator control, and no ops tooling** that consumes or
  re-drives a `.dlq` topic. A parked message stays parked forever. The spec's "Manual replay is
  allowed. Replay SHALL preserve original payload" has no realization.

So the hypothesis "a poison message parks in the DLQ **and can be replayed**" (roadmap Exp 06)
cannot be demonstrated today — the second clause has no mechanism.

### Why this is a real business gap, not just a missing test hook

The most damaging concrete case is in **payment-service**, and it is distinct from the W2 orphan
that ADR-0021 already closed:

- The payment trigger `inventory.reserved` fails **before TX1 commits** — e.g. `payment_db` is
  briefly unreachable, so `beginProcessing` throws a *retryable* DB error. All 4 attempts fail
  during the outage and the event lands in `inventory.reserved-payment.dlq`. **No `Payment` row is ever
  created** (TX1 never committed).
- Nothing recovers it. The ADR-0021 sweeper only re-drives payments already in `PROCESSING`;
  here there is no payment at all. Booking-expiration owns `PENDING` only; the reservation's
  15 m TTL restores stock and the booking expires — **the customer's booking is silently lost**,
  even though the failure was transient and has cleared.
- The only correct resolution is to **replay the parked `inventory.reserved` event** once the
  dependency is healthy: the guard/idempotency machinery then produces exactly one charge and
  the Saga completes normally (or compensates on a real decline).

This is the same shape as the W2 liveness gap ADR-0021 fixed (Exp 04), one step earlier in the
pipeline: **retries-exhausted-before-processing** instead of **crash-between-TX1-and-TX2**.
Closing it is pending, necessary and revenue-relevant — the strongest single-service target.

## 2. Scope decision — payment-service only (for now)

Per the plan discussion we deliberately implement the in-app `@DltHandler` in **one service**,
chosen because it (a) has pending, priority business logic behind the replay, (b) yields the
richest metrics, and (c) already carries the fault-injection harness and idempotency proof from
Exps 04–05. Payment-service wins on all three:

| Criterion | Payment | Booking | Inventory / Search |
|-----------|---------|---------|--------------------|
| Pending, priority business logic behind replay | **Yes** — stranded-but-valid bookings, money involved | Partial — out-of-order already retried (ADR-0007) | Lower — projection/stock, largely self-healing |
| Metric payoff | **High** — reuses provider/skip/recovery meters to prove *exactly-once* on replay | Medium | Low |
| Existing harness to reuse | **Yes** — Exp 04/05 runbooks, WireMock scenarios, ADR-0020 meters | No | No |
| Safe re-drive already proven | **Yes** — `eventId` dedup + provider `Idempotency-Key` (never double-charges) | Yes | Yes |

The DLT handler and its metrics stay **payment-scoped**; `payment.*` topics and schemas are
untouched (no contract change). Rolling the same pattern to booking/inventory/search is a later,
separate ADR per service (`DR-002`) if Exp 06 proves it out — explicitly **out of scope here**.

## 3. What we propose to add (decision)

Everything below is payment-service only; nothing auto-starts (`DLQ consumers SHALL NOT
automatically retry`, dlq-strategy.md).

### 3.1 A manually-started `@DltHandler` with real recovery logic

Add `onInventoryReservedDlt(...)` to `PaymentEventConsumer`, annotated `@DltHandler`, running in
the DLT listener container that `autoStartDltHandler="false"` leaves **stopped**. On each parked
record it classifies the original failure from the DLQ headers (`exceptionClass`) and applies
business logic — this is the "pending logic" that makes the experiment worth running:

- **Recoverable (retries-exhausted / transient class):** re-invoke
  `paymentService.onInventoryReserved(eventId, command)`. Safe by construction — the `eventId`
  dedup absorbs an already-processed record, and the provider `Idempotency-Key = paymentId`
  guarantees no double charge (same guarantees Exps 03/04 proved). The Saga completes normally:
  SUCCEEDED → booking confirms, FAILED → compensation, TIMED_OUT → `PaymentTimedOut` → expiry.
- **Poison (validation / forbidden-transition class):** do **not** reprocess — the same bytes
  would just re-fail. Quarantine: log with the DLQ headers and leave the record read (optionally
  a `…​.dlq.parked` marker table for audit). This makes the sharp point that **replay is not
  unconditional** — a malformed message stays dead.

### 3.2 A safe "start replay" control surface

The DLT container must be startable **on demand and only deliberately** — and, following the
production standard, **without a redeploy**. `PaymentDlqReplayer` finds the DLT
`MessageListenerContainer`(s) by their `*.dlq` topic via `KafkaListenerEndpointRegistry` and
`start()`/`stop()`s them at runtime, exposed as a custom Actuator endpoint:

- `GET  /actuator/dlqreplay` — is replay running?
- `POST /actuator/dlqreplay` `{"action":"start"|"stop"}` (default `start`) — `start` drains
  `inventory.reserved-payment.dlq` and **auto-stops when empty** (redrive semantics, via a
  `ListenerContainerIdleEvent` after `atlas.payment.dlq.idle-timeout-ms`); `stop` aborts a drain.

It lives on the internal management port (9090, not published via ingress); access is network- +
RBAC-gated through the k8s API proxy — the same posture as the existing `prometheus`/`metrics`
endpoints. This is the idiomatic Spring Kafka control for manual DLT processing; the earlier
env-flag + rollout idea was rejected (couples replay to a deployment, toggles only at pod startup).

### 3.3 Two low-cardinality Micrometer counters (ADR-0018/19/20 style)

| Meter (Prometheus name) | Tags | Incremented when |
|--------------------------|------|------------------|
| `atlas_payment_dlq_parked_total` | `reason=validation\|forbidden_transition\|retries_exhausted`, `event=inventory_reserved` | a record arrives on the DLT (one per parked message), classified from the `exceptionClass` header |
| `atlas_payment_dlq_replayed_total` | `outcome=reprocessed\|quarantined`, `event=inventory_reserved` | the on-demand handler drains a record: re-driven to a terminal Saga outcome, or left poison (an already-processed re-drive is absorbed silently by the `eventId` guard → `events_skipped_total{duplicate}`) |

Reused as corroboration (no new code): `atlas_payment_provider_calls_total` (proves the replayed
charge happened **exactly once**), `atlas_payment_events_skipped_total{reason="duplicate"}` (a
replayed already-processed record), `atlas_payment_recoveries_total` (**stays 0** — the sweeper
must not be what settles these; replay is). **Restart semantics** are the ADR-0020 caveat: these
counters are per-process; read them from the pod running the handler across the replay window.

## 4. Validation plan

- **Unit:** `PaymentEventConsumerTest` with a real `SimpleMeterRegistry` (as since ADR-0018)
  asserts `dlq_parked_total{reason}` and each `dlq_replayed_total{outcome}` branch (reprocessed /
  quarantined). `PaymentDlqReplayerTest` asserts start/stop target only the `*.dlq` container and
  are idempotent; `PaymentDlqReplayEndpointTest` asserts the `start`/`stop`/default/invalid actions.
- **Slice:** an `@EmbeddedKafka` (or Testcontainers) test that publishes a malformed and a
  transient-failure record, asserts both land on `inventory.reserved-payment.dlq`, hits
  `POST /actuator/dlqreplay` `{"action":"start"}`, and asserts the transient one reprocesses to a
  terminal payment while the malformed one stays parked — with the meters moving as specified.
- **Experiment (this folder):** the `runbook.sh` end-to-end assertions in the README — both
  scenarios, exactly-once on replay, `recoveries_total == 0`.

## 5. Resolved decisions (in ADR-0022)

1. **Control surface:** a runtime Actuator endpoint (`POST /actuator/dlqreplay`) that starts/stops
   the DLT container via `KafkaListenerEndpointRegistry` — the idiomatic Spring Kafka pattern for
   manual DLT processing and the production-standard "no redeploy" control. `autoStartDltHandler`
   stays `"false"`. The env-flag + rollout option was rejected (couples replay to a deployment).
2. **Quarantine durability:** log-only for MVP (full DLQ headers logged); a `payment_dlq_parked`
   audit table deferred.
3. **`dlq_parked_total` source:** incremented handler-side (simplest); real-time parking while
   the handler is stopped is covered by the infra gauge
   `kafka_topic_partition_current_offset{topic=~".*\.dlq"}`. A park-time recoverer hook is
   deferred.

## 6. Conclusion

Exp 06 turns `dlq-strategy.md`'s replay clause from aspiration into a demonstrated, idempotent,
observable capability — scoped to the one service where a parked message means lost revenue and
where we can prove *exactly-once* on replay. The binding decision is
[**ADR-0022**](../../docs/adr/ADR-0022-payment-dlq-replay.md) (payment-service), COMPLETED; the
follow-up services (booking/inventory/search) are a later, separate track.
