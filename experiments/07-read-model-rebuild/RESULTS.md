# Experiment 07 — Read Model Rebuild · Results

> Within-retention rebuild proof (search-side, no code change). Beyond-retention rebuild is planned
> via Strategy B resync (ADR-0025/0026/0027) — see
> [`rebuild-source-of-truth.md`](./rebuild-source-of-truth.md).

## Run log

| Date | Mode | Scope | Result | Notes |
|------|------|-------|--------|-------|
| 2026-07-20 | offsets | all | **FAIL (finding)** | Read model (10k flights, 2.5k hotels, 3.27M night rows) rebuilt to **0**. Catalog `*.created` events had aged out of the 7-day retention → replay from `earliest` found nothing → beyond-retention gap confirmed. Exposed **destructively** (wipe ran before verifying the log). Fix: added a preflight retention guard (`log-start offset == 0`) that now aborts `offsets` mode before wiping when history is missing, and points to `REBUILD=resync`. |
| 2026-07-26 | offsets | all | **FAIL (finding)** | Catalog converged (`hotel_projections` 2508, `hotel_room_types` 8735). `room_type_availability` 3189173→**3188275** — but `8735 x 365 = 3188275` **exactly**: the rebuild produced a perfect calendar and the 898 delta was *extra rows in the live table* (past nights pending purge + per-hotel window drift), which no replay can reproduce. Verdict re-scoped to `[today, today+horizon)`; residue now reported, not asserted ([`derivable-scope.md`](./derivable-scope.md)). **Still open:** `flight_projections` diverged with 10000→10000 rows and identical ids, so a value moved — likely `reserved`/`version` rebuilt from a partial log, since the retention preflight checks only `CATALOG_TOPICS` and never the six `AVAIL_TOPICS`. Confirm the availability log-start offsets before changing the guard. |

## Notes

- Run same-day as the snapshot (the hotel night calendar is `today`-relative). This is now
  **enforced**: the runbook pins the date once and aborts if it rolls over mid-run, instead of
  reporting the rollover as divergence.
- `room_type_availability` is asserted only inside `[today, today + HORIZON_DAYS)`. Keep
  `HORIZON_DAYS` in step with `atlas.search.hotel.horizon-days` or the window will not match what
  the service materializes.
- The dataset must have been produced within the last 7 days (retention), else replay is incomplete
  by design — that is the gap Strategy B closes.
- `CONTROL=1` demonstrates the catalog-before-availability requirement (reversed order → `reserved`
  short). It leaves the read model in the control state; re-run the ordered rebuild to restore.
