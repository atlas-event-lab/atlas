---
spec_id: ADR-INDEX-001
version: 1.0
status: Approved
---

# Architecture Decision Records — Atlas

ADRs capture architectural changes whose **implementation is deferred**. They are the
registry used to track **what is still to build**. Governed by `DR-001`–`DR-006`
(constraints.md).

# Scope rule

**One ADR per affected service** (`DR-002`). A single architectural change that touches
several services produces several ADRs (one per service), cross-linked, so each service
can be implemented independently.

# Status lifecycle

| Status | Meaning |
|--------|---------|
| `PENDING` | Decision accepted and specs/contracts updated, but **not yet implemented**. The default for a new ADR (`DR-003`). |
| `COMPLETED` | The ADR's changes are **fully implemented and merged**. Flip to this only when done (`DR-003`). |
| `SUPERSEDED` | Replaced by a newer ADR; SHALL link its replacement (`DR-004`). |

To mark an ADR done: set `status: COMPLETED` in its frontmatter **and** update the row
in the table below (and the `SPECS-INDEX.md` Decision Records section, `DR-005`).

# Frontmatter standard

```yaml
---
adr_id: ADR-000X
title: <short imperative title>
service: <Owning service, or "Cross-cutting">
status: PENDING            # PENDING | COMPLETED | SUPERSEDED
date: YYYY-MM-DD
depends_on:                # other ADR ids / spec_ids
  - ADR-000Y
---
```

# Register

| ADR | Service | Title | Status |
|-----|---------|-------|--------|
| [ADR-0001](ADR-0001-booking-price-validation.md) | Booking | Validate prices against Flight/Hotel; request carries explicit items (no `tripId`) | `COMPLETED` |
| [ADR-0002](ADR-0002-search-independent-offers.md) | Search | Replace `TripOffer` with independent flight/hotel offers (live reads) | `COMPLETED` |
| [ADR-0003](ADR-0003-travel-cart-service.md) | Travel Cart | Introduce the REST-only Travel Cart service | `COMPLETED` |
| [ADR-0004](ADR-0004-flight-price-read-endpoint.md) | Flight | Expose a service-readable price endpoint; rehome FlightSegment | `COMPLETED` |
| [ADR-0005](ADR-0005-hotel-price-read-endpoint.md) | Hotel | Expose a service-readable room-type price endpoint | `COMPLETED` |
| [ADR-0006](ADR-0006-code-first-openapi-contracts.md) | Cross-cutting | Code-first API: the code is authoritative, OpenAPI is generated + CI-verified | `COMPLETED` |
| [ADR-0007](ADR-0007-booking-out-of-order-saga-events.md) | Booking | Defer premature Saga events (retry, don't fail) to tolerate out-of-order delivery | `COMPLETED` |
| [ADR-0008](ADR-0008-inventory-per-night-hotel-availability.md) | Inventory | Per-night hotel availability; specialize into `flight_inventory` + `room_type_availability`; absolute + rekeyed events | `COMPLETED` |
| [ADR-0009](ADR-0009-search-per-night-availability-projection.md) | Search | Per-night hotel projection; split flight projection; absolute + versioned consumption; date-range query | `COMPLETED` |
| [ADR-0010](ADR-0010-booking-hotel-stay-dates.md) | Booking | Hotel stay dates on items; nights×rooms pricing; `BookingCreated` carries check-in/check-out | `COMPLETED` |
| [ADR-0011](ADR-0011-cart-hotel-stay-dates.md) | Travel Cart | Hotel stay dates on cart items (forwarded to Booking) | `COMPLETED` |
| [ADR-0012](ADR-0012-automated-formatting-and-style-checks.md) | Cross-cutting | Enforce formatting (Spotless) + style (Checkstyle) in build & CI | `COMPLETED` |
| [ADR-0013](ADR-0013-outbox-relay-concurrency-and-batching.md) | Cross-cutting | Claim-based outbox polling (`SKIP LOCKED`) + batched publish — ends duplicate publishing, lifts relay throughput (booking/inventory/payment/flight/hotel) | `COMPLETED` |
| [ADR-0014](ADR-0014-inventory-saga-consumer-capacity.md) | Inventory | Saga-listener concurrency 2→3 (9 consumers) for `booking.created`/`booking.confirmed`; evaluate KEDA-on-lag | `PENDING` |
| [ADR-0015](ADR-0015-payment-consumer-capacity.md) | Payment | Scale to 12 consumers (KEDA max 3→4 + concurrency 2→3); needs `inventory.reserved` 12 + retry topics | `COMPLETED` |
| [ADR-0016](ADR-0016-kafka-hot-topic-partitions.md) | Kafka-platform | Hot-topic partitions: `booking.created`/`booking.confirmed` 6→9, `inventory.reserved` 6→12 (+ retry/DLQ) | `COMPLETED` |
| [ADR-0017](ADR-0017-wiremock-provider-hpa.md) | Platform (WireMock) | HPA for the fake payment provider — scale with payment concurrency, idle-down (load-test env) | `COMPLETED` |
| [ADR-0018](ADR-0018-inventory-contention-metrics.md) | Inventory | Domain metrics (reservations, oversell attempts, units) for the no-oversell invariant — correctness APM | `COMPLETED` |
| [ADR-0019](ADR-0019-inventory-idempotency-metrics.md) | Inventory | Duplicate-skip metric — make effectively-once (idempotent redelivery) observable | `COMPLETED` |
| [ADR-0020](ADR-0020-payment-idempotency-metrics.md) | Payment | Duplicate-skip + provider-call metrics — make crash-recovery (Exp 04) observable | `COMPLETED` |
| [ADR-0021](ADR-0021-payment-stale-processing-recovery.md) | Payment | Stale-PROCESSING recovery sweeper — idempotent charge re-drive closes the W2 liveness gap | `COMPLETED` |
| [ADR-0022](ADR-0022-payment-dlq-replay.md) | Payment | Manual DLQ replay — deliberately-started `@DltHandler` re-drives parked triggers (reprocess/quarantine) + parked/replayed metrics (Exp 06) | `COMPLETED` |
| [ADR-0023](ADR-0023-payment-per-consumer-dlt-topics.md) | Payment | Per-consumer retry/DLT topics — `inventory.reserved-payment.dlq` isolates payment's parked records from booking's (Exp 06) | `COMPLETED` |
| [ADR-0024](ADR-0024-booking-per-consumer-dlt-topics.md) | Booking | Per-consumer retry/DLT topics — `inventory.reserved-booking.dlq` isolates booking's parked records from payment's (Exp 06) | `COMPLETED` |
| [ADR-0025](ADR-0025-flight-catalog-resync.md) | Flight | Catalog resync — republish current state from `flight_db` for read-model rebuild beyond retention (Exp 07, Strategy B) | `COMPLETED` |
| [ADR-0026](ADR-0026-hotel-catalog-resync.md) | Hotel | Catalog resync — republish hotels/room-types (+ derived night calendar) from `hotel_db` (Exp 07, Strategy B) | `COMPLETED` |
| [ADR-0027](ADR-0027-inventory-availability-resync.md) | Inventory | Availability resync — republish absolute `reserved`+`version` from `inventory_db`, after catalog (Exp 07, Strategy B) | `COMPLETED` |
| [ADR-0028](ADR-0028-booking-saga-outcome-metrics.md) | Booking | Saga outcome + end-to-end duration meters — `POST /bookings` 201 is acceptance, not success (Exp 01) | `COMPLETED` |
| [ADR-0029](ADR-0029-search-calendar-write-path.md) | Search | Batch the hotel calendar write path — Persistable + JDBC batching; one event materializes a year of nights (Exp 07) | `COMPLETED` |
| [ADR-0030](ADR-0030-travel-cart-cpu-hpa.md) | Travel Cart | CPU HPA 1–4 replicas — the journey's first three calls were pinned to one pod with no autoscaler at all (Exp 01) | `COMPLETED` |
| [ADR-0031](ADR-0031-booking-replica-ceiling.md) | Booking | Replica ceiling 4 → 5 — one pod carries REST + producer + consumer; the knee moved here once the cart scaled (Exp 01) | `COMPLETED` |

# Related historical note

- features/manage-travel-cart/migration-notes.md
  — `Obsolete` (written under the reversed "remove Search" decision; superseded by the
  ADRs above).
