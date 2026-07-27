#!/usr/bin/env bash
#
# Set the passwords for the realm users created by realm-import.yaml.
#
# WHY THIS EXISTS: realm-import.yaml deliberately creates `atlas-user` and `atlas-admin`
# WITHOUT credentials, so no password is ever committed. Keycloak's own placeholder
# mechanism (`spec.placeholders` + `${env.VAR}`) would have avoided this extra step, but
# Keycloak 26.0.5 does not perform the replacement during --import-realm: it stores the
# literal `${env.VAR}` string as the password. Verified on a clean import.
# See keycloak/keycloak#33598. Revisit if you bump Keycloak.
#
# Idempotent: safe to re-run. Re-running simply resets both passwords to whatever the
# atlas-realm-credentials Secret currently holds.
#
# Usage:
#   export LB=<ingress EXTERNAL-IP>           # or KEYCLOAK_URL, below
#   ./set-realm-passwords.sh
#
# Config (all env-overridable):
#   LB                      ingress LoadBalancer IP        (required unless KEYCLOAK_URL is set)
#   KEYCLOAK_URL            Keycloak base URL              (default http://keycloak.$LB.nip.io)
#   KEYCLOAK_REALM          realm holding the users        (default atlas)
#   KEYCLOAK_ADMIN_REALM    realm to authenticate admin in (default master)
#   KEYCLOAK_ADMIN_CLIENT   admin token client_id          (default admin-cli)
#   KEYCLOAK_ADMIN_USER     admin username                 (default: temp-admin, or whatever
#                                                           keycloak-initial-admin holds)
#   KEYCLOAK_ADMIN_PASSWORD admin password                 (default: read from the
#                                                           keycloak-initial-admin Secret)
#   CREDENTIALS_SECRET      Secret with the user passwords (default atlas-realm-credentials)
#   NS_SYSTEM               Keycloak namespace             (default atlas-system)
#
# NOTE: Runbook Step 5a tells you to delete `temp-admin` once you have a permanent admin.
# After that, pass KEYCLOAK_ADMIN_USER / KEYCLOAK_ADMIN_PASSWORD explicitly.
set -euo pipefail

NS_SYSTEM="${NS_SYSTEM:-atlas-system}"
REALM="${KEYCLOAK_REALM:-atlas}"
ADMIN_REALM="${KEYCLOAK_ADMIN_REALM:-master}"
ADMIN_CLIENT="${KEYCLOAK_ADMIN_CLIENT:-admin-cli}"
CREDENTIALS_SECRET="${CREDENTIALS_SECRET:-atlas-realm-credentials}"

if [[ -z "${KEYCLOAK_URL:-}" ]]; then
  : "${LB:?Set LB to the ingress EXTERNAL-IP, or set KEYCLOAK_URL directly}"
  KEYCLOAK_URL="http://keycloak.${LB}.nip.io"
fi

# ── Admin credentials ────────────────────────────────────────────────────────
# Default to the operator-generated bootstrap admin. Overridable once it is deleted.
if [[ -z "${KEYCLOAK_ADMIN_USER:-}" || -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
  echo ">> Reading bootstrap admin from secret/keycloak-initial-admin in ${NS_SYSTEM}..."
  KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-$(kubectl -n "$NS_SYSTEM" get secret keycloak-initial-admin \
    -o jsonpath='{.data.username}' | base64 -d)}"
  KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-$(kubectl -n "$NS_SYSTEM" get secret keycloak-initial-admin \
    -o jsonpath='{.data.password}' | base64 -d)}"
fi

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Never pipe curl straight into jq: a non-JSON body (an nginx 404/503 HTML page is the
# common one) surfaces as an opaque `jq: parse error` instead of the real problem. Capture
# the status and the body, judge the status first.
http_post() {  # http_post URL [curl args...] -> sets HTTP_CODE and HTTP_BODY
  local url="$1"; shift
  local raw
  raw=$(curl -sS -w $'\n%{http_code}' "$url" "$@") \
    || die "could not reach ${url} — is the Keycloak Ingress up? (Runbook Step 5)"
  HTTP_CODE="${raw##*$'\n'}"
  HTTP_BODY="${raw%$'\n'*}"
}

echo ">> Authenticating as '${KEYCLOAK_ADMIN_USER}' against ${KEYCLOAK_URL}/realms/${ADMIN_REALM}"
http_post "${KEYCLOAK_URL}/realms/${ADMIN_REALM}/protocol/openid-connect/token" \
  -d grant_type=password -d "client_id=${ADMIN_CLIENT}" \
  --data-urlencode "username=${KEYCLOAK_ADMIN_USER}" \
  --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}"

case "$HTTP_CODE" in
  200) ;;
  401) die "admin login rejected. If you deleted temp-admin (Runbook 5a), export KEYCLOAK_ADMIN_USER and KEYCLOAK_ADMIN_PASSWORD for your permanent admin." ;;
  404) die "HTTP 404 from ${KEYCLOAK_URL} — the Keycloak Ingress is not routing (TS-PLATFORM-04)." ;;
  503) die "HTTP 503 from ${KEYCLOAK_URL} — Keycloak has no ready pod yet. Check: kubectl -n ${NS_SYSTEM} get pod keycloak-0" ;;
  *)   die "token request returned HTTP ${HTTP_CODE}: $(printf '%.200s' "$HTTP_BODY")" ;;
esac

TOKEN=$(jq -r '.access_token // empty' <<<"$HTTP_BODY")
[[ -n "$TOKEN" ]] || die "no access_token in the response: $(printf '%.200s' "$HTTP_BODY")"

# ── Set each user's password from the Secret ─────────────────────────────────
set_password() {
  local username="$1" secret_key="$2" password user_id status

  password=$(kubectl -n "$NS_SYSTEM" get secret "$CREDENTIALS_SECRET" \
    -o jsonpath="{.data.${secret_key}}" | base64 -d)
  if [[ -z "$password" ]]; then
    echo "!! Secret ${CREDENTIALS_SECRET} has no key '${secret_key}'" >&2
    return 1
  fi

  user_id=$(curl -sf -G "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
    --data-urlencode "username=${username}" -d exact=true \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id // empty')
  if [[ -z "$user_id" ]]; then
    echo "!! User '${username}' not found in realm '${REALM}' — did the realm import run?" >&2
    return 1
  fi

  status=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/reset-password" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg v "$password" '{type:"password", value:$v, temporary:false}')")

  if [[ "$status" == "204" ]]; then
    echo ">> ${username}: password set"
  else
    echo "!! ${username}: reset-password returned HTTP ${status}" >&2
    return 1
  fi
}

set_password atlas-user  user-password
set_password atlas-admin admin-password

echo ">> Done. Verify:"
echo "   curl -s ${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token \\"
echo "     -d grant_type=password -d client_id=atlas-web \\"
echo "     -d username=atlas-user -d password=\"\$(kubectl -n ${NS_SYSTEM} get secret ${CREDENTIALS_SECRET} \\"
echo "       -o jsonpath='{.data.user-password}' | base64 -d)\" | jq -r .access_token"
