---
adr_id: ADR-0018
title: Expose inventory domain metrics (reservations, oversell attempts, units) for correctness APM
service: Inventory
status: COMPLETED
date: 2026-07-11
depends_on:
  - ADR-0008
---

# ADR-0018 — Inventory contention metrics

# Status

`COMPLETED` (created 2026-07-11). Merged: the three meters are implemented in `InventoryServiceImpl` and the test constructs the service with a real `SimpleMeterRegistry`. Origin:
[experiments/02-inventory-contention/inventory-observability.md](../../experiments/02-inventory-contention/inventory-observability.md).

# Context

Experiment 02 (inventory contention) proves the **no-oversell** invariant: under many concurrent
bookings for one scarce resource, the pessimistic row lock
(`FlightInventoryRepository.findForUpdate`, `SELECT … FOR UPDATE`) serializes reservations so
`reservedCount` never exceeds `totalCapacity` (`state_machine.md §Concurrency`, ADR-0008).

The Phase-6 observability stack scrapes `/actuator/prometheus`, but inventory emits only
framework metrics (`http_server_requests`, JVM, Kafka client). The reservation path is
Kafka-driven, so its outcomes never appear in HTTP metrics, and there is **no signal at all for
an oversell attempt** — the single number that must provably stay 0. Watching the invariant (and
catching a *transient* breach the settled read can't show) needs domain metrics.

Per-resource gauges (`reserved{flightId}`) were rejected: high cardinality and redundant with the
direct inventory-API read the experiment already uses.

# Decision

Add three low-cardinality Micrometer counters to `InventoryServiceImpl` (constructor-injected
`MeterRegistry`):

1. **`atlas.inventory.reservations`** `{result=reserved|rejected}` — incremented once per
   `BookingCreated` on the reserve / reject branch. Winners vs losers, measured not inferred.
2. **`atlas.inventory.oversell.attempts`** — incremented in a `try/catch (IllegalStateException)`
   around the reserve mutation. The entity guard re-checks availability under the lock, so it
   **cannot** trip in correct operation; a non-zero value means the invariant broke. The catch
   logs `error` and **rethrows unchanged** — the transaction still rolls back (pure observability,
   no behaviour change).
3. **`atlas.inventory.units`** `{action=reserved|released}` — seats/rooms allocated / returned,
   for conservation checks.

Prometheus names become `atlas_inventory_*_total`. Exposed via the existing `/actuator/prometheus`
+ PodMonitor — no scraping changes. These are permanent APM signals, not experiment-gated.

# Consequences

**Positive.** The no-oversell invariant becomes a watchable, recorded time-series with a standing
oversell-attempt alarm; inventory gets real domain APM. **Negative.** A few counter increments on
the reserve/release paths (negligible; the registry caches meter lookups) and one `try/catch`
around the reserve mutation.

# Documents to update at implementation

- `inventory-service` — `InventoryServiceImpl` (meters; done in this change).
- `InventoryServiceImplTest` — construct with a `SimpleMeterRegistry` (done).
- `deploy/platform/observability/atlas-exp02-dashboard.yaml` — the dashboard (added).
- No OpenAPI/AsyncAPI contract change (metrics are not part of a service contract).
