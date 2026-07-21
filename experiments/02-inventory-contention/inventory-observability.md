# Inventory observability — custom metrics for the no-oversell invariant

**Origin:** Experiment 02 — Inventory Contention · **Phase:** 7 (APM) · **Status:** proposal
**Services affected:** inventory-service · **ADR:** [ADR-0018](../../docs/adr/ADR-0018-inventory-contention-metrics.md)

> This is the narrative half of Experiment 02's observability work: what the experiment needed
> to *measure*, why the existing metrics couldn't, what we added, and how it's validated. It is
> scoped to this experiment; the binding service-code change is recorded as **ADR-0018**
> (inventory-service). Mirrors the Experiment 01 convention (`payment-service-scaling.md` ↔
> ADR-0015).

## 1. What the experiment surfaced (the gap)

Experiment 02 asserts a correctness invariant — **no oversell** — and derives the winner count
(`floor(C/q)`) from the settled inventory. The `load.js` `teardown()` proves pass/fail by
reading the inventory API. But to *watch it happen* — and to catch a **transient** breach that
the settled read can't show — we need the numbers as time-series in Grafana.

The observability stack (Phase 6) scrapes `/actuator/prometheus`, but the services emit **only
framework metrics**: `http_server_requests`, JVM, Kafka client. None of them describe the
domain. In particular:

- Reservation *outcomes* (reserved vs rejected) are Kafka-driven, not HTTP, so they don't
  appear in `http_server_requests` at all.
- There is **no signal** for an oversell attempt — the one number that must provably stay 0.

Per-flight gauges (`reserved{flightId}`) were rejected: high-cardinality (one series per
resource) and unnecessary — the invariant is aggregate, and the exact target's stock is already
read directly by `load.js` and the inventory API.

## 2. What we added (decision)

Three low-cardinality Micrometer counters in `InventoryServiceImpl` (constructor-injected
`MeterRegistry`, `CODE` constructor-injection rule):

| Meter (Prometheus name) | Tags | Incremented when | Why it matters |
|--------------------------|------|------------------|----------------|
| `atlas_inventory_reservations_total` | `result=reserved\|rejected` | a `BookingCreated` reserves all items / is rejected | winners vs losers, measured not inferred |
| `atlas_inventory_oversell_attempts_total` | — | the defensive `reserve()` guard throws `IllegalStateException` | **the invariant** — must stay 0 |
| `atlas_inventory_units_total` | `action=reserved\|released` | seats/rooms allocated / returned | conservation; released≈0 confirms winners aren't being freed |

The oversell counter sits in a `try/catch (IllegalStateException)` around the reserve mutation:
availability is re-checked under the pessimistic lock, so the guard **cannot** trip in correct
operation — which is exactly why a non-zero value is a red flag. The catch increments the meter,
logs `error`, and **rethrows** unchanged, so the transaction still rolls back (behaviour
identical to before; this is pure observability).

These are useful beyond the experiment (they belong in prod APM), so they're added to the
service proper, not gated behind a flag.

## 3. Dashboard + load-side metrics

- **Dashboard:** `deploy/platform/observability/atlas-exp02-dashboard.yaml` (ConfigMap,
  auto-loaded by the Grafana sidecar, folder *Atlas*): oversell-attempts stat (0/red),
  reserved-vs-rejected rate, units, consumer lag, and the k6 side.
- **k6 metrics in Grafana:** the harness already emits `oversell` / `bookings_created` /
  `booking_create_duration`. Running with `PROM=1` remote-writes them (`k6_*`) to the same
  Prometheus (receiver already enabled for Tempo — no infra change). Now both halves — what k6
  fired and what inventory did — sit on one dashboard.

## 4. Validation

- Existing `InventoryServiceImplTest` updated to construct the service with a real
  `SimpleMeterRegistry`; behaviour assertions unchanged (the meters don't alter control flow).
- Manual: after a contention run, `atlas_inventory_reservations_total{result="reserved"}`
  equals `floor(C/q)`, `{result="rejected"}` equals `N − winners`, and
  `atlas_inventory_oversell_attempts_total` is **0**. Cross-checks the `teardown()` read.

## 5. Conclusion

The experiment's correctness claim was previously a one-shot read; it's now a **watchable,
recorded** signal, with the oversell-attempt counter as a standing alarm. The pass/fail bar is
unchanged (still the `teardown()` invariant read) — this makes the result observable and gives
inventory real domain APM. Cut to **ADR-0018** (inventory-service); flip it to `COMPLETED` when
merged.
