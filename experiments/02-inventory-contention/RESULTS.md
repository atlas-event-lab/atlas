# Experiment 02 — Results

Record each run here: date, git SHA, the knobs used, and whether the invariant held.
Keep raw k6 summaries alongside (`--summary-export=summary.json`).

## Run template

```
### YYYY-MM-DD — <variant> — <SHA>

Config:   VARIANT=… N=400 Q=1 C=314 (target resource: <flightId=b931959d-8a9f-42c1-b134-12cf606a10e7 / route+date= FRA	BSB 2026-07-11 >)
Payment:  WireMock always-approve

Result:
- Oversell (isOversold ever true)? NO           ← must be NO
- reservedCount / totalCapacity (settled): 314/314
- available floored at 0? 0
- Winners (INVENTORY_RESERVED): 314  expected floor(C/q)=…
- Rejected (FAILED via INVENTORY_REJECTED):0
- Stuck PENDING:0                               ← must be 0
- Conservation: winners×q == reservedCount? 314
- Deadlock aborts (deadlock variant): 0          ← must be 0

Verdict: PASS / FAIL — <PASS>
Notes:
```

_No runs recorded yet — the runnable artifacts are still to be built (see README ›
"What we need to build")._
