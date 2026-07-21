# Read Model Rebuild — choosing the replay source of truth

**Origin:** Experiment 07 — Read Model Rebuild · **Phase:** 7 (architecture) · **Status:** DECISION PENDING
**Services potentially affected:** search + (A) Kafka-platform / (B) flight, hotel, inventory

> Decision doc: to prove "the CQRS read side is fully derivable by replaying events", the events
> must still *exist* to replay. Today they don't beyond 7 days (all source topics are
> `cleanup.policy=delete`, `retention.ms=604800000`, none compacted). This doc compares the two
> ways to make a full rebuild possible and recommends one, so the experiment can target it.

## What the read model needs to rebuild

The search read model (`search_db`) is derived from two event families:

- **Catalog** — `flight.created/updated/deleted`, `hotel.created/updated/deleted` (owned by
  flight-service / hotel-service; keyed by `flightId` / `hotelId`; deduped in `consumed_events`).
  Builds `flight_projections`, `hotel_projections` + `hotel_room_types`, and the per-night
  `room_type_availability` calendar rows.
- **Availability** — `inventory.flight/hotel.reserved/released/expired` (owned by inventory-service;
  **absolute** `reserved` values guarded by `version`; not deduped — last-version-wins). Sets the
  `reserved`/`version` on flight and per-night hotel rows.

A rebuild = quiesce → **TRUNCATE the whole read model** (projections + `consumed_events`) → make
search re-consume from the beginning → verify it converges to the live state. The blocker is
step "re-consume from the beginning": with 7-day delete retention, any entity whose defining
events are older than 7 days is simply **gone** from the log, so replay can't reconstruct it.

Two independent wrinkles compound this (both covered in the experiment regardless of strategy):

- **Ordering.** `applyFlightAvailability`/`applyHotelAvailability` drop an availability event if the
  catalog projection doesn't exist yet (`findById → else log.warn`, no retry). On replay across
  separate topics there's no cross-topic order guarantee → a rebuild must apply **catalog before
  availability**.
- **Clock-relative calendar.** The hotel night window is materialized `today .. today+horizon`
  (`LocalDate.now`), so a rebuild is compared against the *current* horizon, not a stale snapshot.

## Strategy A — Log compaction (Kafka is the durable replay source)

Set `cleanup.policy=compact` (or `compact,delete`) on the catalog + availability topics so Kafka
retains the **latest event per key forever** (bounded by key count, not event volume). Rebuild
stays purely search-side: wipe + reset the search group to `earliest` + re-consume.

**Pros**
- Rebuild is self-contained in search + a topic-config change; no producer involvement, works even
  if an owning service is down at rebuild time.
- The log itself becomes the durable state — "replay the topic" literally reconstructs everything.
- Cheap and bounded: ~one record per live entity, regardless of update volume.

**Cons / Atlas frictions**
- **Doesn't fit the current topic model cleanly.** Catalog is split across three topics
  (`created`/`updated`/`deleted`) with **no version guard**; compaction keeps the latest *per topic*,
  so cross-topic ordering still decides the final state. A correct compaction model wants **one topic
  per aggregate** (keyed by id, `version`-guarded, **tombstone** for delete) — a messaging-contract
  change.
- **Hotel availability doesn't compact per night.** Those events carry *multiple* nights keyed by
  `roomTypeId`; compaction by `roomTypeId` keeps only the *last* event, losing the current value of
  nights it didn't touch. Correct compaction needs one record per `(roomTypeId, night)` — i.e.
  splitting the event — another contract change.
- Requires every producer to key its messages (verify) and to emit tombstones on delete.
- Compaction is eventual; fine for an idempotent/last-wins projection, but not "exact log".

## Strategy B — Republish / resync from the owning service (DB is the source of truth)

Keep Kafka short-retention. Give each owner (flight, hotel, inventory) a **resync capability** — a
job/endpoint that walks its own DB and re-emits the current catalog/availability events through the
existing outbox. Rebuild = wipe read model → trigger resync on each owner (catalog first, then
availability) → search re-consumes.

**Pros**
- **Matches Atlas's actual architecture.** The authoritative state already lives in
  `flight_db` / `hotel_db` / `inventory_db` (outbox pattern); Kafka is transport, not the ledger.
  Resync re-emits from the real source of truth.
- **Solves both wrinkles for free.** The owner emits *current absolute* state, so hotel availability
  is re-emitted correctly across all nights; and the orchestrator can emit **all catalog, then all
  availability**, eliminating the ordering drop without touching the search consumer.
- No messaging-contract change: topics, keys, schemas, retention all stay as they are.
- Point-in-time consistent snapshot straight from each DB.

**Cons / Atlas frictions**
- **Cross-service change in three producers** (resync job in flight, hotel, inventory) → three ADRs
  (`DR-002`) + an orchestration story; larger surface than one topic-config change.
- Re-emitting catalog also re-hits **inventory-service's** `CatalogEventConsumer` (it seeds inventory
  from catalog) and search — must be idempotent (guards already exist) but is a side effect to
  reason about.
- Resynced availability must carry a `version` ≥ the stored one or it's dropped as stale — the resync
  must read and preserve/raise versions.

## Side-by-side (Atlas)

| Dimension | A — Compaction | B — Republish/resync |
|-----------|----------------|----------------------|
| Source of truth | the Kafka log | the owning service DB (as today) |
| What changes | `topics.yaml` + keying + tombstones + (ideally) 1-topic-per-aggregate + per-night availability | resync job in flight/hotel/inventory + rebuild orchestration |
| Scope | Kafka-platform + light producer changes | 3 producer services (3 ADRs) |
| Contract impact | **High** (topic model, tombstones, split availability) | **None** (schemas/topics unchanged) |
| Fixes ordering gap? | No (still cross-topic) | **Yes** (emit catalog then availability) |
| Hotel per-night availability | **Hard** (needs per-night keying) | **Natural** (owner emits current state) |
| Rebuild trigger | search-side only (wipe + reset offsets) | orchestrate resync on owners + wipe search |
| Owner uptime needed at rebuild | No | Yes |
| Storage | bounded latest-per-key in Kafka | short retention; state stays in DBs |
| Effort | medium-high (contract rework) | medium (3 jobs, no contract rework) |

## Recommendation

**Strategy B (republish/resync).** It fits what Atlas already is — DB-as-source-of-truth with an
outbox — and it *dissolves* the two wrinkles that Strategy A leaves open (hotel per-night
availability and catalog-before-availability ordering) instead of forcing a rework of the topic
model, keys, tombstones and event shapes. The price is a resync job in three owning services rather
than one topic-config flag, but each is small and contract-free, and the result is a rebuild that is
correct by construction. Compaction is the more "Kafka-native" answer and worth revisiting if Atlas
later moves to Kafka-as-ledger, but today it fights the current design.

## What this means for Experiment 07

Independent of the strategy, the experiment can **already demonstrate derivability within the
retention window** today (wipe read model → reset search to `earliest` → ordered replay → assert
convergence to the live `flight_projections` / `room_type_availability` state, allowing for the
clock-relative horizon). The strategy chosen here is what the experiment **recommends** to close the
beyond-retention gap, captured as ADR(s):

- **If B:** ADRs for flight / hotel / inventory resync (`DR-002`, one per service) + a search-side
  rebuild runbook that orchestrates them.
- **If A:** a Kafka-platform ADR (compaction + tombstones) plus the availability/topic-shape rework.
