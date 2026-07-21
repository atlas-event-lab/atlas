# Payment idempotency — making crash-recovery visible

**Origin:** Experiment 04 — Consumer Crash mid-Saga · **Phase:** 7 (APM)
**Status:** implemented · **Services affected:** payment-service
**ADR:** [ADR-0020](../../docs/adr/ADR-0020-payment-idempotency-metrics.md)

> Narrative half of Experiment 04's observability work: what the experiment needs to measure,
> why the existing signals fall short, and what we added. Same convention as Exp 01
> (`payment-service-scaling.md` ↔ ADR-0015), Exp 02 (`inventory-observability.md` ↔ ADR-0018)
> and Exp 03 (`idempotency-metrics.md` ↔ ADR-0019).

## 1. The gap

Experiment 04 SIGKILLs every payment-service pod mid-batch and asserts crash-recovery:
no double charge, no lost event, the Saga heals. The durable Postgres invariants carry the
correctness claim, but the *demonstration* was invisible in metrics on two fronts:

- **Dedup was log-only.** Payment's guard has three distinct skip branches — duplicate
  `eventId` (`beginProcessing`: any same-event redelivery, i.e. crash windows W2 *and* W3),
  payment-already-exists for the booking (`beginProcessing`: a re-trigger with a **new**
  `eventId` — not the crash-redelivery case, since TX1 records the `eventId`), and
  already-terminal (`resolve`, a duplicate outcome). Each was observable only as a log line.
  Inventory got a duplicate-skip meter for exactly this reason (ADR-0019); payment had none.
  (W2 is separated from W3 in Postgres — payments left PROCESSING — not by the `reason` tag.)
- **Charges were only countable at the provider.** "No double charge" was asserted from the
  `payments` table plus a best-effort WireMock request count. There was no service-side signal
  of how many charge calls payment actually sent, so the strongest claim of the experiment had
  no positive, watchable metric.

## 2. What we added (decision)

Two low-cardinality Micrometer counters, mirroring the ADR-0018/0019 style:

| Meter (Prometheus name) | Tags | Incremented when |
|--------------------------|------|------------------|
| `atlas_payment_events_skipped_total` | `reason=duplicate\|already_charged\|already_resolved`, `event=inventory_reserved` | an idempotency-guard branch skips work: redelivered `eventId` (W2/W3) / a `Payment` already exists for the booking (new-`eventId` re-trigger) / the payment is already terminal |
| `atlas_payment_provider_calls_total` | `outcome=success\|declined\|transient_error\|timeout` | a provider charge call completes, tagged with its final outcome |

`recordSkip(reason)` in `PaymentTransactionService` keeps the three skip sites uniform;
`PaymentServiceImpl` records the provider call with its `finalOutcome()`. Pure observability:
no guard or control-flow change.

**Restart semantics (why the counters are read *after* recovery).** Micrometer counters are
per-process and the experiment kills the pods, so the replacement pods start at 0. Read after
the crash, `events_skipped_total{reason="duplicate"}` therefore counts exactly the
redeliveries absorbed by *this* recovery (W2 + W3 together; W2 is isolated in Postgres as the
payments left PROCESSING), and `provider_calls_total` counts exactly the charges sent after
the crash, which must equal the payments newly charged (never ≈ 2×). The durable Postgres
invariants still carry the before/after correctness comparison.

## 3. Validation

- `PaymentTransactionServiceTest` constructs the service with a real `SimpleMeterRegistry`
  (same wiring as `InventoryServiceImplTest` since ADR-0018); the three existing idempotency
  tests additionally assert their branch's counter.
- Runbook readout: after recovery, `events_skipped_total{reason="duplicate"}` ≈ redeliveries
  (W2+W3), and `provider_calls_total` == payments charged after the kill. The W2 count comes
  from Postgres (payments stuck PROCESSING).

## 4. Conclusion

Crash-recovery goes from a log-grepping exercise to a positive, watchable signal: the dedup
counter proves the redelivery was absorbed (and *which way*), the provider-calls counter
proves no double charge from the service's own point of view. Cut to **ADR-0020**
(payment-service).
