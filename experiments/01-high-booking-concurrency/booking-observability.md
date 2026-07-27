# Booking observability — measuring the Saga, not just the 201

**Origin:** Experiment 01 — High Booking Concurrency · **Phase:** 7 (APM) · **Status:** implemented
**Services affected:** booking-service · **ADR:** [ADR-0028](../../docs/adr/ADR-0028-booking-saga-outcome-metrics.md)

> This is the narrative half of Experiment 01's observability work: what the experiment claimed
> to measure, why it wasn't measuring it, what we added, and how it's validated. It is scoped to
> this experiment; the binding service-code change is recorded as **ADR-0028** (booking-service).
> Same convention as `payment-service-scaling.md` ↔ ADR-0015 and
> `02-inventory-contention/inventory-observability.md` ↔ ADR-0018.

## 1. What the experiment surfaced (the gap)

The work started as "let's build a Grafana dashboard for Experiment 01." Auditing which metrics
that dashboard would draw from turned up something more important than the dashboard.

Experiment 01's success criterion reads:

> Booking success rate ≥ 98% through the target hold.

**That was not being measured.** `POST /bookings` returns **201 as soon as the Saga is kicked
off** — the booking is `PENDING`, an event is in the outbox, and the outcome will be decided
later by `inventory-service` and `payment-service`. Both signals available at the time stop at
that boundary:

| Signal | What it actually measures |
|---|---|
| k6 `booking_success_rate` | the POST returned 201 — **acceptance** |
| `http_server_requests_seconds_*` | the synchronous handler's latency and status |

> **Update 2026-07-26.** That k6 metric was worse than "acceptance": it recorded a failure when
> the *cart* failed too, so it was really a journey rate under a booking name. It has since been
> split into `journey_success_rate` and `booking_accept_rate` (see the experiment README). The
> point below stands unchanged — neither of them sees the Saga outcome.

So a booking that was accepted and then transitioned to `FAILED` counted as a success. The
reported rate was an upper bound on the true one, and nothing in the system could tell you how
loose that bound was.

The gap sits exactly where the hypothesis lives. Experiment 01 claims degradation past the knee
is **graceful — latency, not errors**. But the synchronous POST barely degrades by construction:
it validates, writes a row, writes an outbox event, returns. The part that stretches under load
is the asynchronous tail — inventory reserve, payment, confirmation — and **nothing was watching
it**. A dashboard built on the existing metrics would have looked authoritative while inheriting
the blind spot.

`booking-service` emitted **no domain metrics at all** — only framework ones. (`atlas.booking.*`
strings in the codebase are `@ConfigurationProperties` prefixes, not meters.)

Two alternatives were rejected:

- **Per-booking or per-user labels** — unbounded cardinality, the same reason ADR-0018 rejected
  per-flight gauges.
- **Deriving the rate from `booking_status_history` at query time** — needs DB access from
  Grafana, crosses the service data boundary (`ARCH-002`), and can't be alerted on.

## 2. What we added (decision)

Two low-cardinality meters in `BookingServiceImpl`, via a constructor-injected `MeterRegistry`
(same shape as `InventoryServiceImpl`). Both are written by one private helper called at **every**
terminal transition and nowhere else, so they cannot drift apart:

```java
private void recordTerminal(Booking booking) {
    String state = booking.getStatus().name();
    meterRegistry.counter(M_OUTCOMES, KEY_TAG_STATE, state).increment();
    ...
    meterRegistry.timer(M_SAGA_DURATION, KEY_TAG_STATE, state)
                 .record(Duration.between(createdAt, clock.instant()));
}
```

**`atlas.booking.outcomes{state}`** — one increment per booking reaching `CONFIRMED`, `FAILED`,
`EXPIRED` or `CANCELLED`. The server-side success rate is `CONFIRMED / all`, true whether or not
k6 is attached.

**`atlas.booking.saga.duration{state}`** — creation → terminal state. This is the end-to-end
Saga latency: the curve the experiment asserts and previously could not draw.

Intermediate states (`INVENTORY_RESERVED`, `CANCELLING`, `PAYMENT_PENDING`) are excluded on
purpose. Counting them would make the outcome totals useless as a success rate, and an in-flight
Saga has no duration yet.

The six call sites are the six terminal transitions: `FAILED` (inventory rejected), `CONFIRMED`,
`FAILED` (payment failed), `EXPIRED` (payment timed out), `CANCELLED` (inventory released), and
`EXPIRED` (expiration scheduler).

### Histogram buckets are not optional here

A plain Micrometer `Timer` publishes only `_count`, `_sum` and `_max` — `histogram_quantile()`
cannot compute a p95 from that. `application.yml` therefore enables buckets for this timer, and
widens the range:

```yaml
percentiles-histogram:
  atlas.booking.saga.duration: true
maximum-expected-value:
  atlas.booking.saga.duration: 5m     # default tops out at 30s
```

The `maximum-expected-value` matters more than it looks: the default ceiling is 30s, and a Saga
past the scaling knee can exceed that. Everything above the top bucket collapses into `+Inf` —
precisely the degraded tail the experiment exists to observe.

## 3. Dashboard

`deploy/platform/observability/atlas-exp01-dashboard.yaml` — *Atlas — Experiment 01: High Booking
Concurrency*, auto-loaded by the Grafana sidecar into the **Atlas** folder.

Worth noting how little of it is new: **only the two `atlas_booking_*` meters had to be built.**
Everything else the experiment's *What to watch* table asks for was already being scraped and was
already in use by other Atlas dashboards.

| Row | Answers | Source |
|---|---|---|
| The verdict | did it pass? | `atlas_booking_outcomes_total`, saga p95, 5xx rate |
| Saga outcome | what the 201 does not tell you | the two new meters vs `http_server_requests` |
| Autoscaling | does the hot path scale? | `kube_horizontalpodautoscaler_status_*`, cAdvisor CPU |
| Database | does the pooler keep connections bounded? | `cnpg_pgbouncer_pools_*`, `cnpg_backends_total`, `hikaricp_connections_*` |
| Kafka | does the backlog drain? | `kafka_consumergroup_lag` |
| k6 | the load side | `k6_*`, only with `PROM=1` |

The dashboard's sharpest panel is **"Latency: synchronous POST vs full Saga"**. The two lines
answer different questions, and the distance between them *is* the asynchronous degradation. The
k6 row deliberately plots client-side acceptance against server-side completion for the same
reason: the gap is work the system took on and then could not honour.

`hikaricp_connections_*` was already exposed by Spring Boot and used by no dashboard — a free
signal. It complements PgBouncer: `cl_waiting` shows pressure at the pooler, `hikaricp_pending`
shows app threads blocked waiting for a connection. Either can be the real constraint.

## 4. Validation

- `BookingServiceImplTest` constructs the service with a real `SimpleMeterRegistry` (the
  ADR-0018 pattern), so the meters are exercised by the existing suite rather than mocked away.
- All six terminal transitions verified to call `recordTerminal` — the count is asserted
  structurally, not by eye.
- Dashboard validated as YAML **and** as embedded JSON; every PromQL series cross-checked against
  metrics that already appear in the other Atlas dashboards, which is how the Spring Boot service
  label was caught as `job` (not `service`).

Open item: the `k6_*` series names depend on the k6 version and on
`K6_PROMETHEUS_RW_TREND_STATS`. The exp-02 dashboard's working `k6_bookings_created` was used as
the naming reference; confirm on the first `PROM=1` run and adjust if the trend suffixes differ.
The k6 summary remains the authoritative record of a run either way.

## 5. Conclusion

The dashboard was the request; the finding was that Experiment 01's headline number measured
acceptance and reported it as success. That is now fixed at the source rather than papered over
in a panel — and the two meters are permanent APM signals, not experiment scaffolding.

**Re-run Experiment 01 before trusting the earlier `RESULTS*.md` success rates.** They were
computed from the client-side acceptance metric, so they are upper bounds. The gap may well be
negligible; the point is that until now there was no way to know.
