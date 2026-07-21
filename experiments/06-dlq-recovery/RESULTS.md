# Experiment 06 — DLQ Recovery · Results

> Blocked on **ADR-0022** (payment-service `@DltHandler` replay + `atlas_payment_dlq_*` meters —
> see [`dlq-replay-payment.md`](./dlq-replay-payment.md)). No runs recorded yet.

## Run log

| Date | Image / commit | N / VUS / POISON_N | Parked (validation / retries_exhausted) | Replayed (reprocessed / quarantined) | Double charges | recoveries_total | Verdict |
|------|----------------|--------------------|-----------------------------------------|--------------------------------------|----------------|------------------|---------|
| —    | —              | —                  | —                                       | —                                    | —              | —                | —       |

## Notes

- Record the meter readout from live pods across the replay window (counters are per-process,
  ADR-0020 restart caveat).
- Attach `k6-batch.log` / `k6-smoke.log` and the DLQ backlog graph screenshot per run.
