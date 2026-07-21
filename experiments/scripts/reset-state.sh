#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# reset-state.sh — return the cluster to a clean, repeatable baseline between
# experiment runs. Doc: experiments/scripts/reset-state.md.
#
# Resets THREE state stores consistently:
#   • Postgres  — targeted TRUNCATE of transactional + outbox + idempotency tables
#                 per service DB (schema & flyway history preserved); inventory stock
#                 counters reset to 0 (flight_inventory + per-night room_type_availability).
#                 Catalogs, user_profiles and keycloak_db preserved.
#   • Kafka     — every consumer group reset --to-latest (apps must be down for this).
#   • Read model— search reserved reset to 0 to mirror inventory, across flight_projections
#                 and room_type_availability (absolute + version model, ADR-0008/0009;
#                 catalog/capacity/calendar kept).
#
# Order is always: quiesce (apps -> 0) → wipe → wait-for-standby → resume. Idempotent,
# re-runnable, and hardened for reuse:
#   • every psql runs with lock_timeout/statement_timeout — fails loudly, never hangs;
#   • stray backends on service DBs are terminated before the wipe (a Ctrl-C'd previous
#     reset leaves an orphaned psql holding locks — the classic cause of a hung reset);
#   • stock/projection resets only touch DIRTY rows (no full-table rewrite → no WAL burst
#     → no standby replication-lag spiral after each reset);
#   • before resuming apps, waits for the standby's replay lag to drain
#     (REPL_MAX_LAG bytes, default 32MB; REPL_WAIT seconds, default 180).
#
# Usage:
#   DRY_RUN=1 ./experiments/scripts/reset-state.sh       # preview, change nothing
#   CONFIRM=yes ./experiments/scripts/reset-state.sh     # execute (destructive)
#   make -C experiments reset                            # (dry-run) via Makefile
#   make -C experiments reset CONFIRM=yes                # execute via Makefile
#
# Flags:
#   --skip-kafka       do not reset consumer group offsets
#   --skip-quiesce     assume apps are already idle (skip apps-idle.sh / resume)
#   --yes              same as CONFIRM=yes
#
# Prereqs: kubectl context pointing at the Atlas cluster.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APPS_NS="atlas-apps"
DATA_NS="atlas-data"
PG_CLUSTER="atlas-pg"
KAFKA_CLUSTER="atlas"
KAFKA_BIN="/opt/kafka/bin/kafka-consumer-groups.sh"
KAFKA_BOOTSTRAP="localhost:9092"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# experiments/scripts -> repo root is two levels up; ops lever lives in deploy/ops.
OPS_DIR="${OPS_DIR:-$(cd "${SCRIPT_DIR}/../../deploy/ops" && pwd)}"

DRY_RUN="${DRY_RUN:-0}"
CONFIRM="${CONFIRM:-no}"
SKIP_KAFKA=0
SKIP_QUIESCE=0

for arg in "$@"; do
  case "$arg" in
    --skip-kafka)     SKIP_KAFKA=1 ;;
    --skip-quiesce)   SKIP_QUIESCE=1 ;;
    --yes)            CONFIRM="yes" ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '   [dry-run] %s\n' "$*"; else eval "$*"; fi; }

# ── Guardrails ───────────────────────────────────────────────────────────────
say "Guardrails"
CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CTX" ]] || die "no kubectl context set."
info "kubectl context: $CTX"
if [[ "$CTX" =~ [Pp]rod ]]; then
  die "context '$CTX' looks like PRODUCTION — refusing. This script is destructive."
fi
kubectl get ns "$APPS_NS" >/dev/null 2>&1 || die "namespace $APPS_NS not found."
kubectl get ns "$DATA_NS" >/dev/null 2>&1 || die "namespace $DATA_NS not found."
if [[ "$DRY_RUN" != "1" && "$CONFIRM" != "yes" ]]; then
  die "destructive op. Re-run with CONFIRM=yes (or --yes), or preview with DRY_RUN=1."
fi

# ── Resolve platform pods ────────────────────────────────────────────────────
say "Resolve platform pods"
PG_PRIMARY="$(kubectl -n "$DATA_NS" get pods \
  -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$PG_PRIMARY" ]]; then
  # older CloudNativePG label
  PG_PRIMARY="$(kubectl -n "$DATA_NS" get pods \
    -l "cnpg.io/cluster=${PG_CLUSTER},role=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
[[ -n "$PG_PRIMARY" ]] || die "could not find CNPG primary pod for cluster ${PG_CLUSTER}."
info "Postgres primary: $PG_PRIMARY"

KAFKA_POD=""
if [[ "$SKIP_KAFKA" != "1" ]]; then
  KAFKA_POD="$(kubectl -n "$DATA_NS" get pods -l "strimzi.io/cluster=${KAFKA_CLUSTER}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -Ei 'dual-role|broker|kafka' | head -1 || true)"
  [[ -n "$KAFKA_POD" ]] || die "could not find a Kafka broker pod for cluster ${KAFKA_CLUSTER} (use --skip-kafka to skip)."
  info "Kafka broker:    $KAFKA_POD"
fi

# psql helpers: run SQL inside the primary pod as superuser against a given DB.
# - `-c postgres` pins the container (silences the "Defaulted container" noise).
# - PGOPTIONS sets lock_timeout/statement_timeout so the script FAILS LOUDLY instead of
#   hanging forever on a stray lock holder or a runaway statement.
PSQL_TIMEOUTS="-c lock_timeout=15s -c statement_timeout=600s"
psql_do() {
  local db="$1" sql="$2"
  run "kubectl -n '$DATA_NS' exec -c postgres '$PG_PRIMARY' -- env PGOPTIONS='$PSQL_TIMEOUTS' psql -U postgres -d '$db' -v ON_ERROR_STOP=1 -c \"$sql\""
}
# Scalar query (always executes, even in dry-run — read-only).
psql_val() {
  local db="$1" sql="$2"
  kubectl -n "$DATA_NS" exec -c postgres "$PG_PRIMARY" -- \
    psql -U postgres -d "$db" -tA -c "$sql" 2>/dev/null | tr -d '[:space:]'
}

# ── 1. Quiesce ───────────────────────────────────────────────────────────────
if [[ "$SKIP_QUIESCE" != "1" ]]; then
  say "1. Quiesce apps (apps-idle.sh) — scale ${APPS_NS} to 0, remove HPAs"
  run "NS='$APPS_NS' bash '${OPS_DIR}/apps-idle.sh'"
  if [[ "$DRY_RUN" != "1" ]]; then
    info "waiting for app pods to terminate..."
    for _ in $(seq 1 60); do
      n="$(kubectl -n "$APPS_NS" get pods --no-headers 2>/dev/null | grep -vc 'Completed' || true)"
      [[ "${n:-0}" -eq 0 ]] && break
      sleep 2
    done
    [[ "${n:-0}" -eq 0 ]] || warn "some app pods still terminating after 120s — Kafka group reset may find active members."
  fi
else
  warn "1. Skipping quiesce (--skip-quiesce): assuming apps already idle."
fi

# ── 2. Wipe Postgres (targeted TRUNCATE per service DB) ───────────────────────
say "2. Wipe Postgres — targeted TRUNCATE (schema + flyway_schema_history preserved)"

# With the apps quiesced, ANY other backend on a service DB is a leftover — typically a psql
# orphaned by a Ctrl-C'd previous reset (kubectl exec dies, the psql inside the pod does not)
# still holding table locks that would make our statements wait forever. Terminate them first.
info "terminating stray backends on service DBs (apps are down; anything there is a leftover)"
psql_do postgres \
  "SELECT count(pg_terminate_backend(pid)) AS terminated FROM pg_stat_activity WHERE datname IN ('booking_db','payment_db','inventory_db','travel_cart_db','flight_db','hotel_db','search_db') AND pid <> pg_backend_pid();"

info "booking_db"
psql_do booking_db \
  "TRUNCATE TABLE bookings, booking_items, travelers, booking_status_history, consumed_events, outbox RESTART IDENTITY CASCADE;"

info "payment_db"
psql_do payment_db \
  "TRUNCATE TABLE payments, payment_attempts, payment_provider_responses, consumed_events, outbox RESTART IDENTITY CASCADE;"

info "inventory_db (truncate reservations/outbox; reset stock counters, keep seeded rows)"
psql_do inventory_db \
  "TRUNCATE TABLE reservations, reservation_history, consumed_events, outbox RESTART IDENTITY CASCADE;"
# Availability split by ADR-0008: flights in flight_inventory (reserved_count), hotels per
# night in room_type_availability (reserved). Reset both; keep seeded capacity/calendar rows.
# ONLY touch dirty rows: an unconditional UPDATE rewrites every row (10k flights, far more
# per-night hotel rows) even when already 0 — a huge WAL burst that floods the standby
# (replication lag) and, under synchronous replication, stalls the primary's commits.
psql_do inventory_db \
  "UPDATE flight_inventory SET reserved_count = 0, updated_at = now() WHERE reserved_count <> 0;"
psql_do inventory_db \
  "UPDATE room_type_availability SET reserved = 0, updated_at = now() WHERE reserved <> 0;"

info "travel_cart_db"
psql_do travel_cart_db \
  "TRUNCATE TABLE cart_items, carts RESTART IDENTITY CASCADE;"

info "flight_db (drain publisher outbox; keep catalog)"
psql_do flight_db \
  "TRUNCATE TABLE outbox RESTART IDENTITY CASCADE;"

info "hotel_db (drain publisher outbox; keep catalog)"
psql_do hotel_db \
  "TRUNCATE TABLE outbox RESTART IDENTITY CASCADE;"

info "search_db (reset read-model reserved to mirror inventory; keep catalog + capacity/calendar)"
# reserved is now an ABSOLUTE value guarded by `version` (ADR-0008/0009), split across
# flight_projections (flights) and room_type_availability (hotels, per night). The former
# shared availability_projections table was dropped. Reset both WITHOUT truncating — capacity
# and the hotel calendar come from catalog events and would not be repopulated while idle.
# Zero `version` too so any post-reset availability event re-applies cleanly (inventory emits
# version = clock.millis(), always > 0).
# Same dirty-row filter as inventory: only rewrite rows that actually diverge.
psql_do search_db \
  "UPDATE flight_projections SET reserved = 0, version = 0, updated_at = now() WHERE reserved <> 0 OR version <> 0;"
psql_do search_db \
  "UPDATE room_type_availability SET reserved = 0, version = 0, updated_at = now() WHERE reserved <> 0 OR version <> 0;"
psql_do search_db \
  "TRUNCATE TABLE consumed_events RESTART IDENTITY;"

info "user_db preserved (test-user profiles); keycloak_db never touched."
info "search catalog projections (flight/hotel/room_types) preserved — repopulated only by catalog replay."

# ── 3. Reset Kafka consumer offsets ──────────────────────────────────────────
if [[ "$SKIP_KAFKA" != "1" ]]; then
  say "3. Reset Kafka consumer groups --to-latest (apps are down, so no active members)"
  # NOTE: named CONSUMER_GROUPS on purpose — GROUPS is a READONLY bash builtin; assigning to
  # it fails and, under set -e, silently killed the script right here (steps 3+4 never ran).
  CONSUMER_GROUPS="$(kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- \
    "$KAFKA_BIN" --bootstrap-server "$KAFKA_BOOTSTRAP" --list 2>/dev/null | grep -v '^$' || true)"
  if [[ -z "$CONSUMER_GROUPS" ]]; then
    warn "no consumer groups found."
  else
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      info "reset group: $g"
      run "kubectl -n '$DATA_NS' exec '$KAFKA_POD' -- '$KAFKA_BIN' --bootstrap-server '$KAFKA_BOOTSTRAP' --group '$g' --reset-offsets --all-topics --to-latest --execute"
    done <<< "$CONSUMER_GROUPS"
  fi
else
  warn "3. Skipping Kafka reset (--skip-kafka)."
fi

# ── 4. Wait for the standby to catch up, then resume ─────────────────────────
# The wipe generates a WAL burst; if the apps come back while the standby is still replaying
# it, primary queries suffer (and under synchronous replication, commits outright stall).
# Wait until replay lag is small before resuming. REPL_MAX_LAG bytes (32MB), REPL_WAIT secs.
REPL_MAX_LAG="${REPL_MAX_LAG:-33554432}"
REPL_WAIT="${REPL_WAIT:-180}"
if [[ "$DRY_RUN" != "1" ]]; then
  say "4a. Wait for standby replication to catch up (max ${REPL_WAIT}s)"
  SYNC_NAMES="$(psql_val postgres 'SHOW synchronous_standby_names;' || true)"
  [[ -n "$SYNC_NAMES" ]] && warn "synchronous replication is ON ('$SYNC_NAMES') — a lagging standby blocks primary commits; this wait matters."
  for _ in $(seq 1 "$(( REPL_WAIT / 5 ))"); do
    lag="$(psql_val postgres 'SELECT coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn))::bigint, 0) FROM pg_stat_replication;' || echo 0)"
    info "standby replay lag: ${lag:-?} bytes"
    [[ "${lag:-0}" -le "$REPL_MAX_LAG" ]] && break
    sleep 5
  done
  if [[ "${lag:-0}" -gt "$REPL_MAX_LAG" ]]; then
    warn "standby still ${lag} bytes behind after ${REPL_WAIT}s — resuming anyway; watch the CNPG cluster."
  fi
fi

if [[ "$SKIP_QUIESCE" != "1" ]]; then
  say "4b. Resume apps (apps-resume.sh) — restore replicas + recreate HPAs"
  run "NS='$APPS_NS' bash '${OPS_DIR}/apps-resume.sh'"
else
  warn "4b. Skipping resume (--skip-quiesce): bring apps back yourself when ready."
fi

# ── 5. Summary ───────────────────────────────────────────────────────────────
say "Done"
if [[ "$DRY_RUN" == "1" ]]; then
  info "DRY-RUN complete — nothing changed. Re-run with CONFIRM=yes to execute."
else
  info "Reset complete. Spot-check before the next run (all reserved sums should be 0):"
  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d booking_db   -c 'SELECT count(*) FROM bookings;'"
  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d inventory_db -c 'SELECT sum(reserved_count) FROM flight_inventory;'"
  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d inventory_db -c 'SELECT sum(reserved) FROM room_type_availability;'"
  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d search_db    -c 'SELECT sum(reserved) FROM flight_projections;'"
  info "  kubectl -n $DATA_NS exec $PG_PRIMARY -- psql -U postgres -d search_db    -c 'SELECT sum(reserved) FROM room_type_availability;'"
  info "  kubectl -n $APPS_NS get deploy,hpa"
fi
