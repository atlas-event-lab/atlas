# Payment-service scaling — findings, decision & plan

**Origin:** Experiment 01 — High Booking Concurrency · **Phase:** 7 · **Status:** proposal
**Services affected:** payment-service (consumer), inventory-service (`inventory.reserved`
topic), platform (Kafka / KEDA).

> This document is the "documented result" of Experiment 01 for the payment side: what the
> load runs surfaced, the decision we took, and the plan to apply it. It is scoped to this
> experiment. When the changes are implemented and merged, cut the binding cross-service
> decisions as **ADRs, one per affected service** (`DR-002`) — payment, inventory,
> kafka-platform — and cross-link them here (this mirrors ADR-0007, which also came out of
> this experiment). Resource envelope for the consumer work: **conservative** — remove the
> bottleneck, keep headroom for booking/inventory/payment to scale during performance runs.

---

## 1. What Experiment 01 surfaced (findings)

Under the ramping checkout load (`RESULTS.md` / `RESULTS_2.md` / `RESULTS_3.md`),
`payment-service` is the Saga bottleneck. Three causes combine and reinforce each other:

**a) The HPA scales on CPU, but payment is I/O-bound.**
The consumer processes `InventoryReserved` by calling the payment provider over HTTP
(`PAYMENT_PROVIDER_TIMEOUT=5s`, up to 3 attempts) and writing to Postgres via Hikari. Time is
spent waiting on I/O, not burning CPU. The current HPA (`autoscaling/v2`,
`targetCPUUtilizationPercentage: 70`, min 1 / max 4) rarely sees CPU reach 70 %, so
**payment stays at 1 pod** while lag grows.

**b) The parallelism ceiling is 3, and it isn't even fully used.**
The consumer listens on **`inventory.reserved`**, a **3-partition** topic. A consumer group
can have no more *active* consumers than partitions: with 3 partitions, at most 3 threads
consume in parallel; any extra pod/thread sits **idle**. Worse: even if the HPA reached 4
pods, the 4th would get no partition assigned — wasted work.

**c) Without `concurrency`, each pod contributes a single consumer thread.**
`spring.kafka.listener.concurrency` is unset → default 1. One pod = one `KafkaConsumer` = one
in-flight message at a time. With provider calls of hundreds of ms, a single thread processes
only a few payments/s — far below the 30–60 bookings/s of the runs.

Evidence: payment consumer lag peaked 44 → 136 at the load peaks, while booking/inventory did
scale out to 4 replicas.

---

## 2. Two clarifications that shaped the design

**The topic to re-partition is `inventory.reserved`, not the `payment.*` topics.**
The `payment.*` topics (`payment.requested/succeeded/failed/timed_out`) are the ones payment
**produces**; adding partitions there helps *downstream* consumers (booking reading
`payment.succeeded`/`failed`), not payment's lag. The lag we care about is on the topic
payment **consumes** — `inventory.reserved` (owned by inventory-service). Since only the
`payment-service` group consumes it, raising its partitions doesn't affect other consumers.

**A partition is NOT "a pod with its own CPU and memory".**
Partitions live on the **broker**, not as pods. Their cost on the broker is low (a few MB of
indexes/buffers and some file handles per partition). What a partition defines is the
**parallelism ceiling** of the consumer group. The rule that governs the design is:

```
useful consumers  =  min( pods × concurrency ,  partitions )
```

CPU/memory is consumed by **pods** (JVM) and **threads** (`concurrency`) inside each pod —
not by partitions. So reach the target parallelism with *few pods plus some concurrency*
(cheap in memory) before adding many pods (a full JVM each).

Confirmed with the team: the inventory-service producer **keys `inventory.reserved` by
`bookingId`**, so per-booking ordering is preserved when moving to more partitions.

---

## 3. Consumer improvement design (conservative)

Parallelism target: **6 in-flight consumers** for payment (2× today), reached **without**
raising the max pod count vs. today.

| Lever | Today | Proposed | Why |
|---|---|---|---|
| `inventory.reserved` partitions | 3 | **6** | Parallelism ceiling = 6. Enough for 2× throughput; cheap on the broker. Can be *raised* later, never lowered. |
| Payment scaling | CPU HPA 70 %, min 1 / max 4 | **KEDA on lag**, min 1 / **max 3** | Scales on the right signal (lag), not CPU. Max 3 pods (≤ 6 partitions with concurrency 2). |
| `concurrency` per pod | 1 (default) | **2** | 3 pods × 2 = 6 threads = 6 partitions, no idle threads. More throughput per pod = fewer pods = less memory. |
| Resources per pod | req 512Mi/150m · lim 768Mi/1 | **unchanged** (validate OOM; ceiling 1Gi if needed) | concurrency=2 adds little heap (small fetch buffers). |

**Key capacity result:** payment's pod ceiling **drops from 4 to 3**, yet throughput rises
~6× (from 1 effective thread to 6). This improvement **lowers** payment's memory ceiling while
removing the bottleneck — the ideal conservative case.

### 3.1 KEDA — scale on lag

- Install KEDA on the platform (namespace `keda`) — **not installed today** (step 0).
- Replace the CPU HPA with a `ScaledObject` using the **native Kafka scaler** (reads lag
  directly from the broker; no Prometheus dependency, though `kafka_consumergroup_lag` is
  already exported and used by the dashboards). Bonus: the scaler never scales beyond the
  partition count.
- Starting parameters (tune under load):
  - `bootstrapServers: atlas-kafka-bootstrap.atlas-data:9092`
  - `consumerGroup: payment-service`, `topic: inventory.reserved`
  - `lagThreshold: "50"` (target lag per replica; replicas ≈ total_lag / lagThreshold, capped
    by `maxReplicaCount`). With concurrency 2 per pod it can go to ~100; start at 50.
  - `activationLagThreshold: "10"` (below this, stay at the minimum).
  - `minReplicaCount: 1` — **never 0**: payment must stay up for the Saga.
  - `maxReplicaCount: 3`.
  - `cooldownPeriod: 300` and a long scale-down stabilization (~300 s) to avoid flapping;
    fast scale-up.
- In `payment.yaml`: set `autoscaling.enabled: false` (so the chart stops emitting the CPU
  HPA and doesn't fight the HPA KEDA creates).

Example `ScaledObject` (standalone manifest, in the style of `pooler.yaml`; can be folded into
the `atlas-service` chart later if other services reuse it):

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: payment-service
  namespace: atlas-apps
spec:
  scaleTargetRef:
    name: payment-service
  minReplicaCount: 1
  maxReplicaCount: 3
  cooldownPeriod: 300
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 300
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: atlas-kafka-bootstrap.atlas-data:9092
        consumerGroup: payment-service
        topic: inventory.reserved
        lagThreshold: "50"
        activationLagThreshold: "10"
        offsetResetPolicy: earliest
```

> The `atlas-service` chart only knows how to emit a CPU HPA (`templates/hpa.yaml`). Simplest
> is to apply the `ScaledObject` outside the chart (like the pooler). If other consumers need
> it later, add a `templates/scaledobject.yaml` gated on `keda.enabled`.

### 3.2 `concurrency` in payment-service

Make the value environment-driven and set it to 2:

```yaml
# payment-service/src/main/resources/application.yml  → spring.kafka.listener
    listener:
      observation-enabled: true
      concurrency: ${KAFKA_CONCURRENCY:2}
```

```yaml
# deploy/helm/atlas-service/values/payment.yaml  → config
  KAFKA_CONCURRENCY: "2"
```

Constraints to respect (why 2, not more, in the conservative case):

- **`max_pods × concurrency ≤ partitions`** → `3 × 2 = 6 ≤ 6`. Exact equality: no idle threads
  at peak, and no over-subscribed partitions.
- **Hikari** (`maximum-pool-size: 10` per pod): concurrency 2 + outbox relay + provider
  retries stays well within 10. If `concurrency` is raised later, revisit Hikari.
- **Memory per pod**: each consumer thread adds small fetch buffers
  (`max.partition.fetch.bytes` ~1MB × assigned partitions). With 6 partitions spread out, the
  increase is a few MB; the JVM base heap dominates. Keep req 512Mi / lim 768Mi and **watch
  OOMKilled**; if it appears, raise the limit to 1Gi (still comfortable).

---

## 4. Does it fit in 3 nodes of 2 vCPU / 16 GB? (conservative check)

Cluster total = **12 vCPU** / 48 GB (3 × 2 OCPU; on x86 shapes 1 OCPU = 1 physical core = 2 vCPU); real *allocatable* ≈ 10.8 vCPU / ~41 GB after kubelet/system
reservations. That budget is already shared by observability (Prometheus/Loki/Tempo/Grafana/
Alloy), Keycloak, the Kafka broker, Postgres (CNPG) + pooler, WireMock, ingress, and the ~7
app services (booking and inventory scaling to 4 each in the runs).

**Incremental** impact of this improvement — and why it's conservative:

- **Payment pods:** ceiling drops 4 → 3. At 768Mi limit each: `3 × 768Mi ≈ 2.3 GB` (was
  `4 × 768Mi ≈ 3.0 GB`). **~0.75 GB freed** at peak vs. today's theoretical max, and
  throughput doubles.
- **Partitions (+3 on one topic, plus retry topics):** a few MB on the broker. Negligible
  next to the broker's heap/page-cache.
- **KEDA:** adds the operator + metrics-adapter (~2–3 pods, ~200–300 MB total, in `keda`).
  The only real *new* cost, and it's small and one-time.
- **CPU:** payment stays I/O-bound; requests `3 × 150m = 450m`. Plenty left for booking/
  inventory scale-out (`4+4 × 150m = 1.2 vCPU` in requests).

Conclusion: the change is **memory-neutral-to-negative** for payment (fewer max pods), the
partition cost is marginal, and the only addition is KEDA's small footprint. Headroom for
booking/inventory/payment to scale during performance runs is preserved. ✔

---

## 5. Validations before accepting the improvement

- **Ordering / partition key.** Moving 3 → 6 partitions is safe because the inventory-service
  producer keys `inventory.reserved` by `bookingId` (confirmed), preserving per-booking order.
  Even out of order, the design tolerates it: idempotency on `eventId` + state-machine guards
  (see ADR-0007).
- **Retry/DLQ topics.** `@RetryableTopic` creates `inventory.reserved-retry-*` and `.dlq`
  auto-generated (not in `topics.yaml`). Confirm their partition count after the change and
  that concurrency leaves no idle threads on them.
- **Partitions are irreversible.** You can only *raise* the partition count, not lower it.
  Hence 6 (conservative), not 12: if the runs show 6 is not enough, raise it in a second step.
- **DB via the pooler.** Each pod opens ≤10 connections to the pooler; 3 pods = ≤30,
  multiplexed by PgBouncer. Within budget.

---

## 6. Rollout order & success criteria

0. **Install KEDA** on the platform (`helm install kedacore/keda -n keda`). Document it like
   the other platform steps (`deploy/platform/...`).
1. **Raise `inventory.reserved` to 6 partitions** in `deploy/platform/strimzi/topics.yaml`
   (`partitions: 3 → 6`) and apply. Coordinate with inventory-service (its topic).
2. **Add `concurrency`** (env-driven) in `payment-service` (`application.yml`) and
   `KAFKA_CONCURRENCY: "2"` in `values/payment.yaml`. Redeploy.
3. **Migrate scaling to KEDA:** `autoscaling.enabled: false` in `payment.yaml` (drops the CPU
   HPA) + apply the `ScaledObject`. Verify KEDA creates its HPA and `TARGETS` shows the lag,
   not `<unknown>`.
4. **Re-run Experiment 01** at `TARGET_RPS=60` (`HOLD=6m`), watching in Grafana:
   `kafka_consumergroup_lag{consumergroup="payment-service"}` (must drain, not grow
   unbounded), payment replicas (should rise on lag and fall back), and OOMKills (none).

### Success criteria

- The `payment-service` lag **drains** during the hold instead of growing monotonically.
- Payment **scales on lag** (1 → up to 3 pods) and scales back in — visible in KEDA/HPA.
- **No OOMKilled**; payment CPU/mem within limits.
- `booking_success_rate` **improves** vs. the 84–86 % in `RESULTS_2/3.md` (fewer failures
  attributable to the payment path), with no new downstream bottleneck.

---

## 7. Broker: sizing + multi-broker (RF=3 / ISR=2) — separate platform phase

This block is **independent** of the three consumer changes (§3). Those remove payment's
bottleneck; this one targets **durability realism**: today there is a single broker with
`RF=1` / `min.insync.replicas=1`, so the `acks: all` that **all** producers already use
guarantees nothing (the "in-sync replicas" are just one). It's durability theater.

### 7.1 Real starting point (measured, no traffic)

`kubectl -n atlas-data top pod` showed the broker `atlas-dual-role-0` at **94m CPU / 810Mi**
at idle. For ~250 *partition-replicas* (72 declared + retry/dlq + internal), that is
comfortable: partition metadata is light, so the broker **does not need a large heap**. Rest
of the `atlas-data` namespace at idle: entity-operator 530Mi, kafka-exporter 28Mi, pg-1
609Mi, pg-2 808Mi, pooler 2×~50Mi, kafka-ui 404Mi, strimzi-operator 309Mi (≈ 3.6 GB total).

### 7.2 Proposed sizing (3 brokers, one per node)

Today the broker runs with **no `resources` and no `jvmOptions`** → **BestEffort** QoS (first
pod evicted/OOM-killed) and a default heap (~25 % of node RAM ≈ ~4 GB, uncontrolled).
"Adjusting" here means **setting predictable limits**, not shrinking — and that *improves*
things.

| | Today (1 broker) | Proposed (each of 3) |
|---|---|---|
| `jvmOptions` | default (~4 GB heap) | `-Xms 1g / -Xmx 1g` |
| requests | — (BestEffort) | `cpu 250m / mem 1.25Gi` |
| limits | — | `cpu 1 / mem 2Gi` |
| QoS | BestEffort | Burstable |
| Storage | 10Gi | 10Gi each (30Gi total) |

```yaml
# deploy/platform/strimzi/kafka.yaml
# --- KafkaNodePool 'dual-role' ---
spec:
  replicas: 3                     # 1 -> 3, one per node (Strimzi spreads them via anti-affinity)
# --- Kafka ---
spec:
  kafka:
    config:
      default.replication.factor: 3
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      min.insync.replicas: 2
      transaction.state.log.min.isr: 2
    resources:
      requests: { cpu: 250m, memory: 1.25Gi }
      limits:   { cpu: "1",  memory: 2Gi }
    jvmOptions:
      -Xms: 1g
      -Xmx: 1g
```

### 7.3 Does adjusting resources hurt? Only if you go too low

Three real risks of an *under*-sized broker, with their floors:

- **Heap < ~1 GB → GC thrash / OOMKill.** With 250 partitions, 1 GB is plenty; `-Xms` = `-Xmx`
  to avoid resizes. Don't go below 1 GB.
- **`limit` pinned to the heap → starves the page cache.** Kafka uses off-heap RAM (page
  cache) for log I/O and replication fetch. Leave ~1 GB above the heap (`-Xmx 1g` + 2Gi limit
  ⇒ ~1 GB for off-heap/cache). At this scale the impact is minor, but it gives headroom.
- **The subtle risk of `min.insync.replicas=2`:** a starved broker enters a long GC pause and
  drops out of the ISR. With RF=3/ISR=2 you tolerate **one** broker down (2 remain in ISR and
  `acks=all` writes proceed); if **two** degrade at once, producers get `NotEnoughReplicas`
  and **block**. An under-sized broker *manufactures* the very unavailability you want to
  measure. The `acks=all` delay you're after must come from the replication round-trip, **not**
  from a choked JVM.

### 7.4 Budget on the 3 nodes

3 brokers at 2Gi limit = 6 GB ceiling (vs ~810Mi today) → **+~5 GB** of limit and **+~2.7 GB**
of requests cluster-wide. With one broker per node, each node carries ~1.5–2 GB of broker
under load on its ~13.5 GB allocatable — it fits alongside the apps if brokers stay this size.
CPU is not a problem (94m idle; ×3 with replication maybe 300–600m). This is the heaviest
change in the plan, so **run the durability experiments in a separate window** from the
max-app-scale runs.

### 7.5 Cruise Control — to reassign RF of existing topics (chosen path)

Raising `replicas: 1 → 3` on the `KafkaTopic` CRs in `topics.yaml` **does not reassign on its
own**: Strimzi only changes the RF of already-created topics if **Cruise Control** is enabled
(or via manual reassignment). *New* topics are born with RF=3. Enabling Cruise Control:

```yaml
# deploy/platform/strimzi/kafka.yaml  (under spec:, alongside kafka/entityOperator)
spec:
  cruiseControl:
    resources:                     # keep it small — node budget
      requests: { cpu: 100m, memory: 512Mi }
      limits:   { memory: 1Gi }
```

Reassignment flow: (1) enable `cruiseControl` and `replicas: 3` on the node pool; (2) raise
`replicas: 3` on the `KafkaTopic` CRs; (3) Strimzi generates a `KafkaRebalance` (or create one
with `mode: full`) that Cruise Control executes to move replicas across the 3 brokers.
Cost: Cruise Control adds ~1 pod (~512Mi–1Gi) — add it to the §7.4 budget. (Alternative
without Cruise Control: recreate the experiment topics with RF=3 from scratch — simpler if
there is no data to preserve — but Cruise Control is chosen here for realism and reuse in
future rebalances.)

### 7.6 What to watch (signal vs noise)

- **UnderReplicatedPartitions** and the ISR shrink/expand rate → must stay 0 / stable. If the
  ISR flaps, it's a starved JVM, not Kafka: raise memory before concluding.
- **Broker OOMKills** → none.
- **`acks=all` latency** (produce p95) with RF=3/ISR=2 vs the RF=1 baseline → that's the "real
  delay" you wanted to measure.

---

## 8. Follow-ups — ADRs to cut on implementation

When the changes are implemented and merged, capture the binding decisions as ADRs
(`DR-002`, one per affected service) and flip them to `COMPLETED` (`DR-003`):

- **payment-service** — lag-based autoscaling (KEDA) + listener concurrency.
- **inventory-service** — `inventory.reserved` partition increase (3 → 6).
- **kafka-platform** — broker sizing + 3-broker RF=3/ISR=2 + Cruise Control.

---

## 9. One-liner

Payment stalls because it scales on CPU (while being I/O-bound), has only 3 partitions and 1
thread per pod. Conservative consumer fix: **KEDA on lag (min 1 / max 3)** +
**`inventory.reserved` to 6 partitions** + **`concurrency: 2`** → 6 in-flight consumers, ~6×
throughput, with a **lower** pod ceiling than today. As a separate platform phase: **3 brokers
with RF=3 / ISR=2** (fixed resources: 1 GB heap, 2Gi limit each) + **Cruise Control** to
reassign existing topics, to measure real durability and `acks=all` delay.
