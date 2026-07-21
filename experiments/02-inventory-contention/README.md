# Experiment 02 — Inventory Contention

**Category:** Correctness · **Type:** Load / concurrency · **Status:** DONE
(pending a target resource + always-approve payment stub — see below)

## Why this experiment

Experiment 01 proved the hot path *scales*. This one proves it stays *correct* while it
does. The single most important invariant of a booking platform is **no oversell**: two
travellers must never both win the last seat. In Atlas the reservation is not a simple
`UPDATE`; it is the Inventory side of the choreography Saga
(`features/reserve-inventory`, `ADR-0008`), guarded by a pessimistic row lock
(`SELECT … FOR UPDATE`) inside a single transaction. This experiment deliberately drives
**many concurrent bookings at one scarce resource** and asserts the invariant holds.

The mechanism under test lives in `inventory-service`:

- `FlightInventoryRepository.findForUpdate(...)` loads the row under
  `LockModeType.PESSIMISTIC_WRITE`, serializing concurrent reservations for the *same*
  flight (`state_machine.md §Concurrency`).
- `InventoryServiceImpl.reserve(...)` evaluates `canReserve(quantity)` and mutates
  `reservedCount` **inside** that lock, all-or-nothing across items and nights.
- The entity is defence-in-depth: `available() = max(0, totalCapacity − reservedCount)`,
  `reserve()` throws if it would exceed capacity, and `isOversold()` is the invariant
  (`totalCapacity < reservedCount`) that must **never** be true.
- Multi-item bookings lock resources in a deterministic order (sort by
  `resourceType`, then `resourceId`) to avoid deadlocks between concurrent Sagas.

Relevant rules/specs: `ARCH-007` (evaluate-before-mutate), `state_machine.md`
(concurrency + reservation transitions), `ADR-0008` (flight scalar vs hotel per-night
model), `inventory-events.yaml` (the `InventoryReserved` / `InventoryRejected` contract).

## Hypothesis

When `N` bookings compete concurrently for a single resource of capacity `C`, each
requesting `q` units:

1. **No oversell — the hard invariant.** `reservedCount` never exceeds `totalCapacity`
   at any instant; `available()` never goes negative. `isOversold()` is never true,
   during or after the burst.
2. **Exactly the reservable subset wins.** The number of bookings that reach
   `INVENTORY_RESERVED` equals `floor(C / q)`; every other booking is cleanly **rejected**
   (`INVENTORY_REJECTED`, booking → `FAILED`), not errored and not silently dropped.
3. **Conservation holds.** With payment stubbed to always-approve (reservations stay held),
   `reservedCount == winners × q` once the burst settles, and it equals the peak — no
   reservation is lost or double-counted under contention.
4. **Graceful serialization.** The lock serializes writers, so latency rises under
   contention but no deadlock aborts the transaction (deterministic lock ordering holds).

Falsifiable: if `reservedCount > totalCapacity` ever appears, or winners `≠ floor(C/q)`,
or a booking neither reserves nor rejects, the hypothesis fails.

## What it does

Unlike Experiment 01, which **spreads** load across the whole `ROUTES` table so inventory
is never the bottleneck, this experiment **concentrates** all virtual users on **one
target resource** with a small, known capacity, then fires a burst.

1. `setup()` picks a **single** contention resource (a flight with a known small
   `totalCapacity = C`, e.g. `C = 10`), discovered from a dedicated route/date reserved for
   this experiment (not shared with other runs).
2. All VUs run the checkout journey (`token → cart → add item(qty=q) → POST /bookings`)
   against **that same** resource, at a burst arrival rate with `N ≫ C` so they collide on
   the one locked row.
3. Booking creation returns `201 PENDING` immediately; the reservation is resolved
   asynchronously by the Saga. So the outcome is measured **after** the burst drains:
   - **Invariant read** — `GET /api/v1/inventory/flight/{flightId}` →
     assert `reservedCount ≤ totalCapacity` and `available ≥ 0`.
   - **Outcome tally** — for each `bookingId` created, `GET /api/v1/bookings/{bookingId}`
     → count `CONFIRMED`/reserved vs `FAILED`. Winners must equal `floor(C/q)`.
   - **Conservation** — `winners × q == reservedCount`.

### Variants (run each separately and compare)

| Variant | Params | Expected |
|---------|--------|----------|
| `unit` (default) | `C=10`, `q=1`, `N=100` | exactly 10 reserve, 90 reject, `reserved=10` |
| `partial` | `C=10`, `q=3`, `N=50` | 3 reserve (9 seats), 1 seat left unused, rest reject |
| `deadlock` (optional) | two shared flights A+B, each booking reserves **both**, opposite discovery order | no deadlock abort; lock-ordering holds; no oversell on either |

The `deadlock` variant specifically exercises the deterministic lock ordering in
`InventoryServiceImpl.reserve()`; skip it for the first pass and add once `unit`/`partial`
pass.

## Prerequisites

Shared setup from the [repo README](../README.md): `k6`, `.env`, the seeded user pool,
Grafana. Plus, specific to this experiment (see **What we need to build** below — these do
not all exist yet):

- A **contention target**: a route/date (or city) that exposes **exactly one** in-stock
  flight/room-type, pinned via `CONTENTION_*`. Either reuse an existing seeded flight
  (`load.js` reads its capacity live — just set `N ≫ C/q`) or seed a dedicated
  small-capacity one for isolation. Keep it off Experiment 01's `ROUTES` so runs don't
  contaminate each other.
- **Payment stubbed to always-approve** (WireMock — the stub already exists in
  `deploy/platform/apps/wiremock.yaml`) so winning reservations stay `RESERVED`/`CONFIRMED`
  and the settled `reservedCount` is stable to read. If payment fails/times out it would
  *release* stock and mask the invariant we want to observe.
- A **clean baseline**: `scripts/reset-state.sh` run before each run so the target resource
  starts at `reservedCount = 0` (stale reservations from a prior run hold stock).
- Reservation **TTL long enough** to outlast the burst + verification (otherwise the TTL
  sweep expires winners mid-measurement); check `ReservationExpirationProperties.ttl`.

## What's built vs. still needed

**Built (this iteration):**

1. ✅ **Harness single-resource "pin" mode.** `lib/k6/booking.js` →
   `resolveContentionOffer(scenario)` resolves **exactly one** offer from the
   `CONFIG.contention` target (env `CONTENTION_ORIGIN/DESTINY/DATE/CITY`, optional
   `CONTENTION_RESOURCE_ID` to disambiguate). Additive — Experiment 01 is untouched.
2. ✅ **`load.js`.** Burst executor (`shared-iterations`, `N` bookings across up-to-pool VUs)
   pinned to the target, reusing `lib/k6/{auth,cart,booking}.js`.
3. ✅ **Verify step** — `teardown()` in `load.js` reads the inventory ground truth
   (`lib/k6/inventory.js` → `GET /inventory/{flight,hotel}/…`, authenticated, no ownership
   check so `loadtest-1` can read the shared resource), asserts **no oversell**
   (`reservedCount ≤ totalCapacity`) and **winners == `floor(C/q)`**, and **throws** (fails
   the run) on violation. Capacity `C` is read **live** in `setup()`, not assumed.

**Still needed to actually run it:**

4. ⏳ **A target resource + always-approve payment.** Point `CONTENTION_*` at a resource that
   exposes exactly one in-stock flight/room-type, and stub payment always-approve (WireMock —
   `deploy/platform/apps/wiremock.yaml`) so winners stay reserved and the settled count is
   stable. Two options for the target: (a) **reuse an existing seeded flight** — `load.js`
   reads its capacity live, so any flight works, just set `N` well above `C/q`; or (b) **seed
   a dedicated small-capacity flight** for isolation via `POST /api/v1/flights` (needs an
   **ADMIN** token + catalog airline/airport UUIDs; capacity flows to inventory through the
   catalog events). A dedicated seed script is the next increment — decide (a) vs (b) first.
5. ✅ **Grafana observation + custom metrics.** Inventory now exposes
   `atlas_inventory_reservations_total{result}`, `atlas_inventory_oversell_attempts_total`,
   and `atlas_inventory_units_total{action}` (ADR-0018), and a dedicated dashboard plots them
   alongside consumer lag and the k6 side. See *What to watch* below.
6. ⏳ **Confirm reset covers it.** Verify `reset-state.sh` zeroes the inventory stock counters
   for the target (it documents resetting inventory stock in `reset-state.md §3`); if not,
   extend it. `load.js` guards against a dirty start (it refuses to run if the target is
   already oversold or has no reservable stock).

## How to run

```bash
cd experiments/02-inventory-contention
set -a; source ../.env; set +a

# point at the ONE scarce resource (a route/date that exposes exactly one in-stock flight):
export CONTENTION_ORIGIN=LIM CONTENTION_DESTINY=CUZ CONTENTION_DATE=2026-09-01
# (hotel instead: SCENARIO=hotel CONTENTION_CITY=Cuzco CONTENTION_DATE=…)
# (disambiguate if several match: CONTENTION_RESOURCE_ID=<flightId|roomTypeId>)

# unit contention: N >> C, expect exactly floor(C/1) winners, the rest rejected
k6 run -e N=100 load.js

# partial: q=3 units per booking
k6 run -e N=50 -e Q=3 load.js
```

Knobs (env): `N` (bookings fired at the resource), `Q` (units per booking = `q`),
`SETTLE` (seconds to wait for the Saga before verifying, default 45), `MAX_VUS`
(concurrency, capped by the pool), `CONTENTION_*` (which resource to pin), `SCENARIO`
(`flight`|`hotel`). `C` (capacity) is **not** a knob — `setup()` reads it live from the
inventory API and derives the expected winners. The run **fails loudly** (non-zero exit) if
`reservedCount > totalCapacity` or winners `≠ floor(C/q)`.

## What to watch (Grafana)

A dedicated dashboard ships with this experiment: **Atlas — Experiment 02: Inventory
Contention** (`deploy/platform/observability/atlas-exp02-dashboard.yaml`). It plots the
custom inventory meters added for this work (ADR-0018) plus the k6 side.

| Layer | Panel / query | Healthy signal |
|-------|---------------|----------------|
| Invariant | `atlas_inventory_oversell_attempts_total` (stat) | **stays 0** — any increment means the reserve guard tripped (oversell) |
| Outcome | `atlas_inventory_reservations_total{result}` (reserved vs rejected) | reserved plateaus at `floor(C/q)`; rejected absorbs the rest |
| Units | `atlas_inventory_units_total{action}` (reserved vs released) | released ~0 during the run (payment always-approve); else winners are being freed |
| Kafka | `kafka_consumergroup_lag{topic="booking.created"}` | spikes during the burst, **drains to ~0** after |
| Load side | `k6_oversell` / `k6_bookings_created` (needs `PROM=1`) | `k6_oversell` 0; `bookings_created` ≈ `N` |

### Observability setup

```bash
# 1. Apply the dashboard (auto-loaded by the Grafana sidecar) — one time:
kubectl apply -f deploy/platform/observability/atlas-exp02-dashboard.yaml

# 2. Grafana → folder "Atlas" → "Atlas — Experiment 02: Inventory Contention":
kubectl -n atlas-observability port-forward svc/kps-grafana 3000:80        # admin / atlas-admin

# 3. (optional) stream k6's OWN metrics into the same dashboard — open a Prometheus
#    port-forward, then run with PROM=1:
kubectl -n atlas-observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
make -C .. run EXP=02-inventory-contention PROM=1
```

The custom `atlas_inventory_*` meters are exposed on `/actuator/prometheus` and scraped by the
existing PodMonitor — no scraping changes needed. The invariant read in `load.js`'s
`teardown()` remains the authoritative pass/fail; the dashboard is for *watching it happen*
(and for catching a transient breach the settled read can't show).

## Success criteria

- **`isOversold()` is never true** — `reservedCount ≤ totalCapacity` throughout; `available`
  never negative. (Primary; a single breach fails the experiment.)
- Winners reaching `INVENTORY_RESERVED` = `floor(C / q)`; all other bookings `FAILED` via
  `INVENTORY_REJECTED`; none left `PENDING`.
- Conservation: `winners × q == reservedCount` once settled (with payment always-approve).
- No deadlock-aborted transactions under the `deadlock` variant.

## Results

Record each run in [`RESULTS.md`](./RESULTS.md). When a run surfaces a change (a lock
tuning, an isolation-level decision, a contract adjustment), capture the reasoning in a
`<topic>.md` findings doc in this folder, and promote binding cross-service decisions to
ADRs (`DR-002`) — same convention as Experiment 01.

Findings/decisions so far:

- [`inventory-observability.md`](./inventory-observability.md) — the custom inventory metrics
  added to measure the invariant, recorded as
  [ADR-0018](../../docs/adr/ADR-0018-inventory-contention-metrics.md).
