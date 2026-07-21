---
adr_id: ADR-0023
title: Per-consumer retry/DLT topics for the payment inventory.reserved consumer
service: Payment
status: COMPLETED
date: 2026-07-20
depends_on:
  - ADR-0022
---

# ADR-0023 — Per-consumer retry/DLT topics (payment)

# Status

`COMPLETED` (created 2026-07-20, implemented in the same change-set). Origin: Experiment 06 —
DLQ Recovery ([experiments/06-dlq-recovery/dlq-replay-payment.md](../../experiments/06-dlq-recovery/dlq-replay-payment.md)).
Paired with [ADR-0024](ADR-0024-booking-per-consumer-dlt-topics.md) (booking), the other
`inventory.reserved` consumer (`DR-002`: one ADR per affected service).

# Context

`inventory.reserved` is consumed by **two** services — payment-service (the Saga charge trigger)
and booking-service (`onInventoryReserved`) — each with its own `@RetryableTopic`. Spring Kafka
derives retry/DLT topic names from the source topic + a suffix, so both consumers used the same
`.dlq` suffix and therefore **shared** `inventory.reserved.dlq` (and `inventory.reserved-retry-*`).

Experiment 06 surfaced the consequences when it first pushed messages through the retry ladder
into the DLQ:

- A single poison `inventory.reserved` message parked **twice** (once per consumer) — the run
  measured 10 DLQ records for 5 injected, because payment *and* booking each failed validation and
  published to the same topic.
- Worse for replay: payment's manually-started `@DltHandler` (ADR-0022) drains the whole
  `inventory.reserved.dlq`, so it would consume and act on records **booking** parked — quarantining
  booking's poison (removing it from booking's reach) or re-driving booking-owned records as
  payments. The `eventId` guard prevents a double charge, but the cross-service contamination is
  wrong and breaks the exactly-once accounting the experiment asserts.

# Decision

Namespace payment's retry/DLT topics by consumer, per the updated `SPEC-KAFKA-DLQ`
(`dlq-strategy.md` §Multiple consumers of one topic). On `PaymentEventConsumer`'s
`@RetryableTopic`:

- `retryTopicSuffix = "-payment-retry"` → `inventory.reserved-payment-retry-0..2`
- `dltTopicSuffix   = "-payment.dlq"`   → `inventory.reserved-payment.dlq`

Payment now parks to, and its `@DltHandler` / `PaymentDlqReplayer` / `/actuator/dlqreplay` now
drain, **only** `inventory.reserved-payment.dlq` (the DLT container is still located by the `.dlq`
suffix, which the new name keeps). No behavioural change to the handler or meters (ADR-0022); only
the topic names change. Booking makes the symmetric change in ADR-0024.

# Consequences

**Positive.** Payment's parked records are isolated from booking's; replay drains exactly payment's
DLQ, restoring the exactly-once accounting Experiment 06 checks. The Kafka dashboard's
`kafka_topic_partition_current_offset{topic=~".*\.dlq"}` still aggregates both namespaced DLQs.
**Negative / migration.** The old shared `inventory.reserved.dlq` and `inventory.reserved-retry-*`
are abandoned; any records parked there before this change must be drained/handled out-of-band (in
the lab, a reset clears them). Topic count grows (per-consumer retry/DLT sets) — update the Strimzi
partition-tuning note (done, `topics.yaml`).

# Documents to update at implementation

- `payment-service` — `PaymentEventConsumer` (`retryTopicSuffix` + `dltTopicSuffix`).
- `dlq-strategy.md` (SPEC-KAFKA-DLQ) — per-consumer naming rule (done).
- `deploy/platform/strimzi/topics.yaml` — retry/DLT topic-name note (done).
- Experiment 06 README/runbook — DLQ topic is now `inventory.reserved-payment.dlq`.
- ADR index (`docs/adr/README.md`) + `docs/SPECS-INDEX.md` (`DR-005`).
- No AsyncAPI/OpenAPI change (retry/DLT topics are infrastructure, not published contracts).
