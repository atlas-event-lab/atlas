# Payment stale-PROCESSING recovery — closing the W2 liveness gap

**Origin:** Experiment 04 — Consumer Crash mid-Saga (design analysis, pre-run) · **Phase:** Saga resilience
**Status:** implemented · **Services affected:** payment-service
**ADR:** [ADR-0021](../../docs/adr/ADR-0021-payment-stale-processing-recovery.md)

> Narrative half of the liveness gap surfaced while preparing Experiment 04. Same convention
> as the other per-experiment findings docs. The binding change is **ADR-0021**.

## 1. The gap (what the W2 analysis showed)

Payment's TX1 commits the `Payment` (PROCESSING) **together with** the `ConsumedEvent(eventId)`.
If the process crashes after TX1 and before TX2 (`resolve`), the redelivered
`inventory.reserved` is — correctly — skipped as a duplicate, the offset commits, and **nothing
ever re-drives the charge**. The orphan chain is designed-in:

- `BookingExpirationScheduler` (booking) expires **PENDING only**; by the *Timeout Ownership*
  addendum, `INVENTORY_RESERVED → EXPIRED` is owned exclusively by Payment's `PaymentTimedOut`
  — which a dead process never emits.
- Inventory's TTL sweep restores the stock but deliberately does not settle the booking.
- Net: stock recovers, but the payment stays PROCESSING and the booking stays
  `INVENTORY_RESERVED` **forever**. Worst sub-case: the crash landed *after* the provider
  charged — a customer charged with no booking and no compensation path.

The at-most-once-charge half of the design (never charge twice) is right. What was missing is
the production-standard other half: **recovery of stalled charge intents**.

## 2. What we added (decision)

A `PaymentRecoveryScheduler` in payment-service — the mirror image of inventory's TTL sweep —
plus the observation that the safe-retry building block **already existed**: the provider
contract sends `Idempotency-Key: <paymentId>` on every charge, so re-driving the same payment
can never double-charge (the provider replays the original outcome).

Sweep loop (every `sweep-interval-ms`, default 60 s): find up to 100 payments in `PROCESSING`
with `updatedAt` older than `stale-after` (default 3 m), and for each one **resume exactly
where `onInventoryReserved` died**: call the provider with the same `paymentId` (same
idempotency key), then run the normal TX2 `resolve`:

- provider replays/returns SUCCESS → `SUCCEEDED` → `PaymentSucceeded` → booking CONFIRMED;
- DECLINED / persistent transient error → `FAILED` → `PaymentFailed` → Saga compensates;
- provider unreachable → `TIMED_OUT` → `PaymentTimedOut` → booking EXPIRED (the owner that
  *Timeout Ownership* was waiting for).

Races are safe by construction: `resolve` no-ops on a terminal payment
(`already_resolved`), and a concurrent duplicate charge is absorbed by the provider's
idempotency key. **Cascading timeout budget:** `stale-after` (3 m) + one recovery pass sits
far below inventory's reservation TTL (15 m) and booking's pending safety-net (30 m), so
recovery always runs before anyone else gives up.

Observability: `atlas_payment_recoveries_total{outcome=…}` counts each recovered payment by
its final provider outcome; the recovered charge also flows through
`atlas_payment_provider_calls_total` (ADR-0020) like any other.

## 3. Validation

- `PaymentServiceImplTest` — resume path: charges the same `paymentId`, resolves, increments
  the recovery counter; skips cleanly when the payment vanished or resolved concurrently.
- `PaymentRecoverySchedulerTest` — sweeps only stale PROCESSING payments; isolates
  per-payment failures (one bad payment does not abort the batch).
- Experiment 04 is the end-to-end proof: after the crash, W2 orphans must now converge —
  every batch booking terminal within `stale-after` + one sweep, with zero double charges.

## 4. Conclusion

The Saga's liveness no longer depends on payment-service never crashing between TX1 and TX2.
W2 goes from "permanent orphan, page an operator" to "self-heals within minutes, visibly" —
and Experiment 04 gains the assertion that proves it. Cut to **ADR-0021** (payment-service).
