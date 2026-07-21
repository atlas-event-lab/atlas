---
adr_id: ADR-0026
title: Hotel catalog resync (republish current state for read-model rebuild)
service: Hotel
status: COMPLETED
date: 2026-07-20
depends_on: []
---

# ADR-0026 — Hotel catalog resync

# Status

`COMPLETED` (created 2026-07-20, implemented in the same change-set). Origin: Experiment 07 — Read Model Rebuild
([experiments/07-read-model-rebuild/rebuild-source-of-truth.md](../../experiments/07-read-model-rebuild/rebuild-source-of-truth.md),
Strategy B). Paired with [ADR-0025](ADR-0025-flight-catalog-resync.md) (flight) and
[ADR-0027](ADR-0027-inventory-availability-resync.md) (inventory) — one ADR per owning service
(`DR-002`).

# Context

Same driver as ADR-0025: full read-model derivability is capped at the 7-day topic retention, and
Strategy B rebuilds it by re-emitting current state from each owner's DB. Hotel-service owns the
hotel catalog (hotels + room types) in `hotel_db`; from it the search read model also **materializes
the per-night availability calendar** (`today .. today+horizon`, clock-relative), so re-emitting the
hotel catalog rebuilds both `hotel_projections`/`hotel_room_types` and the night rows' `capacity`.

# Decision

Add a **resync** capability to hotel-service mirroring ADR-0025:

- `POST /actuator/resync` on the internal management port (RBAC-gated), the ADR-0022 control pattern.
- Iterate hotels in `hotel_db`; for each **active** hotel emit its catalog upsert
  (`hotel.created`/`hotel.updated` payload, including its room types) and for each **withdrawn**
  hotel emit `hotel.deleted` — via the existing **outbox**, keyed by `hotelId`.
- Idempotency: fresh `eventId`s; search re-applies (rebuild) and re-materializes the night calendar
  at the current horizon; inventory's catalog seed re-consumes idempotently (capacity only).
- Ordering: driven by the rebuild orchestrator — catalog (flight + hotel) resync completes before
  availability resync (ADR-0027).

# Consequences

**Positive.** Hotel catalog + the derived night calendar become rebuildable at any time from
`hotel_db`. No schema/contract change. **Negative / assumption.** The rebuilt night window is
**current-horizon** (clock-relative), so a rebuild reproduces today's calendar, not a stale
snapshot — inherent to the rolling window (Exp 07 compares within the current horizon). Re-emit runs
in a maintenance window; volume bounded by hotel × room-type count.

# Documents to update at implementation

- `hotel-service` — resync service + `ResyncEndpoint` (actuator), tests; `application.yml` exposure.
- Experiment 07 runbook — beyond-retention variant orchestrating the resyncs.
- ADR index (`docs/adr/README.md`) + `docs/SPECS-INDEX.md` (`DR-005`).
- No AsyncAPI/OpenAPI change.
