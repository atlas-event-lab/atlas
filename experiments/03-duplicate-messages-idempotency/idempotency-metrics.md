# Inventory idempotency — making effectively-once visible

**Origin:** Experiment 03 — Duplicate Messages / Idempotency · **Phase:** 7 (APM)
**Status:** proposal · **Services affected:** inventory-service
**ADR:** [ADR-0019](../../docs/adr/ADR-0019-inventory-idempotency-metrics.md)

> Narrative half of Experiment 03's observability work: what the experiment needed to measure,
> why the existing signals fell short, and what we added. Scoped to this experiment; the binding
> service-code change is **ADR-0019**. Same convention as Exp 01 (`payment-service-scaling.md` ↔
> ADR-0015) and Exp 02 (`inventory-observability.md` ↔ ADR-0018).

## 1. The gap

Experiment 03 proves **effectively-once**: redelivered `booking.created` events are skipped by
the idempotency guard (`consumedEventRepository.existsById(eventId)`) and have no side effect.
The persistent invariants (`reserved_count`, `consumed_events` and `reservations` row counts,
`outbox` count — all unchanged) prove correctness. But "nothing changed" is an **invisible**
result: from metrics alone you can't tell the difference between "the replay was correctly
deduplicated" and "the replay never arrived." The success is indistinguishable from a no-op.

The Exp 02 meters help but don't close it: `atlas_inventory_reservations_total` staying flat
shows *no new reservation*, yet not *that duplicates were seen and skipped*.

## 2. What we added (decision)

One low-cardinality Micrometer counter in `InventoryServiceImpl`, incremented in **every**
idempotency skip branch (`reserve`, `confirm`, `release`, `expire`):

| Meter (Prometheus name) | Tags | Incremented when |
|--------------------------|------|------------------|
| `atlas_inventory_events_skipped_total` | `reason=duplicate`, `event=<consumer-event-type>` | `existsById(eventId)` is true — a redelivered event is skipped |

A tiny `recordDuplicateSkip(ConsumerEventType)` helper keeps the four call sites uniform and
tags each by the event type, so the dashboard can show *which* redelivered event was skipped.
This is pure observability: it does not change the guard's behaviour (still skip + return).

**Restart semantics (why the counter is read *after* the replay).** Micrometer counters are
per-process; the experiment quiesces and resumes `inventory-service`, so the counter starts at 0
on the fresh pod. Read after the replay, `atlas_inventory_events_skipped_total` therefore equals
exactly the number of events redelivered in *this* replay, and
`atlas_inventory_reservations_total{result="reserved"}` reads 0 — a clean, direct readout of
"the replay caused only skips." The before/after comparison of the durable invariants (Postgres)
is what carries the correctness claim across the restart.

## 3. Validation

- `InventoryServiceImplTest` already constructs the service with a real `SimpleMeterRegistry`
  (added in ADR-0018); the new counter needs no test wiring and does not alter control flow. A
  duplicate-delivery test (`existsById` → true) simply also increments the counter.
- Runbook assertion: after a replay of `R` events, the durable invariants are unchanged and
  `atlas_inventory_events_skipped_total ≈ R`, `reservations_total{result="reserved"} == 0`.

## 4. Conclusion

Effectively-once goes from an invisible non-event to a **positive, watchable** signal, with a
per-event breakdown of what got deduplicated. Correctness itself is still proven by the durable
Postgres invariants in `runbook.sh`; the meter makes the *demonstration* legible. Cut to
**ADR-0019** (inventory-service); flip to `COMPLETED` when merged.
