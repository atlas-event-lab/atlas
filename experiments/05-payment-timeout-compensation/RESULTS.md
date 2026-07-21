# Experiment 05 — Results

Record each run: date, git SHA, batch size, and whether every compensation invariant held.

## Run template

```
### 2026-07-20

Config:   N=20 VUS=5 SMOKE_N=3 SCENARIO=BOTH
Window:   fault applied <11:40:41> → restored <11:43:46>

Batch outcome:
- bookings created / EXPIRED / CONFIRMED       : 20 / 20 / 0   (expected N / N / 0)
- payments TIMED_OUT / PROCESSING              : 20 / 0       (expected N / 0)
- reservations left RESERVED                   : 0           (expected 0)

Compensation (before -> after, must return to baseline):
- inventory flights reserved : 2788 -> 2788
- inventory hotels reserved  : 5576 -> 5576
- search flights reserved    : 2788 -> 2788
- search hotels reserved     : 5576 -> 5576

Meters (fault-window pods):
- atlas_payment_provider_calls_total{outcome=timeout} : 20   (expected N)
- atlas_payment_recoveries_total                      : 0   (expected 0 — sweeper stayed out)
- atlas_inventory_units_total{action=released} delta  : 40   (≈ batch units) - SCENARIO=both, 1 flight and 1 hotel for each booking event
- atlas_inventory_oversell_attempts_total             : 0   (expected 0)

Post-restore smoke:
- bookings CONFIRMED / payments SUCCEEDED : 3 / 3   (expected SMOKE_N / SMOKE_N)

Verdict: PASS / FAIL — <PASS>
```

