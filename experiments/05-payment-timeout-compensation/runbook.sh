#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Experiment 05 — Payment Timeout → Compensation
#
# Stalls the payment provider for a window (WireMock TIMEOUT scenario via
# ATLAS_PAYMENT_PROVIDER_SCENARIO=TIMEOUT), runs a batch of N bookings — every payment must
# time out and the Saga must compensate completely (bookings EXPIRED, stock and Search read
# model back to baseline) — then restores the scenario and proves the system heals with a
# post-restore smoke.
#
# Flow: clean start → BEFORE snapshot → inject fault (env + rollout) → k6 batch → settle
# (lag 0, payments terminal, bookings expired, stock/read-model converged) → restore env →
# post-restore smoke → verdict. A trap restores the env var even if the script dies.
#
# Usage:
#   set -a; source ../.env; set +a
#   DRY_RUN=1 ./runbook.sh                  # preview, change nothing
#   CONFIRM=yes ./runbook.sh                # execute (N=20, VUS=5, SMOKE_N=3)
#   CONFIRM=yes N=40 VUS=8 ./runbook.sh
#
# Env: N (20), VUS (5), SMOKE_N (3), SETTLE (300), SCENARIO (k6 passthrough),
#      DRY_RUN, CONFIRM.
# Prereqs: kubectl context on the Atlas cluster; k6; .env loaded; WireMock with the repo's
#          payment-provider.json mappings; no other load.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APPS_NS="atlas-apps"
DATA_NS="atlas-data"
PG_CLUSTER="atlas-pg"
KAFKA_CLUSTER="atlas"
KAFKA_BIN="/opt/kafka/bin/kafka-consumer-groups.sh"
KAFKA_BOOTSTRAP="localhost:9092"

TOPIC="inventory.reserved"
GROUP="payment-service"
PAYMENT_DEPLOY="payment-service"
FAULT_ENV="ATLAS_PAYMENT_PROVIDER_SCENARIO"   # Spring relaxed binding → atlas.payment.provider.scenario

N="${N:-20}"
VUS="${VUS:-5}"
SMOKE_N="${SMOKE_N:-3}"
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

# ── Fault-restore safety net ─────────────────────────────────────────────────
# If the runbook dies mid-window, the TIMEOUT scenario must NOT stay behind.
FAULT_ACTIVE=0
restore_fault() {
  if [[ "$FAULT_ACTIVE" == "1" && "$DRY_RUN" != "1" ]]; then
    warn "trap: removing ${FAULT_ENV} from ${PAYMENT_DEPLOY} (fault window left open)"
    kubectl -n "$APPS_NS" set env "deploy/${PAYMENT_DEPLOY}" "${FAULT_ENV}-" >/dev/null 2>&1 || true
  fi
}
trap restore_fault EXIT

# ── Guardrails ───────────────────────────────────────────────────────────────
say "Guardrails"
CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CTX" ]] || die "no kubectl context set."
info "kubectl context: $CTX"
[[ "$CTX" =~ [Pp]rod ]] && die "context '$CTX' looks like PRODUCTION — refusing."
kubectl get ns "$APPS_NS" >/dev/null 2>&1 || die "namespace $APPS_NS not found."
kubectl get ns "$DATA_NS" >/dev/null 2>&1 || die "namespace $DATA_NS not found."
command -v k6 >/dev/null 2>&1 || die "k6 not installed."
[[ -f "${LOAD_DIR}/load.js" ]] || die "cannot find Exp 01 load.js at ${LOAD_DIR}/load.js."
[[ -n "${ATLAS_GATEWAY:-}" ]] || die "ATLAS_GATEWAY not set — load ../.env first (set -a; source ../.env; set +a)."
if [[ "$DRY_RUN" != "1" && "$CONFIRM" != "yes" ]]; then
  die "This stalls ALL payments for the window. Re-run with CONFIRM=yes, or preview with DRY_RUN=1."
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
psql_val() { # db, sql
  kubectl -n "$DATA_NS" exec -c postgres "$PG_PRIMARY" -- \
    psql -U postgres -d "$1" -tA -c "$2" 2>/dev/null | tr -d '[:space:]'
}
group_lag_on_topic() {
  kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- \
    "$KAFKA_BIN" --bootstrap-server "$KAFKA_BOOTSTRAP" --group "$GROUP" --describe 2>/dev/null \
    | awk -v t="$TOPIC" '$2==t {s+=$6} END{print s+0}'
}
k6_smoke() { # iterations, vus, logfile
  ( cd "$LOAD_DIR" && k6 run -e ITERATIONS="$1" -e VUS="$2" load.js >"$3" 2>&1 )
}

# ── Clean start + BEFORE snapshot ────────────────────────────────────────────
say "Clean start"
LAG0="$(group_lag_on_topic || echo "")"
info "'$GROUP' lag on '$TOPIC': ${LAG0:-unknown}"
[[ "${LAG0:-0}" -eq 0 ]] || die "group lag is not 0 — another run is in flight. Let it drain first."

say "Snapshot BEFORE (Postgres ground truth)"
B_TS="$(psql_val booking_db "SELECT replace(now()::text, ' ', 'T');")"
B_STOCK_F="$(psql_val inventory_db 'SELECT coalesce(sum(reserved_count),0) FROM flight_inventory;')"
B_STOCK_H="$(psql_val inventory_db 'SELECT coalesce(sum(reserved),0) FROM room_type_availability;')"
B_SEARCH_F="$(psql_val search_db 'SELECT coalesce(sum(reserved),0) FROM flight_projections;')"
B_SEARCH_H="$(psql_val search_db 'SELECT coalesce(sum(reserved),0) FROM room_type_availability;')"
info "inventory reserved: flights=$B_STOCK_F hotels=$B_STOCK_H · search mirror: flights=$B_SEARCH_F hotels=$B_SEARCH_H"
info "fault window starts at (db clock): $B_TS"

# ── 1. Inject the fault ──────────────────────────────────────────────────────
say "1. Inject fault — ${FAULT_ENV}=TIMEOUT on deploy/${PAYMENT_DEPLOY} (all charges will stall)"
run "kubectl -n '$APPS_NS' set env 'deploy/${PAYMENT_DEPLOY}' '${FAULT_ENV}=TIMEOUT'"
FAULT_ACTIVE=1
if [[ "$DRY_RUN" != "1" ]]; then
  kubectl -n "$APPS_NS" rollout status "deploy/${PAYMENT_DEPLOY}" --timeout=180s >/dev/null \
    || die "payment rollout with the fault env did not complete."
  info "fault active — every provider call now hits the 7s-delay TIMEOUT stub."
fi

# ── 2. Fire the batch ────────────────────────────────────────────────────────
say "2. Batch — $N journeys, $VUS parallel (every payment must TIME OUT, ~21s each)"
K6_LOG="${SCRIPT_DIR}/k6-batch.log"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] k6 run -e ITERATIONS=$N -e VUS=$VUS ${LOAD_DIR}/load.js"
else
  k6_smoke "$N" "$VUS" "$K6_LOG" || warn "k6 exited non-zero — see $K6_LOG (journeys can still be valid)."
  info "batch fired (log: $K6_LOG)"
fi

# ── 3. Settle: payments terminal, bookings expired, stock + read model back ──
say "3. Settle (up to ${SETTLE}s) — timeouts, expiries and compensation must all land"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] wait: lag 0 → payments terminal → bookings settled → sums back to baseline"
  say "DRY-RUN complete — nothing changed (trap removed nothing: fault was never applied)."
  FAULT_ACTIVE=0
  exit 0
fi

SETTLED=0
for _ in $(seq 1 "$(( SETTLE / 5 ))"); do
  lag="$(group_lag_on_topic || echo 1)"
  P_OPEN="$(psql_val payment_db \
    "SELECT count(*) FROM payments WHERE created_at >= '$B_TS' AND status NOT IN ('SUCCEEDED','FAILED','TIMED_OUT');")"
  W_OPEN="$(psql_val booking_db \
    "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status IN ('PENDING','INVENTORY_RESERVED','PAYMENT_PENDING');")"
  A_STOCK_F="$(psql_val inventory_db 'SELECT coalesce(sum(reserved_count),0) FROM flight_inventory;')"
  A_STOCK_H="$(psql_val inventory_db 'SELECT coalesce(sum(reserved),0) FROM room_type_availability;')"
  A_SEARCH_F="$(psql_val search_db 'SELECT coalesce(sum(reserved),0) FROM flight_projections;')"
  A_SEARCH_H="$(psql_val search_db 'SELECT coalesce(sum(reserved),0) FROM room_type_availability;')"
  if [[ "${lag:-1}" -eq 0 && "${P_OPEN:-1}" -eq 0 && "${W_OPEN:-1}" -eq 0 \
        && "$A_STOCK_F" == "$B_STOCK_F" && "$A_STOCK_H" == "$B_STOCK_H" \
        && "$A_SEARCH_F" == "$B_SEARCH_F" && "$A_SEARCH_H" == "$B_SEARCH_H" ]]; then
    SETTLED=1; break
  fi
  sleep 5
done
info "settled=$SETTLED · lag=${lag:-?} payments-open=${P_OPEN:-?} bookings-in-flight=${W_OPEN:-?}"
info "stock now: flights=${A_STOCK_F:-?} (baseline $B_STOCK_F) hotels=${A_STOCK_H:-?} (baseline $B_STOCK_H)"
info "search  : flights=${A_SEARCH_F:-?} (baseline $B_SEARCH_F) hotels=${A_SEARCH_H:-?} (baseline $B_SEARCH_H)"

# ── 4. Batch verdict data (before the smoke muddies the window) ──────────────
say "4. Batch outcome"
W_TOTAL="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS';")"
W_EXPIRED="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status = 'EXPIRED';")"
W_CONF="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status = 'CONFIRMED';")"
P_TIMED="$(psql_val payment_db "SELECT count(*) FROM payments WHERE created_at >= '$B_TS' AND status = 'TIMED_OUT';")"
P_PROC="$(psql_val payment_db "SELECT count(*) FROM payments WHERE created_at >= '$B_TS' AND status = 'PROCESSING';")"
R_LEFT="$(psql_val inventory_db "SELECT count(*) FROM reservations WHERE created_at >= '$B_TS' AND status = 'RESERVED';")"
info "bookings=$W_TOTAL expired=$W_EXPIRED confirmed=$W_CONF · payments timed_out=$P_TIMED processing=$P_PROC · reservations still RESERVED=$R_LEFT"

# ── 5. Restore + post-restore smoke ──────────────────────────────────────────
say "5. Restore — remove ${FAULT_ENV}; the system must heal"
run "kubectl -n '$APPS_NS' set env 'deploy/${PAYMENT_DEPLOY}' '${FAULT_ENV}-'"
FAULT_ACTIVE=0
kubectl -n "$APPS_NS" rollout status "deploy/${PAYMENT_DEPLOY}" --timeout=180s >/dev/null \
  || warn "payment rollout after restore did not report complete — check the deployment."

SMOKE_TS="$(psql_val booking_db "SELECT replace(now()::text, ' ', 'T');")"
SMOKE_LOG="${SCRIPT_DIR}/k6-smoke.log"
say "5b. Post-restore smoke — $SMOKE_N journeys must CONFIRM end-to-end"
k6_smoke "$SMOKE_N" 1 "$SMOKE_LOG" || warn "smoke k6 exited non-zero — see $SMOKE_LOG"
info "waiting up to 120s for the smoke bookings to confirm..."
for _ in $(seq 1 24); do
  S_CONF="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$SMOKE_TS' AND status = 'CONFIRMED';")"
  [[ "${S_CONF:-0}" -ge "$SMOKE_N" ]] && break
  sleep 5
done
S_CONF="${S_CONF:-0}"
S_PAY="$(psql_val payment_db "SELECT count(*) FROM payments WHERE created_at >= '$SMOKE_TS' AND status = 'SUCCEEDED';")"

# ── 6. Verdict ───────────────────────────────────────────────────────────────
say "Verdict (compensation invariants)"
FAIL=0
if [[ "$W_TOTAL" -eq "$N" ]]; then ok "batch complete: $W_TOTAL/$N bookings created"; else warn "batch created $W_TOTAL/$N bookings — check $K6_LOG (assertions below use the actual count)"; fi
if [[ "$W_EXPIRED" -eq "$W_TOTAL" && "$W_CONF" -eq 0 ]]; then ok "all batch bookings EXPIRED ($W_EXPIRED/$W_TOTAL), none CONFIRMED"; else bad "expired=$W_EXPIRED confirmed=$W_CONF of $W_TOTAL — compensation incomplete"; FAIL=1; fi
if [[ "$P_TIMED" -eq "$W_TOTAL" && "${P_PROC:-1}" -eq 0 ]]; then ok "all batch payments TIMED_OUT ($P_TIMED), none PROCESSING"; else bad "timed_out=$P_TIMED processing=$P_PROC — the timeout path did not resolve every payment"; FAIL=1; fi
if [[ "${R_LEFT:-1}" -eq 0 ]]; then ok "no batch reservation left RESERVED"; else bad "$R_LEFT reservation(s) still RESERVED"; FAIL=1; fi
if [[ "$A_STOCK_F" == "$B_STOCK_F" && "$A_STOCK_H" == "$B_STOCK_H" ]]; then ok "inventory stock back to baseline (flights $A_STOCK_F, hotels $A_STOCK_H)"; else bad "stock did not return: flights $B_STOCK_F->$A_STOCK_F hotels $B_STOCK_H->$A_STOCK_H"; FAIL=1; fi
if [[ "$A_SEARCH_F" == "$B_SEARCH_F" && "$A_SEARCH_H" == "$B_SEARCH_H" ]]; then ok "search read model back to baseline"; else bad "search mirror did not converge: flights $B_SEARCH_F->$A_SEARCH_F hotels $B_SEARCH_H->$A_SEARCH_H"; FAIL=1; fi
if [[ "${S_CONF:-0}" -ge "$SMOKE_N" ]]; then ok "post-restore smoke: $S_CONF/$SMOKE_N confirmed (payments SUCCEEDED=$S_PAY) — system healed"; else bad "post-restore smoke: only ${S_CONF:-0}/$SMOKE_N confirmed — residue from the fault window"; FAIL=1; fi

echo
info "Record this run in RESULTS.md. Post-window meters (fresh pods per rollout):"
info "  POD=\$(kubectl -n $APPS_NS get pods -l app.kubernetes.io/name=${PAYMENT_DEPLOY} -o jsonpath='{.items[0].metadata.name}')"
info "  kubectl get --raw \"/api/v1/namespaces/$APPS_NS/pods/\${POD}:9090/proxy/actuator/prometheus\" \\"
info "    | grep -E 'atlas_payment_(provider_calls|recoveries)'"
info "  (during the batch: provider_calls{outcome=\"timeout\"} == N and recoveries == 0)"

echo
if [[ "$FAIL" -eq 0 ]]; then
  ok "Experiment 05 PASSED — the stalled payments timed out and the Saga compensated cleanly."
else
  die "Experiment 05 FAILED — a compensation invariant broke. Investigate before re-running."
fi
