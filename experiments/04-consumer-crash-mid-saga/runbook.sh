#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Experiment 04 — Consumer Crash mid-Saga
#
# Kills EVERY payment-service pod abruptly (SIGKILL — no graceful shutdown, no offset
# commit) while a controlled batch of N bookings drains through the Saga, then proves the
# system recovers to the exact state it would have reached without the crash:
# no double charge, no lost event, every booking terminal.
#
# Flow: clean-start checks → BEFORE snapshot → launch k6 batch (Exp 01 load.js, smoke
# mode) → poll payments until KILL_AFTER → SIGKILL all payment pods → wait recovery →
# lag drains → k6 finishes → states settle → AFTER snapshot + assertions.
#
# Usage:
#   set -a; source ../.env; set +a          # k6 needs the gateway/Keycloak config
#   DRY_RUN=1 ./runbook.sh                  # preview, change nothing
#   CONFIRM=yes ./runbook.sh                # execute (N=50, VUS=5, KILL_AFTER=N/3)
#   CONFIRM=yes N=100 VUS=10 ./runbook.sh
#   CONFIRM=yes KILL_MODE=force-delete ./runbook.sh
#
# Env: N (50), VUS (5), KILL_AFTER (N/3), KILL_LAG (10 — standing lag required before the
#      kill so messages are provably in flight; raise VUS if it never builds),
#      KILL_MODE (exec|force-delete), SETTLE (360 — sized to cover the W2 recovery window:
#      stale-after 3m + one sweep, ADR-0021), SCENARIO (passthrough to k6), DRY_RUN, CONFIRM.
# Prereqs: kubectl context on the Atlas cluster; k6 installed; .env loaded; no other load.
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
PAYMENT_SELECTOR="app.kubernetes.io/name=payment-service"
WIREMOCK_SVC="wiremock"

N="${N:-50}"
VUS="${VUS:-5}"
KILL_AFTER="${KILL_AFTER:-$(( N / 3 > 0 ? N / 3 : 1 ))}"
KILL_LAG="${KILL_LAG:-10}"
KILL_MODE="${KILL_MODE:-exec}"
SETTLE="${SETTLE:-360}"
DRY_RUN="${DRY_RUN:-0}"
CONFIRM="${CONFIRM:-no}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_JS="${SCRIPT_DIR}/../01-high-booking-concurrency/load.js"

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
info "kubectl context: $CTX"
[[ "$CTX" =~ [Pp]rod ]] && die "context '$CTX' looks like PRODUCTION — refusing."
kubectl get ns "$APPS_NS" >/dev/null 2>&1 || die "namespace $APPS_NS not found."
kubectl get ns "$DATA_NS" >/dev/null 2>&1 || die "namespace $DATA_NS not found."
command -v k6 >/dev/null 2>&1 || die "k6 not installed (needed to fire the batch)."
[[ -f "$LOAD_JS" ]] || die "cannot find Exp 01 load.js at $LOAD_JS."
[[ -n "${ATLAS_GATEWAY:-}" ]] || die "ATLAS_GATEWAY not set — load ../.env first (set -a; source ../.env; set +a)."
if [[ "$DRY_RUN" != "1" && "$CONFIRM" != "yes" ]]; then
  die "This SIGKILLs every payment-service pod mid-batch. Re-run with CONFIRM=yes, or preview with DRY_RUN=1."
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

# (portable: no mapfile — macOS ships bash 3.2)
PAYMENT_PODS=()
while IFS= read -r p; do [[ -n "$p" ]] && PAYMENT_PODS+=("$p"); done < <(
  kubectl -n "$APPS_NS" get pods -l "$PAYMENT_SELECTOR" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
[[ "${#PAYMENT_PODS[@]}" -gt 0 ]] || die "no running payment-service pods found (selector: $PAYMENT_SELECTOR)."
info "payment pods:    ${PAYMENT_PODS[*]} (${#PAYMENT_PODS[@]})"

# helpers ---------------------------------------------------------------------
psql_val() { # db, sql
  kubectl -n "$DATA_NS" exec "$PG_PRIMARY" -- \
    psql -U postgres -d "$1" -tA -c "$2" 2>/dev/null | tr -d '[:space:]'
}
group_lag_on_topic() {
  kubectl -n "$DATA_NS" exec "$KAFKA_POD" -- \
    "$KAFKA_BIN" --bootstrap-server "$KAFKA_BOOTSTRAP" --group "$GROUP" --describe 2>/dev/null \
    | awk -v t="$TOPIC" '$2==t {s+=$6} END{print s+0}'
}
# Curl a cluster HTTP endpoint through a short-lived local port-forward. Only used where the
# API-server proxy cannot (POST bodies). Hardened: retries until the forward is up, and
# --noproxy so corporate proxy env vars never swallow 127.0.0.1.
# Args: <kubectl target, e.g. svc/x> <remote-port> <path> [curl extra args...].
pf_curl() {
  local target="$1" rport="$2" path="$3"; shift 3
  local lport=$(( 20000 + RANDOM % 10000 )) pf body=""
  kubectl -n "$APPS_NS" port-forward "$target" "${lport}:${rport}" >/dev/null 2>&1 &
  pf=$!
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 1
    body="$(curl -s -m 5 --noproxy '*' "$@" "http://127.0.0.1:${lport}${path}" 2>/dev/null || true)"
    [[ -n "$body" ]] && break
  done
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  printf '%s' "$body"
}
# GET an HTTP endpoint on a pod via the API-server proxy — no local networking, no
# port-forward races, immune to proxy env vars. Args: <pod> <port> <path>.
pod_proxy_get() {
  kubectl get --raw "/api/v1/namespaces/${APPS_NS}/pods/${1}:${2}/proxy${3}" 2>/dev/null
}
# True if ANY payment pod exposes the ADR-0020 meters. Counters are lazy, so this is only
# conclusive once the current pods have charged at least one payment (checked at kill time,
# when >= KILL_AFTER charges were made by them).
payment_metrics_present() {
  # NOTE: capture-then-grep on purpose. `kubectl | grep -q` under `set -o pipefail` is a trap:
  # grep -q exits on first match and closes the pipe, kubectl dies with SIGPIPE (141), and
  # pipefail turns the whole pipeline — a successful match! — into a failure.
  local pod body
  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    body="$(pod_proxy_get "$pod" 9090 /actuator/prometheus || true)"
    if grep -q '^atlas_payment_provider_calls' <<<"$body"; then
      return 0
    fi
  done < <(kubectl -n "$APPS_NS" get pods -l "$PAYMENT_SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  return 1
}
# WireMock POST /payments count via the admin API (best-effort: returns "" on failure).
wiremock_count() {
  pf_curl "svc/${WIREMOCK_SVC}" 8080 /__admin/requests/count \
      -X POST -H 'Content-Type: application/json' \
      -d '{"method":"POST","urlPath":"/payments"}' \
    | sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
}

# ── Clean start + BEFORE snapshot ────────────────────────────────────────────
say "Clean start"
LAG0="$(group_lag_on_topic || echo "")"
info "'$GROUP' lag on '$TOPIC': ${LAG0:-unknown}"
[[ "${LAG0:-0}" -eq 0 ]] || die "group lag is not 0 — another run is in flight. Let it drain first."

say "Snapshot BEFORE (Postgres ground truth)"
# ISO 'T' form: psql_val strips whitespace, so the timestamp must not contain a space.
B_TS="$(psql_val booking_db "SELECT replace(now()::text, ' ', 'T');")"
B_PAY="$(psql_val payment_db 'SELECT count(*) FROM payments;')"
B_CONSUMED="$(psql_val payment_db 'SELECT count(*) FROM consumed_events;')"
B_OUTBOX="$(psql_val payment_db 'SELECT count(*) FROM outbox;')"
B_WM="$(wiremock_count || echo "")"
info "payments=$B_PAY  consumed_events=$B_CONSUMED  outbox=$B_OUTBOX  wiremock POST /payments=${B_WM:-n/a}"
info "batch window starts at (db clock): $B_TS"

# ── 1. Fire the k6 batch in the background ───────────────────────────────────
say "1. Fire the batch — $N journeys, $VUS parallel (Exp 01 load.js, smoke mode)"
K6_LOG="${SCRIPT_DIR}/k6-batch.log"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] k6 run -e ITERATIONS=$N -e VUS=$VUS $LOAD_JS  (> $K6_LOG)"
else
  ( cd "${SCRIPT_DIR}/../01-high-booking-concurrency" && \
    k6 run -e ITERATIONS="$N" -e VUS="$VUS" load.js >"$K6_LOG" 2>&1 ) &
  K6_PID=$!
  info "k6 started (pid $K6_PID, log: $K6_LOG)"
fi

# ── 2. Wait for mid-drain + a SATURATED consumer, then KILL ──────────────────
# Duplicates/W2 only exist if messages are IN FLIGHT at the kill instant. A drained, idle
# consumer killed between messages yields a trivially-clean run (no redelivery at all). So
# the trigger is BOTH: payments >= KILL_AFTER (mid-batch) AND standing lag >= KILL_LAG
# (backlog queued → the consumer is provably mid-processing).
say "2. Kill — waiting for payments >= $KILL_AFTER AND lag >= $KILL_LAG, then SIGKILL every payment pod"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] poll payment_db.payments until >= $KILL_AFTER and lag >= $KILL_LAG"
  info "[dry-run] KILL_MODE=$KILL_MODE on the payment pods resolved at kill time"
else
  cur=0; lag_now=0
  for _ in $(seq 1 300); do
    cur="$(psql_val payment_db "SELECT count(*) FROM payments WHERE created_at >= '$B_TS';" || echo 0)"
    lag_now="$(group_lag_on_topic || echo 0)"
    [[ "${cur:-0}" -ge "$KILL_AFTER" && "${lag_now:-0}" -ge "$KILL_LAG" ]] && break
    if ! kill -0 "$K6_PID" 2>/dev/null; then
      warn "k6 finished before the trigger (payments=$cur, lag=$lag_now) — the consumer never saturated."
      warn "Killing anyway, but expect few/no duplicates. Next run: raise VUS (arrival must outpace payment)."
      break
    fi
    sleep 1
  done
  info "trigger met: payments=$cur, lag on '$TOPIC'=$lag_now — verifying the deployed image before killing"

  # >= KILL_AFTER charges were just made by the CURRENT pods; if none of them exposes the
  # ADR-0020 provider-calls meter, the deployed image predates the instrumentation and the
  # post-recovery readout would be blind. Abort cleanly instead of wasting the run.
  if ! payment_metrics_present; then
    kill "$K6_PID" 2>/dev/null || true
    die "no payment pod exposes atlas_payment_provider_calls_* — the deployed image lacks ADR-0020/0021. Push + CI build + rollout restart payment-service, then re-run."
  fi
  info "ADR-0020 meters present — killing now (${KILL_MODE})"

  # Re-resolve the pods AT KILL TIME: KEDA scales payment on lag, so pods that did not exist
  # when the runbook started may be consuming now — missing one leaves live group members and
  # muddies the rebalance. Kill everything currently running.
  PAYMENT_PODS=()
  while IFS= read -r p; do [[ -n "$p" ]] && PAYMENT_PODS+=("$p"); done < <(
    kubectl -n "$APPS_NS" get pods -l "$PAYMENT_SELECTOR" \
      --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  [[ "${#PAYMENT_PODS[@]}" -gt 0 ]] || die "no running payment pods at kill time?"
  info "pods at kill time: ${PAYMENT_PODS[*]} (${#PAYMENT_PODS[@]})"

  KILL_TS="$(date +%H:%M:%S)"
  for pod in "${PAYMENT_PODS[@]}"; do
    killed=0
    if [[ "$KILL_MODE" == "exec" ]]; then
      # SIGKILL the JVM from inside. If java is PID 1 the kernel blocks in-namespace
      # SIGKILL → fall back to force-delete for that pod.
      if kubectl -n "$APPS_NS" exec "$pod" -- /bin/sh -c \
          'p=$(pidof java || echo 1); [ "$p" != "1" ] && kill -9 $p' 2>/dev/null; then
        # verify the container actually died (restart count moves or pod goes not-ready)
        sleep 2
        phase="$(kubectl -n "$APPS_NS" get pod "$pod" \
          -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || true)"
        [[ -n "$phase" ]] && killed=1
      fi
    fi
    if [[ "$killed" -eq 0 ]]; then
      info "$pod: falling back to force-delete (grace 0 = immediate SIGKILL)"
      kubectl -n "$APPS_NS" delete pod "$pod" --grace-period=0 --force >/dev/null 2>&1 || true
    else
      info "$pod: JVM SIGKILLed in place"
    fi
  done
  info "all payment pods killed at $KILL_TS — group '$GROUP' has no members; lag will build"
fi

# ── 3. Recovery: pods back, lag drained, k6 done, states settled ─────────────
say "3. Recovery"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] wait pods Ready → k6 exit → lag 0 → $SETTLE s settle"
  say "DRY-RUN complete — nothing changed."
  exit 0
fi

info "waiting for payment pods to be Ready again..."
sleep 5   # give the Deployment a beat to create replacement pods (force-delete path)
kubectl -n "$APPS_NS" wait --for=condition=Ready pod -l "$PAYMENT_SELECTOR" --timeout=180s >/dev/null \
  || warn "pods not all Ready after 180s — check the deployment"
PEAK_LAG="$(group_lag_on_topic || echo 0)"
info "lag on '$TOPIC' right after recovery: $PEAK_LAG (redelivery + backlog)"

info "waiting for k6 to finish..."
wait "$K6_PID" || warn "k6 exited non-zero — some journeys failed during the outage (expected: gateway kept working, only payment stalled). See $K6_LOG"

info "waiting for '$GROUP' lag on '$TOPIC' to drain..."
for _ in $(seq 1 180); do
  lag="$(group_lag_on_topic || echo 0)"
  [[ "${lag:-0}" -eq 0 ]] && break
  sleep 2
done
info "final lag: $(group_lag_on_topic)"

info "letting booking states settle (up to ${SETTLE}s — covers the W2 recovery window:"
info "stale-after + one sweep, ADR-0021; early-exit when nothing is in flight)..."
for _ in $(seq 1 "$(( SETTLE / 2 ))"); do
  inflight="$(psql_val booking_db \
    "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status IN ('PENDING','INVENTORY_RESERVED','PAYMENT_PENDING');")"
  [[ "${inflight:-1}" -eq 0 ]] && break
  sleep 2
done

# ── 4. AFTER snapshot + assertions ───────────────────────────────────────────
say "Snapshot AFTER"
A_PAY="$(psql_val payment_db 'SELECT count(*) FROM payments;')"
A_CONSUMED="$(psql_val payment_db 'SELECT count(*) FROM consumed_events;')"
A_OUTBOX="$(psql_val payment_db 'SELECT count(*) FROM outbox;')"
A_WM="$(wiremock_count || echo "")"
DUP_PAY="$(psql_val payment_db 'SELECT count(*) FROM (SELECT booking_id FROM payments GROUP BY booking_id HAVING count(*) > 1) d;')"
W_TOTAL="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS';")"
W_CONF="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status = 'CONFIRMED';")"
W_FAILED="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status = 'FAILED';")"
W_EXPIRED="$(psql_val booking_db "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status = 'EXPIRED';")"
W_STUCK="$(psql_val booking_db \
  "SELECT count(*) FROM bookings WHERE created_at >= '$B_TS' AND status IN ('PENDING','INVENTORY_RESERVED','PAYMENT_PENDING');")"
P_STUCK="$(psql_val payment_db "SELECT count(*) FROM payments WHERE created_at >= '$B_TS' AND status = 'PROCESSING';")"
info "payments=$A_PAY (+$(( A_PAY - B_PAY )))  consumed_events=$A_CONSUMED (+$(( A_CONSUMED - B_CONSUMED )))  outbox=$A_OUTBOX"
info "batch bookings=$W_TOTAL  confirmed=$W_CONF  failed=$W_FAILED  expired=$W_EXPIRED  in-flight=$W_STUCK"
info "payments still PROCESSING (W2 candidates): ${P_STUCK:-0}"
if [[ -n "$B_WM" && -n "$A_WM" ]]; then
  info "wiremock POST /payments: $B_WM -> $A_WM (delta $(( A_WM - B_WM )); payments created: $(( A_PAY - B_PAY )))"
else
  warn "wiremock request count unavailable — skip the provider-side check for this run"
fi

say "Verdict (crash-recovery invariants)"
FAIL=0
if [[ "${DUP_PAY:-1}" -eq 0 ]]; then ok "no double charge: 0 bookings with >1 payment"; else bad "double charge: $DUP_PAY bookings with >1 payment"; FAIL=1; fi
FINAL_LAG="$(group_lag_on_topic || echo -1)"
if [[ "${FINAL_LAG:-1}" -eq 0 ]]; then ok "no loss: '$GROUP' lag on '$TOPIC' drained to 0"; else bad "lag never drained ($FINAL_LAG) — events unprocessed"; FAIL=1; fi
if [[ "${W_STUCK:-1}" -eq 0 ]]; then ok "saga healed: no booking left in flight (W2 orphans recovered by the ADR-0021 sweeper)"; else
  bad "$W_STUCK booking(s) still in flight after ${SETTLE}s (payments stuck PROCESSING: ${P_STUCK:-0})."
  bad "The recovery sweeper (ADR-0021) should have re-driven them within stale-after + one"
  bad "sweep. Check: payment-service deployed with the sweeper? PAYMENT_RECOVERY_STALE_AFTER"
  bad "vs SETTLE? atlas_payment_recoveries_total moving? payment logs for 'Recovering stale'."
  FAIL=1
fi
if [[ "$W_TOTAL" -eq "$N" ]]; then ok "batch complete: $W_TOTAL/$N bookings created"; else warn "batch created $W_TOTAL/$N bookings (journeys can fail at the gateway during the outage — check $K6_LOG)"; fi

echo
info "Record this run in RESULTS.md (kill mode/time, peak lag, per-status counts, W2 count,"
info "wiremock delta, and the post-recovery meters (ADR-0020/0021; counters start at 0 on the new pods):"
info "  POD=\$(kubectl -n $APPS_NS get pods -l $PAYMENT_SELECTOR -o jsonpath='{.items[0].metadata.name}')"
info "  kubectl get --raw \"/api/v1/namespaces/$APPS_NS/pods/\${POD}:9090/proxy/actuator/prometheus\" \\"
info "    | grep -E 'atlas_payment_(events_skipped|provider_calls|recoveries)'"
info "Secondary signal — the duplicate-skip log lines:"
info "  kubectl -n $APPS_NS logs -l $PAYMENT_SELECTOR --tail=-1 | grep -E 'Skipping duplicate|already exists'"

echo
if [[ "$FAIL" -eq 0 ]]; then
  ok "Experiment 04 PASSED — abrupt crash recovered with no loss and no double-processing."
else
  die "Experiment 04 FAILED — an invariant broke under crash-recovery. Investigate before re-running."
fi
