---
adr_id: ADR-0014
title: Raise inventory saga-listener concurrency to 3 (9 consumers) for booking.created/confirmed
service: Inventory
status: PENDING
date: 2026-07-10
depends_on:
  - ADR-0013
  - ADR-0016
---

# ADR-0014 — Inventory saga consumer capacity (concurrency 3)

# Status

`PENDING` — **intentionally deferred (not being pursued).** The prerequisites landed
(ADR-0016 raised booking.created/confirmed to 9 partitions; inventory runs under a CPU HPA),
but the concurrency bump to 3 and the KEDA-on-lag evaluation were **decided against**:
inventory stays at `KAFKA_CONCURRENCY=2`. Kept as `PENDING` (not `COMPLETED`) because the
decision's own change was not applied — it is a conscious "won't do further", not pending work.
Origin:
[experiments/01-high-booking-concurrency/consumer-capacity-scaling.md](../../experiments/01-high-booking-concurrency/consumer-capacity-scaling.md).

# Context

The 2026-07-10 Experiment 01 run (first with ADR-0013 in place) showed **no outbox duplicates** but
inventory consumer lag up to **~7 min** at `TARGET_RPS=60`. Inventory used only **~0.5 CPU** across 3
pods and **~510 Mi/pod** of a 1 Gi limit — it is **I/O-bound (DB reservation + outbox writes), not
compute-bound**. The limiter is consume parallelism.

Inventory consumes `booking.created` / `booking.confirmed` through a dedicated `sagaListenerFactory`
(`KafkaConfig.sagaListenerFactory`, `setConcurrency(KAFKA_CONCURRENCY)`), applied only to those hot
listeners; the other ~12 listeners stay at concurrency 1. Today: HPA (CPU) `min 1 / max 3`,
`KAFKA_CONCURRENCY=2` ⇒ `3 × 2 = 6` consumers over 6 partitions.

# Decision

1. **Raise `KAFKA_CONCURRENCY` 2 → 3** (`values/inventory.yaml`). With the HPA cap of 3 pods this is
   `3 × 3 = 9` consumers, matching the `booking.created` / `booking.confirmed` raise to **9 partitions**
   (ADR-0016). No idle threads (`useful consumers = min(pods × concurrency, partitions) = 9`).
2. **Keep `maxReplicas: 3`.** The lever is threads-per-pod, not more pods; CPU headroom is large
   (~170 m/pod of a 1-CPU limit).
3. **Memory.** Keep `requests 512Mi / limits 1Gi`; concurrency 3 adds ~1 consumer thread + small fetch
   buffers per assigned partition. **Watch OOMKilled** on the re-run; raise the limit only if needed.
4. **Hikari.** Verify the pool covers 3 saga threads + other listeners + outbox relay + REST
   (≥ ~10) before raising concurrency. DB is via the PgBouncer pooler; Hikari is the real cap.

# Consequences

**Positive.** ~50 % more saga consume throughput per the same 3 pods; lag drains at 60/s without more
compute. **Negative.** More concurrent DB work per pod (bounded by Hikari); a few MB more heap.

# Scaler note (evaluate; not blocking this ADR)

Inventory still scales on a **CPU HPA**, but its saga work is DB-I/O-bound, so CPU stays low and the
HPA can scale *in* precisely when lag builds — the trap payment already hit (ADR-0015 /
payment-service-scaling.md). Recommended follow-up: migrate inventory to **KEDA-on-lag**
(trigger on `booking.created` consumer-group lag), mirroring payment, which is more robust for an
I/O-bound consumer. Deferred to a separate step so this ADR stays a minimal capacity bump; if the
re-run shows the CPU HPA scaling in under lag, promote the KEDA migration here.

# Documents to update at implementation

- `values/inventory.yaml` — `KAFKA_CONCURRENCY: "3"`.
- Depends on ADR-0016 (partitions 9) being applied first or together.
- `coding-standards`/service docs — note the 9-consumer target for the saga listeners.

# Scope note

Per `DR-002`, this ADR is **inventory-only**. The partition change is in the kafka-platform ADR
(ADR-0016); payment's symmetric change is ADR-0015.

# Alternatives considered

- **More pods instead of concurrency** (`maxReplicas 4`): a full JVM per pod for the same parallelism;
  costlier in memory than one extra thread. Rejected — concurrency is cheaper.
- **Global `spring.kafka.listener.concurrency=3`**: would put 3 threads on *every* inventory listener
  (~36 threads/pod). Rejected — the dedicated `sagaListenerFactory` keeps concurrency on the hot
  listeners only.
