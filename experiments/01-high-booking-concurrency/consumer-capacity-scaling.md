# Consumer capacity — inventory, payment & the WireMock provider

**Origin:** Experiment 01 — High Booking Concurrency, run **2026-07-10** (first run after
[ADR-0013](../../docs/adr/ADR-0013-outbox-relay-concurrency-and-batching.md): claim-based outbox
polling + adaptive/drained scheduling + batched publish).
**Phase:** 7 · **Status:** proposal
**Services affected:** inventory-service (consumer), payment-service (consumer), kafka-platform
(topics), WireMock (fake payment provider).

> Companion to [`payment-service-scaling.md`](./payment-service-scaling.md) and
> [`cart-inventory-scaling.md`](./cart-inventory-scaling.md). Those removed the outbox duplication
> and the first parallelism limits; this doc addresses the **consume-side capacity** that remained
> once the producer side was healthy. On merge, cut the binding decisions as ADRs, one per affected
> service (`DR-002`) — captured here as ADR-0014..0017.

---

## 1. What the 2026-07-10 run showed (findings)

Run at `TARGET_RPS=60`, `HOLD=6m`, scenario `both`, with ADR-0013 in place.

| Signal | Observation | Read |
|---|---|---|
| Outbox duplicates | **none** | ADR-0013 (SKIP LOCKED claim + adaptive/drain + batch) worked; pods publish disjoint batches, fast |
| payment / inventory consumer lag | up to **~7 min** (was ~15 min) | fewer events now (no dups), but the consumers still can't keep up with ~60/s |
| inventory CPU / mem | **~0.5 CPU** across 3 pods at peak; **1.53 GiB** sustained of a **3 GiB** aggregate limit (≈510 Mi/pod) | far from CPU/mem limits |
| payment CPU / mem | peak **~0.57 CPU**; **1.25 GiB** of **3.37 GiB** aggregate | far from CPU/mem limits |

**Root cause:** both consumers are **I/O-bound, not compute-bound**. The idle CPU and half-used
memory prove that adding compute would not help; the limiter is **consume parallelism** and, for
payment, **downstream provider latency**. The remedy is more in-flight consumers (concurrency +
partitions + pods) and scaling the dependency they wait on — not bigger pods.

Provider latency (WireMock stub, `wiremock/mappings/payment-provider.json`): the **default** path
(priority 10, no scenario header) returns `APPROVED` with a **lognormal ~150 ms** delay. At ~150 ms
per blocking provider call, capacity ≈ `in-flight_threads / 0.15 s`:

- today: 3 pods × concurrency 2 = **6 threads → ~40 payments/s** ⇒ can't hold 60/s ⇒ lag.
- target: 4 pods × concurrency 3 = **12 threads → ~80 payments/s** ⇒ headroom over 60/s.

(The 7 000 ms `TIMEOUT` stub is **fault-injection**, selected only by `X-Payment-Scenario: TIMEOUT`;
it is not the steady-state path, so it doesn't factor into the capacity math unless the load injects it.)

---

## 2. Decisions

Governing rule (from the earlier docs): `useful consumers = min(pods × concurrency, partitions)`.
Keep `pods × concurrency = partitions` (no idle threads, no unused partitions).

### 2.1 inventory — concurrency 2 → 3, hot booking topics 6 → 9 (ADR-0014)

Inventory consumes `booking.created` / `booking.confirmed` on the dedicated `sagaListenerFactory`
(targeted concurrency; other listeners stay at 1). Raise that concurrency **2 → 3** and the two hot
topics **6 → 9**:

- `3 pods (HPA max) × concurrency 3 = 9 consumers = 9 partitions` — exact, no idle threads.
- CPU is ~170 m/pod (of a 1-CPU limit), so concurrency 3 fits with room to spare; watch OOM against
  the 1 Gi/pod limit (today ~510 Mi/pod).

> **Scaler caveat (important).** Inventory still scales on a **CPU HPA**. Its saga work is
> DB-I/O-bound (reserve flight+hotel + write 3 outbox rows per event), so CPU stays low and the HPA
> can scale *in* exactly when lag builds — the same trap payment already hit. Prefer moving inventory
> to **KEDA-on-lag** (trigger on `booking.created` lag), mirroring payment; it is more robust than
> CPU for an I/O-bound consumer. Recorded as an option in ADR-0014.

### 2.2 payment — KEDA max 3 → 4, concurrency 2 → 3, `inventory.reserved` 6 → 12 (ADR-0015)

- `4 pods × concurrency 3 = 12 consumers = 12 partitions` on `inventory.reserved`.
- `payment-scaledobject.yaml`: `maxReplicaCount` **3 → 4**; retune `lagThreshold` (with concurrency 3
  per pod it can rise toward ~150).
- `values/payment.yaml`: `KAFKA_CONCURRENCY` **2 → 3** (global `spring.kafka.listener.concurrency`).
- **Retry/DLQ topics.** `@RetryableTopic(attempts = 4)` auto-creates `inventory.reserved-retry-*`
  (×3) and `inventory.reserved-dlq`. Confirm/raise their partition count when `inventory.reserved`
  goes to 12, or retried events (the `TEMPORARY_FAILURE`/`TIMEOUT` scenarios) serialize on fewer
  partitions and re-create a lag on the retry path.

### 2.3 kafka-platform — the partition raises (ADR-0016)

`booking.created 6→9`, `booking.confirmed 6→9`, `inventory.reserved 6→12`, plus the payment retry
topics. Producers key `booking.*` by `bookingId` and `inventory.reserved` by `bookingId`, so
per-booking order is preserved across the added partitions. **Partition increases are applied by
editing `topics.yaml`** (Strimzi supports partition growth directly); only **RF/replica** changes
need Cruise Control (`payment-service-scaling.md §7.5`) — don't conflate them. Partitions can only be
raised, never lowered.

### 2.4 WireMock — an HPA for the fake provider (ADR-0017)

Scaling payment to 12 in-flight consumers means up to **12 concurrent calls to WireMock**. If WireMock
can't serve them, payment's consumer lag simply becomes provider latency/timeouts — **the bottleneck
moves, it doesn't disappear.** So the WireMock HPA is part of *this* change, not a separate nicety.
Two design points:

- **Metric — KEDA + Prometheus (chosen).** WireMock holds each connection *asleep* during the stub
  delay, so delayed responses burn little CPU — a plain **CPU HPA under-scales** while the Jetty
  thread/connection pool saturates (the earlier pod loss was a **liveness kill under load**, CPU-
  throttled at 250 m, not OOM). We scale via **KEDA on a Prometheus query** over payment's Feign
  client request rate (`http_client_requests_seconds_count{clientName="com.atlas.payment.client.PaymentProviderFeignClient"}`,
  confirmed against Prometheus) — the actual provider load. Manifest
  `deploy/platform/keda/wiremock-scaledobject.yaml`; only `threshold` remains to tune. Recorded in ADR-0017.
- **Cost + cold-start.** The motivation is that 2 idle pods with no payment traffic are wasteful, so
  scale down to a small floor at rest. Keep `minReplicas ≥ 1` with **fast scale-up**; at the ramp
  start a single pod plus payment's retry ladder absorbs the brief warm-up. WireMock is a **test
  double** — this HPA is a load-test-environment (realism/cost) decision, not production architecture.

---

## 3. Validations before accepting

- **Consumer cap:** `inventory 3×3 = 9 = 9`; `payment 4×3 = 12 = 12`. No idle threads, no unused
  partitions.
- **Ordering:** `booking.*` and `inventory.reserved` keyed by `bookingId`; search's ordering on
  `inventory.flight/hotel.reserved` is handled by the payload version field (ADR-0009) and those
  topics are **not** touched here.
- **Retry topics:** confirm `inventory.reserved-retry-*` / `-dlq` partition counts after the raise.
- **Hikari:** with concurrency 3, verify each pod's pool covers saga threads + other listeners +
  outbox relay + REST (≥ ~10). DB is via the PgBouncer pooler (transaction mode), so app→pooler
  connections are cheap; Hikari is the real ceiling on concurrent DB ops.
- **WireMock capacity:** confirm it serves 12 concurrent 150 ms calls without liveness flaps; verify
  the load run isn't injecting the 7 s `TIMEOUT` scenario at a rate that hogs consumer threads.
- **Node budget:** +12 partition-replicas × RF3 ≈ +36 on the brokers (trivial); payment's 4th pod
  ≈ +1.1 Gi aggregate; fits the 3×(2 vCPU/16 GB) nodes.

---

## 4. Rollout order & success criteria

1. **Partitions** (`topics.yaml`): `booking.created`/`booking.confirmed` 6→9, `inventory.reserved`
   6→12; size the payment retry topics to match. Apply.
2. **inventory**: `KAFKA_CONCURRENCY: "3"` in `values/inventory.yaml` (optionally migrate to KEDA-on-lag). Redeploy.
3. **payment**: `KAFKA_CONCURRENCY: "3"` in `values/payment.yaml`; `maxReplicaCount: 4` + retuned
   `lagThreshold` in `payment-scaledobject.yaml`. Redeploy.
4. **WireMock**: add the HPA (rate/concurrency metric); set a lean floor. Apply.
5. **Re-run Experiment 01** at `TARGET_RPS=60` (try `80` once green). Record results.

Success:

- payment & inventory consumer lag **drains within the hold** (no monotonic growth), peak lag well
  below the ~7 min baseline.
- payment scales on lag to 4 pods and back; inventory sustains 9 consumers.
- No OOMKilled; WireMock serves peak concurrency with no liveness flaps and scales down at rest.
- Booking success rate stays high; no new downstream bottleneck.

---

## 5. Follow-ups — ADRs (cut per affected service, `DR-002`)

- **ADR-0014** — inventory-service: saga concurrency 2→3 (9 consumers); KEDA-on-lag option.
- **ADR-0015** — payment-service: KEDA max 3→4 + concurrency 2→3 (12 consumers).
- **ADR-0016** — kafka-platform: hot-topic partition raises (+ retry topics).
- **ADR-0017** — platform/WireMock: HPA for the fake payment provider.

---

## 6. One-liner

After ADR-0013 killed the duplicates, the run exposed pure **consume-side capacity**: payment and
inventory are I/O-bound (idle CPU, half-used memory) and lag ~7 min at 60/s. Fix by parallelism, not
compute — **inventory concurrency 3 / `booking.created`+`booking.confirmed` → 9**, **payment KEDA max
4 + concurrency 3 / `inventory.reserved` → 12 (+ retry topics)** — and, crucially, **give WireMock an
HPA** so scaling payment doesn't just relocate the bottleneck onto the provider.
