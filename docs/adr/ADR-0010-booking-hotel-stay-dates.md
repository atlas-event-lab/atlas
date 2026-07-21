---
adr_id: ADR-0010
title: Hotel stay dates on booking items; nights×rooms pricing; BookingCreated carries check-in/check-out
service: Booking
status: COMPLETED
date: 2026-07-09
depends_on:
  - SPEC-FEATURE-CREATE-BOOKING
  - SPEC-SERVICE-BOOKING
  - ADR-0001
  - ADR-0008
---

# ADR-0010 — Booking: hotel stay dates and per-night pricing

# Status

`PENDING` (created 2026-07-09). Companion to
[ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md) (Inventory),
[ADR-0009](ADR-0009-search-per-night-availability-projection.md) (Search),
[ADR-0011](ADR-0011-cart-hotel-stay-dates.md) (Cart) — one ADR per service (`DR-002`).

# Context

A `BookingItem` carries only `type` · `resourceId` · `quantity` · `unitPrice` ·
`subtotal` — **no stay dates**. The `BookingCreated` event (`BookingItemEvent`) likewise
carries no dates. This is the reason `check-in` / `check-out` cannot reach Inventory
today: even though Search collects them, they are dropped at the cart/booking boundary.
Hotel subtotal is computed as a flat amount and does **not** multiply by the number of
nights.

For date-based inventory ([ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md))
to work, Booking must persist the stay dates on hotel items and propagate them on
`BookingCreated`, and the hotel price must reflect the stay length.

# Decision

1. **Polymorphic booking items (D-item).** `BookingItem` becomes abstract with JPA
   **`SINGLE_TABLE`** inheritance: `FlightBookingItem` and `HotelBookingItem` (the latter
   adds `check_in`, `check_out`). One physical `booking_items` table with a discriminator
   and nullable date columns.
2. **Per-night hotel pricing.** Hotel subtotal SHALL be
   `pricePerNight × nights × rooms`, where `nights = checkOut − checkIn`; flight pricing is
   unchanged. Pricing is computed polymorphically per item type.
3. **Price re-validation uses nights.** The checkout price re-validation against Hotel
   Service (`ADR-0001`) SHALL compute the expected hotel amount using `nights`.
4. **`BookingCreated` carries dates.** The `BookingCreated` payload's hotel items SHALL
   include `checkIn` / `checkOut` (matching `booking-events.yaml`), delivering the stay
   range to Inventory. Flight items are unchanged.
5. **Validation.** Reject at creation (400 RFC7807, `API-004`/`API-005`): `checkOut >
   checkIn`, `checkIn ≥ today`, `nights ≥ 1`, and `nights ≤ maxStay`.

# Consequences

**Positive.** Stay dates flow end-to-end (Cart → Booking → Inventory); hotel totals are
correct for multi-night stays; a single physical items table keeps the change small and
avoids extra joins.

**Negative / trade-offs.** Booking now owns stay-date validation and nights-based pricing;
the `BookingCreated` contract and consumers must be deployed in the right order (producer
before Inventory consumes the new field). `SINGLE_TABLE` leaves flight rows with null date
columns (acceptable).

# Documents to update at implementation

- `docs/services/booking/service.md` — polymorphic items; hotel items carry stay dates;
  hotel subtotal = `pricePerNight × nights × rooms`.
- `docs/features/create-booking/feature.md` (+ `implementation_plan.md`) — request/validation
  for hotel stay dates; nights-based total; price re-validation uses `nights`.
- `docs/contracts/asyncapi/booking-events.yaml` — `BookingCreated.items[]` hotel variant
  gains `checkIn` / `checkOut`.
- OpenAPI (`booking.yaml`) — **generated** (`ADR-0006`): booking request/response hotel
  items gain dates; design in DTO/controller and regenerate — do not hand-edit.

# Implementation tasks

- Flyway (booking-db): add discriminator + `check_in`/`check_out` (nullable) to
  `booking_items`.
- Split `BookingItem` (`SINGLE_TABLE`) into `FlightBookingItem` / `HotelBookingItem`;
  polymorphic subtotal.
- Add stay-date validation; compute totals with `nights`; use `nights` in ADR-0001
  re-validation.
- Include `checkIn`/`checkOut` on hotel items in the `BookingCreated` producer.
- Unit tests (nights×rooms pricing, validation) + integration test asserting
  `BookingCreated` carries hotel dates.
- Flip to `COMPLETED` and update the register + `SPECS-INDEX.md` when merged (`DR-003`,
  `DR-005`).
