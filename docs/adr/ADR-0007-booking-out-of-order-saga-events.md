---
adr_id: ADR-0007
title: Defer premature Saga events in Booking (retry, don't fail) to tolerate out-of-order delivery
service: Booking
status: COMPLETED
date: 2026-07-07
depends_on:
  - SPEC-STATE-BOOKING
  - SPEC-KAFKA-RETRY
  - SPEC-FEATURE-CREATE-BOOKING
---

# ADR-0007 — Defer premature Saga events in Booking to tolerate out-of-order delivery

# Status

`PENDING` (created 2026-07-07). Flip to `COMPLETED` when the Booking changes below are
implemented and merged (`DR-003`). Refines the error-handling semantics of
services/booking/state_machine.md and
contracts/asyncapi/retry-strategy.md; it does
**not** change the set of valid state transitions.

# Context

Load testing (experiment `01-high-booking-concurrency`) surfaced booking failures caused by
**out-of-order event delivery**, not by any business rule violation.

The reservation event `inventory.reserved` is consumed by **two independent services**:
Booking (to move `PENDING → INVENTORY_RESERVED`) and Payment (which carries the `amount`,
charges the provider, and emits `payment.succeeded`). These are two separate consumers on
separate topics/partitions; Kafka gives **no cross-topic ordering** between
`inventory.reserved` and `payment.succeeded`. Causally the former precedes the latter, but
Booking receives them through different paths, and under load Booking's Payment consumer can
overtake its Inventory consumer — especially because the payment provider is mocked
(WireMock) and answers almost instantly.

> Note: in code the Booking constant is named `INVENTORY_BOOKING_RESERVED`, but its **value
> is the topic `inventory.reserved`** — the same topic Payment consumes. There is no separate
> `inventory.booking.reserved` topic.

When `payment.succeeded` reaches Booking while the booking is still `PENDING`, the state guard
rejects `PENDING → CONFIRMED` and throws `InvalidStateTransitionException`. That exception is
in the consumer's non-retryable `exclude` list (treated as *Business validation* per
`SPEC-KAFKA-RETRY`), so the event goes **straight to the DLQ**.

The downstream effect is worse than a "lost" booking:

1. `payment.succeeded` is parked in `payment.succeeded.dlq`.
2. `inventory.reserved` then arrives and Booking moves `PENDING → INVENTORY_RESERVED`.
3. No `payment.timed_out` will ever come (the payment actually **succeeded**), so the booking
   sits in `INVENTORY_RESERVED` until the expiration safety-net job drives it to `EXPIRED`.
4. Result: **the provider charged the user, but the booking ends `EXPIRED`** — and the specs
   state Atlas has no refund path for a settled charge
   (state_machine.md cancellation policy). This is a
   money-level inconsistency.

The failure branch behaves differently and is **not** currently lost. Because the guard already
allows `PENDING → FAILED` and `PENDING → EXPIRED`, a `payment.failed` / `payment.timed_out` that
outruns `inventory.reserved` transitions Booking **directly** from `PENDING` today (payment only
runs *after* inventory reserved, so such an event always has an in-flight reservation behind it).
That direct transition is compensation-safe — Inventory releases on `BOOKING_FAILED` /
`BOOKING_EXPIRED` from its own reservation state, idempotently, backed by a reservation-TTL sweep.
It nonetheless carries three softer costs that folding it into the same deferral rule removes:
(a) the trailing `inventory.reserved` then lands on a now-terminal Booking → DLQ, polluting the
DLQ with non-anomalies under load (and DLQ growth raises alerts); (b) `payment.timed_out` driving
`PENDING → EXPIRED` conflicts with the state machine's timeout-ownership rule (`PENDING → EXPIRED`
belongs to the safety-net job — "no payment in flight" — while `PAYMENT_TIMED_OUT` maps to
`INVENTORY_RESERVED → EXPIRED`); and (c) the status history skips `INVENTORY_RESERVED`, hiding that
inventory was reserved and released. So the failure branch is deferred for **ordering fidelity and
semantic consistency**, not to prevent a loss.

**Rejected alternative.** Collapsing the machine (remove `INVENTORY_RESERVED`, allow
`PENDING → CONFIRMED`) does not fix the race — it only re-labels one ordering as valid — and it
destroys the "was inventory reserved?" distinction that the compensation matrix depends on
(`INVENTORY_REJECTED` from `PENDING` = no release; `PAYMENT_FAILED` from `INVENTORY_RESERVED` =
release owed) and weakens the invariant that `CONFIRMED` means *reserved **and** paid*.

# Decision

Treat an event that arrives **before its causal predecessor** as a **transient, retryable**
condition rather than a fatal business error. This is exactly the ordering guarantee
`SPEC-KAFKA-RETRY` already calls for ("Retries SHALL preserve ordering whenever possible").

1. **Three-way transition outcome.** The Booking transition guard classifies a requested
   transition as one of:
   - **Allowed** — apply the transition (unchanged).
   - **Premature** — the current state is a *legitimate earlier* Saga state from which the
     target becomes reachable once the predecessor event is processed. Throw a new
     **`PrematureSagaEventException`**.
   - **Illegal** — the current state is terminal or otherwise incompatible. Throw
     `InvalidStateTransitionException` (unchanged).

2. **`PrematureSagaEventException` is retryable.** It is **not** added to the consumer's
   `@RetryableTopic` `exclude` list, so it flows through the existing non-blocking retry
   ladder (Attempt 1 immediate → 5 s → 30 s → 2 min → DLQ, `SPEC-KAFKA-RETRY`). By the first
   retry, `inventory.reserved` has virtually always been processed and the transition
   succeeds. Only if the predecessor **never** arrives within the ladder does the event reach
   the DLQ — which is then a genuine anomaly worth inspecting.

3. **Symmetric across success and failure.** The premature classification applies to **all**
   payment outcomes arriving in `PENDING` (per the decision to cover the failure branch):

   | Consumed event | Current state | Classification | Rationale |
   |----------------|---------------|----------------|-----------|
   | `PAYMENT_SUCCEEDED` | `PENDING` | **Premature → retry** | waiting for `inventory.reserved` |
   | `PAYMENT_FAILED` | `PENDING` | **Premature → retry** | payment ran ⇒ reservation event is in flight |
   | `PAYMENT_TIMED_OUT` | `PENDING` | **Premature → retry** | same as above |
   | `PAYMENT_*` | `INVENTORY_RESERVED` | Allowed | normal path |
   | `PAYMENT_*` | `CONFIRMED` (same outcome) | Idempotent no-op | already settled |
   | `PAYMENT_*` | terminal (`FAILED`/`EXPIRED`/`CANCELLED`) | **Illegal → DLQ** | real anomaly |
   | `INVENTORY_RESERVED` / `INVENTORY_REJECTED` | `PENDING` | Allowed | first Saga step, no predecessor |

   For `PAYMENT_SUCCEEDED` this *fixes a break* (`PENDING → CONFIRMED` is forbidden, so it DLQs
   today). For `PAYMENT_FAILED` / `PAYMENT_TIMED_OUT` it **changes today's behaviour**: the guard
   currently allows `PENDING → FAILED` / `PENDING → EXPIRED`, so those events transition directly
   today. The handlers must therefore now raise `PrematureSagaEventException` from `PENDING`
   instead of transitioning — deferring them for the ordering/semantic reasons in §Context.

4. **Idempotency is preserved.** A premature event throws *before* the `consumed_events` row
   is written, so the retry re-processes it cleanly; a truly duplicate event (same `eventId`)
   is still skipped first (`EVT-005`, `EVT-008`).

5. **No change to valid transitions.** The state machine's transition table is untouched;
   `INVENTORY_RESERVED` stays. Only the **error classification** of an out-of-order arrival
   changes (retry instead of DLQ).

# Consequences

**Positive.** Eliminates the paid-but-expired inconsistency for the reported race and its
failure-branch twin; reuses existing non-blocking retry infrastructure; preserves the state
machine, its invariants, and the compensation semantics; keeps genuinely illegal transitions
(terminal states) going to the DLQ.

**Negative / trade-offs.** A reordered booking incurs up to the first retry delay (~5 s) of
extra latency before it confirms — acceptable for a rare event, and tunable via a shorter
initial backoff for these consumers if measured to matter. A predecessor that never arrives
now takes the full retry ladder (~2.5 min) before reaching the DLQ instead of failing fast;
this is the correct trade for a transient-by-nature condition.

# Documents to update at implementation

- `services/booking/state_machine.md` — add an **Out-of-order arrival** subsection: an event
  whose required source state has not yet been reached is **deferred (retried)**, not
  rejected; enumerate the premature cases (payment outcomes in `PENDING`).
- `contracts/asyncapi/retry-strategy.md` — add "Saga precondition not yet met (out-of-order
  event)" to **Retryable Errors**, cross-referencing the "preserve ordering" rule.
- `booking-service` (implementation, this ADR's scope):
  - add `PrematureSagaEventException`;
  - have the transition guard / handlers raise it for the premature cases in §Decision (3);
  - **remove** `PrematureSagaEventException` from being excluded — i.e. keep it **out** of the
    `@RetryableTopic(exclude = …)` list in `BookingEventConsumer` (only
    `InvalidStateTransitionException`, `BookingNotFoundException`, `IllegalArgumentException`,
    `ConstraintViolationException` stay non-retryable);
  - unit/integration tests: `payment.succeeded` (and `payment.failed` / `payment.timed_out`)
    delivered in `PENDING` retries and then settles correctly once `inventory.reserved` is
    consumed; a payment event in a terminal state still DLQs.
- `features/create-booking/feature.md` — note out-of-order tolerance in the Saga/Error
  sections and add an acceptance criterion for premature payment delivery.

# Scope note

Per `DR-002` (one ADR per affected service): the fix is **Booking-only**. Payment and
Inventory are unchanged — no sibling ADRs are required. A related, separate concern (Booking
consuming `inventory.released` while already terminal in the compensation flow) is **out of
scope** here and should be assessed on its own if load tests surface it.

# Alternatives considered (not chosen)

- **Absorb & remember the payment outcome** (persist the approved/failed payment in `PENDING`
  and apply the combined transition when `inventory.reserved` lands): removes retry latency
  and DLQ churn, but adds booking state/fields and turns the consumer into an event buffer.
  Viable hardening if retry latency is later measured to matter.
- **Re-serialize the choreography** (Payment consumes a Booking-emitted event instead of
  `inventory.reserved`): removes the race at its root but adds a hop, couples Payment↔Booking,
  and changes three services' contracts — orchestration-flavoured, better suited to the
  planned Phase-2 choreography→orchestration experiment (project.md).
