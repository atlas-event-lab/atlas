---
adr_id: ADR-0024
title: Per-consumer retry/DLT topics for the booking inventory.reserved consumer
service: Booking
status: COMPLETED
date: 2026-07-20
depends_on:
  - ADR-0023
---

# ADR-0024 — Per-consumer retry/DLT topics (booking)

# Status

`COMPLETED` (created 2026-07-20, implemented in the same change-set). Origin: Experiment 06 —
DLQ Recovery ([experiments/06-dlq-recovery/dlq-replay-payment.md](../../experiments/06-dlq-recovery/dlq-replay-payment.md)).
Paired with [ADR-0023](ADR-0023-payment-per-consumer-dlt-topics.md) (payment), the other
`inventory.reserved` consumer (`DR-002`: one ADR per affected service).

# Context

`inventory.reserved` is consumed by both booking-service (`BookingEventConsumer.onInventoryReserved`)
and payment-service. Both `@RetryableTopic`s used the same `.dlq` suffix, so they **shared**
`inventory.reserved.dlq` and `inventory.reserved-retry-*`. Experiment 06 showed a single poison
message parking twice (once per consumer) and, more importantly, that payment's DLQ replay handler
(ADR-0022) drains the shared topic and would act on booking-owned records. See ADR-0023 for the
full analysis.

# Decision

Namespace booking's retry/DLT topics for its `inventory.reserved` listener by consumer, per the
updated `SPEC-KAFKA-DLQ`. On `BookingEventConsumer.onInventoryReserved`'s `@RetryableTopic`:

- `retryTopicSuffix = "-booking-retry"` → `inventory.reserved-booking-retry-0..2`
- `dltTopicSuffix   = "-booking.dlq"`   → `inventory.reserved-booking.dlq`

Only the `inventory.reserved` listener is affected — booking's other consumed topics
(`payment.succeeded` / `payment.failed` / `payment.timed_out`, `inventory.booking.released` /
`inventory.booking.rejected`) are single-consumer and keep the plain `<topic>.dlq` form. Scope is
booking-service only; no change to booking's DLT handling behaviour, just the topic names.

# Consequences

**Positive.** Booking's parked `inventory.reserved` records are isolated from payment's; neither
service's replay touches the other's DLQ. **Negative / migration.** The old shared
`inventory.reserved.dlq` / `-retry-*` are abandoned (lab reset clears them). If booking later needs
its own on-demand DLQ replay, it can adopt the ADR-0022 pattern against
`inventory.reserved-booking.dlq` (separate, later ADR).

# Documents to update at implementation

- `booking-service` — `BookingEventConsumer.onInventoryReserved` (`retryTopicSuffix` +
  `dltTopicSuffix`).
- `dlq-strategy.md` (SPEC-KAFKA-DLQ) — per-consumer naming rule (done, shared with ADR-0023).
- `deploy/platform/strimzi/topics.yaml` — retry/DLT topic-name note (done).
- ADR index (`docs/adr/README.md`) + `docs/SPECS-INDEX.md` (`DR-005`).
- No AsyncAPI/OpenAPI change.
