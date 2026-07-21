---
adr_id: ADR-0013
title: Claim-based outbox polling (SKIP LOCKED) + batched publish to end duplicate publishing and lift relay throughput
service: Cross-cutting
status: COMPLETED
date: 2026-07-10
depends_on:
  - EVT-009
  - EVT-005
  - ADR-0007
  - ADR-0009
---

# ADR-0013 — Claim-based outbox polling + batched publish for the Phase-1 relay

# Status

`PENDING` (created 2026-07-10). Refines the **relay mechanics** of the Transactional Outbox
(`EVT-009`, coding-standards.md §Outbox & Event Publishing); it does
**not** change the outbox table shape, the write path, or event contracts.

Applies uniformly to **every service that owns an outbox relay**: booking, inventory, payment,
flight, hotel. The relay is the same copied component in each, so this is recorded as **one
Cross-cutting ADR** (as with ADR-0006 and ADR-0012) rather than five near-identical siblings;
see [Scope note](#scope-note) for the `DR-002` rationale.

Implementation note: both the **claim-based polling** (§Decision 1) and the **batched publish**
(§Decision 2) are now implemented in all five relays — `OutboxRepository.claimBatchForPublishing()`
(native `FOR UPDATE SKIP LOCKED`) called from a `@Transactional publishPending()`, plus the
dispatch → flush → await → `saveAll` publish loop. A Testcontainers concurrency test in
booking-service (`OutboxSkipLockedConcurrencyTest`) proves two concurrent claims are disjoint.
This ADR stays `PENDING` until the change builds green, the `coding-standards.md §Outbox` wording
is updated, and it merges in every listed service (`DR-003`).

# Context

Load testing (experiment `01-high-booking-concurrency`, run 2026-07-10 at `TARGET_RPS=60`,
`RAMP=2m`, `HOLD=6m`, scenario `both`) surfaced two reinforcing failures in the Phase-1
outbox relay. Booking completion time degraded from ~4–6 s early in the hold to **up to
~15 min** for the last bookings — the signature of an unbounded queue building faster than it
drains.

**1. Systematic duplicate publishing.** The relay is a `@Scheduled` poller whose read is a
plain, unlocked query:

```java
@Scheduled(fixedDelayString = "${atlas.outbox.poll-interval-ms:2000}")
public void publishPending() {
    var batch = outboxRepository.findTop100ByStatusInOrderByCreatedAtAsc(UNPUBLISHED); // plain SELECT
    for (var event : batch) publish(event);   // kafkaTemplate.send(...).get(); then markPublished
}
```

There is **no row claim** (`FOR UPDATE SKIP LOCKED`), **no intermediate `IN_PROGRESS`
state**, and **no `@Version`** on `OutboxEvent`. The job runs independently on **every
replica**. With booking at 4 pods and inventory at 3, all replicas read the **same** top-100
`PENDING` rows every 2 s and publish them all. This is duplication *by construction*, not a
race that "might" happen. It matches the measurements exactly:

| Signal | Observation |
|---|---|
| booking `booking.created` emitted | ~110 events/s for a 60 req/s offered load (~1.8×; not 4× because some rows flip to `PUBLISHED` before the slower pods commit their read) |
| inventory idempotency drops | ~31 k duplicates out of ~32 k events consumed |
| payment idempotency drops | ~11 k duplicate events |

Consumers already dedupe on `eventId` (`EVT-005`), so this produced **no data corruption** —
but it is pure waste, and it is the amplifier of the second problem.

**2. Insufficient relay throughput — and the duplicates make it worse.** The publish loop is
**serial and blocking**: `kafkaTemplate.send(...).get()` waits on the broker ack for each
message, one at a time, on a single thread, with `fixedDelay` adding the 2 s gap *after* the
batch completes. So the real ceiling is below the naive "100 rows / 2 s = 50 msg/s per pod".
Inventory must additionally publish **3 outbox rows per `booking.created`**
(`inventory.reserved` keyed by `bookingId`, plus `inventory.flight.reserved` and
`inventory.hotel.reserved` keyed by `reservationId`), so 60 bookings/s demands **180 outbox
msg/s**. The observed peak was ~90 msg/s across 3 pods — and much of that 90 was **duplicate
re-publishing**, so useful throughput was a fraction of it. Demand (180/s) far exceeded useful
service rate; the outbox backlog grew through the hold and drained for ~15 min afterward
(inventory outbox rows showed publish delays up to ~12 min; booking up to ~3 min).

Memory pinned at ~100 % of request (limit not far above) added GC pressure that stole CPU from
the relay — a secondary amplifier, not the root cause.

> Measurement caveat: because two pods both `save(markPublished)` the same row, `published_at`
> reflects whichever pod wrote last, so the 3 min / 12 min figures are contaminated by the
> duplication. The backlog is real; the exact tail should be re-measured after Decision 1.

**Root cause, one sentence.** The relay reads without claiming and publishes without batching,
so N replicas turn into N× redundant work over a single-threaded, per-message-blocking
pipeline.

# Decision

Keep the Phase-1 `@Scheduled` relay (CDC/Debezium remains a **later phase**, see §Non-goals),
and fix its mechanics in two parts, applied to **all five outbox services**.

## 1. Claim-based polling with `FOR UPDATE SKIP LOCKED` (the load-bearing fix)

Replace the unlocked read with a claim so each poll grabs a **disjoint** batch that no other
replica can see:

```java
@Query(value = """
        SELECT * FROM outbox
        WHERE status IN ('PENDING', 'FAILED')
        ORDER BY created_at
        LIMIT 100
        FOR UPDATE SKIP LOCKED
        """, nativeQuery = true)
List<OutboxEvent> claimBatchForPublishing();
```

The claim + publish + status write-back run in the poll's transaction, so the locked rows are
released only once marked. Effect: N replicas stop colliding and instead process **N disjoint
batches in parallel** — the same pods that were N× waste become N× useful throughput, and the
steady-state duplicate storm disappears. Delivery stays **at-least-once** (a crash between the
Kafka ack and the status write re-publishes the row on a later poll), which is exactly what the
`eventId` consumer dedupe (`EVT-005`) already covers.

`ShedLock` (single-pod relay) was considered and **rejected**: it would fix duplication by
serializing the relay to one pod, which is the opposite of what a throughput-bound workload
needs. `SKIP LOCKED` fixes correctness **and** scales horizontally.

## 2. Batched / pipelined publish (implemented)

Replace the per-message `send().get()` with: dispatch every send in the batch without blocking,
`flush()` once, then await each ack and `saveAll` the batch:

```java
List<Dispatch> dispatched = new ArrayList<>(batch.size());
for (OutboxEvent e : batch) {
    dispatched.add(new Dispatch(e, kafkaTemplate.send(resolveTopic(e.getEventType()),
            e.getAggregateId().toString(), e.getPayload())));
}
kafkaTemplate.flush();
for (Dispatch d : dispatched) { try { d.future().get(); d.event().markPublished(now); }
                                catch (Exception ex) { d.event().markFailed(); } }
outboxRepository.saveAll(batch);
```

Producers get modest batching (`linger.ms=20`, `batch.size=65536`) so those pipelined sends
coalesce into few broker round-trips instead of one request per row. This turns the relay from
serial-ack-bound into throughput-bound, multiplying msg/s per pod. (Kafka's default idempotent
producer with `acks=all` preserves per-partition order under this pipelining.)

## 3. Ordering is safe under parallel, at-least-once publishing

`SKIP LOCKED` across pods (and pipelined sends) means two rows for the same key may be published
out of order. This is **acceptable** given how consumers are built:

- **Booking, Inventory, Payment** do **not** require strict per-key order. They tolerate
  out-of-order and duplicate delivery via `eventId` idempotency plus state-machine guards that
  defer premature Saga events (ADR-0007). No change needed.
- **Search** *does* require order for `inventory.flight.reserved` / `inventory.hotel.reserved`,
  and that requirement is **already satisfied** by a **version field carried in the event
  payload**: Search applies last-writer-wins by version, so a later-versioned event never gets
  overwritten by an out-of-order earlier one (per ADR-0009's absolute + versioned consumption).

Therefore no ordering guarantee needs to be added to the relay; the existing consumer-side
mechanisms already make reordered/at-least-once delivery correct end-to-end.

## 4. No change to the outbox contract

The table columns, the "write row + state change in one `@Transactional` method" rule, the
`PENDING/PUBLISHED/FAILED` statuses, and all event contracts are untouched. Only *how the relay
reads and ships rows* changes.

# Addendum — adaptive relay scheduling (2026-07-10)

The fixed 2 s `@Scheduled` poll is replaced by an **adaptive** scheduler (`OutboxRelayScheduler`,
one per outbox service) combining two levers:

- **Drain-in-loop.** Within one cycle it keeps claiming batches — each its own transaction, via the
  `OutboxRelay` proxy — until a claim returns fewer than `BATCH_LIMIT` (100) rows, or
  `max-drain-loops` is hit. A traffic burst is cleared in one cycle instead of across many
  fixed-interval polls.
- **Dynamic interval.** A Spring `Trigger` sets the next delay to `min-interval-ms` (default
  250 ms) after any cycle that did work, and doubles it up to `max-interval-ms` (default 5 s) after
  an idle cycle. The relay is thus near-real-time under load and quiet at rest.

`publishPending()` now returns the number of rows published (the drain/backoff signal) and no
longer carries `@Scheduled`. Config keys `atlas.outbox.{min-interval-ms,max-interval-ms,max-drain-loops}`
replace `poll-interval-ms`, and `spring.task.scheduling.pool.size` is raised to 3 so a long drain
cycle cannot starve the other `@Scheduled` safety-net jobs (expiration sweeps, calendar rolling).

This is orthogonal to the SKIP LOCKED claim (§Decision 1): each pod adapts to the *disjoint* batches
it claims, so replicas self-balance without coordination, and it narrows the latency gap to the CDC
endgame while staying a poller. Bounds to respect: keep `min-interval-ms` high enough that an empty
claim (index-backed on `(status, created_at)`) stays cheap; a batch of persistently-`FAILED` rows is
capped per cycle by `max-drain-loops` and retried on the next cycle rather than spun on.

# Non-goals (explicitly deferred)

- **CDC / Debezium relay.** The WAL-based relay that removes polling, scheduler contention and
  duplicate-by-design entirely stays a **later phase** (project.md Future
  Evolution). This ADR keeps the `@Scheduled` poller and makes it correct and fast enough for
  current load.
- **`PUBLISHED`-row retention/cleanup tuning** beyond what `EVT-009` already mandates.
- **Per-service autoscaling / partition counts** — covered by the Experiment 01 scaling docs
  (`payment-service-scaling.md`, `cart-inventory-scaling.md`), not here.

# Consequences

**Positive.** Eliminates steady-state duplicate publishing across all outbox services (removing
the ~30 k/~11 k idempotency-drop load on inventory/payment); converts multi-pod redundancy into
real parallel throughput; combined with batched publish, lets the relay clear the 180 msg/s
inventory demand and drain the backlog within the hold instead of ~15 min after; cuts wasted CPU
and DLQ/idempotency-table churn. No contract or consumer changes required.

**Negative / trade-offs.** The claim query is a native `FOR UPDATE SKIP LOCKED` (slightly less
portable than derived JPA queries, Postgres-specific — acceptable, the platform is Postgres).
Per-key ordering across pods is no longer guaranteed at the relay; this is accepted and covered
by consumer-side idempotency/versioning (§Decision 3). Delivery remains at-least-once by design.

# Documents to update at implementation

- `coding-standards.md §Outbox & Event Publishing` — document the **claim-based** relay read
  (`FOR UPDATE SKIP LOCKED`, disjoint batch per replica) and the **batched publish** (dispatch
  → flush → await → `saveAll`) as the Phase-1 relay standard; note ordering is delegated to
  consumer idempotency (`EVT-005`) + payload versioning where strict order is required.
- Each outbox service (`booking`, `inventory`, `payment`, `flight`, `hotel`):
  - `OutboxRepository` — add `claimBatchForPublishing()` (native `SKIP LOCKED`) and retire the
    unlocked `findTop100ByStatusInOrderByCreatedAtAsc`.
  - `OutboxRelay` — call the claim query inside the scheduled transaction; the batched publish
    is already in place.
  - tests — a two-pod (two-thread) test asserting no row is claimed twice; the existing
    publish/fail unit tests already pass against the batched flow.
- `SPECS-INDEX.md` and `adr/README.md` — register this ADR (done alongside this file).

# Scope note

`DR-002` says "one ADR per affected service." This change is a **single, identical mechanism**
copied verbatim into five relays, so a single **Cross-cutting** ADR (the precedent set by
ADR-0006 and ADR-0012) keeps the decision coherent and avoids five near-duplicate records. Each
service is still implementable independently from the per-service checklist above; if the team
prefers, per-service `COMPLETED` tracking can be added as sub-rows without changing the
decision.

# Alternatives considered (not chosen)

- **ShedLock single-pod relay** — fixes duplicates by serialization; rejected because it caps
  the relay at one pod's throughput, the wrong trade for a throughput-bound stage (§Decision 1).
- **Optimistic `@Version` on `OutboxEvent`** — would detect concurrent publish attempts but via
  lost-update *failures* (retries/churn), not by preventing the redundant Kafka sends; `SKIP
  LOCKED` avoids the wasted publish entirely.
- **Shard the outbox by pod (hash of `aggregate_id`)** — preserves strict per-key order per pod,
  but adds partition-assignment machinery the consumers don't need (their idempotency/versioning
  already tolerates reordering). Revisit only if a future consumer demands broker-independent
  strict order.
- **Jump straight to CDC/Debezium** — the correct endgame, but a platform-level change; deferred
  to keep Phase-1 simple (§Non-goals).
