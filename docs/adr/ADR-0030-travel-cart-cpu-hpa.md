---
adr_id: ADR-0030
title: Add a CPU HPA to travel-cart-service (1–4 replicas) — the hot path's only unscaled hop
service: Travel Cart
status: COMPLETED
date: 2026-07-26
depends_on:
  - ADR-0003
---

# ADR-0030 — travel-cart CPU HPA

# Status

`COMPLETED` (created 2026-07-26). Merged: `values/travel-cart.yaml` now carries an `autoscaling`
block (CPU, 1–4) and `podAntiAffinity`. Origin:
[experiments/01-high-booking-concurrency/cart-inventory-scaling.md](../../experiments/01-high-booking-concurrency/cart-inventory-scaling.md) §2.1.

# Context

`travel-cart-service` is the **first** service in every booking journey and is hit three times
before a booking is even attempted: `POST /carts`, `PUT /carts/{id}/{type}` per item, and
`POST /carts/{id}/convert`.

It had **no autoscaler of any kind**. Its values file carried no `autoscaling` block, so it
inherited `enabled: false` from the chart's `values.yaml`, which makes `templates/deployment.yaml`
render a fixed `replicas: {{ .Values.replicaCount }}` — and `replicaCount` defaults to 1. There
was no HPA object to trigger, and no threshold to tune: the service was pinned at one pod by
construction, permanently. A manual `kubectl scale` would not have survived either, because the
wave-7 ApplicationSet runs with `selfHeal: true` and re-asserts the rendered replica count.

This was measured twice, three weeks apart:

- **2026-07-08** (`cart-inventory-scaling.md`): travel-cart at ~**300% of its CPU request**,
  throttled, pinned at 1 pod. The document proposed exactly this HPA and stayed at
  `Status: proposal`.
- **2026-07-26** (Experiment 01 re-run): `cart_create` p95 **3.84s**, `cart_add_item` p95
  **4.08s**, `cart_convert` p95 **4.07s** — while `booking_create_duration` p95 was **1.00s**,
  comfortably inside its 2s threshold. With `SCENARIO=both` (two item adds) the cart accounts for
  roughly 12 of the 11.72s `journey_duration` p95. The journey threshold failed; the booking one
  passed. The bottleneck was never booking.

The rest of the hot path already scales — booking and inventory on CPU (min 2, max 4), payment on
Kafka lag via KEDA (ADR-0015/0029-adjacent). Scaling those while the journey's first three calls
queue behind a single pod does not move the knee.

**Rejected: KEDA.** travel-cart consumes no Kafka topic — it is synchronous REST end to end — so
there is no lag signal to scale on. CPU is the correct trigger, which is why this ADR does not
follow the payment precedent.

**Rejected: raising `replicaCount` to a fixed 2 or 3.** That pays for peak capacity around the
clock on a 3-node cluster (12 vCPU / 48 GB), and still cannot absorb a burst above the pinned number.

# Decision

Give `travel-cart-service` a standard CPU HPA in `values/travel-cart.yaml`:

```yaml
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilizationPercentage: 70
podAntiAffinity:
  enabled: true
```

`minReplicas: 1` keeps the baseline lean; the cart is idle between load runs. Anti-affinity is
enabled now that more than one pod can exist — at a single replica it was inert.

**`maxReplicas` shipped at 3, then went to 4 on the first measured run.** The original §2.1
proposal said 4; it was cut to 3 for node headroom. The very next Experiment 01 run showed
travel-cart at **600% of its CPU request (~900m against a 1000m limit)** — roughly 90% of the
limit, i.e. actively CPU-throttled at 3 pods. A fourth replica spreads the same work to ~675m
per pod, below the throttle point, so it was raised back to 4.

> **The request, not the ceiling, is the real mis-sizing.** With usage at 600% of request, the
> HPA's input is permanently far above its 70% target, so it never modulates: `maxReplicas`
> stops being a ceiling and becomes the *only* replica count under load. The scheduler has the
> mirror-image problem — it places pods by request (150m) while they draw ~900m, so nodes look
> empty on paper and contend in practice. Raising `requests.cpu` toward real usage would fix
> both, at the cost of fitting fewer pods on the 12 vCPU cluster. Left as a deliberate open item rather
> than changed blind; it needs a capacity decision, not a config tweak.

Enabling `autoscaling` also stops the chart rendering `spec.replicas`, so the HPA owns the count
and ArgoCD no longer re-asserts a fixed 1 on every sync.

# Consequences

**Positive.** The journey's first three calls can scale with demand. The Experiment 01
`journey_duration` threshold becomes reachable for the first time, and the measurement stops being
dominated by a hop that could not scale. Anti-affinity spreads the replicas, so a node loss no
longer takes the cart — and therefore every journey — down with it.

**Negative.** Up to 3 extra pods at peak on a cluster with limited headroom; that is what
`maxReplicas: 4` bounds. Extra replicas add database connections, though these are multiplexed
through the PgBouncer pooler (peak observed 95/200, so there is room). At `minReplicas: 1` the
service still has no HA at idle — a deliberate trade, revisitable by raising it to 2.

**Neutral.** No code, contract, schema or event change. `deploy/ops/apps/resume.sh` already nudges
CPU-HPA-managed deployments off 0 replicas after an idle cycle, so travel-cart is picked up by
that path automatically with no change.

# Documents to update at implementation

- `deploy/helm/atlas-service/values/travel-cart.yaml` — the `autoscaling` + `podAntiAffinity`
  blocks (done in this change).
- `experiments/01-high-booking-concurrency/cart-inventory-scaling.md` — §2.1 flipped from
  proposal to implemented, and the `maxReplicas` history (4 proposed → 3 shipped → 4 after
  the throttling measurement) recorded (done).
- No OpenAPI/AsyncAPI change; no service code change.
- **Not covered here:** `flight-service`, `hotel-service` and `user-service` remain at a fixed
  single replica. That is a deliberate resource decision for flight/hotel, taken with the
  knowledge that their price endpoints are **not** cached — the only Redis cache in the system is
  `usdExchangeRates` (booking + travel-cart), so every `POST /bookings` calls them live. The
  residual risk is availability, not throughput: a restart of either interrupts price validation
  for all bookings.
