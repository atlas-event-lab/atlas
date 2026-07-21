#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# recover-search.sh — rebuild the Search read model from the owning services (Strategy B,
# ADR-0025/0026/0027).
#
# NON-DESTRUCTIVE. It does not wipe or reset offsets. It triggers each owner's
# POST /actuator/resync to re-emit its CURRENT DB state through the outbox; Search re-projects it.
# Use this to recover after a wipe when the event log has aged out of retention (Experiment 07) —
# the authoritative state lives in flight_db / hotel_db / inventory_db, so nothing is lost.
#
# Order matters: catalog (flight, then hotel) first so the projection rows exist, THEN availability
# (inventory) so its absolute reserved values land on existing rows (else Search drops them).
#
# Prereqs: kubectl context on the Atlas cluster; curl; Search running; and the flight/hotel/inventory
#          images built with the resync endpoints (ADR-0025/26/27) — the script verifies this first.
#
# Usage:
#   DRY_RUN=1 ./recover-search.sh        # preview, change nothing
#   CONFIRM=yes ./recover-search.sh      # execute the resync + verify
# Env: SETTLE (300s per phase), DRY_RUN, CONFIRM.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APPS_NS="atlas-apps"
DATA_NS="atlas-data"
PG_CLUSTER="atlas-pg"
MGMT_PORT="9090"
LPORT="19090"
SEARCH_DEPLOY="search-service"
SETTLE="${SETTLE:-300}"
DRY_RUN="${DRY_RUN:-0}"
CONFIRM="${CONFIRM:-no}"

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
command -v curl >/dev/null 2>&1 || die "curl not installed (needed to call /actuator/resync)."
info "kubectl context: $CTX"
if [[ "$DRY_RUN" != "1" && "$CONFIRM" != "yes" ]]; then
  die "This re-emits every catalog + availability event (idempotent). Re-run with CONFIRM=yes, or DRY_RUN=1."
fi

# ── Resolve Postgres primary (for verification) ──────────────────────────────
PG_PRIMARY="$(kubectl -n "$DATA_NS" get pods \
  -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$PG_PRIMARY" ]] || PG_PRIMARY="$(kubectl -n "$DATA_NS" get pods \
  -l "cnpg.io/cluster=${PG_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$PG_PRIMARY" ]] || die "could not find CNPG primary for ${PG_CLUSTER}."
info "Postgres primary: $PG_PRIMARY"

psql_val() { # db, sql
  kubectl -n "$DATA_NS" exec -c postgres "$PG_PRIMARY" -- \
    psql -U postgres -d "$1" -tA -c "$2" 2>/dev/null | tr -d '[:space:]'
}

# ── Ensure Search is running (it must consume the re-emitted events) ──────────
REPLICAS="$(kubectl -n "$APPS_NS" get deploy "$SEARCH_DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
if [[ "${REPLICAS:-0}" -lt 1 ]]; then
  say "Search is scaled to 0 — scaling to 1 so it can consume the resync"
  if [[ "$DRY_RUN" != "1" ]]; then
    kubectl -n "$APPS_NS" scale "deploy/${SEARCH_DEPLOY}" --replicas=1 >/dev/null
    kubectl -n "$APPS_NS" rollout status "deploy/${SEARCH_DEPLOY}" --timeout=180s >/dev/null 2>&1 || true
  fi
fi

# ── Resync helper (port-forward → POST /actuator/resync) ─────────────────────
resync_owner() { # deploy-name
  local pod pf out
  pod="$(kubectl -n "$APPS_NS" get pods -l "app.kubernetes.io/name=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || die "no $1 pod found."
  if [[ "$DRY_RUN" == "1" ]]; then info "[dry-run] POST http://<$1>:${MGMT_PORT}/actuator/resync"; return; fi
  kubectl -n "$APPS_NS" port-forward "pod/$pod" "${LPORT}:${MGMT_PORT}" >/dev/null 2>&1 &
  pf=$!
  for _ in $(seq 1 15); do curl -sf "http://localhost:${LPORT}/actuator/health" >/dev/null 2>&1 && break; sleep 1; done
  # Preflight: the resync endpoint must be deployed (ADR-0025/26/27). /actuator lists exposed endpoints.
  if ! curl -sf "http://localhost:${LPORT}/actuator" 2>/dev/null | grep -q '"resync"'; then
    kill "$pf" 2>/dev/null || true
    die "$1 does not expose /actuator/resync — build & deploy the image with ADR-0025/26/27 first."
  fi
  out="$(curl -s -X POST "http://localhost:${LPORT}/actuator/resync" -H 'Content-Type: application/json' || echo 'POST failed')"
  info "$1 resync → $out"
  kill "$pf" 2>/dev/null || true
}

# Poll a search_db count until it reaches >= target (or SETTLE elapses).
wait_count_ge() { # label, sql, target
  local label="$1" sql="$2" target="$3" v
  for _ in $(seq 1 "$(( SETTLE / 5 ))"); do
    v="$(psql_val search_db "$sql")"
    [[ "${v:-0}" -ge "$target" ]] && { info "$label: ${v}/${target}"; return; }
    sleep 5
  done
  warn "$label: reached ${v:-0}/${target} within ${SETTLE}s (continuing)"
}

# ── Targets from the owning DBs (source of truth) ────────────────────────────
say "Targets (owning DBs)"
T_FLIGHTS="$(psql_val flight_db "SELECT count(*) FROM flights WHERE status='ACTIVE';")"
T_HOTELS="$(psql_val hotel_db "SELECT count(*) FROM hotels WHERE status='ACTIVE';")"
T_FLIGHT_RES="$(psql_val inventory_db "SELECT coalesce(sum(reserved_count),0) FROM flight_inventory;")"
T_HOTEL_RES="$(psql_val inventory_db "SELECT coalesce(sum(reserved),0) FROM room_type_availability WHERE stay_date >= current_date;")"
info "active flights=$T_FLIGHTS · active hotels=$T_HOTELS · flight reserved(sum)=$T_FLIGHT_RES · hotel reserved(sum, future)=$T_HOTEL_RES"
info "search now: flight_projections=$(psql_val search_db 'SELECT count(*) FROM flight_projections;') hotel_projections=$(psql_val search_db 'SELECT count(*) FROM hotel_projections;')"

# ── 1. Catalog resync (flight, then hotel) ───────────────────────────────────
say "1. Resync CATALOG — flight-service, then hotel-service"
resync_owner flight-service
resync_owner hotel-service
if [[ "$DRY_RUN" != "1" ]]; then
  wait_count_ge "flight_projections" "SELECT count(*) FROM flight_projections;" "${T_FLIGHTS:-0}"
  wait_count_ge "hotel_projections"  "SELECT count(*) FROM hotel_projections;"  "${T_HOTELS:-0}"
fi

# ── 2. Availability resync (inventory) — catalog rows now exist ──────────────
say "2. Resync AVAILABILITY — inventory-service"
resync_owner inventory-service
if [[ "$DRY_RUN" != "1" ]]; then
  info "waiting for availability to apply (flight reserved sum → ${T_FLIGHT_RES})..."
  wait_count_ge "flight reserved(sum)" "SELECT coalesce(sum(reserved),0) FROM flight_projections;" "${T_FLIGHT_RES:-0}"
fi

# ── 3. Verify against the owning DBs ─────────────────────────────────────────
say "3. Verify (search vs owning DBs)"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would assert: flight_projections==active flights; hotel_projections==active hotels;"
  info "[dry-run]              sum(flight_projections.reserved)==sum(flight_inventory.reserved_count)"
  say "DRY-RUN complete — nothing changed."
  exit 0
fi

FAIL=0
A_FLIGHTS="$(psql_val search_db 'SELECT count(*) FROM flight_projections;')"
A_HOTELS="$(psql_val search_db 'SELECT count(*) FROM hotel_projections;')"
A_ROOMTYPES="$(psql_val search_db 'SELECT count(*) FROM hotel_room_types;')"
A_FLIGHT_RES="$(psql_val search_db 'SELECT coalesce(sum(reserved),0) FROM flight_projections;')"
A_HOTEL_RES="$(psql_val search_db 'SELECT coalesce(sum(reserved),0) FROM room_type_availability;')"

if [[ "${A_FLIGHTS:-0}" -eq "${T_FLIGHTS:-0}" && "${T_FLIGHTS:-0}" -gt 0 ]]; then ok "flight_projections = $A_FLIGHTS (matches active flights)"; else bad "flight_projections=$A_FLIGHTS vs active flights=$T_FLIGHTS"; FAIL=1; fi
if [[ "${A_HOTELS:-0}" -eq "${T_HOTELS:-0}" ]]; then ok "hotel_projections = $A_HOTELS (matches active hotels)"; else bad "hotel_projections=$A_HOTELS vs active hotels=$T_HOTELS"; FAIL=1; fi
if [[ "${A_FLIGHT_RES:-0}" -eq "${T_FLIGHT_RES:-0}" ]]; then ok "flight reserved sum = $A_FLIGHT_RES (matches inventory)"; else bad "flight reserved sum: search=$A_FLIGHT_RES vs inventory=$T_FLIGHT_RES"; FAIL=1; fi
info "hotel_room_types=$A_ROOMTYPES · hotel reserved sum: search=$A_HOTEL_RES vs inventory(future)=$T_HOTEL_RES (may differ if the night horizons differ — informational)"

echo
if [[ "$FAIL" -eq 0 ]]; then
  ok "Search read model recovered from the owning services."
else
  die "Recovery incomplete — some projections did not converge. Check search-service logs and the resync outputs above."
fi
