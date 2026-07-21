---
adr_id: ADR-0025
title: Flight catalog resync (republish current state for read-model rebuild)
service: Flight
status: COMPLETED
date: 2026-07-20
depends_on: []
---

# ADR-0025 — Flight catalog resync

# Status

`COMPLETED` (created 2026-07-20, implemented in the same change-set). Origin: Experiment 07 — Read Model Rebuild
([experiments/07-read-model-rebuild/rebuild-source-of-truth.md](../../experiments/07-read-model-rebuild/rebuild-source-of-truth.md),
Strategy B). Paired with [ADR-0026](ADR-0026-hotel-catalog-resync.md) (hotel) and
[ADR-0027](ADR-0027-inventory-availability-resync.md) (inventory) — one ADR per owning service
(`DR-002`). Flip to `COMPLETED` when implemented and merged (`DR-003`).

# Context

Experiment 07 showed the search read model is derivable by replay only **within** the 7-day topic
retention: all source topics are `cleanup.policy=delete, retention.ms=604800000`, so a rebuild from
`earliest` cannot reconstruct entities whose defining events aged out. Strategy B
(`rebuild-source-of-truth.md`) makes the read model rebuildable at any time by having each **owning
service re-emit its current state from its own DB** (the real source of truth; Kafka is transport),
instead of relying on Kafka durability. Flight-service owns the flight catalog in `flight_db`.

# Decision

Add an operational **resync** capability to flight-service that re-publishes the current catalog:

- Trigger: a guarded actuator endpoint `POST /actuator/resync` on the internal management port
  (RBAC-gated via the k8s API, not exposed via ingress) — same operational-control pattern as
  [ADR-0022](ADR-0022-payment-dlq-replay.md)'s `dlqreplay`. Deliberate, no redeploy.
- Action: iterate flights in `flight_db`; for each **active** flight emit its catalog upsert event
  (the `flight.created`/`flight.updated` payload shape) and for each **withdrawn** flight emit
  `flight.deleted` — all through the existing **outbox** (EVT-009: state read + events emitted, no
  dual-write), keyed by `flightId`, preserving order per key.
- Idempotency: fresh `eventId`s. Search (mid-rebuild, `consumed_events` wiped) re-applies them;
  inventory-service's `CatalogEventConsumer` also re-consumes (it seeds capacity from catalog) but
  its upsert is idempotent and touches capacity only, never `reserved` — a benign re-seed. (An
  alternative that reuses original `eventId`s to make inventory dedup is possible but needs the
  original ids persisted; not needed for MVP.)
- Ordering: the rebuild orchestrator (Exp 07 runbook) calls catalog resync (flight + hotel) and
  waits for it to project **before** availability resync (ADR-0027) — so this endpoint stays
  independent, no cross-service coupling in code.

# Consequences

**Positive.** The flight catalog becomes rebuildable at any time regardless of Kafka retention,
from the authoritative `flight_db`. No schema/contract change — same topics, keys and payloads.
**Negative / assumption.** Re-emitting catalog re-triggers inventory's seed consumer (idempotent);
resync SHOULD run in a maintenance window / no-load, since it republishes the whole catalog. Volume
is bounded by the number of flights.

# Documents to update at implementation

- `flight-service` — resync service (DB scan + outbox emit) + `ResyncEndpoint` (actuator), tests.
- `application.yml` — expose the `resync` actuator endpoint.
- Experiment 07 runbook — a beyond-retention variant that wipes search then orchestrates the resyncs.
- ADR index (`docs/adr/README.md`) + `docs/SPECS-INDEX.md` (`DR-005`).
- No AsyncAPI/OpenAPI change (operational endpoint; catalog event contracts unchanged).
