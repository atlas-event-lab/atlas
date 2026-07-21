---
adr_id: ADR-0004
title: Expose a service-readable flight price endpoint; rehome FlightSegment
service: Flight
status: COMPLETED
date: 2026-06-25
depends_on:
  - SPEC-SERVICE-FLIGHT
---

# ADR-0004 — Flight: service-readable price endpoint (+ FlightSegment home)

# Status

`COMPLETED` (created 2026-06-25, implemented 2026-06-25). Required by [ADR-0001](ADR-0001-booking-price-validation.md).

# Context

Booking now validates flight prices against Flight Service directly (ADR-0001). Today
Flight exposes only **ADMIN-RBAC** reads (`GET /flights/{flightId}`, `GET /flights`;
flight.yaml), which Booking (a service caller, not an admin user) cannot use. Separately,
`domain/trip.md` is retired (ADR-0002), but it currently hosts background for the
**FlightSegment** (multi-leg) concept that flight.yaml / flight/service.md reference.

# Decision

1. **Add a narrow, service-readable price endpoint** for authenticated service callers
   (not `ADMIN`-only), returning the minimum Booking needs:
   `GET /flights/{flightId}/price` → `{ flightId, basePrice (Money), status }`
   (`ACTIVE`/`WITHDRAWN`). RFC7807 errors; `404` for unknown; reflects catalog source of
   truth. (Alternative considered: relax auth on `GET /flights/{flightId}` — rejected to
   keep the admin surface separate and the Booking dependency minimal.)
2. **Rehome the FlightSegment concept** into Flight Service's own spec (it already owns the
   `FlightSegment` entity, flight/service.md) so references no longer point at the obsolete
   `domain/trip.md`.

# Consequences

**Positive.** Booking gets an authoritative, minimal price read; admin surface stays
separate; FlightSegment documented where it is owned.

**Negative / trade-offs.** A new public-ish (authenticated) endpoint to secure and test;
Flight must keep `status` semantics consistent for Booking's withdrawn check.

# Documents to update at implementation

- `contracts/openapi/flight.yaml` — add `GET /flights/{flightId}/price` (authenticated,
  non-admin) with a `FlightPrice` schema.
- `services/flight/service.md` — document the price read endpoint and its auth; absorb the
  FlightSegment background previously linked from `domain/trip.md`.
- Update `flight.yaml`/`manage-flight-catalog` references that point to `domain/trip.md`
  for segments → point to Flight's own spec.

# Implementation tasks

- Implement the price read in flight-service (controller → service; no business logic in
  controller, `API-003`); RBAC allows an authenticated service caller.
- Unit-test the endpoint (price + withdrawn/404 paths).
