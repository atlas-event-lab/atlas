---
adr_id: ADR-0009
title: Per-night hotel availability projection; split flight projection; absolute + versioned consumption; date-range query
service: Search
status: COMPLETED
date: 2026-07-09
depends_on:
  - SPEC-READMODEL-SEARCH
  - SPEC-SERVICE-SEARCH
  - SPEC-FEATURE-SEARCH-HOTELS
  - ADR-0002
  - ADR-0008
---

# ADR-0009 — Search: per-night availability projection and date-aware hotel query

# Status

`PENDING` (created 2026-07-09). Companion to
[ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md) (Inventory),
[ADR-0010](ADR-0010-booking-hotel-stay-dates.md) (Booking),
[ADR-0011](ADR-0011-cart-hotel-stay-dates.md) (Cart) — one ADR per service (`DR-002`).

# Context

`GET /api/v1/search/hotels` requires `checkIn` / `checkOut` but they are **dead
parameters**: they are validated (`checkOut > checkIn`, `checkIn ≥ today`) and used to
derive a display-only `nights`, but `HotelSearchCustomRepository` applies **no** date
predicate. The availability filter is scalar: a single `AvailabilityProjection` row per
`roomTypeId` with `available = capacity − reserved ≥ rooms`. So a room type sold out for
one night inside the requested range is still returned as available.

`AvailabilityProjection` is a shared table across FLIGHT and HOTEL (discriminated by
`resource_type`); the hotel and flight queries are independent, so the shared table adds a
discriminator and a join without benefit. Availability updates arrive as **commutative
deltas** (`reserved += / −= qty`) keyed by `reservationId`; correctness relies on dedupe
by `eventId`.

With Inventory moving to per-night availability
([ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md)), the projection and the
query must become date-aware, and the delta scheme is replaced by absolute values.

# Decision

1. **Per-night hotel projection.** Introduce `room_type_availability` (Search read model):
   one row per `(resourceId = roomTypeId, stayDate)` with `capacity`, `reserved`,
   `status`, `version`, `updated_at`; `UNIQUE(resource_id, stay_date)`,
   `INDEX(resource_id, stay_date)`. It **replaces** the hotel side of
   `AvailabilityProjection`.
2. **Split the flight projection.** `flight_projections` gains `capacity`, `reserved`,
   `version`; the shared `AvailabilityProjection` table and its `resource_type`
   discriminator are **removed**. Hotel and flight availability are now independent.
3. **Absolute + versioned consumption (D-evento).** `InventoryAvailabilityConsumer`
   upserts `reserved := value` **iff** `incoming.version ≥ stored.version` (else skip),
   per night for hotels (keyed by `roomTypeId`) and per flight (keyed by `flightId`). This
   is idempotent under at-least-once and correct under the per-key ordering guaranteed by
   the rekey in [ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md). It
   supersedes the commutative-delta approach.
4. **Date-aware hotel query.** A room type is eligible **iff every** night of
   `[checkIn, checkOut)` exists in the calendar **and** has `available ≥ rooms` **and**
   `status = ACTIVE`. Concretely: join `HotelRoomType` × `room_type_availability` filtered
   to the stay nights, group by room type, and keep only those where
   `COUNT(rows in range) = nights` **and** `COUNT(available ≥ rooms) = nights`. `nights` is
   derived from the request dates (now functional, not display-only). Rating / price /
   `maxOccupancy` / sort / pagination are unchanged.
5. **Validation.** Add `nights ≤ maxStay` alongside the existing `checkOut > checkIn` /
   `checkIn ≥ today`; invalid input → 400 RFC7807 (`API-005`).

Search remains a pure read model built only from projections — no source-DB access, no
synchronous cross-service calls (ADR-0002, feature.md).

# Consequences

**Positive.** Correct availability by stay range; sold-out single nights exclude the room
type. Independent hotel/flight projections improve query locality/performance. Absolute +
version removes the need for `eventId` dedupe on availability and is robust to redelivery.

**Negative / trade-offs.** Projection row count grows to room types × horizon; needs the
`(resource_id, stay_date)` index and reflects Inventory's rolling purge. The hotel query
gains a group-by over the night set. Absolute values are last-writer-wins, so correctness
depends on the per-key ordering from the rekey — a mis-key would corrupt the projection
(covered by tests). Rebuild (not migrate) the projection from catalog + inventory events.

# Documents to update at implementation

- `docs/services/search/read_model.md` — replace shared `AvailabilityProjection` with
  per-night `room_type_availability` (hotels) + `capacity`/`reserved`/`version` on
  `flight_projections`; document absolute + version-guarded consumption.
- `docs/services/search/service.md` — hotel query is night-range aware.
- `docs/features/search-hotels/feature.md` — availability filter over the night set;
  `nights` functional; add `maxStay` validation.
- OpenAPI (`search.yaml`) — **generated** (`ADR-0006`): `checkIn`/`checkOut` gain real
  semantics; design in the DTO/controller and regenerate — do not hand-edit.
- (Consumes `docs/contracts/asyncapi/inventory-events.yaml` — owned by
  [ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md).)

# Implementation tasks

- Flyway (search-db): create `room_type_availability`; add `capacity`/`reserved`/`version`
  to `flight_projections`; drop `availability_projections`. Forward-only; data rebuilt.
- New projection entity + repository; remove shared `AvailabilityProjection` + its
  `ResourceType` usage.
- Rework `InventoryAvailabilityConsumer` to absolute + version-guarded upserts, per night.
- Rewrite `HotelSearchCustomRepository` predicate to the night-range constraint; derive
  `nights`; add `maxStay` validation.
- Unit + integration tests: inclusion/exclusion by night; missing-night exclusion;
  absolute-upsert idempotency; stale-version rejection; sort/pagination intact.
- Flip to `COMPLETED` and update the register + `SPECS-INDEX.md` when merged (`DR-003`,
  `DR-005`).
