---
adr_id: ADR-0003
title: Introduce the REST-only Travel Cart service
service: Travel Cart
status: COMPLETED
date: 2026-06-25
depends_on:
  - SPEC-SERVICE-TRAVEL-CART
  - SPEC-FEATURE-MANAGE-TRAVEL-CART
---

# ADR-0003 — Travel Cart service (pre-booking selection)

# Status

`COMPLETED` (created 2026-06-25, implemented 2026-06-25).

# Context

With independent flight/hotel offers (ADR-0002) and Booking receiving explicit items
(ADR-0001), the system needs a place to hold a user's in-progress selection (one flight +
one hotel) between searching and checkout. This is a synchronous, user-facing concern with
a short TTL — not a Saga or event flow.

# Decision

1. **New independently deployable service** `travel-cart-service` owning `travel-cart-db`
   (`ARCH-002`, `ARCH-009`).
2. **REST-only — no Kafka** (`EVT-007` is SHOULD; a short-lived user-facing aggregate is
   the canonical REST case). No produced/consumed events; no AsyncAPI contract.
3. **Aggregate:** one `ACTIVE` cart per user (JWT subject, `SEC-004`); entities
   `Cart`/`CartItem`; `CartStatus` ∈ `ACTIVE`·`EXPIRED`·`CONVERTED`. MVP: at most one
   `FLIGHT` and one `HOTEL` item (upsert per type).
4. **Server-authoritative total** recomputed from item snapshots; never client-supplied.
   The per-item price is a **display-only** frozen snapshot (authoritative validation is
   Booking's, ADR-0001).
5. **TTL = 30 min**, enforced lazily on read **and** by an idempotent scheduled sweeper.
6. **Decoupled from Booking:** Booking does not read or convert the cart; the frontend
   composes the Booking request and calls `POST /carts/{id}/conversion` after a successful
   checkout.

# Consequences

**Positive.** Clean separation of selection vs. booking; a deliberate "not everything
needs Kafka" example (`PORT-001`); stale cart prices are harmless (Booking re-validates).

**Negative / trade-offs.** A new service/database to operate; cart price can drift from
catalog (surfaces as a Booking `422`, by design).

# Documents already authored (confirm at implementation)

- `services/travel-cart/service.md`, `features/manage-travel-cart/feature.md`,
  `contracts/openapi/travel-cart.yaml`.

# Implementation tasks

- Scaffold `travel-cart-service` (standalone Spring Boot, Flyway, Dockerfile, Helm).
- Implement the cart endpoints, server-side total, owner authorization, the idempotent
  TTL sweeper, and the idempotent `conversion` transition.
- Register `atlas-travel-cart-service` repo (project.md repo structure).
