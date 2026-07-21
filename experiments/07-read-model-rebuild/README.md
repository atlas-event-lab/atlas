# Experiment 07 — Read Model Rebuild

**Category:** Architecture · **Type:** Rebuild / replay · **Status:** READY — two modes:
`REBUILD=offsets` (within-retention, replay the log, no code change) and `REBUILD=resync`
(beyond-retention, re-emit from the owners — Strategy B, ADR-0025/0026/0027, implemented)

## Why this experiment

The CQRS claim for Atlas is that the read side (search) holds **no authoritative state** — it is a
pure projection, fully **derivable by replaying events** (`docs/architecture.md`, ADR-0008/0009).
If that holds, the entire `search_db` can be dropped and rebuilt from the event log with no loss.
This experiment demonstrates the rebuild and, just as importantly, delimits *where the claim
currently holds*: the projection logic is deterministic and idempotent, so a rebuild converges — but
only for events still in the log. All source topics are `cleanup.policy=delete`,
`retention.ms=7d`, so full derivability beyond 7 days needs a durable replay source; the chosen
answer is **Strategy B — republish/resync from the owning services** (that decision doc is
[`rebuild-source-of-truth.md`](./rebuild-source-of-truth.md); productionization is ADR-0025/0026/0027).

## Hypothesis

Given a dataset created within the retention window, after wiping the entire read model and
replaying the events in **catalog-before-availability** order, the rebuilt `search_db` converges to
the exact pre-wipe state:

1. **Catalog converges.** `flight_projections` (catalog columns + `status`) and
   `hotel_projections` + `hotel_room_types` match row-for-row (by natural key), same counts.
2. **Availability converges.** `flight_projections.reserved`/`version` and every
   `room_type_availability` night (`resource_id`, `stay_date`, `capacity`, `reserved`, `version`,
   `status`) match — the absolute+`version` model makes replay order-independent *once the catalog
   row exists*.
3. **Order matters (falsifiable control).** If availability is replayed **before** catalog, some
   updates are dropped (`applyFlightAvailability`/`applyHotelAvailability` skip when the projection
   is absent) and `reserved` does **not** converge — proving the rebuild must sequence catalog first.

Falsifiable: any projection row, `reserved`, or `version` that differs after an ordered rebuild;
counts that don't match; or convergence even under reversed order (which would mean the ordering
concern is moot).

> **Clock-relative calendar.** The hotel night window is materialized `today .. today+horizon`
> (`LocalDate.now`), so the comparison is scoped to rows within the *current* horizon and the rebuild
> is run same-day as the snapshot. This is inherent to a rolling window, not a rebuild defect.

## What it does

`runbook.sh` (search-side, no code change — proves derivability **within retention**):

1. **Guardrails + resolve pods** (kubectl context, Postgres primary, Kafka broker, search deploy);
   no other load.
2. **Snapshot BEFORE** — per read-model table: row count + a content **checksum over the semantic
   columns** (natural key + projected fields, excluding the random night PK and `updated_at`).
3. **Quiesce search** — scale `search-service` to 0 so the consumer group has no members (required
   to reset offsets).
4. **Wipe** — `TRUNCATE flight_projections, hotel_projections, hotel_room_types,
   room_type_availability, consumed_events` in `search_db`.
5. **Ordered replay** (the ordering fix, no code):
   - reset the `search-service` group to `earliest` for the **catalog** topics and to `latest` for
     the **availability** topics; scale search up; wait until catalog is projected (lag 0 on catalog).
   - scale to 0; reset the **availability** topics to `earliest`; scale up; wait lag 0.
6. **Snapshot AFTER** + **verdict** — counts and checksums equal BEFORE; print a diff on mismatch.
   Optional §3 control run: reset availability first to show non-convergence.

## Prerequisites

- Shared setup ([repo README](../README.md)): `kubectl` context, `.env` (only for the optional
  seed/booking step), `psql`/Kafka access via the cluster pods.
- A dataset **created within the last 7 days** whose catalog + availability events are still in the
  log (a fresh `make -C .. reset` + a seed + a small booking batch is the cleanest baseline).
- No other load during the run (the read model must be quiescent to snapshot/compare).
- **Beyond-retention** rebuild (data older than 7 days) is covered by `REBUILD=resync`, which
  re-emits current state from the owning services (Strategy B, ADR-0025/0026/0027 — implemented) and
  does not read the historical log at all.

## How to run

```bash
cd experiments/07-read-model-rebuild
set -a; source ../.env; set +a
DRY_RUN=1 ./runbook.sh                    # preview, change nothing
CONFIRM=yes ./runbook.sh                  # within-retention: wipe + ordered log replay + verify
CONFIRM=yes CONTROL=1 ./runbook.sh        # also run the reversed-order control (expect non-convergence)
CONFIRM=yes REBUILD=resync ./runbook.sh   # beyond-retention: wipe + re-emit from owners + verify
```

Env knobs: `REBUILD` (`offsets` = replay the existing log within retention, default; `resync` =
re-emit current state from the owning services, ADR-0025/0026/0027, works beyond retention),
`SETTLE` (seconds per drain phase, default 180), `SCOPE` (`all` | `flights`, default `all`),
`CONTROL` (demonstrate the ordering failure; offsets mode only), `DRY_RUN`, `CONFIRM`.

**`REBUILD=resync` flow.** Snapshot BEFORE → scale search to 0 → TRUNCATE the read model → scale
search up → `POST /actuator/resync` on flight-service (and hotel-service when `SCOPE=all`), wait for
catalog to project → `POST /actuator/resync` on inventory-service, wait for availability → verify
convergence. Each owner republishes its current DB state through the outbox, so this does **not**
depend on old events still being in the log — it is the beyond-retention proof. Requires the images
built with ADR-0025/0026/0027 and `curl` locally (calls the internal management port via
port-forward).

## What to watch (Grafana)

| Layer | Panel / query | Healthy signal |
|-------|---------------|----------------|
| Rebuild lag | `kafka_consumergroup_lag{consumergroup="search-service"}` | spikes to the full backlog after each offset reset, drains to 0 per phase |
| Read model | row counts of `flight_projections` / `room_type_availability` | drop to 0 on wipe, climb back to the baseline |
| Ordering (optional) | `atlas_search_availability_orphaned_total` (proposed meter) | 0 under ordered replay; > 0 in the reversed-order control |

## Success criteria

- Counts of all read-model tables after the ordered rebuild equal the pre-wipe counts.
- Semantic checksums (catalog + availability, by natural key) match BEFORE == AFTER.
- No `reserved`/`version` drift on flights or hotel nights.
- Control (if run): reversed order leaves `reserved` short → convergence fails, proving the
  catalog-before-availability sequencing requirement.

## Results & decisions

Record runs in [`RESULTS.md`](./RESULTS.md). Decisions:

- [`rebuild-source-of-truth.md`](./rebuild-source-of-truth.md) — compaction vs. republish; **Strategy
  B (republish/resync)** chosen to close the beyond-retention gap.
- [ADR-0025](../../docs/adr/ADR-0025-flight-catalog-resync.md) (Flight) /
  [ADR-0026](../../docs/adr/ADR-0026-hotel-catalog-resync.md) (Hotel) /
  [ADR-0027](../../docs/adr/ADR-0027-inventory-availability-resync.md) (Inventory) — the per-owner
  resync capability (`POST /actuator/resync`), **COMPLETED**.
