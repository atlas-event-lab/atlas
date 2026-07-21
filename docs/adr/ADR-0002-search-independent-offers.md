---
adr_id: ADR-0002
title: Replace TripOffer with independent flight/hotel offers (live reads)
service: Search
status: COMPLETED
date: 2026-06-25
depends_on:
  - SPEC-SERVICE-SEARCH
---

# ADR-0002 — Search serves independent flight/hotel offers (no TripOffer)

# Status

`COMPLETED` (created 2026-06-25, implemented 2026-06-25).

# Context

Search previously materialized a combined **`TripOffer`** snapshot (flight + hotel, frozen
price/availability, 15-min TTL) and exposed `/search/trips` + `/trips/{tripId}`, the
latter resolved by Booking. The UX is now two independent steps — the user selects a
flight and a hotel separately, in any order — and Booking validates price against
Flight/Hotel directly ([ADR-0001](ADR-0001-booking-price-validation.md)), so the snapshot
is redundant.

# Decision

1. **Remove `TripOffer` entirely** — the snapshot table, its `expiresAt`/TTL, the sweeper,
   and the `/search/trips` + `/trips/{tripId}` endpoints.
2. **Expose two independent offer queries** as **live reads** of the projections (no
   snapshot, no TTL, eventually consistent):
   - `GET /search/flights` → page of `FlightOffer` (FlightProjection + AvailabilityProjection);
   - `GET /search/hotels` → page of `HotelOffer` (HotelProjection + AvailabilityProjection, one per room type).
3. **Keep the index projections** (`FlightProjection`, `HotelProjection`,
   `AvailabilityProjection`, `BookingProjection`) and their event ingestion unchanged.
4. **Keep booking history** (`BookingProjection` + `GET /me/bookings`) unchanged.
5. Offers expose the ids the frontend needs (`flightId`, `hotelId` + `roomTypeId`) to add
   to the cart and later to the Booking request.

# Consequences

**Positive.** Simpler Search (no snapshot store/sweeper, nothing offer-specific to
rebuild); decoupled flight/hotel selection; CQRS read role preserved.

**Negative / trade-offs.** Offers reflect projection lag (eventually consistent); the
authoritative price check moves to Booking (ADR-0001). No frozen quote — acceptable
because the cart holds a display snapshot and Booking re-validates.

# Documents already updated (confirm at implementation)

- `contracts/openapi/search.yaml` (v3) — `/search/flights`, `/search/hotels`,
  `/me/bookings`; `TripOffer`/`/trips` schemas removed.
- `services/search/service.md`, `read_model.md`, `events.md` — TripOffer removed; offers
  are computed per request.
- `features/search-flights/feature.md`, `features/search-hotels/feature.md` — new;
  `features/search-trips/feature.md` marked `Obsolete`.

# Implementation tasks

- Drop the TripOffer table/migration and its sweeper from `search-service`.
- Implement `searchFlights` / `searchHotels` as projection reads with filtering, sorting,
  pagination and availability filtering (read_model.md).
- Retain `BookingProjection` consumers and `getMyBookings`.
