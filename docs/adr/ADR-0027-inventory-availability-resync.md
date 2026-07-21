---
adr_id: ADR-0027
title: Inventory availability resync (republish absolute state for read-model rebuild)
service: Inventory
status: COMPLETED
date: 2026-07-20
depends_on:
  - ADR-0025
  - ADR-0026
---

# ADR-0027 — Inventory availability resync

# Status

`COMPLETED` (created 2026-07-20, implemented in the same change-set). Origin: Experiment 07 — Read Model Rebuild
([experiments/07-read-model-rebuild/rebuild-source-of-truth.md](../../experiments/07-read-model-rebuild/rebuild-source-of-truth.md),
Strategy B). Paired with [ADR-0025](ADR-0025-flight-catalog-resync.md) (flight) and
[ADR-0026](ADR-0026-hotel-catalog-resync.md) (hotel) — one ADR per owning service (`DR-002`).
Depends on the catalog resyncs: availability must be re-applied **after** catalog projections exist.

# Context

Completes Strategy B. Inventory-service owns availability in `inventory_db`: `flight_inventory`
(`reserved_count`) and per-night `room_type_availability` (`reserved`). The search read model stores
these as **absolute** `reserved` values guarded by `version` (ADR-0008/0009). For a rebuild, inventory
must re-emit the current absolute availability so search's `reserved`/`version` reconstruct. This is
also where compaction (Strategy A) was weakest: hotel availability events carry *multiple nights*
keyed by `roomTypeId`, so re-emitting current state from the DB is the clean source — the owner emits
every night's current value, nothing is lost.

# Decision

Add a **resync** capability to inventory-service:

- `POST /actuator/resync` on the internal management port (RBAC-gated), the ADR-0022 pattern.
- Emit **absolute** availability from `inventory_db` via the existing **outbox**: for each flight,
  an `inventory.flight.reserved`-shaped event carrying `reserved` + the stored `version`; for each
  room type, an `inventory.hotel.*` event carrying its nights' `reserved` + `version`.
- **Version preservation is mandatory:** the emitted `version` MUST be ≥ the value search currently
  stores, or search's version guard (`payload.version() >= stored`) drops it as stale. Emitting the
  stored `version` (or `version+bump` on a fresh rebuild where search starts at 0) satisfies this.
- Idempotency/order-independence: availability is absolute + version-guarded, so re-applying is
  naturally idempotent; only **search** consumes these topics, so there are no cross-service side
  effects. The rebuild orchestrator runs this **after** catalog resync (ADR-0025/0026) so every
  `resource_id`/night row already exists (else search drops the update — the Exp 07 ordering result).

# Consequences

**Positive.** Availability (flights + hotel nights) becomes rebuildable at any time from
`inventory_db`, correctly across all nights — the case compaction could not cover cleanly. No
schema/contract change. **Negative / assumption.** Correctness depends on emitting a non-stale
`version`; the resync must read and preserve it. Runs after catalog resync in a maintenance window;
volume bounded by flights + (room-types × horizon nights).

# Documents to update at implementation

- `inventory-service` — resync service (scan `flight_inventory` + `room_type_availability`, emit via
  outbox with preserved versions) + `ResyncEndpoint` (actuator), tests; `application.yml` exposure.
- Experiment 07 runbook — beyond-retention variant: wipe search → resync catalog → resync availability.
- ADR index (`docs/adr/README.md`) + `docs/SPECS-INDEX.md` (`DR-005`).
- No AsyncAPI/OpenAPI change.
