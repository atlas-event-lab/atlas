---
adr_id: ADR-0011
title: Hotel stay dates on cart items
service: Travel Cart
status: COMPLETED
date: 2026-07-09
depends_on:
  - SPEC-SERVICE-TRAVEL-CART
  - SPEC-FEATURE-MANAGE-TRAVEL-CART
  - ADR-0003
  - ADR-0010
---

# ADR-0011 — Travel Cart: hotel stay dates on cart items

# Status

`PENDING` (created 2026-07-09). Companion to
[ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md) (Inventory),
[ADR-0009](ADR-0009-search-per-night-availability-projection.md) (Search),
[ADR-0010](ADR-0010-booking-hotel-stay-dates.md) (Booking) — one ADR per service
(`DR-002`).

# Context

`CartItem` carries `type` · `resourceId` · `unitPrice` · `quantity` — **no stay dates**.
The Travel Cart is the step where a Search hotel offer (which was selected for specific
`checkIn` / `checkOut`) is held before checkout. Because the cart drops the dates, they
never reach Booking or Inventory. For date-based inventory
([ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md)) and nights-based pricing
([ADR-0010](ADR-0010-booking-hotel-stay-dates.md)), the cart must carry the stay range for
hotel items so checkout can forward it.

# Decision

1. **Polymorphic cart items (D-item).** `CartItem` becomes abstract with JPA
   **`SINGLE_TABLE`** inheritance: `FlightCartItem` and `HotelCartItem` (the latter adds
   `check_in`, `check_out`). One physical `cart_items` table with a discriminator and
   nullable date columns.
2. **Dates on add/update.** The cart upsert request for a hotel item SHALL accept
   `checkIn` / `checkOut`; the cart response SHALL echo them. They are forwarded verbatim
   to Booking at checkout.
3. **Validation.** `checkOut > checkIn`, `checkIn ≥ today`, `nights ≥ 1`,
   `nights ≤ maxStay` (400 RFC7807, `API-004`/`API-005`). The cart does not compute
   availability or authoritative price (that stays with Search/Inventory/Booking), **but its
   displayed total DOES multiply a hotel line by nights** (`pricePerNight × nights × rooms`) so
   the cart total equals the amount Booking recomputes and re-validates at checkout (ADR-0010).

# Consequences

**Positive.** Stay dates survive the Search → Cart → Booking hand-off; minimal, single-table
change. Keeps the cart a thin holder (no availability/price authority).

**Negative / trade-offs.** Cart gains light date validation; flight rows carry null date
columns (acceptable). Contract/consumer deploy ordering must precede Booking relying on the
forwarded dates.

# Documents to update at implementation

- `docs/services/travel-cart/service.md` — polymorphic cart items; hotel items carry stay
  dates.
- `docs/features/manage-travel-cart/feature.md` — add/update hotel item with `checkIn` /
  `checkOut`; validation.
- OpenAPI (`travel-cart.yaml`) — **generated** (`ADR-0006`): cart upsert/response hotel
  items gain dates; design in DTO/controller and regenerate — do not hand-edit.

# Implementation tasks

- Flyway (cart-db): add discriminator + `check_in`/`check_out` (nullable) to `cart_items`.
- Split `CartItem` (`SINGLE_TABLE`) into `FlightCartItem` / `HotelCartItem`.
- Accept/echo/forward hotel stay dates; add validation.
- Unit tests (validation, forwarding at checkout).
- Flip to `COMPLETED` and update the register + `SPECS-INDEX.md` when merged (`DR-003`,
  `DR-005`).
