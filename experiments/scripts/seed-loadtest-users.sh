#!/usr/bin/env bash
#
# Seed load-test users in Keycloak for the Atlas experiments.
#
# WHY: the travel-cart service keeps ONE active cart per user (keyed by the JWT subject).
# A load test that reuses a single user makes every virtual user collide on the same cart.
# The harness therefore maps each k6 VU to its own user (loadtest-<N>); this script creates
# that pool. See experiments/README.md ("Auth for load tests").
#
# Idempotent: safe to re-run. Existing users are left ALONE (they already work) and only the
# missing ones are created. Re-run with a larger LOADTEST_USER_COUNT to grow the pool.
# Pass --force-password to also rewrite the profile + password of users that already exist
# (needed only after the pool password in the Secret changes).
#
# COST MODEL — why this is fast, and where the remaining time goes.
# The naive shape is 5 HTTP calls per user (lookup, create, lookup-the-new-id, profile,
# password) — ~1000 calls for a 200-user pool, each paying DNS to nip.io + TCP + a fresh curl
# process through the ingress. That, not the hashing, was the bottleneck: it took 15-20 min.
# Keycloak 26 accepts the FULL user representation (profile + requiredActions + credentials)
# on the create call, and can list the whole pool in one paginated query, so this script does:
#     1-2 calls  list every existing pool member    (bulk, briefRepresentation)
#     1 call     per MISSING user (create + profile + password in one POST)
#     3 calls    sample token grants to prove the pool actually authenticates
# A cold 200-user run is ~205 calls; a warm re-run is 5, because existing users are not
# touched at all (see --force-password).
#
# MEASURED on the Civo cluster (3 nodes, keycloak-0 at cpu 2, public nip.io route):
#     cold  25 users -> 10s      cold 100 users -> 37s      warm any size -> ~2s
# i.e. ~0.32s of marginal cost per created user, and ~2s of fixed overhead. A 200-user pool
# lands around 70s, down from 15-20 min.
#
# That 0.32s is mostly ROUND-TRIP, not Argon2 — if hashing dominated, each create would cost
# ~0.5-1s on its own. So the next lever, if this ever needs to be faster, is removing the hop
# through the ingress (run this as an in-cluster Job against keycloak-service:8080), NOT
# pre-hashed credentials or partialImport: those would save ~a minute while coupling this
# script to Keycloak's internal credential format. Deliberately not done.
#
# Usage:
#   export KEYCLOAK_ADMIN_PASSWORD=...        # Keycloak admin (required)
#   export LOADTEST_USER_PASSWORD=...         # shared password for the pool (required)
#   ./seed-loadtest-users.sh                  # creates loadtest-1..LOADTEST_USER_COUNT
#   ./seed-loadtest-users.sh --force-password # also resets existing members
#
# Flags:
#   --force-password  Rewrite profile + password on users that ALREADY exist. Off by default:
#                     it is the expensive path (one Argon2 hash each) and is only needed when
#                     the shared pool password changed.
#   --no-verify       Skip the sample token grants at the end.
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
#   VERIFY_CLIENT           public client for the token check (default atlas-web)
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
VERIFY_CLIENT="${VERIFY_CLIENT:-atlas-web}"

FORCE_PASSWORD=false
DO_VERIFY=true

PROGRESS_EVERY=25
PAGE_SIZE="${KC_PAGE_SIZE:-1000}"   # Admin API page size for the bulk listing below
                                    # (overridable so the pagination path can be tested with a
                                    # pool far smaller than 1000)

# ── Small utilities ──────────────────────────────────────────────────────────
ADMIN_TOKEN=""
BODY_FILE="$(mktemp)"     # response body of the last kc_api call
HEAD_FILE="$(mktemp)"     # response headers of the last kc_api call
REQ_LOG="$(mktemp)"       # one byte per HTTP call, so the run can report its own call count
WANTED_FILE="$(mktemp)"   # every username the pool should contain, sorted
EXISTING_FILE="$(mktemp)" # every username the realm already has for this prefix, sorted
MISSING_FILE="$(mktemp)"  # wanted - existing  -> the ones to create
PRESENT_FILE="$(mktemp)"  # wanted ∩ existing  -> the ones to leave alone (or rewrite)
trap 'rm -f "$BODY_FILE" "$HEAD_FILE" "$REQ_LOG" "$WANTED_FILE" "$EXISTING_FILE" "$MISSING_FILE" "$PRESENT_FILE"' EXIT

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Counted in a FILE, not a variable: kc_api runs inside $( ) command substitutions, so a shell
# counter would be incremented in a subshell and lost.
count_request() { printf '.' >>"$REQ_LOG"; }
request_count() { wc -c <"$REQ_LOG" | tr -d ' '; }

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

# Percent-encode a value for use in a query string. The pool prefix is tame today
# (loadtest-), but LOADTEST_USER_PREFIX is user-supplied and goes straight into a URL.
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

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
    count_request
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
# Echoes the HTTP status code; the response body is left in $BODY_FILE and the response
# headers in $HEAD_FILE.
# Transparently refreshes the (short-lived) admin token once on a 401 and retries.
# Also retries a transient 502/503/504 a few times: Keycloak can still be settling while this
# runs, and a single blip used to abort the whole pool halfway through.
kc_api() {
  local method="$1" path="$2" body="${3:-}"
  _call() {
    local args=(-sS --connect-timeout 5 --max-time 30 -o "$BODY_FILE" -D "$HEAD_FILE"
                -w '%{http_code}' -X "$method" -H "Authorization: Bearer $ADMIN_TOKEN")
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data "$body")
    local out rc=0
    count_request
    # Normalise a connection failure to 000 ourselves. curl ALSO writes "000" via -w on a
    # failed connection, so a naive `curl ... || printf '000'` yields "000000".
    out="$(curl "${args[@]}" "$KEYCLOAK_URL$path")" || rc=$?
    if (( rc != 0 )); then printf '000'; else printf '%s' "$out"; fi
  }
  local code attempt
  code="$(_call)"
  if [[ "$code" == "401" ]]; then
    fetch_admin_token
    code="$(_call)"
  fi
  for attempt in 1 2 3; do
    case "$code" in
      000|502|503|504) sleep $(( attempt * 2 )); code="$(_call)" ;;
      *) break ;;
    esac
  done
  printf '%s' "$code"
}

# ── (B) One bulk listing instead of one lookup per user ──────────────────────
# Collects every username already in the realm whose name matches the pool prefix, into a
# sorted file. The Admin API's `username=` filter is a FUZZY match, not an exact one, so it
# also returns neighbours (searching `bench-` matches `bench-new-7` too): we never trust the
# server's filtering, we only intersect its answer with the exact names we generate.
# Paginated because the filter has no "all" mode.
#
# A sorted FILE + comm, not an associative array: macOS ships bash 3.2, where `declare -A`
# does not exist, and every script in this repo is run from a Mac. Keep it that way.
load_existing_users() {
  local first=0 code n q
  q="$(urlenc "$USER_PREFIX")"
  : >"$EXISTING_FILE"
  while :; do
    code="$(kc_api GET "/admin/realms/$REALM/users?username=$q&first=$first&max=$PAGE_SIZE&briefRepresentation=true")"
    [[ "$code" == "200" ]] || die "bulk user listing failed (HTTP $code): $(head -c 300 "$BODY_FILE")"
    n="$(jq 'length' "$BODY_FILE")"
    jq -r '.[].username // empty' "$BODY_FILE" >>"$EXISTING_FILE"
    (( n < PAGE_SIZE )) && break
    first=$(( first + PAGE_SIZE ))
  done
  LC_ALL=C sort -u -o "$EXISTING_FILE" "$EXISTING_FILE"
}

# ── (A) One POST creates the user complete ───────────────────────────────────
# Keycloak accepts the full representation on create: profile, emailVerified, an EMPTY
# requiredActions, and the credential itself. Sending all of it at once is what collapses the
# old create → profile → password sequence into a single call.
#
# `emailVerified: true` + `requiredActions: []` + `temporary: false` are not cosmetic: any one
# of them wrong produces a user that EXISTS but cannot use the password grant ("Account is not
# fully set up" / invalid_grant), which would only surface later as a k6 auth failure. That is
# exactly what verify_sample() at the end guards against.
#
# Built with jq, never string interpolation: the pool password comes from a generated Secret
# and a stray quote or backslash in it would produce malformed JSON.
user_json() {
  local username="$1" index="$2"
  jq -nc --arg u "$username" --arg idx "$index" --arg pw "$USER_PASSWORD" \
         --arg email "${USER_PREFIX}${index}@atlas.example" '{
    username: $u, enabled: true, emailVerified: true, requiredActions: [],
    firstName: "Load", lastName: ("Tester " + $idx), email: $email,
    credentials: [{ type: "password", temporary: false, value: $pw }]
  }'
}

# Echoes "created" or "existed"; dies on anything else.
create_user() {
  local username="$1" index="$2" code
  code="$(kc_api POST "/admin/realms/$REALM/users" "$(user_json "$username" "$index")")"
  case "$code" in
    201) printf 'created' ;;
    409) printf 'existed' ;;   # raced, or the fuzzy listing above missed it — both are fine
    *) die "create failed for '$username' (HTTP $code): $(head -c 300 "$BODY_FILE")" ;;
  esac
}

# ── (C) The expensive rewrite of EXISTING users, now opt-in ──────────────────
# This is what made a re-run cost as much as a first run: every existing member paid a profile
# PUT plus an Argon2 hash for a password it already had. Only needed when the shared pool
# password in the Secret actually changed.
reset_existing_user() {
  local username="$1" index="$2" code id
  code="$(kc_api GET "/admin/realms/$REALM/users?exact=true&username=$(urlenc "$username")")"
  [[ "$code" == "200" ]] || die "lookup failed for '$username' (HTTP $code)"
  id="$(jq -r '.[0].id // empty' "$BODY_FILE")"
  [[ -n "$id" ]] || die "user '$username' vanished between listing and update"
  code="$(kc_api PUT "/admin/realms/$REALM/users/$id" \
    "$(jq -nc --arg idx "$index" --arg email "${USER_PREFIX}${index}@atlas.example" \
        '{enabled:true, emailVerified:true, requiredActions:[],
          firstName:"Load", lastName:("Tester " + $idx), email:$email}')")"
  [[ "$code" == "204" ]] || die "profile update failed for '$username' (HTTP $code)"
  code="$(kc_api PUT "/admin/realms/$REALM/users/$id/reset-password" \
    "$(jq -nc --arg pw "$USER_PASSWORD" '{type:"password", temporary:false, value:$pw}')")"
  [[ "$code" == "204" ]] || die "set-password failed for '$username' (HTTP $code)"
}

# ── Verification ─────────────────────────────────────────────────────────────
# Prove the pool can actually AUTHENTICATE, not merely that the users exist. Uses the public
# atlas-web client (directAccessGrantsEnabled, no client secret needed), so this costs nothing
# to wire up. Samples the first, middle and last member — the failure modes this catches
# (a required action left attached, temporary credential, incomplete profile) are systematic,
# so a sample is as good as the whole pool.
verify_sample() {
  local -a probe=(1 $(( (USER_COUNT + 1) / 2 )) "$USER_COUNT")
  local i username raw code failed=0
  for i in $(printf '%s\n' "${probe[@]}" | sort -un); do
    username="${USER_PREFIX}${i}"
    count_request
    raw="$(curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' -X POST \
      "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -d 'grant_type=password' -d "client_id=$VERIFY_CLIENT" \
      --data-urlencode "username=$username" \
      --data-urlencode "password=$USER_PASSWORD" 2>/dev/null)" || raw=000
    code="$raw"
    if [[ "$code" == "200" ]]; then
      log "  ✔ $username can obtain a token"
    else
      log "  ✘ $username FAILED the token grant (HTTP $code)"
      failed=1
    fi
  done
  (( failed == 0 )) || die "pool members exist but cannot authenticate via client '$VERIFY_CLIENT'. Check that the client exists with directAccessGrantsEnabled, that LOADTEST_USER_PASSWORD matches the pool, and that no required action is attached. Re-run with --force-password to rewrite the existing members."
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-password) FORCE_PASSWORD=true; shift ;;
      --no-verify)      DO_VERIFY=false; shift ;;
      -h|--help)        sed -n '2,60p' "$0"; exit 0 ;;
      *)                die "unknown argument: $1" ;;
    esac
  done

  require_deps
  validate_config

  log "Seeding users '${USER_PREFIX}1'..'${USER_PREFIX}${USER_COUNT}' in realm '$REALM' at $KEYCLOAK_URL"
  fetch_admin_token   # retries through Keycloak's first-boot readiness flaps (see its comment)

  local start=$SECONDS i
  for ((i = 1; i <= USER_COUNT; i++)); do printf '%s%s\n' "$USER_PREFIX" "$i"; done \
    | LC_ALL=C sort >"$WANTED_FILE"

  load_existing_users
  # Set difference / intersection against the exact names we want. Both inputs are sorted
  # with the same (C) collation, which is what comm requires.
  LC_ALL=C comm -23 "$WANTED_FILE" "$EXISTING_FILE" >"$MISSING_FILE"
  LC_ALL=C comm -12 "$WANTED_FILE" "$EXISTING_FILE" >"$PRESENT_FILE"

  local missing_n present_n matched_n
  missing_n="$(wc -l <"$MISSING_FILE" | tr -d ' ')"
  present_n="$(wc -l <"$PRESENT_FILE" | tr -d ' ')"
  matched_n="$(wc -l <"$EXISTING_FILE" | tr -d ' ')"
  log "  $present_n/$USER_COUNT pool member(s) already exist; $missing_n to create" \
      "($matched_n name(s) matched the prefix search)"

  local created=0 existed="$present_n" reset=0 done_n=0 username idx status
  while IFS= read -r username; do
    [[ -n "$username" ]] || continue
    idx="${username#"$USER_PREFIX"}"
    status="$(create_user "$username" "$idx")"
    if [[ "$status" == "created" ]]; then created=$((created + 1)); else existed=$((existed + 1)); fi
    done_n=$((done_n + 1))
    (( done_n % PROGRESS_EVERY == 0 )) && log "  …created $done_n/$missing_n"
  done <"$MISSING_FILE"

  if [[ "$FORCE_PASSWORD" == true ]]; then
    log "  rewriting profile + password on $present_n existing member(s)…"
    done_n=0
    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      idx="${username#"$USER_PREFIX"}"
      reset_existing_user "$username" "$idx"
      reset=$((reset + 1))
      done_n=$((done_n + 1))
      (( done_n % PROGRESS_EVERY == 0 )) && log "  …reset $done_n/$present_n"
    done <"$PRESENT_FILE"
  fi

  if [[ "$DO_VERIFY" == true ]]; then
    log "Verifying the pool can authenticate (client '$VERIFY_CLIENT')…"
    verify_sample
  fi

  log "Done. created=$created existed=$existed reset=$reset total=$USER_COUNT"
  log "      $(request_count) HTTP call(s) in $((SECONDS - start))s"
  [[ "$FORCE_PASSWORD" == false && "$existed" -gt 0 ]] && \
    log "      ($existed member(s) left untouched — pass --force-password after a password change)"
  return 0
}

main "$@"
