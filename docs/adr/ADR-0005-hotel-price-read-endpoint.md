---
adr_id: ADR-0005
title: Expose a service-readable hotel room-type price endpoint
service: Hotel
status: COMPLETED
date: 2026-06-25
depends_on:
  - SPEC-SERVICE-HOTEL
---

# ADR-0005 — Hotel: service-readable room-type price endpoint

# Status

`COMPLETED` (created 2026-06-25, implemented 2026-06-25). Required by [ADR-0001](ADR-0001-booking-price-validation.md).

# Context

Booking now validates hotel prices against Hotel Service directly (ADR-0001). Today Hotel
exposes only **ADMIN-RBAC** reads (`GET /hotels/{hotelId}`, `GET /hotels`; hotel.yaml),
unusable by Booking as a service caller. Hotel price lives at the **room-type** level.

# Decision

**Add a narrow, service-readable price endpoint** for authenticated service callers (not
`ADMIN`-only) at room-type granularity, returning the minimum Booking needs:
`GET /hotels/{hotelId}/room-types/{roomTypeId}/price` →
`{ hotelId, roomTypeId, pricePerNight (Money), status }` (`ACTIVE`/`WITHDRAWN`).
RFC7807 errors; `404` for unknown hotel/room type. Reflects catalog source of truth.
(Alternative considered: relax auth on `GET /hotels/{hotelId}` — rejected to keep the
admin surface separate and the Booking dependency minimal.)

# Consequences

**Positive.** Booking gets an authoritative, minimal price read at the correct
(room-type) granularity; admin surface stays separate.

**Negative / trade-offs.** A new authenticated endpoint to secure and test; Hotel must
keep room-type `status` semantics consistent for Booking's withdrawn check.

# Documents to update at implementation

- `contracts/openapi/hotel.yaml` — add the room-type price read (authenticated,
  non-admin) with a `RoomTypePrice` schema.
- `services/hotel/service.md` — document the price read endpoint and its auth.

# Implementation tasks

- Implement the price read in hotel-service (controller → service; no business logic in
  controller, `API-003`); RBAC allows an authenticated service caller.
- Unit-test the endpoint (price + withdrawn/404 paths).
