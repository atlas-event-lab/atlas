---
adr_id: ADR-0008
title: Per-night hotel availability; specialize Inventory into flight_inventory + room_type_availability
service: Inventory
status: COMPLETED
date: 2026-07-09
depends_on:
  - SPEC-SERVICE-INVENTORY
  - SPEC-STATE-INVENTORY
  - SPEC-FEATURE-RESERVE-INVENTORY
  - SPEC-FEATURE-SEED-INVENTORY
  - ADR-0009
  - ADR-0010
---

# ADR-0008 — Inventory: date-based (per-night) hotel availability

# Status

`PENDING` (created 2026-07-09). One of several ADRs for the date-based-hotel-inventory
change (`DR-002`): Inventory (this) · Search ([ADR-0009](ADR-0009-search-per-night-availability-projection.md))
· Booking ([ADR-0010](ADR-0010-booking-hotel-stay-dates.md)) · Travel Cart
([ADR-0011](ADR-0011-cart-hotel-stay-dates.md)).

# Context

Inventory models availability as a **scalar per resource**: one `Inventory` row per room
type with `available = totalCapacity − reservedCount` (services/inventory/service.md).
There is **no date dimension**, so a hotel reservation consumes the same single counter
regardless of stay dates. `check-in` / `check-out` never reach Inventory — the
`BookingCreated` items (`BookingItemEvent`) carry only `resourceId` / `quantity` /
`amount`. As a result, two bookings for **non-overlapping** stays of the same room type
compete for the same counter (false sold-out), and overlapping stays are not correctly
serialized on the nights they share.

Hotels are intrinsically **per-night**: a room type has capacity **for each night**, and a
stay `[checkIn, checkOut)` occupies the nights `checkIn … checkOut−1` (the check-out night
is not occupied). Flights do not have this shape — a flight instance already **is** a date.

The current `Inventory` entity carries a `resourceType` discriminator and a
`parentResourceId` (the `hotelId`, `null` for flights) purely to reconcile hotel room-type
rows. With hotels moving to a per-night table keyed by `hotelId`, both fields become dead
weight on the flight path.

# Decision

1. **Hotels become per-night.** Introduce `room_type_availability` — one row per
   `(roomTypeId, stayDate)` — as the authoritative hotel inventory. It **replaces** the
   scalar hotel `Inventory` rows. Columns: `id`, `room_type_id`, `hotel_id`, `stay_date`,
   `total_rooms`, `reserved`, `status` (`ACTIVE` · `DISABLED`), audit timestamps;
   `UNIQUE(room_type_id, stay_date)`, `INDEX(room_type_id, stay_date)`.
   `available(night) = max(0, total_rooms − reserved)` (clamp preserved, `DB-001`).
2. **Flights keep the scalar model, specialized.** Rename `Inventory` → `flight_inventory`
   and **drop** `resource_type` and `parent_resource_id`. The `ResourceType` discriminator
   is removed from persistence; FLIGHT/HOTEL semantics survive only where events require
   them.
3. **Per-night status (`DR-002` D-status).** `status` lives on each night row (no thin
   room-type header). `HOTEL_DELETED` bulk-sets `status = DISABLED` on the room type's
   **future** nights; existing reservations are untouched (as today).
4. **Reservations carry the stay range.** `Reservation` becomes abstract with JPA
   **`SINGLE_TABLE`** inheritance: `FlightReservation` (no dates) and `HotelReservation`
   (`check_in`, `check_out`). One physical `reservations` table with a discriminator and
   nullable date columns.
5. **All-or-nothing across items *and* nights.** On `BOOKING_CREATED`, for every hotel
   item Inventory locks the item's night rows (`PESSIMISTIC_WRITE`, ordered by
   `stay_date` to keep a deterministic lock order and avoid deadlocks) and reserves
   `rooms` on **each** night only if **every** night of **every** item has
   `available ≥ rooms` and is `ACTIVE`. Any shortfall → the whole transaction rolls back
   and Inventory emits the booking-level `INVENTORY_REJECTED` (`ARCH-007`). Release /
   expire restore `reserved` on each night of the stored range.
6. **Resource-facing events become absolute + rekeyed** (aligns with
   [ADR-0009](ADR-0009-search-per-night-availability-projection.md), D-evento). Hotel
   `*RoomsReserved/Released/Expired` carry, per affected night, the **new absolute**
   `reserved` plus a monotonic `version`, and are **keyed by `roomTypeId`** (flight events
   carry absolute `reserved` + `version`, keyed by `flightId`) so a single partition
   totally orders all updates of a resource. Booking-facing events
   (`INVENTORY_RESERVED/REJECTED/RELEASED`) are unchanged.
7. **Bounded calendar with a rolling horizon.** Catalog seeding materializes nights for
   `[today, today + horizon)`; a scheduled job rolls the window forward (creates the new
   far night, purges long-past nights). Horizon and purge window are configuration
   (recommended defaults: horizon 365 days, purge 7 days after checkout — confirm before
   implementation).

Idempotency on the envelope `eventId` is preserved throughout (`EVT-005`, `EVT-008`);
state + produced events still commit together via the outbox (`EVT-009`).

# Consequences

**Positive.** Correct date-based availability (non-overlapping stays no longer collide;
overlapping stays serialize on shared nights only). Removes the `total_rooms` /
`totalCapacity` duplication and the flight-path dead columns. Absolute+versioned events
make the Search projection idempotent without dedupe.

**Negative / trade-offs.** Locking grows from 1 row/item to N rows/item (one per night) —
more contention on popular dates; mitigated by ordered locking + the `(room_type_id,
stay_date)` index. Per-night `status` means `HOTEL_DELETED` is a bulk update over future
nights. Calendar size = room types × horizon; needs the rolling purge. The
`ResourceType`-as-column removal is a mechanical refactor across ~17 files. Rekeying
resource-facing events changes partitioning (see partitioning.md update).

# Documents to update at implementation

- `docs/services/inventory/service.md` — replace the scalar `Inventory` model with
  `room_type_availability` (hotels) + `flight_inventory` (flights); describe per-night
  reserve/release/expire, horizon seeding + rolling job, per-night status.
- `docs/services/inventory/state_machine.md` — availability restore is per-night;
  `HotelReservation` carries the range; note the ordered multi-row lock under §Concurrency.
- `docs/features/reserve-inventory/feature.md` — all-or-nothing across items **and nights**;
  hotel items consume `checkIn`/`checkOut`.
- `docs/features/seed-inventory-from-catalog/feature.md` — seeding materializes the horizon;
  `HOTEL_UPDATED` updates future nights; `HOTEL_DELETED` disables future nights.
- `docs/contracts/asyncapi/inventory-events.yaml` — resource-facing hotel/flight events:
  absolute `reserved` per night + `version`; rekeyed (see partitioning.md).
- `docs/contracts/asyncapi/partitioning.md` — resource-facing events keyed by
  `roomTypeId` / `flightId`.
- OpenAPI (`inventory.yaml`) — **generated** (`ADR-0006`); the read-only availability query
  accepts a hotel date range. Design in the controller/DTO, regenerate — do not hand-edit.

# Implementation tasks

- Flyway: create `room_type_availability`; rename `inventory` → `flight_inventory` (drop
  `resource_type`, `parent_resource_id`); add discriminator + `check_in`/`check_out` to
  `reservations`. Forward-only (data rebuilt per Phase 6 of the impl plan).
- New entity `RoomTypeNightAvailability` + repository (`findForUpdate…StayDateIn` ordered
  by `stay_date`; range read; `findByHotelId`). Specialize `FlightInventory`.
- Split `Reservation` (`SINGLE_TABLE`) into `FlightReservation` / `HotelReservation`.
- Reserve/release/expire over the night set; ordered multi-row pessimistic lock.
- Seeding materializes the horizon; add the rolling/purge `@Scheduled` job.
- Emit absolute + versioned, rekeyed resource-facing events.
- Unit + integration tests (Testcontainers Kafka+PG): overlapping vs non-overlapping
  stays; partial-night sold-out → reject; TTL sweep restores per night; deadlock-free
  concurrent reservations.
- Flip to `COMPLETED` and update the register + `SPECS-INDEX.md` when merged (`DR-003`,
  `DR-005`).
