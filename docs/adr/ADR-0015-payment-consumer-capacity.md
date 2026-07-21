---
adr_id: ADR-0015
title: Scale payment to 12 consumers (KEDA max 4 + concurrency 3) to hold 60 req/s
service: Payment
status: COMPLETED
date: 2026-07-10
depends_on:
  - ADR-0013
  - ADR-0016
  - ADR-0017
---

# ADR-0015 — Payment consumer capacity (12 in-flight consumers)

# Status

`PENDING` (created 2026-07-10). Flip to `COMPLETED` when merged (`DR-003`). Origin:
[experiments/01-high-booking-concurrency/consumer-capacity-scaling.md](../../experiments/01-high-booking-concurrency/consumer-capacity-scaling.md).
Builds on [payment-service-scaling.md](../../experiments/01-high-booking-concurrency/payment-service-scaling.md)
(KEDA + concurrency + `inventory.reserved` 3→6). Depends on the partition raise (ADR-0016) and the
WireMock HPA (ADR-0017).

# Context

The 2026-07-10 run showed **no duplicates** but payment consumer lag up to **~7 min** at 60 req/s,
with payment at only **~0.57 CPU** and **~1.1 Gi/pod** of its limit — **I/O-bound** on the provider
(WireMock) HTTP call, not compute-bound.

Provider latency: the default stub path returns `APPROVED` after a **lognormal ~150 ms** delay. At
~150 ms per blocking call, capacity ≈ `in-flight_threads / 0.15 s`:

- today `3 pods × concurrency 2 = 6 threads → ~40 payments/s` ⇒ can't hold 60/s ⇒ lag.
- target `4 pods × concurrency 3 = 12 threads → ~80 payments/s` ⇒ headroom.

# Decision

1. **KEDA `maxReplicaCount` 3 → 4** (`deploy/platform/keda/payment-scaledobject.yaml`); scaling stays
   **lag-based** (payment is I/O-bound; a CPU HPA barely triggers). Retune `lagThreshold` upward
   (with concurrency 3 per pod it can rise toward ~150).
2. **`KAFKA_CONCURRENCY` 2 → 3** (`values/payment.yaml`; global `spring.kafka.listener.concurrency`).
   `4 × 3 = 12` consumers = 12 partitions on `inventory.reserved` (ADR-0016). No idle threads.
3. **Retry/DLQ topics.** `@RetryableTopic(attempts = 4)` auto-creates `inventory.reserved-retry-*` (×3)
   and `inventory.reserved-dlq`. Confirm/raise their partition count alongside the main topic so
   retried events (`TEMPORARY_FAILURE` 503 / `TIMEOUT` scenarios) don't serialize on fewer partitions.
4. **Depends on the WireMock HPA (ADR-0017).** 12 in-flight consumers ⇒ up to 12 concurrent provider
   calls; without scaling WireMock, payment's consumer lag simply becomes provider latency. The two
   changes ship together.

# Consequences

**Positive.** ~2× effective throughput (6 → 12 in-flight) at the right signal (lag), holding 60/s with
headroom for 80/s. **Negative / trade-offs.** A 4th pod adds ~1.1 Gi aggregate (fits the nodes);
concurrency 3 adds Hikari pressure (verify pool ≥ ~10) and a few MB heap. Effectiveness is **gated by
WireMock capacity** (ADR-0017) — scaling payment alone only relocates the bottleneck.

# Documents to update at implementation

- `deploy/platform/keda/payment-scaledobject.yaml` — `maxReplicaCount: 4`, retuned `lagThreshold`.
- `values/payment.yaml` — `KAFKA_CONCURRENCY: "3"`.
- Depends on ADR-0016 (`inventory.reserved` 12 + retry topics) and ADR-0017 (WireMock HPA).

# Scope note

Per `DR-002`, this ADR is **payment-only**. Partitions → ADR-0016; provider scaling → ADR-0017;
inventory's symmetric change → ADR-0014.

# Alternatives considered

- **Raise concurrency higher on 3 pods (e.g. 4)** instead of a 4th pod: fewer JVMs but a hotter
  Hikari pool and less failure isolation; 4×3 keeps `pods × concurrency = partitions` clean.
- **CPU HPA**: already rejected in payment-service-scaling.md — payment is I/O-bound, CPU never
  reaches target while lag grows. KEDA-on-lag stays.
