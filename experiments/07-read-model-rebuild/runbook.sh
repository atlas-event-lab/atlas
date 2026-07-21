#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Experiment 07 — Read Model Rebuild (within-retention proof)
#
# Proves the CQRS read side (search) is derivable by replay: wipe the entire read model, replay the
# event log in catalog-before-availability order, and verify search_db converges to the pre-wipe
# state (counts + semantic checksums). No code change — this demonstrates the mechanism within the
# 7-day retention window; the beyond-retention rebuild is Strategy B (resync, ADR-0025/26/27).
#
# Flow: guardrails → snapshot BEFORE → quiesce search (replicas 0) → TRUNCATE read model →
#       ordered replay (reset catalog→earliest / availability→latest, drain; then availability→
#       earliest, drain) → snapshot AFTER → verdict. A trap restores the original replica count.
#
# Usage:
#   set -a; source ../.env; set +a
#   DRY_RUN=1 ./runbook.sh                  # preview, change nothing
#   CONFIRM=yes ./runbook.sh                # wipe + ordered rebuild + verify
#   CONFIRM=yes CONTROL=1 ./runbook.sh      # also run reversed-order control (expect non-convergence)
#   CONFIRM=yes REBUILD=resync ./runbook.sh # beyond-retention: rebuild by re-emitting from the owners
#                                           # (POST /actuator/resync on flight/hotel/inventory, ADR-0025/26/27)
#
# Env: SETTLE (180), SCOPE (all|flights), REBUILD (offsets|resync), CONTROL (0), DRY_RUN, CONFIRM.
#   REBUILD=offsets replays the existing log (proves derivability within the 7-day retention);
#   REBUILD=resync  re-emits current state from the owning services (works beyond retention).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APPS_NS="atlas-apps"
DATA_NS="atlas-data"
PG_CLUSTER="atlas-pg"
KAFKA_CLUSTER="atlas"
KAFKA_GROUPS="/opt/kafka/bin/kafka-consumer-groups.sh"
KAFKA_OFFSETS="/opt/kafka/bin/kafka-get-offsets.sh"
KAFKA_BOOTSTRAP="localhost:9092"

GROUP="search-service"
SEARCH_DEPLOY="search-service"

SETTLE="${SETTLE:-180}"
SCOPE="${SCOPE:-all}"
REBUILD="${REBUILD:-offsets}"   # offsets = replay existing log (within retention); resync = re-emit from owners (ADR-0025/26/27)
CONTROL="${CONTROL:-0}"
DRY_RUN="${DRY_RUN:-0}"
CONFIRM="${CONFIRM:-no}"
MGMT_PORT="9090"
RESYNC_LPORT="19090"            # local port for the owner-resync port-forward

CATALOG_TOPICS=(flight.created flight.updated flight.deleted hotel.created hotel.updated hotel.deleted)
AVAIL_TOPICS=(inventory.flight.reserved inventory.flight.released inventory.flight.expired \
              inventory.hotel.reserved inventory.hotel.released inventory.hotel.expired)
TABLES=(flight_projections hotel_projections hotel_room_types room_type_availability)
if [[ "$SCOPE" == "flights" ]]; then
  CATALOG_TOPICS=(flight.created flight.updated flight.deleted)
  AVAIL_TOPICS=(inventory.flight.reserved inventory.flight.released inventory.flight.expired)
  TABLES=(flight_projections)
fi

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m   PASS %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m   FAIL %s\033[0m\n' "$*"; }

# ── Guardrails ───────────────────────────────────────────────────────────────
say "Guardrails"
CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CTX" ]] || die "no kubectl context set."
[[ "$CTX" =~ [Pp]rod ]] && die "context '$CTX' looks like PRODUCTION — refusing."
info "kubectl context: $CTX · scope: $SCOPE · rebuild: $REBUILD"
[[ "$REBUILD" == "offsets" || "$REBUILD" == "resync" ]] || die "REBUILD must be 'offsets' or 'resync'."
if [[ "$REBUILD" == "resync" ]]; then
  command -v curl >/dev/null 2>&1 || die "curl not installed (needed to call /actuator/resync)."
fi
if [[ "$DRY_RUN" != "1" && "$CONFIRM" != "yes" ]]; then
  die "This TRUNCATEs the search read model and rebuilds it. Re-run with CONFIRM=yes, or DRY_RUN=1."
fi

# ── Resolve platform pods ────────────────────────────────────────────────────
say "Resolve platform pods"
PG_PRIMARY="$(kubectl -n "$DATA_NS" get pods \
  -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$PG_PRIMARY" ]] || PG_PRIMARY="$(kubectl -n "$DATA_NS" get pods \
  -l "cnpg.io/cluster=${PG_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$PG_PRIMARY" ]] || die "could not find CNPG primary for ${PG_CLUSTER}."
KAFKA_POD="$(kubectl -n "$DATA_NS" get pods -l "strimzi.io/cluster=${KAFKA_CLUSTER}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -Ei 'dual-role|broker|kafka' | head -1 || true)"
[[ -n "$KAFKA_POD" ]] || die "could not find a Kafka broker pod for ${KAFKA_CLUSTER}."
info "Postgres primary: $PG_PRIMARY · Kafka broker: $KAFKA_POD"

# ── Helpers ──────────────────────────────────────────────────────────────────
psql_val() { kubectl -n "$DATA_NS" exec -c postgres "$PG_PRIMARY" -- psql -U postgres -d search_db -tA -c "$1" 2>/dev/null | tr -d '[:space:]'; }
psql_do()  { kubectl -n "$DATA_NS" exec -i -c postgres "$PG_PRIMARY" -- psql -U postgres -d search_db -v ON_ERROR_STOP=1 -q -c "$1"; }

# Semantic checksum: md5 over each row's jsonb (minus volatile columns), ordered by natural key.
# room_type_availability also drops its random UUID PK; its natural key is (resource_id, stay_date).
table_checksum() { # table
  case "$1" in
    room_type_availability)
      psql_val "SELECT md5(coalesce(string_agg(j::text,'|' ORDER BY resource_id::text, stay_date),'')) \
        FROM (SELECT (to_jsonb(t)-'updated_at'-'created_at'-'id') j, resource_id, stay_date FROM room_type_availability t) s;" ;;
    *)
      psql_val "SELECT md5(coalesce(string_agg(j::text,'|' ORDER BY id::text),'')) \
        FROM (SELECT (to_jsonb(t)-'updated_at'-'created_at') j, id FROM $1 t) s;" ;;
  esac
}
table_count() { psql_val "SELECT count(*) FROM $1;"; }

# Sum the log-START (earliest) offsets over the given topics. > 0 means retention has deleted old
# segments — the full history is no longer replayable, so an offsets rebuild would be lossy.
topic_start_offsets() { # topics...
  local total=0 t o
  for t in "$@"; do
    o="$(kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- "$KAFKA_OFFSETS" \
      --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$t" --time -2 2>/dev/null \
      | awk -F: '{s+=$3} END{print s+0}')"
    total=$((total + ${o:-0}))
  done
  echo "$total"
}
topic_args() { local a=(); for t in "$@"; do a+=(--topic "$t"); done; printf '%s ' "${a[@]}"; }
lag_over() { # topics...
  local pat; pat="$(printf '%s|' "$@")"; pat="${pat%|}"
  kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- "$KAFKA_GROUPS" --bootstrap-server "$KAFKA_BOOTSTRAP" \
    --group "$GROUP" --describe 2>/dev/null | awk -v p="^($pat)$" '$2 ~ p {s+=$6} END{print s+0}'
}
reset_offsets() { # to-earliest|to-latest  topics...
  local dir="$1"; shift
  kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- "$KAFKA_GROUPS" --bootstrap-server "$KAFKA_BOOTSTRAP" \
    --group "$GROUP" --reset-offsets "--$dir" $(topic_args "$@") --execute >/dev/null
}
scale_search() { # replicas
  kubectl -n "$APPS_NS" scale "deploy/${SEARCH_DEPLOY}" --replicas="$1" >/dev/null
  kubectl -n "$APPS_NS" rollout status "deploy/${SEARCH_DEPLOY}" --timeout=180s >/dev/null 2>&1 || true
}
wait_drain() { # phase-label topics...
  local label="$1"; shift
  for _ in $(seq 1 "$(( SETTLE / 5 ))"); do
    lag="$(lag_over "$@" || echo 1)"; [[ "${lag:-1}" -eq 0 ]] && { info "$label drained (lag 0)"; return; }
    sleep 5
  done
  warn "$label did not fully drain within ${SETTLE}s (lag=${lag:-?})"
}

# Owner resync (REBUILD=resync): POST /actuator/resync on a service's internal management port via a
# short-lived port-forward (RBAC-gated; never publicly exposed) — same pattern as the Exp 06 replay.
resync_owner() { # deploy-name
  local pod pf
  pod="$(kubectl -n "$APPS_NS" get pods -l "app.kubernetes.io/name=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { warn "no $1 pod found — skipping its resync"; return 1; }
  kubectl -n "$APPS_NS" port-forward "pod/$pod" "${RESYNC_LPORT}:${MGMT_PORT}" >/dev/null 2>&1 &
  pf=$!
  for _ in $(seq 1 15); do curl -sf "http://localhost:${RESYNC_LPORT}/actuator/health" >/dev/null 2>&1 && break; sleep 1; done
  info "$1 resync → $(curl -s -X POST "http://localhost:${RESYNC_LPORT}/actuator/resync" -H 'Content-Type: application/json' || echo 'POST failed')"
  kill "$pf" 2>/dev/null || true
}

# ── Restore replicas on exit ─────────────────────────────────────────────────
ORIG_REPLICAS="$(kubectl -n "$APPS_NS" get deploy "$SEARCH_DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
[[ "$ORIG_REPLICAS" -ge 1 ]] || ORIG_REPLICAS=1
restore() { [[ "$DRY_RUN" == "1" ]] && return; warn "restoring ${SEARCH_DEPLOY} to ${ORIG_REPLICAS} replica(s)"; scale_search "$ORIG_REPLICAS" || true; }
trap restore EXIT
info "search replicas (to restore): $ORIG_REPLICAS · tables: ${TABLES[*]}"

if [[ "$DRY_RUN" == "1" ]]; then
  say "DRY-RUN plan"
  info "1. snapshot BEFORE: count + checksum for ${TABLES[*]}"
  info "2. scale $SEARCH_DEPLOY → 0"
  info "3. TRUNCATE ${TABLES[*]}, consumed_events"
  if [[ "$REBUILD" == "resync" ]]; then
    info "4. scale up; POST /actuator/resync on flight-service${SCOPE:+ (+ hotel-service if all)}; drain catalog"
    info "5. POST /actuator/resync on inventory-service; drain availability"
  else
    info "4. reset group '$GROUP': catalog→earliest [${CATALOG_TOPICS[*]}], availability→latest; scale up; drain catalog"
    info "5. scale → 0; reset availability→earliest [${AVAIL_TOPICS[*]}]; scale up; drain availability"
  fi
  info "6. snapshot AFTER; assert counts + checksums equal BEFORE"
  [[ "$CONTROL" == "1" ]] && info "CONTROL: repeat with availability replayed FIRST → expect reserved NOT to converge"
  say "DRY-RUN complete — nothing changed."
  trap - EXIT
  exit 0
fi

# ── 1. Snapshot BEFORE ───────────────────────────────────────────────────────
# Parallel indexed arrays (not associative) so this runs on macOS's default Bash 3.2. Index i in
# B_COUNT/B_SUM corresponds to TABLES[i]; flight_projections is always index 0.
say "1. Snapshot BEFORE (read model ground truth)"
B_COUNT=(); B_SUM=()
for t in "${TABLES[@]}"; do
  c="$(table_count "$t")"; s="$(table_checksum "$t")"
  B_COUNT+=("$c"); B_SUM+=("$s")
  info "$t: rows=$c sum=${s:0:12}"
done

# ── Preflight (offsets mode): the log MUST still hold full history, or the wipe is unrecoverable ──
# This guard is why the destructive TRUNCATE is safe: if any catalog event has aged out of the 7-day
# retention, replaying from earliest cannot rebuild the read model — so we abort BEFORE wiping and
# point to REBUILD=resync (which re-emits from the owning DBs, independent of retention).
if [[ "$REBUILD" == "offsets" ]]; then
  say "Preflight — verify the catalog log still holds full history (retention check)"
  START="$(topic_start_offsets "${CATALOG_TOPICS[@]}")"
  info "catalog topics log-start offset (sum): ${START}"
  if [[ "${START:-0}" -gt 0 ]]; then
    die "Catalog events have aged out of retention (log-start offset ${START} > 0). An 'offsets' replay would REBUILD TO EMPTY and cannot be undone — refusing to wipe. Use REBUILD=resync (re-emits current state from flight/hotel/inventory, ADR-0025/26/27)."
  fi
  info "log-start offset is 0 — full catalog history present; safe to wipe and replay."
fi

# ── 2-3. Quiesce + wipe ──────────────────────────────────────────────────────
say "2. Quiesce search (replicas → 0)"
scale_search 0
say "3. Wipe read model (TRUNCATE)"
psql_do "TRUNCATE TABLE $(IFS=,; echo "${TABLES[*]}"), consumed_events RESTART IDENTITY CASCADE;"
info "wiped: ${TABLES[*]} + consumed_events"

if [[ "$REBUILD" == "resync" ]]; then
  # ── 4/5. Beyond-retention rebuild: re-emit current state from the owning services ──────────
  # No dependence on old events being in the log — owners republish from their DBs (ADR-0025/26/27).
  say "4. Rebuild via RESYNC — search back up (consumes new re-emitted events from its committed offset)"
  scale_search "$ORIG_REPLICAS"
  say "4a. Resync CATALOG owners (flight${SCOPE:+, hotel if all}) — before availability"
  resync_owner flight-service
  [[ "$SCOPE" == "all" ]] && resync_owner hotel-service
  wait_drain "catalog(resync)" "${CATALOG_TOPICS[@]}"
  for t in flight_projections hotel_projections hotel_room_types; do
    [[ " ${TABLES[*]} " == *" $t "* ]] && info "after catalog resync: $t rows=$(table_count "$t")"
  done
  say "5. Resync AVAILABILITY (inventory) — catalog now present"
  resync_owner inventory-service
  wait_drain "availability(resync)" "${AVAIL_TOPICS[@]}"
else
  # ── 4. Replay catalog first (within-retention, from the log) ─────────────────────────────
  say "4. Replay CATALOG first (availability parked at latest)"
  reset_offsets to-earliest "${CATALOG_TOPICS[@]}"
  reset_offsets to-latest   "${AVAIL_TOPICS[@]}"
  scale_search "$ORIG_REPLICAS"
  wait_drain "catalog" "${CATALOG_TOPICS[@]}"
  for t in flight_projections hotel_projections hotel_room_types; do
    [[ " ${TABLES[*]} " == *" $t "* ]] && info "after catalog: $t rows=$(table_count "$t")"
  done

  # ── 5. Replay availability ─────────────────────────────────────────────────────────────
  say "5. Replay AVAILABILITY (catalog now present)"
  scale_search 0
  reset_offsets to-earliest "${AVAIL_TOPICS[@]}"
  scale_search "$ORIG_REPLICAS"
  wait_drain "availability" "${AVAIL_TOPICS[@]}"
fi

# ── 6. Snapshot AFTER + verdict ──────────────────────────────────────────────
say "6. Snapshot AFTER + verdict"
FAIL=0
i=0
for t in "${TABLES[@]}"; do
  a_count="$(table_count "$t")"; a_sum="$(table_checksum "$t")"
  if [[ "$a_count" == "${B_COUNT[$i]}" && "$a_sum" == "${B_SUM[$i]}" ]]; then
    ok "$t converged (rows=$a_count)"
  else
    bad "$t DIVERGED: rows ${B_COUNT[$i]}->$a_count · sum ${B_SUM[$i]:0:12}->${a_sum:0:12}"; FAIL=1
  fi
  i=$((i + 1))
done

echo
if [[ "$FAIL" -eq 0 ]]; then
  ok "Experiment 07 PASSED — the read model rebuilt to an identical state from the event log (within retention)."
else
  die "Experiment 07 FAILED — the rebuilt read model diverged. Investigate (ordering? stale events? clock horizon?)."
fi

# ── Optional control: reversed order should NOT converge (offsets mode only) ──
if [[ "$CONTROL" == "1" && "$REBUILD" == "offsets" ]]; then
  say "CONTROL — reversed order (availability BEFORE catalog) should leave reserved short"
  scale_search 0
  psql_do "TRUNCATE TABLE $(IFS=,; echo "${TABLES[*]}"), consumed_events RESTART IDENTITY CASCADE;"
  reset_offsets to-earliest "${AVAIL_TOPICS[@]}"
  reset_offsets to-latest   "${CATALOG_TOPICS[@]}"
  scale_search "$ORIG_REPLICAS"; wait_drain "availability-first" "${AVAIL_TOPICS[@]}"
  scale_search 0; reset_offsets to-earliest "${CATALOG_TOPICS[@]}"; scale_search "$ORIG_REPLICAS"; wait_drain "catalog-late" "${CATALOG_TOPICS[@]}"
  c_sum="$(table_checksum flight_projections)"
  if [[ "$c_sum" != "${B_SUM[0]}" ]]; then   # flight_projections is TABLES[0] in both scopes
    ok "control confirms ordering matters — reversed replay did NOT converge (availability dropped before catalog existed)"
  else
    warn "control converged unexpectedly — the dataset may not exercise the ordering window"
  fi
  warn "read model left in the CONTROL state — re-run the ordered rebuild to restore it."
fi
