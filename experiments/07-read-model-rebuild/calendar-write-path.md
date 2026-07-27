# Calendar write path — why replaying `hotel.created` was slow

**Origin:** Experiment 07 — Read Model Rebuild · **Phase:** 7 · **Status:** implemented (phase 1)
**Services affected:** search-service · **ADR:** [ADR-0029](../../docs/adr/ADR-0029-search-calendar-write-path.md)

> The narrative half of the rebuild-performance work: what was actually slow, why the obvious fix
> was the wrong first move, what we changed, and what still has to be measured. Same convention as
> `01-high-booking-concurrency/payment-service-scaling.md` ↔ ADR-0015.

## 1. The symptom, and the first hypothesis

Replaying the catalog during a rebuild is dominated by `hotel.created`. The proposal on the table
was to parallelise it: raise the topic from 3 to 12 partitions and run 12 consumers
(`concurrency: 4` × 3 pods).

The reasoning behind it was sound — **one catalog event fans out into a year of availability
rows**, so per-message cost is unusually high and the topic looks like a natural candidate for
scale-out. That part of the diagnosis was right and is what sent us looking in the right place.

But three things about the premise did not survive checking the code.

**`concurrency` is not configured in search-service at all.** Not in `application.yml`, not on the
`@KafkaListener`, not in `values/search.yaml`. The only service that sets it is payment
(`KAFKA_CONCURRENCY: "3"`). Spring Kafka's default is one thread per listener per pod.

**`values/search.yaml` is `minReplicas: 1, maxReplicas: 3`.** There is no guaranteed pod count. A
rebuild generates no HTTP traffic, so the CPU-driven HPA may well leave search at one replica.

Together: the "3 consumers today" baseline is really **1–3, depending on where the HPA happens to
be**, and "4 × 3 pods = 12" only holds at max replicas.

## 2. What was actually slow

`materializeHotelCalendar` wrote one row per room type per night — with two multipliers on top.

**Every row was its own round-trip.** The write sat inside a nested loop:

```java
for (RoomTypeEvent roomType : roomTypes) {
    for (LocalDate date = today; date.isBefore(endExclusive); date = date.plusDays(1)) {
        if (!existingDates.contains(date)) {
            roomTypeAvailabilityRepository.save(new RoomTypeNightAvailabilityProjection(...));
        }
    }
}
```

and `application.yml` configured no `hibernate.jdbc.batch_size`, so nothing grouped the inserts.

**And each `save()` was a `merge()`, not a `persist()` — so each row cost a SELECT as well.** This
is the subtle one. `SimpleJpaRepository.save()` branches on `isNew()`:

```java
if (entityInformation.isNew(entity)) { em.persist(entity); } else { return em.merge(entity); }
```

`isNew()` looks for a JPA `@Version` field; failing that it falls back to "is the id null?". The
entity has neither escape hatch: the `@Id` is assigned in the application (`UUID.randomUUID()`),
and its `version` column is a **domain** guard for absolute `reserved` updates (ADR-0009), a plain
`long` with no `@Version` annotation. So `isNew()` answered `false` for every row we had just
constructed, and Hibernate issued a `SELECT` before each `INSERT` to find out whether it already
existed.

The arithmetic, using this experiment's own dataset (2,500 hotels, 3.27M night rows → ~3.6 room
types per hotel):

```
per hotel.created:  ~1,300 rows x 2 round-trips  ≈  2,600
full rebuild:       2,500 events                 ≈  6.5M round-trips
```

## 3. Why parallelism was the wrong first move

Twelve consumers instead of three is a **4x** ceiling. The write path carried a factor of roughly
a thousand. Worse, the two do not compose: each consumer still performs its ~2,600 sequential
round-trips against the same database, and `upsertHotel` is `@Transactional`, so a consumer holds
a pooled connection for the entire materialization. With `maximum-pool-size: 10` per pod, adding
consumers converts a slow serial path into a contended one — the speedup lands well under 4x.

There were also two costs specific to repartitioning:

- **It is a one-way door.** Kafka can raise a topic's partition count and never lower it.
- **It changes the key → partition mapping.** `OutboxRelay` publishes with `aggregateId` — the
  `hotelId` — as the key. After the change, a hotel's existing events stay where they are while
  its future events hash elsewhere, so `created` and a later `deleted` for the same hotel can sit
  in different partitions and be consumed out of order. `upsertHotel` is guarded by `eventId` and
  availability by `version`, but `status` under `disableHotel` vs `upsertHotel` is last-writer-wins
  by arrival. Replay from `earliest` — exactly what this experiment does — is where that surfaces.

None of this makes partitioning wrong. It makes it the *second* step, taken on evidence, once the
write path is no longer the constraint.

## 4. What we changed (phase 1)

Three changes, all inside search-service, no infrastructure touched — see
[ADR-0029](../../docs/adr/ADR-0029-search-calendar-write-path.md).

**`RoomTypeNightAvailabilityProjection implements Persistable<UUID>`** with a `@Transient` newness
flag set in the constructor and cleared by `@PostLoad` / `@PostPersist`. New rows insert; loaded
rows still update. The redundant `SELECT` per row disappears.

**Both calendar writers batch.** `materializeHotelCalendar` and
`HotelProjectionMaintenanceServiceImpl.rollHorizonForward` collect their new rows and issue a
single `saveAll`. The rolling-window job had the identical pattern and runs daily across the whole
catalog, so it inherits the same win.

**JDBC batching is on**: `hibernate.jdbc.batch_size: 100`, `order_inserts`, `order_updates`. The
ordering flags matter — batching only groups same-type statements when they are adjacent.

Rows that already exist are still mutated through dirty checking (capacity is catalog-owned), which
now batches as `UPDATE`s for the same reason.

## 5. Validation

`ProjectionServiceImplTest` now asserts **one `saveAll` and zero `save()`** calls, and that every
row reports `isNew() == true`. That is deliberate: it pins both halves of the fix, so a future
refactor back to a row-at-a-time loop fails the suite rather than silently restoring the old cost.

Behaviour is unchanged by construction — same rows, same values, same transaction. Which means the
**Experiment 07 checksum comparison is the right proof**: run the rebuild, and the before/after
checksums must still match exactly. If they do, the optimisation is semantically clean.

## 6. Still to measure

This has not yet been run against the cluster. What to capture on the next Experiment 07 run,
using the dashboard (`atlas-exp07-dashboard.yaml`):

- **Wall-clock of the catalog phase** — the drain of `hotel.created` lag in *Lag by topic*. This is
  the headline number, and there is no "before" recorded yet, so capture a baseline first if the
  current image is still deployed.
- **`search_db` write rate** — inserts/s should climb sharply; the same total rows in less time.
- **Checksums identical** — the correctness gate.

Only if the catalog phase is still the bottleneck after this does partitioning become worth its
one-way door. At that point the decision should be made with the measured numbers, and the
`concurrency` and `minReplicas` gaps in §1 fixed as part of it — otherwise the consumer count
remains whatever the HPA happens to have chosen.
