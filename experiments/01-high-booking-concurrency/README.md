# Experiment 01 — High Booking Concurrency

**Category:** Scalability · **Type:** Load / stress · **Status:** DONE
## Why this one first

This is the baseline experiment. It builds the k6 harness every other experiment reuses,
and it produces the reference numbers — throughput, latency, where the system starts to
bend — that the resilience experiments are measured *against*. It also directly exercises
the Phase 7 prep: the HPA on `booking`/`inventory` and the PgBouncer pooler in front of
Postgres.

## Hypothesis

As booking traffic rises, the system scales horizontally instead of falling over:

1. `booking-service` (and `inventory-service`, reached through the Saga) scale out under
   CPU pressure via their HPAs, rather than saturating a fixed replica set.
2. Database connections stay bounded by the **PgBouncer pooler**, so Postgres never hits
   `max_connections: 200` — the artificial limit that would otherwise cap concurrency.
3. Booking success rate stays high (> 98%) and p95 latency stays bounded while the ramp
   is within capacity; degradation, when it comes, is graceful (rising latency / queueing)
   rather than a cliff of errors.

## What it does

`load.js` drives the full **checkout journey** at a **ramping arrival rate** (journeys
started per second), letting k6 add virtual users as needed so latency never throttles the
offered load. Each iteration:

1. gets a cached OAuth2 token for this VU's own pool user (`loadtest-${__VU}`),
2. picks real, in-stock offer(s) discovered once in `setup()` (see scenarios below),
3. creates a cart — `POST /carts` (this VU's own active cart),
4. adds the item(s) — `PUT /carts/{cartId}/flight` and/or `/hotel`; the cart re-prices and
   returns `totalInUSD`,
5. POSTs the booking — `POST /bookings` — with `travelers`, `items`, and `total` mapped
   from the cart's `totalInUSD`, using a fresh `Idempotency-Key`,
6. on success, converts the cart — `POST /carts/{cartId}/conversion` — as the real frontend
   does, leaving a fresh cart for the VU's next iteration.

Each VU uses a distinct pool user so concurrent journeys never share a cart (the travel-cart
service keeps one active cart per user — see the [repo README](../README.md)).

The booking is a synchronous Saga kickoff: Booking reserves inventory and initiates payment
through choreographed events, so this path touches travel-cart + booking + inventory
(+ payment/flight/hotel downstream) — a realistic hot path, not a trivial CRUD write.

### Scenarios

Set `SCENARIO` (one per run — run each separately and compare):

| `SCENARIO` | Journey | Discovered from |
|------------|---------|-----------------|
| `flight` (default) | one flight | `GET /search/flights` over the `ROUTES` origins/destinies |
| `hotel` | one hotel room | `GET /search/hotels` over the `ROUTES` cities |
| `both` | a flight **and** a hotel in one cart/booking | both of the above |

Discovery fans out over **all** the routes you curate, so the load spreads across real
inventory instead of hammering a single resource. The route table is hardcoded in
[`lib/k6/config.js`](../lib/k6/config.js) as `ROUTES` — a list of
`{ origin, destiny, city }` where `origin`/`destiny` drive flight search and `city` drives
hotel search, keeping the two coherent (e.g. `{ origin:'LIM', destiny:'CUZ', city:'Cuzco' }`).
It's yours to fill and validate; the scripts don't validate it, they just use it and fail
loudly if it yields no in-stock results.

## Prerequisites

- The shared setup in the [repo README](../README.md): `k6` installed, `.env` filled in
  (gateway, Keycloak, load-test client), the **user pool seeded**
  (`scripts/seed-loadtest-users.sh`), the `ROUTES` table filled in (`lib/k6/config.js`), and
  **seeded inventory** on those routes/cities for the dates used.
- HPAs restored and the pooler applied (`deploy/scripts/phase7-prep.sh`).
- Grafana open — this experiment is only meaningful if you watch it scale.

## Smoke test first (recommended)

Before any real load, run a handful of journeys to confirm the whole flow works — auth,
discovery, cart, booking — with no bugs. Set `ITERATIONS=N` to run **exactly N journeys**
(each successful journey creates **1 booking**, even in the `both` scenario), sequentially:

```bash
cd experiments/01-high-booking-concurrency
set -a; source ../.env; set +a

k6 run -e ITERATIONS=1 load.js          # 1 journey  -> 1 booking
k6 run -e ITERATIONS=5 load.js          # 5 journeys -> 5 bookings
make -C .. smoke EXP=01-high-booking-concurrency N=5   # same, via Makefile
```

Add `-e VUS=2` to run a few in parallel, `-e SCENARIO=both` to smoke the flight+hotel path.
In the end-of-run summary, the counters tell you exactly what happened:
`bookings_created` (201) should equal your `ITERATIONS`, `bookings_failed` should be 0, and
`checks` should be 100%. Any non-zero failure or a threshold breach means something to fix
before scaling up.

> Why a dedicated flag: `load.js` defines a scenario in `options`, so k6 ignores the
> `--vus`/`--iterations` CLI flags. `ITERATIONS` switches the script to a `shared-iterations`
> executor that runs an exact count.

## How to run (load)

```bash
cd experiments/01-high-booking-concurrency
set -a; source ../.env; set +a          # load env into the shell

# baseline (flight scenario)
k6 run load.js

# other scenarios
k6 run -e SCENARIO=hotel load.js
k6 run -e SCENARIO=both  load.js

# push harder / longer (override without editing the file)
k6 run -e SCENARIO=both -e TARGET_RPS=60 -e HOLD=6m load.js
```

Knobs (env): `SCENARIO` (flight|hotel|both), `TARGET_RPS` (peak journeys/sec, default 30),
`RAMP`, `HOLD`, `MAX_VUS`, `PRE_ALLOCATED_VUS`. The routes/cities come from the `ROUTES`
table in `lib/k6/config.js`. Start modest and climb across runs — find the knee, don't
guess it.

## What to watch (Grafana)

| Layer | Panel / query | What "healthy" looks like |
|-------|---------------|---------------------------|
| Autoscaling | HPA replicas for `booking` / `inventory` | replicas climb during the hold, settle after |
| Compute | CPU / mem for the app pods (Namespace: atlas-apps) | CPU rises toward the HPA target (~70%), no OOMKills |
| Database | PgBouncer pool: `cnpg_pgbouncer_pools_cl_waiting`, `_maxwait` | near zero; if climbing, the pool is too small |
| Database | CNPG connections vs `max_connections` (200) | stays well under 200 — the pooler is doing its job |
| Kafka | consumer lag (inventory / payment consumers) | lag transient, drains after the ramp |
| App | `booking_success_rate`, `booking_create_duration` p95 (k6 summary) | success > 98%, p95 bounded |

## Success criteria

- Booking success rate ≥ 98% through the target hold.
- HPA demonstrably scales `booking`/`inventory` out and back in.
- Postgres connection count stays below `max_connections`, with pooler wait time ~0.
- Any degradation past the knee is graceful (latency/queueing), not an error cliff.

## Results

Record each run in [`RESULTS.md`](./RESULTS.md) — that file is the "documented result"
half of the Phase 7 exit criterion.
