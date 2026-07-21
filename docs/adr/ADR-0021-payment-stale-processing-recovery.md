---
adr_id: ADR-0021
title: Recover stale PROCESSING payments with an idempotent charge re-drive sweeper
service: Payment
status: COMPLETED
date: 2026-07-18
depends_on:
  - ADR-0020
---

# ADR-0021 — Payment stale-PROCESSING recovery sweeper

# Status

`COMPLETED` (created 2026-07-18, implemented in the same change-set). Origin:
[experiments/04-consumer-crash-mid-saga/payment-recovery.md](../../experiments/04-consumer-crash-mid-saga/payment-recovery.md).

# Context

`onInventoryReserved` runs TX1 (`beginProcessing`: dedupe on `eventId` + create the Payment in
PROCESSING), the untransacted provider call, then TX2 (`resolve`). TX1 commits the
`ConsumedEvent` with the Payment, so if the process crashes between TX1 and TX2 (window
**W2**, Experiment 04), the redelivered event is — correctly — skipped as a duplicate and the
charge is never re-driven. Nothing else settles it: booking-expiration owns `PENDING` only
(*Timeout Ownership*: `INVENTORY_RESERVED → EXPIRED` belongs to `PaymentTimedOut`, which a
dead process never emits), and inventory's TTL sweep restores stock without settling the
booking. Result: a permanent orphan pair (payment PROCESSING, booking `INVENTORY_RESERVED`) —
and, if the crash landed after the provider charged, a customer charged with no booking.

The safe-retry building block already exists: every charge carries
`Idempotency-Key: <paymentId>` (provider contract assumption,
`features/payment/implementation_plan.md`), so re-driving the same payment cannot
double-charge — the provider replays the original outcome.

# Decision

Add a `PaymentRecoveryScheduler` to payment-service (mirror of inventory's
`ReservationExpirationScheduler`), with `PaymentRecoveryProperties`
(`atlas.payment.recovery.*`):

- Every `sweep-interval-ms` (default 60 000), find up to 100 payments in `PROCESSING` with
  `updatedAt < now - stale-after` (default `3m`) and call
  `PaymentService.recoverStalePayment(paymentId)` — per-payment failures are isolated.
- `recoverStalePayment` resumes exactly where the crash cut the flow: provider charge with
  the same `paymentId` (same idempotency key) → the shared charge-and-resolve path (TX2).
  Every terminal outcome re-enters the normal Saga: SUCCEEDED → booking confirms; FAILED →
  compensation; TIMED_OUT → `PaymentTimedOut` → booking EXPIRED.
- Races are safe: `resolve` no-ops on terminal payments (`already_resolved`, ADR-0020) and
  the provider idempotency key absorbs concurrent duplicate charges. `stale-after` SHALL
  exceed the worst-case provider budget (~30 s) so a legitimately in-flight charge is never
  swept, and SHALL stay — including one sweep + recovery pass — under inventory's reservation
  TTL (15 m) and booking's pending safety-net (30 m) per the cascading timeout budget.
- Observability: **`atlas.payment.recoveries`** `{outcome=success|declined|transient_error|
  timeout}` (Prometheus `atlas_payment_recoveries_total`) counts recovered payments; the
  re-driven charge also increments `atlas_payment_provider_calls_total` (ADR-0020).

Scope: payment-service only. Booking already consumes every terminal payment event; no
contract change — `payment.*` topics and message schemas are untouched.

# Consequences

**Positive.** The Saga's liveness no longer depends on payment-service never crashing between
TX1 and TX2: W2 orphans self-heal within `stale-after` + one sweep, visibly (Experiment 04
asserts it). The charged-but-unresolved sub-case now converges to SUCCEEDED instead of
requiring manual reconciliation. **Negative / assumption.** Charging becomes at-least-once
*under the idempotency-key assumption*: correctness against double charge now rests on the
provider honoring `Idempotency-Key`. The WireMock fake does not enforce it (each call returns
a fresh outcome) — acceptable in the lab, but a real provider integration MUST support it.

# Documents to update at implementation

- `payment-service` — `PaymentRecoveryScheduler`, `PaymentRecoveryProperties`,
  `PaymentService.recoverStalePayment` (+ shared charge-and-resolve in `PaymentServiceImpl`),
  `PaymentRepository.findTop100ByStatusAndUpdatedAtBeforeOrderByUpdatedAtAsc`,
  `application.yml` (`atlas.payment.recovery.*`), tests (done).
- Experiment 04 README/runbook — W2 success criteria now assert convergence via the sweeper.
- No AsyncAPI/OpenAPI change.
