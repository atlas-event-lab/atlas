---
adr_id: ADR-0031
title: Raise the booking-service replica ceiling to 5 — one pod carries REST, producer and consumer
service: Booking
status: COMPLETED
date: 2026-07-26
depends_on:
  - ADR-0030
---

# ADR-0031 — booking-service replica ceiling

# Status

`COMPLETED` (created 2026-07-26). Merged: `values/booking.yaml` raises `autoscaling.maxReplicas`
from 4 to 5. Origin: Experiment 01 run of 2026-07-26, the first one taken after
[ADR-0030](ADR-0030-travel-cart-cpu-hpa.md) removed the travel-cart bottleneck.

# Context

Removing the cart bottleneck moved the knee downstream, exactly as expected — and made
booking-service the slowest hop for the first time:

| | before ADR-0030 | after |
|---|---|---|
| `cart_create` p95 | 3.84s | 3.08s |
| `cart_add_item` p95 | 4.08s | 3.26s |
| `cart_convert` p95 | 4.07s | 3.30s |
| **`booking_create_duration` p95** | **1.00s** | **7.81s** |
| journey failures | 942 | **0** |

The shape of that regression matters more than its size. The distribution is healthy up to p90
and then falls off a cliff — median **719ms**, p90 **1.82s**, p95 **7.81s**, max **20.21s**. That
is queueing, not uniform slowness: most requests pass quickly while a minority waits on a
contended resource.

**booking-service does three jobs inside one pod**, and the HPA sees only their combined CPU:

1. the synchronous REST hot path (`POST /bookings`, which also makes blocking Feign calls to
   flight-service and hotel-service for price validation);
2. the outbox relay **producing** to Kafka;
3. **consuming** the Saga topics (`inventory.*`, `payment.*`) to drive state transitions.

So REST latency and consumer throughput compete for the same budget: a burst of Saga events can
starve the request path inside a pod without the HPA distinguishing the two. It is the most
resource-demanding service in the hot path — `cart-inventory-scaling.md` recorded that back on
2026-07-08 ("booking replicas 1 → 4, most CPU/mem-demanding, held").

**Rejected: splitting REST and consumer into separate deployments.** It would let each scale on
its own signal and is probably right eventually, but it is an architecture change with its own
ADR, not a response to one measurement.

**Rejected: doing nothing pending better data.** The run that produced these numbers never
reached its target rate (VU-bound at ~35 of 60 iterations/s), so booking was not pushed to its
own limit. Raising the ceiling is cheap and reversible, and lets the next run answer the question
instead of hitting a config wall.

# Decision

Raise `autoscaling.maxReplicas` from 4 to **5** in `values/booking.yaml`. `minReplicas: 2`,
the 70% CPU target, and anti-affinity are unchanged.

# Consequences

**Positive.** One more pod of headroom for whichever of the three roles is starving. Combined
with travel-cart's 3 → 4 (ADR-0030), the hot path can absorb more of the arrival rate before
queueing, which is what the `booking_create_duration` p95 threshold needs.

**Negative.** One more pod at peak on a 3-node cluster (12 vCPU / 48 GB). Scheduling is by *request*
(150m), so it fits comfortably on paper; the caveat below is about real usage.

**Neutral / open.** The same request mis-sizing flagged in ADR-0030 applies here: with the CPU
request at 150m and a 1000m limit, a service drawing several hundred milli-cores sits permanently
above the HPA's 70% target, so the HPA is pinned at `maxReplicas` rather than modulating. Raising
the ceiling therefore raises the *fixed* replica count under load, not the responsiveness of the
scaling. Right-sizing `requests.cpu` across the chart is the follow-up that would make these
ceilings behave like ceilings again — a capacity decision, deliberately not bundled here.

**Unverified.** The leading hypothesis for the p95 cliff is the blocking Feign calls to
flight-service and hotel-service, both deliberately pinned at a single replica and **not** cached
(the only Redis cache is `usdExchangeRates`). If that is the cause, extra booking replicas will
not fix it — they will queue against the same two single-pod services. Confirm on the next run
before concluding that this ADR worked:

```promql
sum(rate(http_client_requests_seconds_sum{job="booking-service"}[$__rate_interval]))
  / sum(rate(http_client_requests_seconds_count{job="booking-service"}[$__rate_interval]))
```

(Percentiles need `management.metrics.distribution.percentiles-histogram.http.client.requests`,
which is not enabled — hence the mean.)

# Documents to update at implementation

- `deploy/helm/atlas-service/values/booking.yaml` — `maxReplicas` 4 → 5 (done in this change).
- `experiments/01-high-booking-concurrency/cart-inventory-scaling.md` — the 2026-07-26 follow-up
  recorded (done).
- No OpenAPI/AsyncAPI change; no service code change.
