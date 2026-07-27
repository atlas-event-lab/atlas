---
adr_id: ADR-0029
title: Batch the hotel calendar write path in search-service (Persistable + JDBC batching)
service: Search
status: COMPLETED
date: 2026-07-26
depends_on:
  - ADR-0009
---

# ADR-0029 — Hotel calendar write path

# Status

`COMPLETED` (created 2026-07-26). Merged: `RoomTypeNightAvailabilityProjection` implements
`Persistable`, both calendar writers use `saveAll`, and Hibernate JDBC batching is enabled.
Origin: [experiments/07-read-model-rebuild/calendar-write-path.md](../../experiments/07-read-model-rebuild/calendar-write-path.md).

# Context

Experiment 07 rebuilds the CQRS read model by replaying the catalog topics. Replaying
`hotel.created` is by far the slowest part, and the reason is structural rather than accidental:
**one catalog event fans out into a year of availability rows.** `materializeHotelCalendar`
writes one row per room type per night over `horizon-days` (365).

With the Experiment 07 dataset — 2,500 hotels, 3.27M night rows, so ~3.6 room types per hotel —
a single `hotel.created` writes roughly **1,300 rows**, and a full rebuild writes 3.27M.

Two properties of the write path multiplied that cost:

1. **Every row was its own round-trip.** `materializeHotelCalendar` called
   `roomTypeAvailabilityRepository.save(...)` inside a nested loop, and no Hibernate JDBC
   batching was configured, so each row produced its own `INSERT`.

2. **Each `save()` was a `merge()`, not a `persist()`** — so each row cost a `SELECT` *and* an
   `INSERT`. `SimpleJpaRepository.save()` branches on `isNew()`. The entity assigns its `@Id` in
   the application (`UUID.randomUUID()`) and its `version` column is a **domain** guard for
   absolute `reserved` updates (ADR-0009), *not* a JPA `@Version`. With neither a null id nor a
   version field, `isNew()` returns `false` for every freshly constructed row, routing it to
   `EntityManager.merge()`, which issues a `SELECT` to discover whether the row already exists.

The two compound: ~2,600 round-trips per event, ~6.5M for a full rebuild. That is what makes the
replay slow — not consumer parallelism.

**Rejected: more partitions and consumers first.** The original proposal was to raise
`hotel.created` from 3 to 12 partitions and run 12 consumers. It would help, but it is the wrong
first move: it caps at the replica multiplier (~4x) while the write path carries a ~1000x factor;
the gain is further limited by the connection pool, since `upsertHotel` is `@Transactional` and
holds a connection for the whole materialization; raising Kafka partitions is **irreversible**;
and repartitioning changes the `hotelId` → partition mapping, so a hotel's `created` and a later
`deleted` can land in different partitions and lose their relative order — a correctness risk in
precisely the replay Experiment 07 exercises. Partitioning stays available as a later step, on
evidence, once the write path is no longer the constraint.

# Decision

Three changes, all inside search-service:

1. **`RoomTypeNightAvailabilityProjection implements Persistable<UUID>`**, backed by a
   `@Transient` newness flag set in the all-args constructor and cleared by `@PostLoad` /
   `@PostPersist`. New rows are inserted; loaded rows still update. This removes the redundant
   `SELECT` per row.

2. **Batch the writers.** `materializeHotelCalendar` and
   `HotelProjectionMaintenanceServiceImpl.rollHorizonForward` collect their new rows and issue a
   single `saveAll` instead of a `save()` per row.

3. **Enable Hibernate JDBC batching** in `application.yml`: `hibernate.jdbc.batch_size: 100`
   plus `order_inserts` and `order_updates`. The ordering flags are load-bearing — JDBC batching
   only groups statements of the same type when they are adjacent.

Rows that already exist are still mutated in place through dirty checking (capacity is
catalog-owned), which now batches as `UPDATE`s for the same reason.

# Consequences

**Positive.** Round-trips for a `hotel.created` drop from roughly 2,600 to a few dozen batches.
The rebuild in Experiment 07 gets faster without touching Kafka, without an irreversible topic
change, and without introducing an ordering hazard. `rollHorizonForward`, which runs daily across
the whole catalog, benefits identically. No API, contract, schema or event change.

**Negative.** `saveAll` holds the new rows in memory and in the persistence context until commit
— bounded here by `room types × horizon-days` for one hotel (~1,300 rows), which is acceptable;
a materially larger horizon would want chunked flushes. `Persistable` adds a transient field and
two lifecycle callbacks to the entity, and makes newness explicit rather than inferred — that is
the point, but it must be kept correct if new constructors are added.

**Neutral.** Behaviour is unchanged: the same rows, with the same values, in the same
transaction. This is a write-path optimisation, not a semantic change — which is why the
Experiment 07 checksum comparison is the right way to prove it.

# Documents to update at implementation

- `search-service` — `RoomTypeNightAvailabilityProjection` (Persistable; done in this change).
- `search-service` — `ProjectionServiceImpl.materializeHotelCalendar` (`saveAll`; done).
- `search-service` — `HotelProjectionMaintenanceServiceImpl.rollHorizonForward` (`saveAll`; done).
- `search-service` — `application.yml` (JDBC batching; done).
- `ProjectionServiceImplTest` — asserts one `saveAll` and no `save()`, so a regression to a
  row-at-a-time loop fails the suite (done).
- No OpenAPI/AsyncAPI contract change, and no Flyway migration (the schema is untouched).
