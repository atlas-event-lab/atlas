#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# Manual bootstrap of the per-service DB secrets (README Step 2b).
#
# Creates one basic-auth Secret per service with FOUR keys (username/password for
# CloudNativePG's managed role, DB_USERNAME/DB_PASSWORD for the app's envFrom). Each
# secret is created in EVERY namespace that consumes it, with the SAME password, so
# both sides match:
#   <svc>-secret      -> atlas-data (CNPG role) + atlas-apps (the service)
#   keycloak-db-secret -> atlas-data (CNPG role) + atlas-system (Keycloak)
#
# These are PLAINTEXT secrets created directly in the cluster — fine for a manual
# bootstrap (nothing is committed). For the GitOps flow, seal them instead (see
# README "Secrets"): pipe each `kubectl create ... --dry-run=client -o yaml` into
# `kubeseal` and commit the SealedSecret. That path needs the sealed-secrets
# controller in-cluster + the `kubeseal` CLI locally.
#
# Re-runnable (apply semantics). Requires: kubectl, openssl.
# Usage:  ./create-db-secrets.sh
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

# service-secret-name : role/username : namespaces (space-separated)
make_secret() {
  local secret="$1" user="$2"; shift 2
  local namespaces=("$@")
  local pw; pw="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
  for ns in "${namespaces[@]}"; do
    kubectl create secret generic "$secret" -n "$ns" \
      --type=kubernetes.io/basic-auth \
      --from-literal=username="$user" \
      --from-literal=password="$pw" \
      --from-literal=DB_USERNAME="$user" \
      --from-literal=DB_PASSWORD="$pw" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  echo "  ✔ $secret  (user=$user)  -> ${namespaces[*]}"
}

echo "Creating per-service DB secrets..."
make_secret user-secret        user_user        atlas-data atlas-apps
make_secret flight-secret      flight_user      atlas-data atlas-apps
make_secret hotel-secret       hotel_user       atlas-data atlas-apps
make_secret inventory-secret   inventory_user   atlas-data atlas-apps
make_secret travel-cart-secret travel_cart_user atlas-data atlas-apps
make_secret booking-secret     booking_user     atlas-data atlas-apps
make_secret payment-secret     payment_user     atlas-data atlas-apps
make_secret search-secret      search_user      atlas-data atlas-apps
make_secret keycloak-db-secret keycloak_user    atlas-data atlas-system
echo "Done. Verify:  kubectl get secret -n atlas-data"
