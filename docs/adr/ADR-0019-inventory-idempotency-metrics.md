---
adr_id: ADR-0019
title: Expose an inventory duplicate-skip metric to make effectively-once delivery observable
service: Inventory
status: COMPLETED
date: 2026-07-11
depends_on:
  - ADR-0018
---

# ADR-0019 — Inventory idempotency metric

# Status

`COMPLETED` (created 2026-07-11). Merged: the counter and `recordDuplicateSkip` helper are
implemented in `InventoryServiceImpl` and covered by `reserve_duplicateEvent_is_skipped`
(`InventoryServiceImplTest`, wired with a real `SimpleMeterRegistry`). Origin:
[experiments/03-duplicate-messages-idempotency/idempotency-metrics.md](../../experiments/03-duplicate-messages-idempotency/idempotency-metrics.md).

# Context

Atlas consumers are idempotent: each `@Transactional` handler starts with
`if (consumedEventRepository.existsById(eventId)) return;` and commits the state change together
with the `consumed_events` insert, so a redelivered event (Kafka at-least-once) is a no-op
(`EVT-005`, `EVT-008`). Experiment 03 demonstrates this by replaying `booking.created` to
`inventory-service` and asserting the durable invariants are unchanged.

The problem is that a correct dedup is **invisible** in metrics — "nothing changed" looks
identical to "nothing arrived." The Exp 02 meters (ADR-0018) show *no new reservation* but not
*that duplicates were seen and skipped*. There is no positive signal for the effectively-once
property.

# Decision

Add one low-cardinality Micrometer counter to `InventoryServiceImpl`, incremented in every
idempotency skip branch (`reserve`, `confirm`, `release`, `expire`) via a small
`recordDuplicateSkip(ConsumerEventType)` helper:

- **`atlas.inventory.events.skipped`** `{reason="duplicate", event=<consumer-event-type>}` —
  incremented when `existsById(eventId)` is true.

Prometheus name `atlas_inventory_events_skipped_total`. Exposed via the existing
`/actuator/prometheus` + PodMonitor — no scraping change. Pure observability: the guard's
behaviour (skip + return) is unchanged. Because Micrometer counters are per-process, the
experiment reads the counter *after* the consumer restart, where its value equals the events
redelivered in that replay; the durable Postgres invariants carry the before/after correctness
comparison.

# Consequences

**Positive.** Effectively-once becomes a positive, watchable signal with a per-event breakdown;
the Experiment 02 dashboard shows dedup directly. **Negative.** One counter increment on each
skip branch (negligible).

# Documents to update at implementation

- `inventory-service` — `InventoryServiceImpl` (counter + `recordDuplicateSkip` helper; done).
- No contract (OpenAPI/AsyncAPI) change — metrics are not part of a service contract.
- Dashboard `atlas-exp02-dashboard.yaml` already carries a "duplicates skipped" query for
  Experiment 03 (shared meters).
