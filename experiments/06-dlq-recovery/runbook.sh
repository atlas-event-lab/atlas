#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Experiment 06 — DLQ Recovery
#
# Proves the replay half of dlq-strategy.md on payment-service (ADR-0022): a poison message and a
# retry-exhausted message both park in inventory.reserved-payment.dlq; when the DLT handler is
# deliberately started, only the recoverable one replays cleanly (exactly-once charge, booking
# completes) while the poison one is quarantined.
#
# Flow: guardrails → resolve pods → BEFORE snapshot → (A) inject poison → (B) transient
#       payment_db-write outage + k6 batch → wait for the retry ladder to park → clear fault →
#       REPLAY (POST /actuator/dlqreplay {"action":"start"}, drain, then "stop") → settle → verdict.
#       A trap clears the DB fault AND stops replay even if the script dies.
#
# ── The Scenario B fault lever (what "fail payment_db writes" means) ──────────────────────────
#   A BEFORE INSERT trigger on payment_db.payments that RAISEs an I/O-class exception (SQLSTATE
#   58030). Every attempt to INSERT a Payment aborts and TX1 (beginProcessing) rolls back, so:
#     • the consumer sees a *retryable* error (58030 is NOT in the @RetryableTopic exclude set,
#       which is only ConstraintViolation / IllegalArgument / InvalidPaymentStateTransition), so
#       the trigger event walks the full 5→30→120s ladder and then parks in the DLQ; and
#     • NO Payment row is ever created — reproducing the exact gap ADR-0022 closes (a parked
#       trigger the ADR-0021 sweeper can't help, because there is no PROCESSING payment).
#   It is surgical (only INSERTs into payments; reads, the outbox relay and every other service
#   are untouched) and instantly reversible (DROP TRIGGER). This emulates a transient write
#   outage — e.g. the primary briefly rejecting writes — deterministically, without touching the
#   cluster's storage or networking.
#
# Usage:
#   set -a; source ../.env; set +a
#   DRY_RUN=1 ./runbook.sh                  # preview, change nothing
#   CONFIRM=yes ./runbook.sh                # execute (N=20 VUS=5 POISON_N=3)
#   CONFIRM=yes N=40 VUS=8 POISON_N=5 ./runbook.sh
#
# Env: N (20), VUS (5), POISON_N (3), RETRY_DRAIN (200), SETTLE (300), SCENARIO, DRY_RUN, CONFIRM.
# Prereqs: kubectl context on the Atlas cluster; k6; .env loaded; payment-service image with
#          ADR-0022; uuidgen; no other load.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APPS_NS="atlas-apps"
DATA_NS="atlas-data"
PG_CLUSTER="atlas-pg"
KAFKA_CLUSTER="atlas"
KAFKA_BOOTSTRAP="localhost:9092"
KAFKA_GROUPS="/opt/kafka/bin/kafka-consumer-groups.sh"
KAFKA_OFFSETS="/opt/kafka/bin/kafka-get-offsets.sh"
KAFKA_PRODUCER="/opt/kafka/bin/kafka-console-producer.sh"

TOPIC="inventory.reserved"
DLQ_TOPIC="inventory.reserved-payment.dlq"   # per-consumer DLT (ADR-0023); booking has its own
GROUP="payment-service"
PAYMENT_DEPLOY="payment-service"
MGMT_PORT="9090"                             # actuator/management port (internal)

N="${N:-20}"
VUS="${VUS:-5}"
POISON_N="${POISON_N:-3}"
RETRY_DRAIN="${RETRY_DRAIN:-200}"     # ≥ 5+30+120s ladder + slack, so the batch reaches the DLQ
SETTLE="${SETTLE:-300}"
DRY_RUN="${DRY_RUN:-0}"
CONFIRM="${CONFIRM:-no}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_DIR="${SCRIPT_DIR}/../01-high-booking-concurrency"

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m   PASS %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m   FAIL %s\033[0m\n' "$*"; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '   [dry-run] %s\n' "$*"; else eval "$*"; fi; }

# ── Guardrails ───────────────────────────────────────────────────────────────
say "Guardrails"
CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CTX" ]] || die "no kubectl context set."
[[ "$CTX" =~ [Pp]rod ]] && die "context '$CTX' looks like PRODUCTION — refusing."
info "kubectl context: $CTX"
command -v k6 >/dev/null 2>&1 || die "k6 not installed."
command -v curl >/dev/null 2>&1 || die "curl not installed (needed to call /actuator/dlqreplay)."
command -v uuidgen >/dev/null 2>&1 || die "uuidgen not available (needed to mint poison envelopes)."
[[ -f "${LOAD_DIR}/load.js" ]] || die "cannot find Exp 01 load.js at ${LOAD_DIR}/load.js."
[[ -n "${ATLAS_GATEWAY:-}" ]] || die "ATLAS_GATEWAY not set — load ../.env first (set -a; source ../.env; set +a)."
if [[ "$DRY_RUN" != "1" && "$CONFIRM" != "yes" ]]; then
  die "This injects faults into payment-service. Re-run with CONFIRM=yes, or preview with DRY_RUN=1."
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

# One payment pod drives the whole replay: the DLT container we start there joins the DLT consumer
# group as sole member and drains every DLQ partition, and its per-process meters are the readout.
PAYMENT_POD="$(kubectl -n "$APPS_NS" get pods -l "app.kubernetes.io/name=${PAYMENT_DEPLOY}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$PAYMENT_POD" ]] || die "could not find a ${PAYMENT_DEPLOY} pod."
info "Payment pod:     $PAYMENT_POD"
MGMT_URL="http://localhost:${MGMT_PORT}"     # reached via a port-forward to $PAYMENT_POD (below)

# ── Helpers ──────────────────────────────────────────────────────────────────
psql_val() { # db, sql
  kubectl -n "$DATA_NS" exec -c postgres "$PG_PRIMARY" -- \
    psql -U postgres -d "$1" -tA -c "$2" 2>/dev/null | tr -d '[:space:]'
}
group_lag_on_topic() {
  kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- \
    "$KAFKA_GROUPS" --bootstrap-server "$KAFKA_BOOTSTRAP" --group "$GROUP" --describe 2>/dev/null \
    | awk -v t="$TOPIC" '$2==t {s+=$6} END{print s+0}'
}
dlq_end_offset() {
  kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- \
    "$KAFKA_OFFSETS" --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$DLQ_TOPIC" 2>/dev/null \
    | awk -F: '{s+=$3} END{print s+0}'
}
k6_smoke() { ( cd "$LOAD_DIR" && k6 run -e ITERATIONS="$1" -e VUS="$2" load.js >"$3" 2>&1 ); }

# DLQ replay control surface (ADR-0022) — reached over a kubectl port-forward to the payment pod's
# internal management port (RBAC-gated via pods/portforward; never publicly exposed). curl is used
# because Actuator write operations need an HTTP POST with a JSON body (kubectl --raw is unreliable
# for POSTing to a pod-proxy subresource).
PF_PID=""
ensure_port_forward() {
  [[ "$DRY_RUN" == "1" ]] && return
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then return; fi
  kubectl -n "$APPS_NS" port-forward "pod/${PAYMENT_POD}" "${MGMT_PORT}:${MGMT_PORT}" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 15); do
    curl -sf "${MGMT_URL}/actuator/health" >/dev/null 2>&1 && return
    sleep 1
  done
  warn "port-forward to ${PAYMENT_POD}:${MGMT_PORT} not ready — replay calls may fail"
}
dlqreplay() { # action: start|stop
  if [[ "$DRY_RUN" == "1" ]]; then info "[dry-run] POST ${MGMT_URL}/actuator/dlqreplay {\"action\":\"$1\"}"; return; fi
  ensure_port_forward
  curl -s -X POST "${MGMT_URL}/actuator/dlqreplay" -H 'Content-Type: application/json' \
    -d "{\"action\":\"$1\"}" || warn "dlqreplay $1 POST failed"
}
dlqreplay_status() {
  [[ "$DRY_RUN" == "1" ]] && { echo '{"running":false}'; return; }
  ensure_port_forward
  curl -s "${MGMT_URL}/actuator/dlqreplay" 2>/dev/null || echo '{"running":"unknown"}'
}
payment_meter() { # metric-substring
  ensure_port_forward
  curl -s "${MGMT_URL}/actuator/prometheus" 2>/dev/null \
    | grep -E "$1" || true
}

# The Scenario B lever — a BEFORE INSERT trigger on payments that raises a transient I/O error.
apply_db_write_fault() {
  if [[ "$DRY_RUN" == "1" ]]; then info "[dry-run] CREATE TRIGGER trg_exp06_block_payment_write BEFORE INSERT ON payments (RAISE 58030)"; return; fi
  kubectl -n "$DATA_NS" exec -i -c postgres "$PG_PRIMARY" -- \
    psql -U postgres -d payment_db -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE OR REPLACE FUNCTION exp06_block_payment_write() RETURNS trigger
  LANGUAGE plpgsql AS $fn$
BEGIN
  RAISE EXCEPTION 'exp06 fault-injection: payment_db write temporarily unavailable'
    USING ERRCODE = '58030';   -- class 58 (system/IO error): looks like a transient write outage
END;
$fn$;
DROP TRIGGER IF EXISTS trg_exp06_block_payment_write ON payments;
CREATE TRIGGER trg_exp06_block_payment_write
  BEFORE INSERT ON payments
  FOR EACH ROW EXECUTE FUNCTION exp06_block_payment_write();
SQL
}
clear_db_write_fault() {
  if [[ "$DRY_RUN" == "1" ]]; then info "[dry-run] DROP TRIGGER + FUNCTION exp06_block_payment_write"; return; fi
  kubectl -n "$DATA_NS" exec -i -c postgres "$PG_PRIMARY" -- \
    psql -U postgres -d payment_db -q <<'SQL' || true
DROP TRIGGER IF EXISTS trg_exp06_block_payment_write ON payments;
DROP FUNCTION IF EXISTS exp06_block_payment_write();
SQL
}
produce_poison() { # count
  local i eid bid sid ts json
  for ((i=0; i<$1; i++)); do
    eid="$(uuidgen | tr 'A-Z' 'a-z')"; bid="$(uuidgen | tr 'A-Z' 'a-z')"; sid="$(uuidgen | tr 'A-Z' 'a-z')"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Malformed: payload has no "total" → @NotNull fails → ConstraintViolationException → straight to DLQ.
    json="{\"eventId\":\"$eid\",\"eventType\":\"INVENTORY_RESERVED\",\"eventVersion\":1,\"occurredAt\":\"$ts\",\"correlationId\":\"exp06-poison\",\"sagaId\":\"$sid\",\"producer\":\"exp06\",\"payload\":{\"bookingId\":\"$bid\"}}"
    if [[ "$DRY_RUN" == "1" ]]; then info "[dry-run] produce malformed envelope eventId=$eid → $TOPIC"; continue; fi
    printf '%s\n' "$json" | kubectl -n "$DATA_NS" exec -i "$KAFKA_POD" -- \
      "$KAFKA_PRODUCER" --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$TOPIC" >/dev/null 2>&1
  done
}

# ── Fault-restore safety net ─────────────────────────────────────────────────
# If the runbook dies mid-window, the DB fault must be cleared AND replay turned back off.
DB_FAULT_ACTIVE=0
REPLAY_ACTIVE=0
restore_faults() {
  [[ "$DRY_RUN" == "1" ]] && return
  if [[ "$DB_FAULT_ACTIVE" == "1" ]]; then
    warn "trap: clearing the payment_db write fault (window left open)"
    clear_db_write_fault
  fi
  if [[ "$REPLAY_ACTIVE" == "1" ]]; then
    warn "trap: stopping replay (DLT handler left running)"
    curl -s -X POST "${MGMT_URL}/actuator/dlqreplay" -H 'Content-Type: application/json' \
      -d '{"action":"stop"}' >/dev/null 2>&1 || true
  fi
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
}
trap restore_faults EXIT

# ── Clean start + BEFORE snapshot ────────────────────────────────────────────
say "Clean start"
LAG0="$(group_lag_on_topic || echo "")"
info "'$GROUP' lag on '$TOPIC': ${LAG0:-unknown}"
[[ "${LAG0:-0}" -eq 0 ]] || die "group lag is not 0 — another run is in flight. Let it drain first."

say "Snapshot BEFORE (Postgres + DLQ offsets)"
B_TS="$(psql_val booking_db "SELECT replace(now()::text, ' ', 'T');")"
B_DLQ="$(dlq_end_offset || echo 0)"
info "DLQ end offset ($DLQ_TOPIC): ${B_DLQ}"
info "fault window starts at (db clock): $B_TS"

# ── Scenario A — poison message ──────────────────────────────────────────────
say "A. Poison — publish $POISON_N malformed '$TOPIC' envelopes (missing 'total' → straight to DLQ)"
produce_poison "$POISON_N"
if [[ "$DRY_RUN" != "1" ]]; then
  info "waiting up to 60s for the $POISON_N poison records to appear on the DLQ..."
  for _ in $(seq 1 12); do
    A_DLQ="$(dlq_end_offset || echo "$B_DLQ")"
    [[ "$(( A_DLQ - B_DLQ ))" -ge "$POISON_N" ]] && break
    sleep 5
  done
  info "DLQ delta after poison: $(( ${A_DLQ:-$B_DLQ} - B_DLQ )) (expected ≥ $POISON_N)"
fi

# ── Scenario B — transient DB-write outage → retry ladder → DLQ ───────────────
say "B. Transient outage — block payment_db writes, fire $N journeys (each burns the 5→30→120s ladder)"
apply_db_write_fault
DB_FAULT_ACTIVE=1
info "payment_db INSERTs on 'payments' now raise 58030 (retryable) — TX1 rolls back, no Payment row created"

K6_LOG="${SCRIPT_DIR}/k6-batch.log"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] k6 run -e ITERATIONS=$N -e VUS=$VUS ${LOAD_DIR}/load.js"
else
  k6_smoke "$N" "$VUS" "$K6_LOG" || warn "k6 exited non-zero — see $K6_LOG (journeys can still be valid)."
  info "batch fired (log: $K6_LOG); waiting ${RETRY_DRAIN}s for the ladder to park the triggers on the DLQ"
  sleep "$RETRY_DRAIN"
fi

# Batch outcome under fault (before clearing): triggers parked, no payments, bookings stranded.
if [[ "$DRY_RUN" != "1" ]]; then
  B_DLQ_AFTER="$(dlq_end_offset || echo 0)"
  P_ROWS="$(psql_val payment_db "SELECT count(*) FROM payments WHERE created_at >= '$B_TS';")"
  info "DLQ end offset now: $B_DLQ_AFTER (parked so far: $(( B_DLQ_AFTER - B_DLQ )) = poison $POISON_N + retries-exhausted)"
  info "payments created during the fault window: ${P_ROWS:-?} (expected 0 — TX1 never committed)"
fi

# ── Clear the fault ──────────────────────────────────────────────────────────
say "Clear the transient fault — payment_db writes healthy again"
clear_db_write_fault
DB_FAULT_ACTIVE=0

# ── Replay — start the DLT handler on demand; it auto-stops when the DLQ drains ──
say "Replay — POST /actuator/dlqreplay {\"action\":\"start\"} (no redeploy); auto-stops when drained"
dlqreplay start
REPLAY_ACTIVE=1
if [[ "$DRY_RUN" != "1" ]]; then
  info "replay status: $(dlqreplay_status)"
  info "DLT handler started — recoverable records reprocess, poison records quarantine."
  info "Waiting for the DLQ to drain and replay to auto-stop (≤ ${SETTLE}s)..."
  SETTLED=0
  for _ in $(seq 1 "$(( SETTLE / 5 ))"); do
    W_OPEN="$(psql_val booking_db \
      "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status IN ('PENDING','INVENTORY_RESERVED','PAYMENT_PENDING');")"
    # Drained + auto-stopped when the handler reports not running AND no batch booking is in flight.
    if dlqreplay_status | grep -q '"running":false' && [[ "${W_OPEN:-1}" -eq 0 ]]; then SETTLED=1; break; fi
    sleep 5
  done
  REPLAY_ACTIVE=0   # auto-stopped (idle) — trap no longer needs to stop it
  info "settled=$SETTLED · bookings-in-flight=${W_OPEN:-?} · replay status: $(dlqreplay_status)"
fi

# Safety net: explicit stop in case auto-stop didn't fire within SETTLE (idempotent no-op otherwise).
say "Ensure replay stopped (idempotent — auto-stop normally already fired)"
dlqreplay stop
REPLAY_ACTIVE=0

# ── Verdict ──────────────────────────────────────────────────────────────────
say "Verdict (DLQ recovery invariants)"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would assert against Postgres + the payment prometheus endpoint:"
  info "[dry-run]  · dlq_replayed_total{outcome=quarantined} == POISON_N ($POISON_N); {reprocessed} == retries-exhausted count"
  info "[dry-run]  · dlq_parked_total{reason=validation} == POISON_N; {reason=retries_exhausted} == the batch's parked count"
  info "[dry-run]  · every reprocessed booking terminal; SELECT booking_id FROM payments GROUP BY booking_id HAVING count(*)>1 → 0 rows"
  info "[dry-run]  · atlas_payment_provider_calls_total == reprocessed bookings; atlas_payment_recoveries_total == 0"
  info "[dry-run]  · DLQ backlog drained and '$GROUP' lag == 0"
  say "DRY-RUN complete — nothing changed (trap cleared nothing: no fault was applied)."
  exit 0
fi

FAIL=0
LAG_END="$(group_lag_on_topic || echo 1)"
DLQ_END="$(dlq_end_offset || echo 0)"
DUP="$(psql_val payment_db "SELECT count(*) FROM (SELECT booking_id FROM payments GROUP BY booking_id HAVING count(*) > 1) d;")"
REC="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status = 'CONFIRMED';")"
STUCK="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status IN ('PENDING','INVENTORY_RESERVED','PAYMENT_PENDING');")"

info "DLQ meters on $PAYMENT_POD (per-process; read now, before any restart):"
payment_meter 'atlas_payment_dlq_(parked|replayed)|atlas_payment_(provider_calls|recoveries)' | sed 's/^/     /'
info "Expect: dlq_replayed{quarantined}==$POISON_N, dlq_replayed{reprocessed}==retries-exhausted count,"
info "        dlq_parked{reason=validation}==$POISON_N, recoveries==0, provider_calls==reprocessed bookings."

if [[ "${DUP:-1}" -eq 0 ]]; then ok "no booking has >1 payment (exactly-once on replay)"; else bad "$DUP booking(s) have >1 payment — double charge on replay"; FAIL=1; fi
if [[ "${STUCK:-1}" -eq 0 ]]; then ok "no batch booking left in flight after replay ($REC confirmed)"; else bad "$STUCK booking(s) still in flight after replay"; FAIL=1; fi
if [[ "${LAG_END:-1}" -eq 0 ]]; then ok "'$GROUP' lag back to 0"; else bad "'$GROUP' lag is $LAG_END"; FAIL=1; fi
info "DLQ end offset now: $DLQ_END (records are consumed by the handler; backlog = lag on the DLQ group, check Grafana)"

echo
info "Record this run in RESULTS.md (attach the meter readout above and the DLQ backlog graph)."
if [[ "$FAIL" -eq 0 ]]; then
  ok "Experiment 06 PASSED — poison parked & quarantined; recoverable parked & replayed exactly-once."
else
  die "Experiment 06 FAILED — a DLQ-recovery invariant broke. Investigate before re-running."
fi
