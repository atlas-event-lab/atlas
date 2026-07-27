# What is actually derivable — scoping the rebuild comparison

**Origin:** Experiment 07 — Read Model Rebuild · **Status:** implemented (runbook change, no service code)
**Services affected:** none — this is a change to the experiment's success criterion

> Why the 2026-07-26 run reported a failure that was not one, what part of the read model events
> genuinely determine, and how the verdict was re-scoped to match the claim.

## 1. The run that surfaced it

```
FAIL flight_projections DIVERGED: rows 10000->10000 · sum 73686383fe52->6b267c0182a7
PASS hotel_projections converged (rows=2508)
PASS hotel_room_types converged (rows=8735)
FAIL room_type_availability DIVERGED: rows 3189173->3188275 · sum 46464583b951->ad94fb839ea7
```

The arithmetic on the availability table tells the story:

```
8,735 room types x 365 nights = 3,188,275   ← exactly the AFTER count
BEFORE = 3,189,173 = AFTER + 898
```

The rebuild produced a **perfect** calendar: every room type in the catalog with exactly one night
per horizon day, which is what `materializeHotelCalendar` writes by construction. Nothing was
missing from the rebuild. There were **898 extra rows in the live table**, and the comparison
called that a failure.

## 2. The read model is only partly event-derived

Experiment 07's hypothesis is that the CQRS read side is *fully derivable by replaying events*.
For `flight_projections`, `hotel_projections` and `hotel_room_types` that holds — they are pure
functions of the catalog events, and all three converged.

`room_type_availability` is different. Two mechanisms put rows in it that no replay can
reproduce:

**Processing-time anchoring.** `materializeHotelCalendar` computes its window from
`LocalDate.now(clock)` **at the moment the event is consumed**, not from anything in the event. A
hotel whose `hotel.created` was processed three days ago holds `[T-3, T-3+365)`. Replay that exact
same event today and it produces `[T, T+365)`. The event did not change; the rows did.

**A maintenance job on a timer.** `HotelProjectionRollingScheduler.rollAndPurge()` runs every 24h:
`rollHorizonForward` adds frontier nights, and `purgePastNights` only deletes nights older than
`purge-after-days` (7). So the live table legitimately carries up to a week of **past** nights that
a freshly rebuilt calendar will never contain.

Together these explain the 898: accumulated per-hotel window drift plus past nights awaiting
purge. A whole-table comparison could only pass if the entire dataset had been created today and
no maintenance job had run since — which is not a property of the system, it is a coincidence.

> Worth noting what did *not* happen: the scheduler did not interfere *during* the run.
> `rollHorizonForward` targets `today + horizon - 1`, a night the materialization has already
> created, so `alreadyExtended` covers every room type and it creates none. If it had fired you
> would see `8,735 x 366 = 3,197,010` rows instead.

## 3. The decision

Two options were on the table:

- **(A) Scope the checksum to the derivable window** — compare only
  `[today, today + horizon)`, the range the events determine.
- **(B) Leave the comparison and restate the hypothesis** — declare that derivability applies to
  the current window and not to maintenance residue.

**(A) was chosen**, because it makes the experiment *automatically* reproducible rather than
requiring a human to interpret every diff. (B) is more honest about the system's guarantee but
leaves a red verdict that a reader has to explain away every time — and an experiment whose
failure mode is "read the notes" stops being a test.

The two are not exclusive: the runbook now scopes the assertion **and** reports the residue, so
the non-derivable part stays visible instead of being quietly dropped.

## 4. What changed in `runbook.sh`

**The comparison window.** `table_count` and `table_checksum` filter
`room_type_availability` to `[SNAPSHOT_DATE, SNAPSHOT_DATE + HORIZON_DAYS)`. `HORIZON_DAYS`
(default 365) is a new env var and **must** match `atlas.search.hotel.horizon-days`.

**Residue is reported, not asserted.** `residue_count()` counts rows outside the window and prints
them in both snapshots. A rebuild is expected to take it to 0; that is information, not a verdict.

**The date is pinned once.** `snapshot_setup()` reads `CURRENT_DATE` from Postgres a single time
and both snapshots reuse it. Calling `CURRENT_DATE` twice would shift the window if the run
crossed midnight, turning a clock tick into a spurious failure.

**Midnight rollover now fails loudly.** `assert_same_day()` re-checks the date before the verdict
and aborts with an explicit message if it moved. The README asked you to "run same-day"; this
enforces it rather than trusting it.

## 5. `flight_projections` is a separate, still-open finding

The availability scoping does not explain the flight divergence: 10,000 rows before and after,
same ids, different content — so a *value* changed, almost certainly `reserved`/`version`, which
come from the availability replay. Flight availability is scalar (ADR-0008), with no calendar and
no clock dependence, so the drift explanation does not apply.

The most likely cause is a gap in the retention preflight. It guards only the catalog:

```bash
START="$(topic_start_offsets "${CATALOG_TOPICS[@]}")"
```

The six `AVAIL_TOPICS` are never checked. If `inventory.flight.reserved|released|expired` have
aged out of the 7-day retention, replaying from `earliest` rebuilds `reserved` from a partial
history and converges to a different value — with nothing aborting the run. That is the **same
class of bug** already found and fixed on 2026-07-20, applied to only half the topics.

To confirm before changing anything:

```bash
kubectl -n atlas-data exec atlas-dual-role-0 -- /opt/kafka/bin/kafka-get-offsets.sh \
  --bootstrap-server localhost:9092 --topic inventory.flight.reserved --time -2
```

A log-start offset greater than 0 means history has been deleted and an `offsets` rebuild cannot
reproduce `reserved` — the case `REBUILD=resync` exists for. **This has deliberately not been
changed yet**: extending the guard is a one-line fix, but it should be made once the cause is
confirmed rather than on suspicion.
