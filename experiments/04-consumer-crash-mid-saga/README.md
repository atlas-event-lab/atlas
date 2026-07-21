# Experiment 04 — Consumer Crash mid-Saga

**Category:** Resilience · **Type:** Fault-injection (process kill) · **Status:** DONE

## Why this experiment

Experiments 02 and 03 proved the idempotency guard under *controlled* conditions: Exp 03
replayed already-committed offsets with the apps quiesced cleanly. This experiment probes the
scenario that guard actually exists for: a consumer that **dies abruptly mid-processing**, with
uncommitted offsets and in-flight transactions. The consumer group rebalances, Kubernetes
restarts the process, and Kafka redelivers everything since the last committed offset
(at-least-once). The system must end in the exact state it would have reached without the
crash — nothing lost, nothing double-processed (`EVT-005`, `EVT-008`, `EVT-010`).

The target is **payment-service**, the most dangerous window in the Saga. Its processing is
deliberately split (see `PaymentServiceImpl` / `PaymentTransactionService`,
`services/payment/service.md`):

1. **TX1 `beginProcessing`** — dedupe on `eventId`, create the `Payment`, CREATED → PROCESSING,
   emit `PaymentRequested` (one transaction, outbox);
2. **provider call** — `POST /payments` to the fake provider (WireMock), **outside any
   transaction**;
3. **TX2 `resolve`** — PROCESSING → terminal, emit the terminal event (one transaction, outbox).

A crash can land in three windows, each with a distinct expected recovery:

| Window | Crash lands… | On redelivery, expected |
|--------|--------------|--------------------------|
| **W1** | before TX1 commits | full clean reprocess — the event was never applied, nothing was charged |
| **W2** | after TX1, before TX2 (around the provider call) | TX1 already recorded the `eventId`, so the redelivery is skipped as a **duplicate** — no re-charge from the consumer path. The payment sits in PROCESSING until the **recovery sweeper** ([ADR-0021](../../docs/adr/ADR-0021-payment-stale-processing-recovery.md)) re-drives it: same `paymentId` → same provider `Idempotency-Key` (never a double charge), then the normal `resolve` → the Saga settles (CONFIRMED / FAILED / EXPIRED via `PaymentTimedOut`). Before ADR-0021 this was a permanent orphan — the gap this experiment surfaced during design analysis (see [`payment-recovery.md`](./payment-recovery.md)) |
| **W3** | after TX2, before the offset commit | pure duplicate — the `eventId` dedup makes redelivery a no-op |

(The `already_charged` guard branch is *not* the W2 signature: it only fires for a re-trigger
with a **new** `eventId`. A same-event redelivery — the crash case — always hits the
`duplicate` branch; W2 is separated from W3 in Postgres, as payments stuck PROCESSING.)

Payment is also **new coverage**: the inventory guard was exercised twice (Exp 02, Exp 03);
the payment guard (`ConsumedEvent` + `findByBookingId` + terminal no-op in `resolve`) has not
been probed by any experiment. And because payment sits mid-Saga, recovery proves the whole
chain heals: booking still receives the terminal payment event and confirms, inventory still
consumes `booking.confirmed`.

## Hypothesis

When every `payment-service` pod is killed abruptly (SIGKILL — no graceful shutdown, no
offset commit) while a controlled batch of N bookings is draining through the Saga:

1. **No double charge.** Never more than one `Payment` row per `bookingId`; the provider
   (WireMock) receives at most one charge sequence per booking. Redelivered
   `inventory.reserved` events are absorbed by the guard (visible as `Skipping duplicate
   InventoryReserved` / `Payment already exists for booking` log lines).
2. **No loss.** After the pods return, the `payment-service` group's lag on
   `inventory.reserved` drains to 0 and **every** booking in the batch leaves
   `INVENTORY_RESERVED` — no booking is stranded waiting for a payment event that never comes.
3. **The Saga heals — including W2, via the recovery sweeper.** Every booking in the batch
   reaches a coherent end state: `CONFIRMED` (or `FAILED` for legitimately declined
   payments). Bookings whose payment crashed exactly in **W2** take the long way — they wait
   in PROCESSING/`INVENTORY_RESERVED` until the sweeper (ADR-0021) re-drives the charge
   (`stale-after` + one sweep, ≈ 4 min at defaults) — but they **must** converge, with zero
   double charges, and each one shows up in `atlas_payment_recoveries_total`. A booking still
   in flight after the recovery window fails the experiment.

Falsifiable: a second `Payment` for the same booking, a duplicate charge at the provider, a
booking permanently stuck, or lag that never drains — any of these fails the experiment.

## What it does

`runbook.sh` orchestrates the whole run:

1. **Guardrails + clean start:** kubectl context checks; the `payment-service` group must
   start with lag 0 on `inventory.reserved`; no other load may be running.
2. **Snapshot BEFORE** (Postgres ground truth): `payment_db` (`payments`, `consumed_events`,
   `outbox` counts), `booking_db` (bookings by status), and the WireMock
   `POST /payments` request count (best-effort, via the admin API).
3. **Fire the batch:** launches k6 in the background — Experiment 01's `load.js` in smoke
   mode (`ITERATIONS=N`, `VUS` parallel) — so N real journeys (cart → booking → Saga) start
   flowing. Requires `.env` loaded, exactly like any other experiment.
4. **Kill:** polls `payment_db.payments` until `KILL_AFTER` payments exist (default N/3 — the
   batch is mid-drain), then kills **every** payment-service pod abruptly:
   - `KILL_MODE=exec` (default): `kill -9` of the java process inside each container — the
     JVM dies instantly, no shutdown hook, no offset commit. If the image has no shell or
     java is PID 1 (SIGKILL to PID 1 from inside the namespace is blocked by the kernel), it
     falls back automatically to
   - `KILL_MODE=force-delete`: `kubectl delete pod --grace-period=0 --force` — immediate
     SIGKILL from the kubelet, same abrupt-death semantics, pod replaced by the Deployment.

   All pods die together so the group has no members: lag accumulates visibly while k6 keeps
   booking, and the recovery is a true cold rejoin + redelivery, not a quiet rebalance.
5. **Recover + settle:** waits for the pods to come back Ready, for k6 to finish, for the
   group's lag to drain to 0, and then for booking states to stop changing (`SETTLE`).
6. **Snapshot AFTER + assert:** the invariants above, directly against Postgres; prints the
   WireMock delta and the exact per-window counts for the run log.

## Prerequisites

- Shared setup from the [repo README](../README.md): k6, `.env` loaded, `kubectl` context on
  the Atlas cluster, seeded load-test users (the batch uses `VUS` of them).
- Seeded bookable inventory for the configured `SCENARIO` (same requirement as Exp 01).
- A clean baseline helps the readout (`make -C .. reset CONFIRM=yes`), but is not required —
  the runbook counts bookings by creation timestamp, not absolute totals.
- `payment-service` built with the ADR-0020 meters and the ADR-0021 recovery sweeper (the W2
  convergence assertion depends on it). Verify the *deployed* image actually has them —
  pushed commits + CI build + rollout are three separate steps, and Micrometer counters are
  lazy (absent until first increment), so the check is: run `make -C .. smoke
  EXP=01-high-booking-concurrency N=3` and confirm `atlas_payment_provider_calls_total`
  appears with value 3 on a payment pod. The runbook also aborts before killing if no pod
  exposes the meter.
- No other load running against the cluster during the experiment.

## How to run

```bash
cd experiments/04-consumer-crash-mid-saga
set -a; source ../.env; set +a
# preview everything, change nothing:
DRY_RUN=1 ./runbook.sh
# execute (kills payment pods mid-batch):
CONFIRM=yes N=1000 VUS=20 ./runbook.sh       # recommended: arrival outpaces payment → standing
                                             # lag → guaranteed in-flight messages at the kill
CONFIRM=yes ./runbook.sh                     # defaults: N=50 VUS=5 (may kill an idle consumer!)
CONFIRM=yes KILL_MODE=force-delete ./runbook.sh
```

> **Why VUS matters:** duplicates and W2 recoveries only exist if messages are mid-processing
> at the kill instant. With a low arrival rate the payment consumer drains and idles between
> messages, and a kill in that gap yields a trivially-clean run (zero redeliveries — nothing
> was uncommitted). The runbook therefore waits for standing lag (`KILL_LAG`, default 10)
> before killing; if the lag never builds, raise `VUS` so arrival outpaces payment capacity.

Env knobs: `N` (journeys in the batch, default 50), `VUS` (parallel journeys, default 5),
`KILL_AFTER` (payments count that arms the kill, default `N/3`), `KILL_LAG` (standing lag on
`inventory.reserved` also required before killing, default 10 — proves messages are in
flight), `KILL_MODE` (`exec` | `force-delete`), `SETTLE` (seconds for states to stabilize,
default 360 — sized to cover the W2 recovery window: `stale-after` 3 m + one sweep; lower
`PAYMENT_RECOVERY_STALE_AFTER` on the deployment for faster runs), `SCENARIO` (passthrough
to k6), `DRY_RUN`, `CONFIRM`.

Pod-restart note: with `KILL_MODE=exec` the JVM dies in place and the pod's `RESTARTS`
column increments; the `force-delete` fallback **replaces** the pods, so `RESTARTS` stays 0
and the evidence of the kill is the new pod names/age (and the runbook's own log).

## What to watch (Grafana)

| Layer | Panel / query | Healthy signal |
|-------|---------------|----------------|
| Kafka | `kafka_consumergroup_lag{topic="inventory.reserved", consumergroup="payment-service"}` | jumps when the pods die, drains to ~0 after they return |
| Pods | `kube_pod_container_status_restarts_total{container="payment-service"}` (or new pod names with `force-delete`) | +1 per pod at the kill, then Ready |
| Dedup | `atlas_payment_events_skipped_total{reason="duplicate"}` | rises after recovery = redeliveries absorbed (counts W2 **and** W3; split them in Postgres via payments stuck PROCESSING) |
| Dedup (re-trigger) | `atlas_payment_events_skipped_total{reason="already_charged"}` | normally 0 here — fires only on a re-trigger with a *new* `eventId`, not on same-event redelivery |
| No double charge | `atlas_payment_provider_calls_total` (sum over `outcome`) | tracks payments charged after the kill — never ≈ 2× |
| W2 recovery | `atlas_payment_recoveries_total` (ADR-0021) | == the W2 count, ≈ `stale-after` + one sweep after the kill |
| Saga | booking-service logs / booking states in Postgres | bookings keep confirming after the pods return |

> **Counters reset on restart.** Micrometer counters are per-process and the experiment kills
> the pods, so the replacement pods start at 0 — by design: read *after* recovery, the skip
> counters equal exactly this crash's absorbed redeliveries (split W1/W3 vs W2 by `reason`),
> and `provider_calls_total` equals the charges actually sent. Meters added by
> [ADR-0020](../../docs/adr/ADR-0020-payment-idempotency-metrics.md); the duplicate-skip log
> lines remain as a secondary signal.

## Success criteria

- `SELECT booking_id FROM payments GROUP BY booking_id HAVING count(*) > 1` → **0 rows**.
- WireMock `POST /payments` delta ≈ number of payments created (± the provider client's inner
  retries), never ≈ 2× — no double charge.
- `payment-service` lag on `inventory.reserved` == 0 at the end; no booking of the batch left
  in `INVENTORY_RESERVED` after `SETTLE`.
- Every batch booking terminal: `CONFIRMED` / `FAILED` (or `EXPIRED` if a W2 recovery timed
  out at the provider) — **including** W2 orphans, which must be settled by the sweeper
  within the recovery window (`stale-after` + one sweep). None may show a double charge.
- `consumed_events` in `payment_db` grew by exactly the number of *distinct* trigger events
  processed (redeliveries add nothing).
- After recovery: `atlas_payment_events_skipped_total{reason="duplicate"}` ≈ redeliveries
  (W2+W3), `atlas_payment_provider_calls_total` == payments charged after the kill, and
  `atlas_payment_recoveries_total` == the W2 count (payments the sweeper re-drove).

## Results

Record each run in [`RESULTS.md`](./RESULTS.md). Findings/decisions:

- [`payment-idempotency-metrics.md`](./payment-idempotency-metrics.md) — the duplicate-skip
  and provider-call meters added to make crash-recovery visible, recorded as
  [ADR-0020](../../docs/adr/ADR-0020-payment-idempotency-metrics.md).
- [`payment-recovery.md`](./payment-recovery.md) — the W2 liveness gap (orphaned PROCESSING
  payments) surfaced by this experiment's design analysis, closed by the recovery sweeper in
  [ADR-0021](../../docs/adr/ADR-0021-payment-stale-processing-recovery.md).
