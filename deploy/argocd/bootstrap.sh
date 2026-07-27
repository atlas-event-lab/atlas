#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Atlas GitOps bootstrap — the ONE imperative piece of the deployment.
#
# Everything declarative (operators, CRs, the 8 services, observability, KEDA) is managed by
# Argo CD via the app-of-apps root. This script only does what can't live in git:
#   • the per-service DB secrets (random passwords, per-cluster)
#   • the WireMock mappings ConfigMap
#   • installs Argo CD + the custom health checks, then hands the stack to the root app
#   • the LB-IP-dependent pieces: the `atlas-issuer` Secret and the public nip.io hostnames
#
# It runs as ONE command: Phase A sets everything up, then Phase B blocks until Argo has
# provisioned the ingress LoadBalancer IP and the host-bearing objects, patches them, and prints
# a URL card. Idempotent — safe to re-run (apply/upgrade semantics throughout).
#
# Usage:
#   ./deploy/argocd/bootstrap.sh [--realm <path|url>] [--loadtest-users N]
#                                [--kafka-ui-user U] [--kafka-ui-pass P]
#
#   --realm           OVERRIDE only. Argo CD already applies the repo's complete atlas realm
#                     (deploy/platform/keycloak/realm-import.yaml, wave 5): the ADMIN role, the
#                     atlas-web + atlas-loadtest clients and the atlas-user + atlas-admin users.
#                     Pass this only to import your OWN exported realm instead.
#   --loadtest-users  Size of the k6 load-test user pool to seed (default: 200; 0 skips it).
#                     travel-cart keeps one active cart per user, so the experiments need one
#                     user per virtual user. See experiments/README.md.
#   --kafka-ui-user   Basic-auth user for the Kafka UI ingress (default: admin).
#   --kafka-ui-pass   Basic-auth password for the Kafka UI ingress (default: random, printed).
#
# Requires: kubectl (context on the target cluster), helm 3.x, openssl. htpasswd optional
# (falls back to openssl) for the Kafka UI basic-auth secret.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Pinned Argo CD chart version (argo/argo-cd). Bump deliberately.
ARGOCD_CHART_VERSION="7.8.23"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARGO_DIR="$REPO_ROOT/deploy/argocd"

REALM_SRC=""
LOADTEST_USERS="200"
KAFKA_UI_USER="admin"
KAFKA_UI_PASS=""

log()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --realm)          REALM_SRC="${2:?--realm needs a value}"; shift 2 ;;
    --loadtest-users) LOADTEST_USERS="${2:?--loadtest-users needs a value}"; shift 2 ;;
    --kafka-ui-user) KAFKA_UI_USER="${2:?}"; shift 2 ;;
    --kafka-ui-pass) KAFKA_UI_PASS="${2:?}"; shift 2 ;;
    -h|--help)       grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

# ── helpers ──────────────────────────────────────────────────────────────────
# Wait until an object exists (Argo creates it as the waves progress). Empty ns = cluster-scoped.
wait_for_object() {  # kind ns name [timeout_s]
  local kind="$1" ns="$2" name="$3" timeout="${4:-600}" waited=0
  local -a nsflag=(); [[ -n "$ns" ]] && nsflag=(-n "$ns")
  while ! kubectl "${nsflag[@]}" get "$kind" "$name" >/dev/null 2>&1; do
    (( waited >= timeout )) && return 1
    sleep 5; waited=$((waited + 5))
  done
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE A — pre-root: secrets, configmap, Argo CD, root app
# ═════════════════════════════════════════════════════════════════════════════
log "Phase A — bootstrap prerequisites + Argo CD"

# 1. Preflight.
command -v kubectl >/dev/null || die "kubectl not found"
command -v helm    >/dev/null || die "helm not found"
command -v openssl >/dev/null || die "openssl not found"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl can't reach a cluster — check your context"
if ! kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
      2>/dev/null | grep -q true; then
  warn "No StorageClass is marked (default). Postgres/Kafka PVCs may stay Pending — see TROUBLESHOOTING TS-PLATFORM-02."
fi
ok "Preflight passed ($(kubectl config current-context))"

# 2. Namespaces (so the secrets below have a home).
kubectl apply -f "$REPO_ROOT/deploy/platform/00-namespaces.yaml"
ok "Namespaces applied"

# 3. Per-service DB secrets (random passwords, replicated across namespaces). Reused as-is.
bash "$REPO_ROOT/deploy/platform/cloudnative-pg/create-db-secrets.sh"
ok "DB secrets created"

# 3b. Realm user passwords. The realm manifest deliberately creates its users WITHOUT
# credentials so nothing sensitive is committed; Phase B applies these to them. Same
# namespace as the Keycloak CR. Created here so all generated secrets live in one place.
if kubectl -n atlas-system get secret atlas-realm-credentials >/dev/null 2>&1; then
  ok "atlas-realm-credentials already exists — keeping current passwords"
else
  kubectl create secret generic atlas-realm-credentials -n atlas-system \
    --from-literal=user-password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)" \
    --from-literal=admin-password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)" \
    --from-literal=loadtest-password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
  ok "atlas-realm-credentials created (user / admin / loadtest passwords)"
fi

# 4. WireMock mappings ConfigMap (mounted by the wave-6 WireMock deployment).
kubectl create configmap wiremock-mappings -n atlas-apps \
  --from-file="$REPO_ROOT/wiremock/mappings/" --dry-run=client -o yaml | kubectl apply -f -
ok "wiremock-mappings ConfigMap applied"

# 5. Install Argo CD + custom health, then wait for the server.
log "Installing Argo CD (chart $ARGOCD_CHART_VERSION)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" -f "$ARGO_DIR/install/argocd-values.yaml" --wait
# Merge the CNPG/Strimzi/Keycloak custom health into the Helm-managed argocd-cm.
kubectl -n argocd patch configmap argocd-cm --type merge \
  --patch-file "$ARGO_DIR/install/argocd-cm-health.yaml"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
ok "Argo CD installed"

# 6. Project + root app → Argo drives waves 0..9.
kubectl apply -f "$ARGO_DIR/projects/atlas-project.yaml"
kubectl apply -f "$ARGO_DIR/root-app.yaml"
ok "AppProject + root app applied — Argo is now converging the stack"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE B — LB-IP-dependent: atlas-issuer, hostnames, realm import
# ═════════════════════════════════════════════════════════════════════════════
log "Phase B — waiting for the ingress LoadBalancer IP (Argo provisions it in wave 1)"

# 7. Poll the ingress-nginx Service for its external IP (or hostname).
LB=""
for _ in $(seq 1 120); do   # up to ~10 min
  LB="$(kubectl -n atlas-system get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -z "$LB" ]] && LB="$(kubectl -n atlas-system get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$LB" ]] && break
  sleep 5
done
[[ -n "$LB" ]] || die "LoadBalancer IP never appeared — check the ingress-nginx app in the Argo UI"
ok "LoadBalancer IP: $LB"

# 8. atlas-issuer Secret (public Keycloak issuer) — services (wave 7) need it to start.
kubectl create secret generic atlas-issuer -n atlas-apps \
  --from-literal=KEYCLOAK_ISSUER_URI="http://keycloak.$LB.nip.io/realms/atlas" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "atlas-issuer Secret applied"

# 9. kafka-ui-basic-auth Secret (the Kafka UI ingress gates on it; nginx 503s without it).
[[ -z "$KAFKA_UI_PASS" ]] && KAFKA_UI_PASS="$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)"
if command -v htpasswd >/dev/null 2>&1; then
  AUTH_LINE="$(htpasswd -nb "$KAFKA_UI_USER" "$KAFKA_UI_PASS")"
else
  AUTH_LINE="$KAFKA_UI_USER:$(openssl passwd -apr1 "$KAFKA_UI_PASS")"
fi
kubectl create secret generic kafka-ui-basic-auth -n atlas-data \
  --from-literal=auth="$AUTH_LINE" --dry-run=client -o yaml | kubectl apply -f -
ok "kafka-ui-basic-auth Secret applied (user: $KAFKA_UI_USER)"

# 10. Patch the live public hostnames (each covered by ignoreDifferences so self-heal keeps them).
log "Patching public nip.io hostnames with $LB (waiting for each object as Argo creates it)"
if wait_for_object ingress argocd argocd-server 300; then
  kubectl -n argocd patch ingress argocd-server --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"argocd.$LB.nip.io\"}]"
  ok "Argo CD UI host set"
else warn "argocd-server ingress not found — patch manually: host argocd.$LB.nip.io"; fi

if wait_for_object keycloak atlas-system keycloak 600; then
  kubectl -n atlas-system patch keycloak keycloak --type merge \
    -p "{\"spec\":{\"hostname\":{\"hostname\":\"http://keycloak.$LB.nip.io\"}}}"
  kubectl -n atlas-system patch ingress keycloak --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"keycloak.$LB.nip.io\"}]" 2>/dev/null || true
  ok "Keycloak host set"
else warn "keycloak CR not found yet — patch manually once wave 5 syncs: hostname http://keycloak.$LB.nip.io"; fi

if wait_for_object ingress atlas-data kafka-ui 600; then
  kubectl -n atlas-data patch ingress kafka-ui --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"kafka.$LB.nip.io\"}]"
  ok "Kafka UI host set"
else warn "kafka-ui ingress not found yet — patch manually once wave 8 syncs: host kafka.$LB.nip.io"; fi

# 11. Keycloak realm. Argo applies the repo's realm in wave 5 — we only wait for it here.
# --realm overrides it with your own exported realm (applied on top; the operator will not
# replace an existing realm, so use it on a fresh cluster).
if [[ -n "$REALM_SRC" ]]; then
  log "Applying your realm override from $REALM_SRC"
  if wait_for_object crd "" keycloakrealmimports.k8s.keycloak.org 600 2>/dev/null \
     || kubectl get crd keycloakrealmimports.k8s.keycloak.org >/dev/null 2>&1; then
    kubectl apply -n atlas-system -f "$REALM_SRC" && ok "Realm override applied"
  else
    warn "KeycloakRealmImport CRD not ready — apply yours later: kubectl apply -n atlas-system -f $REALM_SRC"
  fi
fi

log "Waiting for the atlas realm import to finish (Argo applies it in wave 5)"
REALM_READY=false
if wait_for_object keycloakrealmimport atlas-system atlas-realm 900; then
  if kubectl -n atlas-system wait --for=condition=Done \
       keycloakrealmimport/atlas-realm --timeout=600s >/dev/null 2>&1; then
    REALM_READY=true; ok "Realm 'atlas' imported"
  else
    warn "Realm import did not report Done in time — check: kubectl -n atlas-system describe keycloakrealmimport atlas-realm"
  fi
else
  warn "KeycloakRealmImport 'atlas-realm' never appeared — is the keycloak app synced in the Argo UI?"
fi

# 12. Realm user passwords. The imported users have no credentials by design; this applies the
# ones generated in Phase A. Idempotent — re-running just resets them to the Secret's values.
if [[ "$REALM_READY" == true ]]; then
  log "Setting realm user passwords"
  if LB="$LB" bash "$REPO_ROOT/deploy/platform/keycloak/set-realm-passwords.sh"; then
    ok "atlas-user and atlas-admin can now log in"
  else
    warn "set-realm-passwords.sh failed — re-run it manually: LB=$LB ./deploy/platform/keycloak/set-realm-passwords.sh"
    REALM_READY=false
  fi
fi

# 13. Load-test user pool. travel-cart keeps ONE active cart per user, so k6 needs one user per
# VU — sharing an identity makes every VU collide on the same cart. Keycloak-only, so this does
# not wait on the services.
if [[ "$REALM_READY" == true && "$LOADTEST_USERS" != "0" ]]; then
  log "Seeding $LOADTEST_USERS load-test users (--loadtest-users 0 to skip)"
  ADMIN_USER="$(kubectl -n atlas-system get secret keycloak-initial-admin \
                  -o jsonpath='{.data.username}' | base64 -d)"
  ADMIN_PASS="$(kubectl -n atlas-system get secret keycloak-initial-admin \
                  -o jsonpath='{.data.password}' | base64 -d)"
  LOADTEST_PASS="$(kubectl -n atlas-system get secret atlas-realm-credentials \
                  -o jsonpath='{.data.loadtest-password}' | base64 -d)"
  if KEYCLOAK_URL="http://keycloak.$LB.nip.io" \
     KEYCLOAK_ADMIN_USER="$ADMIN_USER" KEYCLOAK_ADMIN_PASSWORD="$ADMIN_PASS" \
     LOADTEST_USER_PASSWORD="$LOADTEST_PASS" LOADTEST_USER_COUNT="$LOADTEST_USERS" \
     bash "$REPO_ROOT/experiments/scripts/seed-loadtest-users.sh"; then
    ok "Load-test pool ready ($LOADTEST_USERS users)"
  else
    warn "seed-loadtest-users.sh failed — see experiments/README.md § 'Auth for load tests'"
  fi
fi

# 14. URL card.
ARGO_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret \
           -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<already-rotated>')"
KC_ADMIN_USER="$(kubectl -n atlas-system get secret keycloak-initial-admin \
                 -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo '<n/a>')"
KC_ADMIN_PW="$(kubectl -n atlas-system get secret keycloak-initial-admin \
               -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<n/a>')"
cat <<EOF

┌─────────────────────────────────────────────────────────────────────────────
│  Atlas is converging. Watch it in the Argo CD UI (tiles go yellow → green).
├─────────────────────────────────────────────────────────────────────────────
│  Argo CD    http://argocd.$LB.nip.io        admin / $ARGO_PW
│  Grafana    (port-forward svc/kps-grafana)  admin / atlas-admin
│  Kafka UI   http://kafka.$LB.nip.io          $KAFKA_UI_USER / $KAFKA_UI_PASS
│  Keycloak   http://keycloak.$LB.nip.io       $KC_ADMIN_USER / $KC_ADMIN_PW
│  API        http://$LB/api/v1/flights
├─────────────────────────────────────────────────────────────────────────────
│  Realm users (passwords in secret/atlas-realm-credentials, ns atlas-system):
│    atlas-user   — the booking flow          key: user-password
│    atlas-admin  — ADMIN role                key: admin-password
│    loadtest-N   — k6 pool ($LOADTEST_USERS)  key: loadtest-password
│    kubectl -n atlas-system get secret atlas-realm-credentials \\
│      -o jsonpath='{.data.user-password}' | base64 -d
├─────────────────────────────────────────────────────────────────────────────
│  NEXT — while Argo converges, open Grafana / Kafka UI / a DB session first:
│    kubectl -n atlas-observability port-forward svc/kps-grafana 3000:80
│    kubectl -n atlas-data port-forward svc/atlas-pg-rw 5432:5432
│  Then publish the catalog (search returns [] until you do) and watch it flow:
│    deploy/argocd/README.md  §  "Open everything" -> "Publish the catalog"
│  Keycloak's $KC_ADMIN_USER is a BOOTSTRAP account: create your own admin and
│  delete it (DEPLOYMENT-RUNBOOK.md § 5a).
├─────────────────────────────────────────────────────────────────────────────
│  Fallback (no ingress host): kubectl -n argocd port-forward svc/argocd-server 8080:443
└─────────────────────────────────────────────────────────────────────────────
EOF
ok "Bootstrap complete."
