#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Experiment 03 — Duplicate Messages / Idempotency
#
# Forces at-least-once REDELIVERY by resetting the inventory-service consumer group's offset
# backwards on booking.created, then proves the idempotency guard makes it effectively-once:
# no new reservations, no stock change, no new outbox rows — only duplicate skips.
#
# It reuses the same levers as scripts/reset-state.sh (ops/apps idle+resume, kafka-consumer-
# groups in the broker pod, psql in the CNPG primary). It is NON-destructive to data: it moves
# ONE consumer group's offsets and never truncates a table.
#
# Usage:
#   DRY_RUN=1 ./runbook.sh                 # preview, change nothing
#   CONFIRM=yes ./runbook.sh               # execute: --shift-by -REPLAY_N on booking.created
#   CONFIRM=yes REPLAY_N=200 ./runbook.sh  # replay more per partition
#   CONFIRM=yes REPLAY_ALL=1 ./runbook.sh  # --to-earliest (whole topic)
#
# Env: TOPIC (booking.created), GROUP (inventory-service), REPLAY_N (50), REPLAY_ALL,
#      SETTLE (seconds to wait for catch-up, 40), DRY_RUN, CONFIRM.
# Prereq: kubectl context on the Atlas cluster; processed booking.created events must exist.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APPS_NS="atlas-apps"
DATA_NS="atlas-data"
PG_CLUSTER="atlas-pg"
KAFKA_CLUSTER="atlas"
KAFKA_BIN="/opt/kafka/bin/kafka-consumer-groups.sh"
KAFKA_BOOTSTRAP="localhost:9092"

TOPIC="${TOPIC:-booking.created}"
GROUP="${GROUP:-inventory-service}"
REPLAY_N="${REPLAY_N:-50}"
REPLAY_ALL="${REPLAY_ALL:-0}"
SETTLE="${SETTLE:-40}"
DRY_RUN="${DRY_RUN:-0}"
CONFIRM="${CONFIRM:-no}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The quiesce/resume levers live in deploy/ops/apps (idle.sh + resume.sh). Override OPS_DIR
# if you keep them elsewhere; they are validated at startup by require_ops_scripts below.
OPS_DIR="${OPS_DIR:-$(cd "${SCRIPT_DIR}/../../deploy/ops/apps" 2>/dev/null && pwd)}"

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m   PASS %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m   FAIL %s\033[0m\n' "$*"; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '   [dry-run] %s\n' "$*"; else eval "$*"; fi; }

# Validate the ops levers BEFORE anything runs. Without this the run gets as far as taking a
# snapshot and only then dies with a bare "No such file or directory", mid-procedure — the
# worst moment to discover a path is wrong.
require_ops_scripts() {
  local missing=()
  [[ -n "$OPS_DIR" && -d "$OPS_DIR" ]] || {
    die "ops directory not found: '${OPS_DIR:-<unresolved>}'. Expected the quiesce/resume" \
        "levers at deploy/ops/apps (idle.sh, resume.sh). Set OPS_DIR to their location."
  }
  [[ -f "$OPS_DIR/idle.sh"   ]] || missing+=("idle.sh")
  [[ -f "$OPS_DIR/resume.sh" ]] || missing+=("resume.sh")
  if (( ${#missing[@]} )); then
    die "missing in '$OPS_DIR': ${missing[*]}. These are the apps quiesce/resume levers" \
        "(deploy/ops/README.md). If your tree still has the old apps-idle.sh /" \
        "apps-resume.sh at deploy/ops, it predates the ops reorganization — update it or" \
        "set OPS_DIR."
  fi
}

# ── Guardrails ───────────────────────────────────────────────────────────────
say "Guardrails"
require_ops_scripts
info "ops levers: $OPS_DIR/{idle,resume}.sh"
CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CTX" ]] || die "no kubectl context set."
info "kubectl context: $CTX"
[[ "$CTX" =~ [Pp]rod ]] && die "context '$CTX' looks like PRODUCTION — refusing."
kubectl get ns "$APPS_NS" >/dev/null 2>&1 || die "namespace $APPS_NS not found."
kubectl get ns "$DATA_NS" >/dev/null 2>&1 || die "namespace $DATA_NS not found."
if [[ "$DRY_RUN" != "1" && "$CONFIRM" != "yes" ]]; then
  die "This moves consumer offsets. Re-run with CONFIRM=yes, or preview with DRY_RUN=1."
fi

# ── Resolve platform pods ────────────────────────────────────────────────────
say "Resolve platform pods"
PG_PRIMARY="$(kubectl -n "$DATA_NS" get pods \
  -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$PG_PRIMARY" ]] || PG_PRIMARY="$(kubectl -n "$DATA_NS" get pods \
  -l "cnpg.io/cluster=${PG_CLUSTER},role=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$PG_PRIMARY" ]] || die "could not find CNPG primary pod for cluster ${PG_CLUSTER}."
info "Postgres primary: $PG_PRIMARY"

KAFKA_POD="$(kubectl -n "$DATA_NS" get pods -l "strimzi.io/cluster=${KAFKA_CLUSTER}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -Ei 'dual-role|broker|kafka' | head -1 || true)"
[[ -n "$KAFKA_POD" ]] || die "could not find a Kafka broker pod for cluster ${KAFKA_CLUSTER}."
info "Kafka broker:    $KAFKA_POD"

# helpers ---------------------------------------------------------------------
# Scalar SQL against inventory_db in the CNPG primary (returns a bare number/string).
psql_val() {
  kubectl -n "$DATA_NS" exec "$PG_PRIMARY" -- \
    psql -U postgres -d inventory_db -tA -c "$1" 2>/dev/null | tr -d '[:space:]'
}
kadmin() {
  kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- \
    "$KAFKA_BIN" --bootstrap-server "$KAFKA_BOOTSTRAP" "$@"
}
# Sum the LAG column of `--describe` for our topic (col 6 in the standard output).
group_lag_on_topic() {
  kadmin --group "$GROUP" --describe 2>/dev/null \
    | awk -v t="$TOPIC" '$2==t {s+=$6} END{print s+0}'
}

# ── Precondition + BEFORE snapshot ───────────────────────────────────────────
say "Snapshot BEFORE (Postgres ground truth)"
B_CONSUMED="$(psql_val 'SELECT count(*) FROM consumed_events;')"
B_RESV="$(psql_val 'SELECT count(*) FROM reservations;')"
B_STOCK="$(psql_val 'SELECT coalesce(sum(reserved_count),0) FROM flight_inventory;')"
B_HOTEL="$(psql_val 'SELECT coalesce(sum(reserved),0) FROM room_type_availability;')"
B_OUTBOX="$(psql_val 'SELECT count(*) FROM outbox;')"
info "consumed_events=$B_CONSUMED  reservations=$B_RESV  flight_reserved=$B_STOCK  hotel_reserved=$B_HOTEL  outbox=$B_OUTBOX"

if [[ "${B_CONSUMED:-0}" -eq 0 ]]; then
  die "consumed_events is empty — nothing has been processed to replay. Run Exp 01/02 or a smoke first."
fi

# ── 1. Quiesce ───────────────────────────────────────────────────────────────
say "1. Quiesce apps (ops/apps/idle.sh) — so the '$GROUP' group has no active members"
run "NS='$APPS_NS' bash '${OPS_DIR}/idle.sh'"
if [[ "$DRY_RUN" != "1" ]]; then
  info "waiting for app pods to terminate..."
  for _ in $(seq 1 30); do
    n="$(kubectl -n "$APPS_NS" get pods --no-headers 2>/dev/null | grep -vc 'Completed' || true)"
    [[ "${n:-0}" -eq 0 ]] && break
    sleep 2
  done
fi

# ── 2. Replay: move ONLY this group's offset backwards on the topic ──────────
say "2. Replay — reset '$GROUP' offsets on '$TOPIC' backwards"
if [[ "$REPLAY_ALL" == "1" ]]; then
  info "mode: --to-earliest (whole topic)"
  run "kubectl -n '$DATA_NS' exec '$KAFKA_POD' -- '$KAFKA_BIN' --bootstrap-server '$KAFKA_BOOTSTRAP' --group '$GROUP' --topic '$TOPIC' --reset-offsets --to-earliest --execute"
else
  info "mode: --shift-by -$REPLAY_N (per partition)"
  run "kubectl -n '$DATA_NS' exec '$KAFKA_POD' -- '$KAFKA_BIN' --bootstrap-server '$KAFKA_BOOTSTRAP' --group '$GROUP' --topic '$TOPIC' --reset-offsets --shift-by -${REPLAY_N} --execute"
fi

REPLAYED=0
if [[ "$DRY_RUN" != "1" ]]; then
  REPLAYED="$(group_lag_on_topic)"
  info "events queued for redelivery (lag on $TOPIC): $REPLAYED"
  [[ "${REPLAYED:-0}" -gt 0 ]] || warn "replay lag is 0 — offsets may already be at earliest, or the topic is empty."
fi

# ── 3. Resume ────────────────────────────────────────────────────────────────
say "3. Resume apps (ops/apps/resume.sh) — inventory re-consumes and dedups the replay"
run "NS='$APPS_NS' bash '${OPS_DIR}/resume.sh'"

if [[ "$DRY_RUN" == "1" ]]; then
  say "DRY-RUN complete — nothing changed."
  exit 0
fi

info "waiting up to ${SETTLE}s for '$GROUP' lag on '$TOPIC' to drain..."
for _ in $(seq 1 "$SETTLE"); do
  lag="$(group_lag_on_topic || echo 0)"
  [[ "${lag:-0}" -eq 0 ]] && break
  sleep 1
done
info "final lag on $TOPIC: $(group_lag_on_topic)"
# Give the outbox relay a moment to flush any (there should be none) produced events.
sleep 5

# ── 4. AFTER snapshot + assertions ───────────────────────────────────────────
say "Snapshot AFTER"
A_CONSUMED="$(psql_val 'SELECT count(*) FROM consumed_events;')"
A_RESV="$(psql_val 'SELECT count(*) FROM reservations;')"
A_STOCK="$(psql_val 'SELECT coalesce(sum(reserved_count),0) FROM flight_inventory;')"
A_HOTEL="$(psql_val 'SELECT coalesce(sum(reserved),0) FROM room_type_availability;')"
A_OUTBOX="$(psql_val 'SELECT count(*) FROM outbox;')"
info "consumed_events=$A_CONSUMED  reservations=$A_RESV  flight_reserved=$A_STOCK  hotel_reserved=$A_HOTEL  outbox=$A_OUTBOX"

say "Verdict (idempotency invariants)"
FAIL=0
chk() { # name before after
  if [[ "$2" == "$3" ]]; then ok "$1 unchanged ($2)"; else bad "$1 changed: $2 -> $3"; FAIL=1; fi
}
chk "consumed_events count" "$B_CONSUMED" "$A_CONSUMED"
chk "reservations count"    "$B_RESV"    "$A_RESV"
chk "flight reserved_count" "$B_STOCK"   "$A_STOCK"
chk "hotel reserved"        "$B_HOTEL"   "$A_HOTEL"
chk "outbox count"          "$B_OUTBOX"  "$A_OUTBOX"

echo
info "Visible-dedup metric (best-effort; read inventory /actuator/prometheus if reachable):"
info "  atlas_inventory_events_skipped_total{reason=\"duplicate\"}  should be ≈ $REPLAYED"
info "  atlas_inventory_reservations_total{result=\"reserved\"}     should be 0 (no new reservations)"
info "  → open the 'Atlas — Experiment 02' dashboard, or:"
info "    kubectl -n $APPS_NS port-forward deploy/inventory-service 19090:9090 &"
info "    curl -s localhost:19090/actuator/prometheus | grep -E 'atlas_inventory_(events_skipped|reservations)'"

echo
if [[ "$FAIL" -eq 0 ]]; then
  ok "Experiment 03 PASSED — redelivery produced no side effects (effectively-once)."
else
  die "Experiment 03 FAILED — a persistent invariant changed under replay. Investigate the guard."
fi
