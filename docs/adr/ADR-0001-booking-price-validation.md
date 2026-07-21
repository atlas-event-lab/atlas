---
adr_id: ADR-0001
title: Booking validates prices against Flight/Hotel; explicit items, no tripId
service: Booking
status: COMPLETED
date: 2026-06-25
depends_on:
  - ADR-0002
  - ADR-0004
  - ADR-0005
  - SPEC-SERVICE-BOOKING
---

# ADR-0001 — Booking validates prices against Flight/Hotel, not Search

# Status

`PENDING` (created 2026-06-25). Flip to `COMPLETED` when the Booking changes below are
implemented and merged (`DR-003`). Supersedes the Search-resolved pricing step in
features/create-booking/feature.md and the
retired `Trip`/`TripOffer` mechanism (domain/trip.md).

# Context

Booking previously resolved a `tripId` through Search (`GET /trips/{tripId}`) to obtain a
frozen `TripOffer` and validate the total. Two changes remove that path: Search no longer
produces `TripOffer` (it serves independent flight/hotel offers as live reads —
[ADR-0002](ADR-0002-search-independent-offers.md)), and a Travel Cart now holds the
user's selection with a **display-only** price snapshot
([ADR-0003](ADR-0003-travel-cart-service.md)). Booking must therefore obtain an
authoritative price from the **source of truth**: Flight and Hotel Service.

# Decision

1. **Booking does not call Search.** The synchronous `GET /trips/{tripId}` dependency is
   removed. Search remains a downstream consumer of `booking.*` events
   (`BookingProjection` / `GET /me/bookings`) — unchanged.
2. **The Create Booking request carries the selection explicitly.** `travelers[]` stays;
   `tripId` is removed; `items[]` carry concrete catalog ids + client-presented prices:
   - flight item: `flightId`, `unitPrice`, `quantity` (pax requiring a seat);
   - hotel item: `hotelId`, `roomTypeId`, `unitPrice`, `quantity` (rooms × nights).
   The total is **never** client-supplied (`SEC-004`).
3. **Booking validates prices against Flight/Hotel directly.** Before persisting
   `PENDING`, Booking calls Flight Service (flight item) and Hotel Service (hotel item)
   read-only (`ARCH-006`; never their DBs, `ARCH-003`), recomputes the total per
   domain/pricing.md (`BigDecimal`, scale 2, `HALF_UP`, single
   currency), and **rejects with `422`** on any price mismatch or withdrawn/missing
   resource. Availability is still re-checked by the Inventory Saga step.
4. **Booking is decoupled from the Cart.** Booking does not read or convert the cart; the
   frontend composes the request and triggers cart conversion (ADR-0003).

# Dependencies

The Flight/Hotel **read endpoints** Booking calls are delivered by
[ADR-0004](ADR-0004-flight-price-read-endpoint.md) and
[ADR-0005](ADR-0005-hotel-price-read-endpoint.md). This ADR SHALL NOT be marked
`COMPLETED` before ADR-0004 and ADR-0005 are `COMPLETED`.

# Consequences

**Positive.** Authoritative pricing (source of truth, not a stale projection/snapshot);
Booking decoupled from Search read models; the cart snapshot may be stale without risk.

**Negative / trade-offs.** Booking gains two synchronous REST dependencies on the create
path (Flight, Hotel) — deliberate use of REST for an immediate query (`ARCH-006`), to be
made resilient (timeouts; failures mapped to RFC7807 `422`/`503`). A price change between
cart-add and checkout surfaces as `422`; the user re-selects (eventual-consistency
example, `PORT-001`).

# Documents to update at implementation

- `contracts/openapi/booking.yaml` — `CreateBookingRequest`: drop `tripId`; `items[]`
  carry `flightId`/`hotelId`/`roomTypeId` + `unitPrice` + `quantity`; remove the
  search.yaml reference; `BookingResponse` drops `tripId`.
- `contracts/asyncapi/booking-events.yaml` — `BOOKING_CREATED` payload: drop `tripId`.
- `features/create-booking/feature.md` + `implementation_plan.md` — replace the
  `GET /trips/{tripId}` step with Flight/Hotel price validation; update Actors, Required
  Context, error scenarios, acceptance.
- `services/booking/service.md` — Depends On already updated (Flight/Hotel; Search only
  as event consumer); confirm at implementation.
- `services/booking/diagrams.md` — already updated to Flight/Hotel calls; confirm.
- `domain/booking.md` — already updated (explicit items, no `TripId`); confirm.

# Scope note

Does **not** change the Booking Saga (choreography), state machine, idempotency, or the
events Booking produces/consumes. Only the pre-persist pricing validation and the request
shape change.
