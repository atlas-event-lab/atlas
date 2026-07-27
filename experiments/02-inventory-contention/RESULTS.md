# Experiment 02 — Results

Record each run here: date, git SHA, the knobs used, and whether the invariant held.
Keep raw k6 summaries alongside (`--summary-export=summary.json`).

The pass/fail is not a judgement call: `teardown()` in [`load.js`](./load.js) asserts the
invariant and **exits non-zero** if it breaks. A run that finished green is a PASS; copy its
numbers here so the claim is auditable rather than asserted.

---

## Runs

### 2026-07-11 — `unit` variant — PASS

```
Config:   N=400  Q=1  C=314  SCENARIO=flight
Target:   flightId b931959d-8a9f-42c1-b134-12cf606a10e7  (FRA → BSB, 2026-07-11)
Payment:  WireMock always-approve
```

| Check | Expected | Observed | |
|-------|----------|----------|---|
| Oversell (`isOversold()` ever true) | NO | **NO** | ✅ |
| `reservedCount` / `totalCapacity` (settled) | ≤ 314 | **314 / 314** | ✅ |
| `available` floored at 0 (never negative) | ≥ 0 | **0** | ✅ |
| Winners (`INVENTORY_RESERVED`) | `floor(314/1)` = 314 | **314** | ✅ |
| Conservation (`winners × q == reservedCount`) | 314 | **314** | ✅ |
| Stuck `PENDING` | 0 | **0** | ✅ |
| Deadlock aborts | 0 | **0** | ✅ |
| Rejected (`INVENTORY_REJECTED` → `FAILED`) | 86 | *see note* | ⚠️ |

**Verdict: PASS on the primary invariant.** 400 bookings raced for 314 seats; exactly 314
won, the resource landed precisely at capacity, and `available` floored at 0 without ever
going negative. The pessimistic row lock (`findForUpdate`) serialized the writers as
designed — no oversell, no deadlock, nothing left in flight.

> ⚠️ **Open discrepancy — the rejected count.** The original notes recorded `Rejected: 0`,
> but with `N=400` and 314 winners the arithmetic demands **86** rejections. Both cannot be
> true. Either the tally was never captured (most likely — it is a manual field), or 86
> bookings ended somewhere other than `FAILED`, which would falsify hypothesis 2 ("every
> other booking is cleanly rejected, not errored and not silently dropped"). The primary
> invariant (no oversell) is unaffected either way.
>
> **To close it:** re-run with `--summary-export=summary.json` and record the observed
> number. If it is not 86, that is a real finding — write it up as a `<topic>.md` in this
> folder per the repo convention.

---

## Run template

Copy this block for each new run.

```
### YYYY-MM-DD — <variant: unit | partial | deadlock> — <SHA>

Config:   N=…  Q=…  C=…  SCENARIO=flight|hotel
Target:   <flightId | roomTypeId>  (<origin> → <destiny>, <date>)
Payment:  WireMock always-approve

Result:
- Oversell (isOversold ever true)?              ← must be NO
- reservedCount / totalCapacity (settled):
- available floored at 0 (never negative)?
- Winners (INVENTORY_RESERVED):                 ← expected floor(C/q)
- Rejected (FAILED via INVENTORY_REJECTED):     ← expected N − winners
- Stuck PENDING:                                ← must be 0
- Conservation: winners×q == reservedCount?
- Deadlock aborts (deadlock variant):           ← must be 0

Verdict: PASS | FAIL
Notes:
```

### Variants still unrun

| Variant | Params | Status |
|---------|--------|--------|
| `partial` | `Q=3`, `N=50` | ⏳ not yet run — expect `floor(C/3)` winners, leaving `C mod 3` seats unused |
| `deadlock` | two flights, opposite discovery order | ⏳ not yet run — exercises the deterministic lock ordering |
