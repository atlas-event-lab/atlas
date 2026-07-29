# Experiment 04 — Results

Record each crash run: date, git SHA, batch size, kill mode/timing, and whether every
invariant held.

## Run template

```
### 2026-07-19 — Test-1

Config:   N=1000 VUS=20 KILL_AFTER=333 KILL_MODE=exec|force-delete SCENARIO=BOTH
Kill:     at <02:11:03>, payments-in-window at kill = 435, pods killed = 2
Peak lag: 226 on inventory.reserved right after recovery

Invariants:
- double charge (bookings with >1 payment)         : 0   (expected 0)
- final lag on inventory.reserved                  : 0   (expected 0)
- batch bookings created                           : 1000/N
- CONFIRMED / FAILED / EXPIRED / in-flight         : 995 / 5 / 0 / 0
- W2 orphans recovered by the sweeper (ADR-0021)   : 0   (expected 0–few; ALL must converge —
                                                          atlas_payment_recoveries_total == this;
                                                          payments left PROCESSING at the end: 0)
- consumed_events delta                            : 997   (expected = distinct events processed)
- wiremock POST /payments delta vs payments created: 997 vs 995  (≈ equal; never ≈ 2×)

Dedup evidence (post-recovery meters — counters start at 0 on the replacement pods, ADR-0020):
- atlas_payment_events_skipped_total{reason=duplicate}       : 43   (≈ redeliveries, W2+W3)
- atlas_payment_events_skipped_total{reason=already_charged} : 0   (expected 0; only new-eventId re-triggers)
- atlas_payment_recoveries_total (sum over outcome)          : 2   (== W2 count)
- atlas_payment_provider_calls_total (sum over outcome)      : 531   (== payments created after the kill)
- log lines "Skipping duplicate" / "already exists"          : 43 / 0   (secondary signal)

Verdict: PASS / FAIL — <PASS>
Notes:   (rebalance behavior, KEDA scaling during the outage, anything surprising)
The 2 recovered payments ended in CONFIRMED bookings.
The 5 failed bookings are due to inventory restrictions (expected scenario)
```

---

```
### 2026-07-19 — Test-2

Config:   N=1000 VUS=20 KILL_AFTER=333 KILL_MODE=exec|force-delete SCENARIO=BOTH
Kill:     at <02:52:54>, payments-in-window at kill = 473, pods killed = 2
Peak lag: 251 on inventory.reserved right after recovery

Invariants:
- double charge (bookings with >1 payment)         : 0   (expected 0)
- final lag on inventory.reserved                  : 0   (expected 0)
- batch bookings created                           : 1000/N
- CONFIRMED / FAILED / EXPIRED / in-flight         : 988 / 12 / 0 / 0
- W2 orphans recovered by the sweeper (ADR-0021)   : 0   (expected 0–few; ALL must converge —
                                                          atlas_payment_recoveries_total == this;
                                                          payments left PROCESSING at the end: 0)
- consumed_events delta                            : 988   (expected = distinct events processed)
- wiremock POST /payments delta vs payments created: 990 vs 988  (≈ equal; never ≈ 2×)

Dedup evidence (post-recovery meters — counters start at 0 on the replacement pods, ADR-0020):
- atlas_payment_events_skipped_total{reason=duplicate}       : 46   (≈ redeliveries, W2+W3)
- atlas_payment_events_skipped_total{reason=already_charged} : 0   (expected 0; only new-eventId re-triggers)
- atlas_payment_recoveries_total (sum over outcome)          : 2   (== W2 count)
- atlas_payment_provider_calls_total (sum over outcome)      : -   (== payments created after the kill)
- log lines "Skipping duplicate" / "already exists"          : 46 / 0   (secondary signal)

Verdict: PASS / FAIL — <PASS>
Notes:   (rebalance behavior, KEDA scaling during the outage, anything surprising)
The 2 recovered payments ended in CONFIRMED bookings.
12 bookings failed due to inventory restrictions
```
