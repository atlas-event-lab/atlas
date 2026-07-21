# Experiment 03 — Results

Record each replay run: date, git SHA, replay depth, and whether every invariant held.

## Run template

```
### 2026-07-18

Config:   TOPIC=booking.created GROUP=inventory-service REPLAY_N=106
Replayed: <events redelivered = lag after reset>

Persistent invariants (before -> after, must be UNCHANGED):
- consumed_events count : … -> 0
- reservations count    : … -> 0
- flight reserved_count : … -> 0
- hotel reserved        : … -> 0
- outbox count          : … -> 0

Visible dedup (after resume):
- atlas_inventory_events_skipped_total{reason=duplicate} : 106   (expected ≈ replayed)
- atlas_inventory_reservations_total{result=reserved}    : 0  (expected 0)
- atlas_inventory_oversell_attempts_total                : 0   (expected 0)

Verdict: PASS / FAIL — <PASSED>
Notes:
```

_No runs recorded yet._
