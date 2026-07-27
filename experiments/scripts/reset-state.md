# Experiment State Reset — Atlas

Runnable procedure to return the cluster to a **clean, repeatable baseline between runs**.
A load / resilience test leaves durable state in three places — Postgres (per-service DBs),
Kafka (topic data + consumer offsets), and the search read model — and unless all three are
reset consistently, the *next* run starts contaminated (stale reservations holding stock, old
events replaying, offsets mid-stream). This doc fixes *what* is wiped, *what* is preserved, and
*why*; the executable counterpart is [`reset-state.sh`](./reset-state.sh).

It respects the database-per-service boundary (`ARCH-002`, `ARCH-003`): the reset touches each
service's **own** logical database only, never crosses a boundary, and never joins across DBs.

---

## 1. Principle — quiesce, then wipe, then resume

A wipe under live traffic races the apps (in-flight Sagas keep writing; `TRUNCATE` blocks on
active connections). So the order is always:

1. **Quiesce** — scale `atlas-apps` to 0 and remove the HPAs, so no client holds a connection
   or runs a Saga. Reuses the tested lever [`deploy/ops/apps/idle.sh`](../../deploy/ops/apps/idle.sh)
   (it deletes HPAs *first*, otherwise they immediately re-scale back to `minReplicas`).
2. **Wipe** — truncate transactional + outbox + idempotency tables per DB; reset Kafka
   consumer offsets; reset the inventory stock counters (§3).
3. **Resume** — bring the apps back with [`deploy/ops/apps/resume.sh`](../../deploy/ops/apps/resume.sh),
   which restores replicas **and recreates the HPAs** (the experiments test HPA scaling, so the
   HPAs must come back). Flyway is a no-op on restart because the schema and
   `flyway_schema_history` are preserved (§2).

> Why not "disconnect the DB pod"? The Postgres pods are managed by CloudNativePG; detaching or
> killing the primary triggers a failover, not a quiet pause. Scaling the **apps** to 0 removes
> every client connection without touching the data layer — safer and faster.

---

## 2. Wipe strategy — targeted `TRUNCATE`, not `DROP SCHEMA`

`DROP SCHEMA public CASCADE; CREATE SCHEMA public;` also destroys `flyway_schema_history`,
forcing a full re-migration on restart, and on PostgreSQL 15+ it requires re-granting schema
ownership to the service role or Flyway fails to recreate objects. For a **repeatable** reset
where the schema is stable, a targeted `TRUNCATE ... RESTART IDENTITY CASCADE` is faster,
deterministic, and avoids the grant pitfalls. Schema, migration history and reference data
survive untouched. `flyway_schema_history` is **never** in any truncate list.

---

## 3. What is wiped vs preserved (per service DB)

Table inventory is derived from each service's Flyway migrations (`src/main/resources/db/migration`).

| DB (`atlas-pg`) | Truncated | Preserved | Notes |
|-----------------|-----------|-----------|-------|
| `booking_db` | `bookings`, `booking_items`, `travelers`, `booking_status_history`, `consumed_events`, `outbox` | — | All booking state is transactional. |
| `payment_db` | `payments`, `payment_attempts`, `payment_provider_responses`, `consumed_events`, `outbox` | — | All payment state is transactional. |
| `inventory_db` | `reservations`, `reservation_history`, `consumed_events`, `outbox` | `flight_inventory`, `room_type_availability` (rows) | **Stock tables are NOT truncated** — they hold seeded capacity/calendar kept in sync by catalog events. Instead the counters are reset: `UPDATE flight_inventory SET reserved_count = 0` and `UPDATE room_type_availability SET reserved = 0` (per-night hotel stock, ADR-0008). See §3.1. |
| `travel_cart_db` | `cart_items`, `carts` | — | Transactional. |
| `flight_db` | `outbox` | catalog (`flights`, `flight_segments`, `airlines`, `airports`) | Catalog is fixed read-only test input; only the **publisher outbox** is drained. |
| `hotel_db` | `outbox` | catalog (`hotels`, `room_types`, `amenities`, `hotel_images`, `room_images`) | Same as flight: catalog preserved, outbox drained. |
| `search_db` | `consumed_events`; **`flight_projections.reserved` and `room_type_availability.reserved` → 0, `version` → 0 (UPDATE, not truncate)** | `flight_projections`, `hotel_projections`, `hotel_room_types`, `room_type_availability` rows (incl. `capacity`/calendar) | Read model. `reserved` is an absolute, `version`-guarded value fed by inventory events (ADR-0008/0009) — reset to mirror inventory; `capacity`/calendar and catalog projections come from catalog events and would not repopulate while idle, so they are kept. See §3.2. |
| `user_db` | — | `user_profiles` | Fixed test-user dataset; treated like reference data. |
| `keycloak_db` | — | everything | **Never touched.** Wiping it destroys the realm/users all 8 services authenticate against. |

Critically, **every service with a publisher has its `outbox` truncated** — including the
catalog services `flight` and `hotel`, whose catalog rows we keep but whose outbox must be
drained so stale change events are not republished on resume.

### 3.1 Inventory stock reset (decision to confirm)

Availability is split by ADR-0008: flights in `flight_inventory`
(`available = total_capacity - reserved_count`) and hotels **per night** in
`room_type_availability` (`available = total_rooms - reserved`, one row per
`room_type_id × stay_date`). Reservations raise the reserved counter; releasing/expiring lowers
it. A clean slate therefore means **the reserved counter back to 0** on every row, not deleting
the rows (which would erase the seeded/synced capacity and the hotel calendar, and would *not* be
recreated since Flyway won't re-run). The reset does:

```sql
UPDATE flight_inventory       SET reserved_count = 0, updated_at = now();
UPDATE room_type_availability SET reserved       = 0, updated_at = now();
```

`total_capacity` / `total_rooms` are left as-is (catalog is not modified during a run, so it is
already the baseline). This is the one place the reset encodes a domain assumption; if the
intended baseline differs (e.g. re-seed capacity from catalog), flag it and this doc changes.

### 3.2 Search read model mirrors inventory — reset `reserved`, keep `capacity`

`search-service` holds availability in two projections (ADR-0009; the former shared
`availability_projections` was dropped): flight availability folded into `flight_projections`
(`available = capacity - reserved`), and per-night hotel availability in `room_type_availability`
(one row per `resource_id × stay_date`). In both, the columns have **different sources**:

- `capacity`/calendar is written by **catalog** events (Flight/Hotel `created`/`updated`).
- `reserved` is an **absolute value guarded by `version`** driven by inventory resource-facing
  events (ADR-0008): `InventoryAvailabilityConsumer` sets `reserved` to the new absolute value
  iff `version ≥` the stored one (keyed by `flightId` / `roomTypeId`). This replaced the old
  commutative delta counters.

Consequence for the reset: when we reset the inventory counters to 0, the search projections do
**not** self-correct — inventory is idle after the wipe and emits no new events. Leaving them
stale makes search over-report reservations. So the reset **mirrors inventory**:
`UPDATE flight_projections SET reserved = 0, version = 0` and
`UPDATE room_type_availability SET reserved = 0, version = 0`. It does **not** truncate the tables,
because that would also wipe `capacity`/calendar (catalog-sourced, not repopulated while idle) and
the catalog projections — leaving search empty. Zeroing `version` guarantees the next real
availability event (which carries `version = clock.millis() > 0`) re-applies. This is the
symmetric counterpart of the inventory reset in §3.1: both `reserved` counters go to 0, both keep
their capacity.

A full read-model rebuild (truncate all projections + replay catalog from offset earliest) is a
different operation, owned by the Read-Model-Rebuild experiment (07), not this baseline reset.

### 3.3 Kafka consistency

Truncating `consumed_events` (the idempotency ledger) without also advancing consumer offsets
would let a consumer re-process pre-reset events and double-insert. So the Kafka step resets
**every consumer group to `--to-latest`** while the apps are down (offset reset refuses to run
against a group with active members — quiescing first is what makes it work). Combined with the
drained outboxes and cleared `consumed_events`, no pre-reset event is re-delivered or
re-published. Cluster: Strimzi `atlas`, bootstrap `atlas-kafka-bootstrap.atlas-data:9092`.

Topic **data** is not purged by default (offsets-to-latest is enough to ignore it, and RF/retention
experiments may want the log intact).

---

## 4. Safety guardrails

The script refuses to run unless: the current `kubectl` context is confirmed (printed, and
blocked if it matches a `prod` pattern); the `atlas-apps` and `atlas-data` namespaces exist; and
an explicit `CONFIRM=yes` (or `--yes`) is supplied. `DRY_RUN=1` prints every action and changes
nothing — run it first, every time.

### 4.1 Robustness (post-mortem of the hung resets)

Early versions could hang mid-wipe or die silently; four fixes make the script re-runnable:

- **No silent hangs.** Every `psql` runs with `lock_timeout=15s` / `statement_timeout=600s`
  (via `PGOPTIONS`): a stray lock holder or runaway statement now fails loudly with a clear
  error instead of blocking forever.
- **Stray-backend cleanup.** A Ctrl-C'd reset kills the `kubectl exec` but *not* the `psql`
  inside the pod — the orphan keeps its table locks and the next reset waits on them forever.
  With the apps quiesced, any other backend on a service DB is by definition a leftover, so
  the script terminates them all (`pg_terminate_backend`) before wiping. `keycloak_db` and
  the script's own session are never touched.
- **Dirty-row updates only.** The stock/projection resets previously rewrote *every* row
  (`UPDATE 10000` on flights, far more on per-night hotel rows) even when already `0`. That
  WAL burst flooded the standby (large replication lag) and — under synchronous replication —
  stalled the primary's own commits, which read as a hang. All these `UPDATE`s now carry a
  `WHERE ... <> 0` filter, so a reset after a modest experiment touches only the rows that
  actually diverged.
- **Standby catch-up before resume (step 4a).** After the wipe, the script waits for the
  standby's replay lag to drain below `REPL_MAX_LAG` (32 MB default, up to `REPL_WAIT=180s`)
  before resuming the apps, and warns explicitly when `synchronous_standby_names` is set
  (that is the configuration where a lagging standby blocks primary commits).

One latent bash bug is also worth recording: the consumer-group list was assigned to a
variable named `GROUPS`, which is a **readonly bash builtin** — the assignment failed and,
under `set -e`, silently killed the script right before step 3, so the Kafka offset reset
*and the app resume* never actually ran in earlier resets. Renamed to `CONSUMER_GROUPS`.

---

## 5. How to run

```bash
# preview — changes nothing
DRY_RUN=1 ./experiments/scripts/reset-state.sh

# execute (destructive)
CONFIRM=yes ./experiments/scripts/reset-state.sh

# or via the Makefile (dry-run by default; pass CONFIRM=yes to execute)
make -C experiments reset
make -C experiments reset CONFIRM=yes
```

What it does: guardrails → resolve CNPG primary + Kafka broker pods → `idle.sh` (wait for
0 pods) → per-DB truncate set (§3) + inventory/search `reserved` reset via
`psql -v ON_ERROR_STOP=1` in the primary pod → reset every Kafka consumer group to latest →
`resume.sh` → summary (both `reserved` sums should read 0).

Flags: `--skip-kafka`, `--skip-quiesce` (when apps are already idle).

---

## 6. Rule references

- `ARCH-002`, `ARCH-003`, `DB-001`, `DB-003` — per-service DB isolation honored: each DB is
  reset independently, no cross-DB access.
- Deployment-roadmap `§6` (database-per-service layout, roles), `§10.4` (scale non-essential
  services to 0 in experiment windows), `§Phase 7`.
- `SEC-*` — logs no secrets; authenticates via in-pod `psql` (peer), never echoes credentials.

## 7. Open decisions

- **Inventory baseline** (§3.1): `reserved_count = 0` vs full re-seed from catalog. Current
  choice: reset counter. Confirm.
- **Search read model** (§3.2): reset `reserved = 0` (keep capacity/catalog) vs full
  truncate-and-replay. Current choice: reset `reserved`, mirroring inventory. Full rebuild is
  deferred to experiment 07.
- **Topic purge** (§3.3): offsets-to-latest vs deleting/recreating topics. Current choice:
  offsets only.
