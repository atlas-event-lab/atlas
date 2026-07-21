# Experiment 07 — Read Model Rebuild · Results

> Within-retention rebuild proof (search-side, no code change). Beyond-retention rebuild is planned
> via Strategy B resync (ADR-0025/0026/0027) — see
> [`rebuild-source-of-truth.md`](./rebuild-source-of-truth.md).

## Run log

| Date | Mode | Scope | Result | Notes |
|------|------|-------|--------|-------|
| 2026-07-20 | offsets | all | **FAIL (finding)** | Read model (10k flights, 2.5k hotels, 3.27M night rows) rebuilt to **0**. Catalog `*.created` events had aged out of the 7-day retention → replay from `earliest` found nothing → beyond-retention gap confirmed. Exposed **destructively** (wipe ran before verifying the log). Fix: added a preflight retention guard (`log-start offset == 0`) that now aborts `offsets` mode before wiping when history is missing, and points to `REBUILD=resync`. |

## Notes

- Run same-day as the snapshot (the hotel night calendar is `today`-relative).
- The dataset must have been produced within the last 7 days (retention), else replay is incomplete
  by design — that is the gap Strategy B closes.
- `CONTROL=1` demonstrates the catalog-before-availability requirement (reversed order → `reserved`
  short). It leaves the read model in the control state; re-run the ordered rebuild to restore.
