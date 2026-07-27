---
adr_id: ADR-0028
title: Expose booking Saga outcome and end-to-end duration metrics for scalability APM
service: Booking
status: COMPLETED
date: 2026-07-26
depends_on:
  - ADR-0018
---

# ADR-0028 — Booking Saga outcome metrics

# Status

`COMPLETED` (created 2026-07-26). Merged: both meters are implemented in `BookingServiceImpl`
and the test constructs the service with a real `SimpleMeterRegistry`. Origin:
[experiments/01-high-booking-concurrency/booking-observability.md](../../experiments/01-high-booking-concurrency/booking-observability.md).

# Context

Experiment 01 (high booking concurrency) claims that the hot path **scales**, and that past the
knee the system degrades **gracefully — in latency, not in errors**. Its success criterion is
stated as *"booking success rate ≥ 98% through the target hold."*

That criterion was not being measured. `POST /bookings` returns **201 as soon as the Saga is
kicked off**; the outcome is decided asynchronously afterwards, by `inventory-service` and
`payment-service` events that `booking-service` consumes. So both available signals answer the
wrong question:

- **k6's `booking_success_rate`** counts HTTP 201 responses — that is *acceptance*, not success.
  A booking that is accepted and then transitions to `FAILED` is indistinguishable from one that
  reaches `CONFIRMED`.
- **`http_server_requests_seconds_*`** likewise covers only the synchronous half, and stops at
  the moment the event is written to the outbox.

> **Post-implementation note (2026-07-26).** The k6 metric named here was later found to record
> a failure for a failed *cart* as well, making it a journey rate rather than an acceptance rate.
> It has been split into `journey_success_rate` and `booking_accept_rate`. This does not change
> the decision — neither k6 rate observes the Saga outcome, which is exactly why these meters
> exist.

`booking-service` emitted **no domain metrics at all** — only framework ones. The result is a
measurement gap exactly where the experiment's hypothesis lives: the asynchronous tail is the
part that stretches under load, and nothing was watching it. A dashboard built on the existing
signals would have inherited the same blind spot while looking authoritative.

Per-booking or per-user labels were rejected for the usual cardinality reason. Deriving the rate
from `booking_status_history` at query time was rejected too: it needs DB access from Grafana,
crosses the service's data boundary (`ARCH-002`), and cannot be alerted on.

# Decision

Add two low-cardinality Micrometer meters to `BookingServiceImpl` (constructor-injected
`MeterRegistry`, matching the inventory precedent in ADR-0018), both recorded by a single private
`recordTerminal(Booking)` helper invoked at **every** terminal transition and nowhere else:

1. **`atlas.booking.outcomes`** `{state=CONFIRMED|FAILED|EXPIRED|CANCELLED}` — one increment per
   booking reaching a terminal state. The server-side success rate is then
   `CONFIRMED / all`, independent of whether a load generator is attached.
2. **`atlas.booking.saga.duration`** `{state}` — a Timer recording `createdAt → clock.instant()`,
   i.e. the end-to-end Saga latency. Percentile buckets are enabled for it in `application.yml`
   (`percentiles-histogram`), with `maximum-expected-value: 5m` so a degraded tail stays
   resolvable instead of collapsing into the `+Inf` bucket.

Intermediate states (`INVENTORY_RESERVED`, `CANCELLING`, `PAYMENT_PENDING`) are deliberately
excluded: counting them would make the outcome totals unusable as a success rate, and an in-flight
Saga has no duration yet.

Prometheus names become `atlas_booking_outcomes_total` and `atlas_booking_saga_duration_seconds_*`.
Exposed via the existing `/actuator/prometheus` + PodMonitor — no scraping changes. These are
permanent APM signals, not experiment-gated.

# Consequences

**Positive.** The experiment's own success criterion becomes measurable server-side and
alertable. The gap between `k6_booking_success_rate` (acceptance) and
`atlas_booking_outcomes_total{state="CONFIRMED"}` (completion) becomes visible, and that gap is
itself the interesting quantity: work the system accepted and then could not honour. The
Saga-duration histogram gives the graceful-degradation claim a curve instead of an assertion.

**Negative.** One counter increment and one timer record per terminal transition (negligible; the
registry caches meter lookups). A histogram carries more series than a plain Timer — bounded here
by 4 states × the bucket count, on one service. `BookingServiceImpl`'s constructor gains a
parameter, so any manual construction must pass a registry.

**Neutral.** `recordTerminal` is called after the state mutation and inside the same
`@Transactional` method, so a rolled-back transaction still leaves the counter incremented. This
is accepted: the transitions in question are event-consumer paths that commit or retry, and the
alternative (an after-commit hook) adds machinery disproportionate to an observability signal.

# Documents to update at implementation

- `booking-service` — `BookingServiceImpl` (meters + `recordTerminal`; done in this change).
- `booking-service` — `application.yml` (`percentiles-histogram` + `maximum-expected-value`; done).
- `BookingServiceImplTest` — construct with a `SimpleMeterRegistry` (done).
- `deploy/platform/observability/atlas-exp01-dashboard.yaml` — the dashboard (added).
- `experiments/01-high-booking-concurrency/README.md` — success criteria and *What to watch*
  corrected to distinguish acceptance from completion (done).
- No OpenAPI/AsyncAPI contract change (metrics are not part of a service contract).
