#!/usr/bin/env bash
#
# Seed load-test users in Keycloak for the Atlas experiments.
#
# WHY: the travel-cart service keeps ONE active cart per user (keyed by the JWT subject).
# A load test that reuses a single user makes every virtual user collide on the same cart.
# The harness therefore maps each k6 VU to its own user (loadtest-<N>); this script creates
# that pool. See experiments/README.md ("Auth for load tests").
#
# Idempotent: safe to re-run. Existing users are kept; only missing ones are created, and
# every user's password is (re)set to the shared load-test password. Re-run with a larger
# LOADTEST_USER_COUNT to grow the pool — existing users are untouched.
#
# Usage:
#   export KEYCLOAK_ADMIN_PASSWORD=...        # Keycloak admin (required)
#   export LOADTEST_USER_PASSWORD=...         # shared password for the pool (required)
#   ./seed-loadtest-users.sh                  # creates loadtest-1..LOADTEST_USER_COUNT
#
# Config (all env-overridable; defaults target the current cluster):
#   KEYCLOAK_URL            Keycloak base URL              (default http://keycloak.<gateway-ip>.nip.io)
#   KEYCLOAK_REALM          target realm for the users     (default atlas)
#   KEYCLOAK_ADMIN_REALM    realm to authenticate admin in (default master)
#   KEYCLOAK_ADMIN_CLIENT   admin token client_id          (default admin-cli)
#   KEYCLOAK_ADMIN_USER     admin username                 (default admin)
#   KEYCLOAK_ADMIN_PASSWORD admin password                 (required)
#   LOADTEST_USER_PREFIX    username prefix                 (default loadtest-)
#   LOADTEST_USER_COUNT     how many users to ensure        (default 200)
#   LOADTEST_USER_PASSWORD  shared pool password            (required)
#
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.<gateway-ip>.nip.io}"
REALM="${KEYCLOAK_REALM:-atlas}"
ADMIN_REALM="${KEYCLOAK_ADMIN_REALM:-master}"
ADMIN_CLIENT="${KEYCLOAK_ADMIN_CLIENT:-admin-cli}"
ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
USER_PREFIX="${LOADTEST_USER_PREFIX:-loadtest-}"
USER_COUNT="${LOADTEST_USER_COUNT:-200}"
USER_PASSWORD="${LOADTEST_USER_PASSWORD:-}"

PROGRESS_EVERY=25

# ── Small utilities ──────────────────────────────────────────────────────────
ADMIN_TOKEN=""
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_deps() {
  local dep
  for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || die "missing dependency: $dep"
  done
}

validate_config() {
  [[ -n "$ADMIN_PASSWORD" ]] || die "KEYCLOAK_ADMIN_PASSWORD is required"
  [[ -n "$USER_PASSWORD" ]] || die "LOADTEST_USER_PASSWORD is required"
  [[ "$USER_COUNT" =~ ^[0-9]+$ && "$USER_COUNT" -gt 0 ]] \
    || die "LOADTEST_USER_COUNT must be a positive integer (got '$USER_COUNT')"
}

# ── Keycloak Admin API ───────────────────────────────────────────────────────
# Acquire an admin token, retrying through Keycloak's first-boot readiness flaps. On a fresh
# cluster keycloak-0 boots slowly (Quarkus augmentation) and can restart during convergence, so
# the public route can serve a 200 on one request and 503 on the very next while it flaps
# Ready↔NotReady. Polling well-known for a single 200 and then authenticating once still races
# into a 503 on the token call. We therefore make the TOKEN request itself the readiness gate:
# retry transient failures (000 unreachable / 502 / 503 / 504) until KC_WAIT is spent, and fail
# fast only on definitive errors (401 wrong creds, 404 misrouted Ingress). This also covers the
# short refresh path: kc_api re-invokes it on a 401 mid-run, where Keycloak is already healthy
# and it returns on the first attempt. Override the budget with KC_WAIT (seconds).
fetch_admin_token() {
  # Budget by REAL elapsed time (deadline), not by summing interval, and bound each curl so an
  # unreachable host fails in seconds instead of blocking the OS default (~1–2 min) per try.
  local wait="${KC_WAIT:-300}" interval=10 start=$SECONDS raw rc code body
  while :; do
    rc=0
    raw="$(curl -sS --connect-timeout 5 --max-time 15 -w $'\n%{http_code}' -X POST \
      "$KEYCLOAK_URL/realms/$ADMIN_REALM/protocol/openid-connect/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -d 'grant_type=password' \
      -d "client_id=$ADMIN_CLIENT" \
      --data-urlencode "username=$ADMIN_USER" \
      --data-urlencode "password=$ADMIN_PASSWORD" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then code=000; body=""; else code="${raw##*$'\n'}"; body="${raw%$'\n'*}"; fi
    case "$code" in
      200)
        ADMIN_TOKEN="$(jq -r '.access_token // empty' <<<"$body")"
        [[ -n "$ADMIN_TOKEN" ]] && return 0
        die "could not obtain admin token — no access_token in response: $(printf '%.200s' "$body")" ;;
      401) die "admin login rejected — check KEYCLOAK_ADMIN_USER / KEYCLOAK_ADMIN_PASSWORD." ;;
      404) die "HTTP 404 from $KEYCLOAK_URL — the Keycloak Ingress is not routing (TS-PLATFORM-04)." ;;
      000|502|503|504)
        (( SECONDS - start >= wait )) && die "Keycloak still returning HTTP $code after ${wait}s (real time). HTTP 000 = unreachable (e.g. an unresolvable keycloak.<host>.nip.io URL — pass a reachable KEYCLOAK_URL). Else check: kubectl -n atlas-system get pod keycloak-0 (TS-PLATFORM-08 if it loops on exit 137)."
        log "  Keycloak not ready (HTTP $code); retrying… ($((SECONDS - start))s/${wait}s)"
        sleep "$interval" ;;
      *) die "admin token request returned HTTP $code: $(printf '%.200s' "$body")" ;;
    esac
  done
}

# kc_api METHOD PATH [JSON_BODY]
# Echoes the HTTP status code; the response body is left in $BODY_FILE.
# Transparently refreshes the (short-lived) admin token once on a 401 and retries.
kc_api() {
  local method="$1" path="$2" body="${3:-}"
  _call() {
    local args=(-sS --connect-timeout 5 --max-time 30 -o "$BODY_FILE" -w '%{http_code}' -X "$method"
                -H "Authorization: Bearer $ADMIN_TOKEN")
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data "$body")
    curl "${args[@]}" "$KEYCLOAK_URL$path"
  }
  local code
  code="$(_call)"
  if [[ "$code" == "401" ]]; then
    fetch_admin_token
    code="$(_call)"
  fi
  printf '%s' "$code"
}

# Echoes the user's id, or empty string if it doesn't exist.
lookup_user_id() {
  local username="$1" code
  code="$(kc_api GET "/admin/realms/$REALM/users?exact=true&username=$username")"
  [[ "$code" == "200" ]] || die "user lookup failed for '$username' (HTTP $code): $(cat "$BODY_FILE")"
  jq -r '.[0].id // empty' "$BODY_FILE"
}

# Creates the user if missing (409 = already exists is fine). Echoes the user id.
create_user() {
  local username="$1" code
  code="$(kc_api POST "/admin/realms/$REALM/users" \
    "{\"username\":\"$username\",\"enabled\":true,\"emailVerified\":true}")"
  case "$code" in
    201 | 409) ;; # created, or a concurrent create already made it
    *) die "create failed for '$username' (HTTP $code): $(cat "$BODY_FILE")" ;;
  esac
  lookup_user_id "$username"
}

set_password() {
  local id="$1" code
  code="$(kc_api PUT "/admin/realms/$REALM/users/$id/reset-password" \
    "{\"type\":\"password\",\"temporary\":false,\"value\":\"$USER_PASSWORD\"}")"
  [[ "$code" == "204" ]] || die "set-password failed for id '$id' (HTTP $code): $(cat "$BODY_FILE")"
}

# Complete the user's profile (first/last/email) and clear any required actions, so the
# password grant isn't rejected with "Account is not fully set up" — which Keycloak returns
# when the declarative user profile is incomplete or actions (verify email, update profile,
# update password) are pending. Idempotent: also fixes users created by an earlier run.
enforce_profile() {
  local id="$1" index="$2" code
  code="$(kc_api PUT "/admin/realms/$REALM/users/$id" \
    "{\"enabled\":true,\"emailVerified\":true,\"requiredActions\":[],\"firstName\":\"Load\",\"lastName\":\"Tester ${index}\",\"email\":\"${USER_PREFIX}${index}@atlas.example\"}")"
  [[ "$code" == "204" ]] || die "profile update failed for id '$id' (HTTP $code): $(cat "$BODY_FILE")"
}

# Ensures one user exists with a complete profile and the shared password. Echoes
# "created" or "existed". `index` is the pool number (used for the profile fields).
ensure_user() {
  local username="$1" index="$2" id status
  id="$(lookup_user_id "$username")"
  if [[ -z "$id" ]]; then
    id="$(create_user "$username")"
    status=created
  else
    status=existed
  fi
  enforce_profile "$id" "$index"
  set_password "$id"
  printf '%s' "$status"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  case "${1:-}" in -h | --help) sed -n '2,35p' "$0"; exit 0 ;; esac

  require_deps
  validate_config

  log "Seeding users '${USER_PREFIX}1'..'${USER_PREFIX}${USER_COUNT}' in realm '$REALM' at $KEYCLOAK_URL"
  fetch_admin_token   # retries through Keycloak's first-boot readiness flaps (see its comment)

  local created=0 existed=0 i username status
  for ((i = 1; i <= USER_COUNT; i++)); do
    username="${USER_PREFIX}${i}"
    status="$(ensure_user "$username" "$i")"
    [[ "$status" == "created" ]] && created=$((created + 1)) || existed=$((existed + 1))
    (( i % PROGRESS_EVERY == 0 )) && log "  …$i/$USER_COUNT"
  done

  log "Done. created=$created existed=$existed total=$USER_COUNT"
}

main "$@"
