# Runbook — apply the payment-service scaling changes

Applies the changes designed in
[`experiments/01-high-booking-concurrency/payment-service-scaling.md`](../../experiments/01-high-booking-concurrency/payment-service-scaling.md).

Two independent phases:

- **Phase A — consumer scaling (§3):** partitions + concurrency + KEDA. Removes payment's
  bottleneck. Low risk.
- **Phase B — multi-broker durability (§7):** 3 brokers, RF=3 / ISR=2, Cruise Control. Heavier
  and stateful. **Run in a separate window** from the max-app-scale runs.

> Prereqs: `kubectl` + `helm` context on the Atlas cluster; run from the repo root; `k6`
> installed and `experiments/.env` filled for Phase A step 5.
>
> ⚠️ The `concurrency` change lives in `application.yml` (baked into the image). Setting the
> `KAFKA_CONCURRENCY` env on the **old** image does nothing — deploy a **new** payment image
> (CI builds `sha-<git-sha>` on push to `main`). Without the env, the image default is 2.

---

## Phase A — consumer scaling

### Step 2 — raise `inventory.reserved` to 6 partitions

```bash
kubectl -n atlas-data patch kafkatopic inventory.reserved \
  --type merge -p '{"spec":{"partitions":6}}'
# (alternative: kubectl apply -f deploy/platform/strimzi/topics.yaml)

# verify (CR + broker)
kubectl -n atlas-data get kafkatopic inventory.reserved -o jsonpath='{.spec.partitions}{"\n"}'
kubectl -n atlas-data exec atlas-dual-role-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic inventory.reserved
```

Expect `PartitionCount: 6`. Partitions can only be raised, never lowered.

### Step 3 — install KEDA + deploy payment with the new image

```bash
# 3a. KEDA (once)
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm upgrade --install keda kedacore/keda -n keda --create-namespace
kubectl -n keda get pods

# 3b. deploy payment (or let CI do it on push to main)
TAG="sha-$(git -C payment-service rev-parse HEAD)"
helm upgrade --install payment-service atlas-gitops/charts/atlas-service \
  -f atlas-gitops/charts/atlas-service/values/payment.yaml -n atlas-apps \
  --set image.tag="$TAG" --wait --timeout 5m

# verify: CPU HPA gone, concurrency env present
kubectl -n atlas-apps get hpa payment-service                       # -> NotFound (correct)
kubectl -n atlas-apps exec deploy/payment-service -- printenv KAFKA_CONCURRENCY   # -> 2
```

### Step 4 — apply the KEDA ScaledObject

```bash
kubectl apply -f deploy/platform/keda/payment-scaledobject.yaml
kubectl -n atlas-apps get scaledobject payment-service              # READY=True
kubectl -n atlas-apps get hpa keda-hpa-payment-service              # TARGETS = lag, not <unknown>
```

`ACTIVE=False` with lag below the activation threshold (10) is normal — payment stays at min 1.

### Step 5 — re-run Experiment 01 at 60 rps

```bash
cd experiments
set -a; source .env; set +a
make smoke EXP=01-high-booking-concurrency N=5        # smoke first
cd 01-high-booking-concurrency
k6 run -e SCENARIO=both -e TARGET_RPS=60 -e HOLD=6m --summary-export=summary.json load.js
```

Watch while it runs:

```bash
watch -n5 'kubectl -n atlas-apps get scaledobject,deploy payment-service'
watch -n5 'kubectl -n atlas-data exec atlas-dual-role-0 -c kafka -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group payment-service'
```

Success: lag drains (not monotonic growth), payment scales 1→≤3 on lag and back, no OOMKilled,
`booking_success_rate` improves vs the prior 84–86%. Record the run in a `RESULTS_*.md`.

### Phase A rollback

```bash
kubectl -n atlas-apps delete -f deploy/platform/keda/payment-scaledobject.yaml
# then set autoscaling.enabled=true, keda.enabled=false in values/payment.yaml and redeploy
```

Partitions are not reverted (Kafka can't shrink them); extra partitions simply sit idle with
fewer consumers — harmless.

---

## Phase B — multi-broker RF=3 / ISR=2 (separate window)

Adds 2 brokers (one per node), fixes broker resources, enables Cruise Control, and reassigns
existing topics to RF=3. This is stateful — schedule it apart from heavy app-scale runs.

**Capacity note:** 3 brokers at 2Gi limit ≈ 6Gi ceiling (was ~810Mi) and 3 × 50Gi PVCs
(oci-bv) — the live volumes are 50Gi, and `kafka.yaml` matches that (Strimzi rejects shrinking
storage). Confirm each of the 3 nodes has room.

> **⚠️ ORDER MATTERS — do NOT set `min.insync.replicas: 2` while topics are still RF=1.**
> Existing topics stay RF=1 until B2 reassigns them. With `acks=all` (all producers) and a
> broker-default ISR of 2 but only 1 replica, every produce fails with `NotEnoughReplicas` and
> blocks payment/booking on the live cluster. Safe order: **B1 CC + resources (ISR stays 1) →
> B2 reassign to RF=3 → B3 flip ISR to 2.** `kafka.yaml` holds the END state (ISR=2); reach it
> via the steps below, applying the ISR bump last.

### Step B1 — enable Cruise Control + broker resources (ISR stays 1)

Cruise Control is **not a separate object you create** — the Strimzi operator deploys it when
the Kafka CR carries `spec.cruiseControl`. The 3 brokers already exist (only `replicas` was
changed live), so here we add just Cruise Control + the resource/heap sizing, via targeted
patches that leave `min.insync.replicas` at 1. Both trigger a broker rolling restart (to inject
the CC Metrics Reporter and apply the new resources) — brief per-partition blips while topics
are RF=1, so do it in a quiet window.

```bash
# Cruise Control
kubectl -n atlas-data patch kafka atlas --type merge -p '{
  "spec": {"cruiseControl": {"resources": {
    "requests": {"cpu": "100m", "memory": "512Mi"},
    "limits": {"memory": "1Gi"}}}}}'

# Broker resources + fixed heap (predictable Burstable QoS)
kubectl -n atlas-data patch kafka atlas --type merge -p '{
  "spec": {"kafka": {
    "resources": {"requests": {"cpu": "250m", "memory": "1.25Gi"}, "limits": {"cpu": "1", "memory": "2Gi"}},
    "jvmOptions": {"-Xms": "1g", "-Xmx": "1g"}}}}'

# watch CC come up + brokers roll
kubectl -n atlas-data get deploy atlas-cruise-control -w                 # 1/1 when ready
kubectl -n atlas-data get pods -l strimzi.io/name=atlas-cruise-control   # atlas-cruise-control-... Running
kubectl -n atlas-data get pods -l strimzi.io/cluster=atlas -o wide -w
```

**If `atlas-cruise-control` never appears**, diagnose:

```bash
kubectl -n atlas-data get kafka atlas -o jsonpath='{.spec.cruiseControl}{"\n"}'   # non-empty?
kubectl -n atlas-data get kafka atlas -o jsonpath='{.status.conditions}{"\n"}'    # any Warning?
kubectl -n atlas-data get pods -l strimzi.io/cluster=atlas -o wide               # any Pending?
kubectl -n atlas-data logs deploy/strimzi-cluster-operator | grep -iE "cruise|atlas" | tail -30
```

Common causes: (a) `spec.cruiseControl` empty → the patch didn't apply; (b) a broker Pending on
`Insufficient memory` — the 3 brokers at 1.25Gi request compete with the apps, so free room or
use a quieter window; (c) operator too old to run Cruise Control with KRaft (check its version).
CC only starts once the brokers it depends on are Ready.

### Step B2 — reassign existing topics to RF=3 (ISR still 1)

Raising `spec.replicas` on the KafkaTopic CRs drives the RF change. The Topic Operator hands it
to Cruise Control, which runs it as an **ongoing execution** (an inter-broker replica movement):

```bash
kubectl apply -f deploy/platform/strimzi/topics.yaml

# track the replica change (this IS Cruise Control's ongoing execution)
kubectl -n atlas-data get kafkatopic -o custom-columns=\
NAME:.metadata.name,SPEC:.spec.replicas,CHANGE:.status.replicasChange.state | head -30
```

`CHANGE = ongoing/pending` means it's running — **let it finish, do not interrupt** (aborting
mid-reassignment leaves topics partially replicated). When `CHANGE` is empty on all topics and
`--describe` shows `ReplicationFactor: 3`, the RF change is done.

> **Do NOT run the `full` KafkaRebalance (`kafka-rebalance.yaml`) at the same time.** Cruise
> Control runs one execution at a time: while the RF reassignment is ongoing, a rebalance fails
> with `Cannot start a new execution while there is an ongoing execution` and lands `NotReady`.
> The `full` rebalance is **optional** — adding brokers + the RF reassignment already spreads
> replicas across all 3 brokers. Only run it later, when CC is idle, to optimize load balance:
> `kubectl apply -f deploy/platform/strimzi/kafka-rebalance.yaml`, wait for `ProposalReady`, then
> `kubectl -n atlas-data annotate kafkarebalance atlas-rebalance-full strimzi.io/rebalance=approve`.
> (In `NotReady` the only valid annotation is `refresh`, not `approve`. To abandon it:
> `kubectl -n atlas-data delete kafkarebalance atlas-rebalance-full`.)

> If your Strimzi version does not apply replica-count changes to existing topics, do it
> manually with `bin/kafka-reassign-partitions.sh` (generate a plan setting RF=3, then
> `--execute`). The internal `__consumer_offsets` / `__transaction_state` topics were created
> at RF=1; the cluster config change only affects *new* internal topics, so reassign these two
> explicitly if you want them at RF=3.

Confirm every topic reached RF=3 with 3 in-sync replicas **before** B3:

```bash
kubectl -n atlas-data exec atlas-dual-role-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions
# empty output = all replicas in sync; safe to raise ISR
```

### Step B3 — flip `min.insync.replicas` to 2 (only now that topics are RF=3)

Now the ISR bump is safe. Apply the full manifest (its END state carries ISR=2), or patch just
the two ISR keys:

```bash
kubectl -n atlas-data patch kafka atlas --type merge -p '{
  "spec": {"kafka": {"config": {
    "min.insync.replicas": 2,
    "transaction.state.log.min.isr": 2}}}}'
# (equivalently: kubectl apply -f deploy/platform/strimzi/kafka.yaml — same end state)
```

Producers can now lose 1 broker and still write (2 of 3 in ISR); losing 2 blocks writes — the
intended durability guarantee.

### Step B4 — verify durability is real

```bash
# RF=3 and ISR healthy on a business topic
kubectl -n atlas-data exec atlas-dual-role-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic inventory.reserved
# expect ReplicationFactor: 3 and Isr listing 3 brokers

# 0 under-replicated partitions
kubectl -n atlas-data exec atlas-dual-role-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions
# (empty output = healthy)

# internal topics RF
kubectl -n atlas-data exec atlas-dual-role-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic __consumer_offsets | head
```

### What to watch (signal vs noise)

- `UnderReplicatedPartitions` and ISR shrink/expand rate → 0 / stable. If the ISR flaps, it's a
  starved JVM (raise broker memory), not Kafka.
- Broker OOMKills → none.
- Produce p95 (`acks=all`) with RF=3/ISR=2 vs the RF=1 baseline → this is the real durability
  delay you wanted to measure.

### Phase B rollback

Reverting RF on a live cluster is disruptive; prefer fixing forward. If you must, scale the
node pool back to 1 only **after** reassigning every topic back to RF=1 (otherwise partitions
become under-replicated / offline). Treat this as a last resort.

---

## Follow-ups

On merge, cut the ADRs (`DR-002`, one per service) and flip to `COMPLETED` (`DR-003`):
payment-service (KEDA + concurrency), inventory-service (partitions 3→6), kafka-platform
(3 brokers RF=3/ISR=2 + Cruise Control). See payment-service-scaling.md §8.
