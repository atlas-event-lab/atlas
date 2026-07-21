# Cart + Inventory scaling — findings, decision & plan

**Origin:** Experiment 01 — High Booking Concurrency, run **2026-07-08** (`RESULTS_3.md`)
**Phase:** 7 · **Status:** proposal
**Services affected:** travel-cart-service, inventory-service (consumer), booking-service
(topic owner for `booking.*`).

> Companion to [`payment-service-scaling.md`](./payment-service-scaling.md). That doc fixed the
> payment consumer; this one addresses the next bottlenecks surfaced once payment was no longer
> the limiter. Same rule as before: on merge, cut ADRs per affected service (`DR-002`). Envelope:
> conservative — keep headroom on the 3×(2 vCPU/16 GB) nodes.

---

## 1. What the 2026-07-08 run showed (findings)

Run at `TARGET_RPS=60`, `HOLD=6m`, scenario `both`. Headline: **100 % success, 0 failed,
28 845 bookings** — the system held. But the bottleneck moved off payment onto the cart, and
inventory fell behind on lag:

| Signal | Observation | Read |
|---|---|---|
| `booking_success_rate` | 100 % | healthy |
| `cart_create` p95 / `cart_add` p95 | 878 ms / 884 ms | **cart is the new hot spot** |
| `journey_duration` p95 | 3.01 s (was 1.28 s) | dominated by cart latency |
| travel-cart replicas | 1 → **1** (no HPA), ~300 % CPU-of-request | pinned at 1 pod, throttled |
| payment (KEDA) | scaled on lag, peak lag 482, drained | ✓ working |
| inventory replicas | 1 → 3 (CPU HPA) | scaled, but… |
| inventory consumer lag peak | **1890** | fell behind on `booking.created` |
| booking replicas | 1 → 4 | most CPU/mem-demanding, held |
| Postgres conns peak / limit | 95 / 200 | fine (pooler) |

Root causes:

- **travel-cart has no HPA at all.** Its values file carries no `autoscaling` block, so it runs
  at `replicaCount: 1` forever. Every journey hits it (create cart → add flight/hotel → reprice
  → convert), it's CPU-bound REST (no Kafka), and one pod saturated → the ~880 ms cart latency.
- **inventory consumes `booking.created` (the reserve hot path) with concurrency 1 over a
  3-partition topic.** Parallelism ceiling 3, one thread per pod → lag built to 1890 before the
  CPU HPA's 3 pods drained it. Same shape as payment's old problem, milder.

---

## 2. Decisions

### 2.1 travel-cart — add a CPU HPA (REST / CPU-bound)

travel-cart is synchronous REST with no Kafka, and the run shows it scales on CPU, so a standard
CPU HPA is the right tool (not KEDA). Enable autoscaling and anti-affinity, matching booking:

```yaml
# atlas-gitops/charts/atlas-service/values/travel-cart.yaml
autoscaling:
  enabled: true
  minReplicas: 1               # lean baseline; raise to 2 for HA windows
  maxReplicas: 4
  targetCPUUtilizationPercentage: 70
podAntiAffinity:
  enabled: true
```

At 70 % of the 150m request with the observed CPU, this scales travel-cart to ~3–4 pods under
peak — satisfying "≥ 3 replicas at high traffic" — and brings cart p95 back down. DB access is
through the pooler, so extra replicas just add multiplexed connections (peak was 95/200).

### 2.2 inventory — keep the CPU HPA (cap max 3) + targeted concurrency

Inventory's CPU HPA already scales (it reached 3). We keep it but **cap `maxReplicas` at 3** to
match the consumer parallelism we're provisioning, and add concurrency **only on the hot
listeners** to avoid multiplying threads across its ~12 `@KafkaListener` methods.

```yaml
# atlas-gitops/charts/atlas-service/values/inventory.yaml
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 3               # 4 -> 3; matches 3 pods x concurrency 2 = 6 = partitions
  targetCPUUtilizationPercentage: 70
config:
  KAFKA_CONCURRENCY: "2"       # consumed by the dedicated factory below
```

**Targeted concurrency (small code change in inventory-service).** A global
`spring.kafka.listener.concurrency=2` would put 2 threads on every listener (~24 consumer
threads/pod). Instead, define one dedicated factory at concurrency 2 and use it only on the
high-throughput saga listeners (`booking.created`, `booking.confirmed`); everything else stays
at the default concurrency 1.

```java
// inventory-service — Kafka config
@Bean
ConcurrentKafkaListenerContainerFactory<String, Object> sagaListenerFactory(
        ConcurrentKafkaListenerContainerFactoryConfigurer configurer,
        ConsumerFactory<Object, Object> consumerFactory,
        @Value("${KAFKA_CONCURRENCY:2}") int concurrency) {
    var factory = new ConcurrentKafkaListenerContainerFactory<String, Object>();
    configurer.configure(factory, consumerFactory);
    factory.setConcurrency(concurrency);
    return factory;
}
```

```java
// BookingEventConsumer — annotate only the hot listeners
@KafkaListener(topics = EventTopics.BOOKING_CREATED,   groupId = "...", containerFactory = "sagaListenerFactory")
@KafkaListener(topics = EventTopics.BOOKING_CONFIRMED, groupId = "...", containerFactory = "sagaListenerFactory")
```

**Cap math:** 3 pods × concurrency 2 = **6 consumers** on `booking.created` / `booking.confirmed`
→ needs those topics at 6 partitions (§2.3). No idle threads at peak.

**Memory.** The measured inventory usage was ~1.89 GB total across the 3 pods ≈ **~630 MB/pod**,
under the current 768 Mi limit. (Note: `1890` in `RESULTS_3.md` is the *lag*, a different metric.)
Targeted concurrency adds only ~2 extra consumer threads/pod, so keep `requests 512Mi`, and set an
explicit `limits: 1Gi` for headroom now that horizontal scale is capped at 3; **watch OOMKilled**
and confirm per-pod memory during the re-run.

### 2.3 booking.* partitions — raise the two hot topics to 6

Booking's `OutboxRelay` publishes with `key = aggregateId = bookingId`, so raising partitions
preserves per-booking ordering. Only the ~1-per-booking topics are hot:

```yaml
# deploy/platform/strimzi/topics.yaml
booking.created    partitions: 3 -> 6
booking.confirmed  partitions: 3 -> 6
```

`booking.cancelled/failed/expired` are unhappy-path, low volume — leave at 3. Confirm no other
consumer group relies on tight ordering across a single partition before applying (today
inventory is the consumer of these on the hot path).

### 2.4 booking — no change

booking was the most CPU/memory-demanding service, peaked at 4 replicas, and held 100 % success.
Keep its CPU HPA at `min 1 / max 4`. No change.

---

## 3. Fit on the 3 nodes (conservative check)

- **travel-cart:** new max 4 pods at 768 Mi limit ≈ 3 GB ceiling, but only under peak; scales
  back after. It's the highest-value add — it removes the journey bottleneck.
- **inventory:** max drops 4 → 3, so its ceiling *decreases* (3 × ≤1Gi ≈ 3 GB) while throughput
  rises via concurrency. Net neutral-to-negative, like payment.
- **partitions:** +6 partition-replicas on the broker (2 topics × 3). Negligible.
- **booking:** unchanged.

CPU requests stay modest (travel-cart/inventory at 150m each). Headroom for the durability
(multi-broker) phase remains intact — run that in a separate window as before.

---

## 4. Validations

- **Ordering:** `booking.*` keyed by `bookingId` (OutboxRelay) — confirmed; 3→6 is safe.
- **Consumer cap:** keep `inventory max_pods × concurrency ≤ partitions` → `3 × 2 = 6 ≤ 6`.
- **Hikari:** inventory `maximum-pool-size` must cover 2 hot threads + other listeners + DB work;
  verify it's ≥ ~10 (as payment) before raising concurrency.
- **travel-cart HPA metrics:** `TARGETS` must show a real % (not `<unknown>`) after enabling.
- **Memory:** confirm inventory per-pod memory with concurrency; raise limit only if OOMKilled.

---

## 5. Rollout order & success criteria

1. **travel-cart HPA** — edit `values/travel-cart.yaml`, redeploy, verify HPA `TARGETS` real.
2. **booking.created / booking.confirmed → 6 partitions** — patch/apply `topics.yaml`.
3. **inventory** — add the `sagaListenerFactory` (code) + `KAFKA_CONCURRENCY=2`, `maxReplicas: 3`,
   explicit resources; build image; redeploy.
4. **Re-run Experiment 01** at `TARGET_RPS=60` (and try `80` once green). Record in `RESULTS_4.md`.

Success:

- `cart_*` p95 and `journey_duration` p95 drop materially; travel-cart scales to ≥ 3 under peak.
- inventory consumer lag drains (no monotonic growth), peak lag well below 1890.
- No OOMKilled; booking still 100 % success at 4 replicas.
- Postgres connections stay < 200 via the pooler.

---

## 6. Follow-ups — ADRs to cut on implementation

- **travel-cart-service** — add CPU HPA (hot-path REST autoscaling).
- **inventory-service** — CPU HPA cap 3 + targeted saga-listener concurrency.
- **booking-service / kafka-platform** — `booking.created`/`booking.confirmed` partitions 3→6.

---

## 7. One-liner

Run 3 held at 100 %, but the bottleneck moved to travel-cart (no HPA, 1 pod, ~880 ms cart p95)
and inventory lagged (1890) consuming `booking.created` with concurrency 1 over 3 partitions.
Plan: **give travel-cart a CPU HPA (max 4)**, **cap inventory at 3 replicas with concurrency 2
targeted at the hot saga listeners**, **raise `booking.created`/`booking.confirmed` to 6
partitions**, and **leave booking at max 4**.
