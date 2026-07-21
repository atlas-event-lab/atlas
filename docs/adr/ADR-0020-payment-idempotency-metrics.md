---
adr_id: ADR-0020
title: Expose payment duplicate-skip and provider-call metrics to make crash-recovery observable
service: Payment
status: COMPLETED
date: 2026-07-18
depends_on:
  - ADR-0019
---

# ADR-0020 — Payment idempotency metrics

# Status

`COMPLETED` (created 2026-07-18, implemented in the same change-set). Origin:
[experiments/04-consumer-crash-mid-saga/payment-idempotency-metrics.md](../../experiments/04-consumer-crash-mid-saga/payment-idempotency-metrics.md).

# Context

Payment's processing is split into two transactions around an untransacted provider call
(`PaymentServiceImpl` / `PaymentTransactionService`): TX1 `beginProcessing` (dedupe on
`eventId`, CREATED → PROCESSING, `PaymentRequested`), the provider `POST /payments`, TX2
`resolve` (PROCESSING → terminal). Idempotency is enforced in three branches (`EVT-005`,
`EVT-008`, `EVT-010`): a redelivered `eventId` is skipped, a booking that already has a
`Payment` is never charged again, and a duplicate outcome on a terminal payment is a no-op.

Experiment 04 (consumer crash mid-Saga) SIGKILLs the payment pods mid-batch and needs those
branches to be *visible*: how many redeliveries were absorbed by the guard, and how many
charge calls the service actually sent (the no-double-charge claim). Both were log-only;
inventory closed the same gap with ADR-0019, payment had no equivalent. (A same-event
redelivery always hits the `duplicate` branch — TX1 records the `eventId` — so the crash
windows W2/W3 share that reason; W2 is isolated in Postgres as payments left PROCESSING.)

# Decision

Add two low-cardinality Micrometer counters:

- **`atlas.payment.events.skipped`** `{reason=duplicate|already_charged|already_resolved,
  event=inventory_reserved}` — incremented in each idempotency skip branch via a
  `recordSkip(reason)` helper in `PaymentTransactionService`:
  - `duplicate` — `existsById(eventId)` in `beginProcessing` (any same-event redelivery:
    crash windows W2/W3);
  - `already_charged` — a `Payment` already exists for the `bookingId` (a re-trigger with a
    **new** `eventId`; not the redelivery case);
  - `already_resolved` — `resolve` on an already-terminal payment.
- **`atlas.payment.provider.calls`** `{outcome=success|declined|transient_error|timeout}` —
  incremented in `PaymentServiceImpl` when a provider charge call completes, tagged with
  `ProviderCallResult.finalOutcome()`.

Prometheus names `atlas_payment_events_skipped_total` / `atlas_payment_provider_calls_total`,
exposed via the existing `/actuator/prometheus` + PodMonitor — no scraping change. Pure
observability: no guard or control-flow change. Counters are per-process; Experiment 04 reads
them on the replacement pods, where they count exactly this recovery's redeliveries and
charges (the durable Postgres invariants carry the before/after correctness comparison).

# Consequences

**Positive.** Crash-recovery (effectively-once under abrupt death) becomes a positive,
watchable signal; the W1/W3-vs-W2 split and the charges-sent count are readable straight from
Grafana. **Negative.** One counter increment per skip/charge (negligible).

# Documents to update at implementation

- `payment-service` — `PaymentTransactionService` (skip counter + `recordSkip` helper),
  `PaymentServiceImpl` (provider-calls counter); `PaymentTransactionServiceTest` wired with a
  real `SimpleMeterRegistry` (done).
- No contract (OpenAPI/AsyncAPI) change — metrics are not part of a service contract.
- Experiment 04 README/runbook reference the meters for the post-recovery readout.
