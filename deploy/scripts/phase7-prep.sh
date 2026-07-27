#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Phase 7 prep — make the cluster ready for the scalability / resilience experiments.
#
# Idempotent. Re-runnable. Reads live state and only nudges what's needed.
# Covers the two in-cluster prep tasks:
#   1) Restore HPA on inventory-service and search-service (pinned to replica=1 during
#      the Postgres incident) — WITHOUT changing the running image tag.
#   2) Apply the PgBouncer Pooler (deploy/platform/cloudnative-pg/pooler.yaml) + verify.
#
# The 3rd prep task — raising max-pods-per-node to ~30 — is an OCI node-pool change that
# recycles nodes and needs your OCIDs; it is NOT run here. See README-phase7-prep.md §3.
#
# Usage:
#   ./deploy/scripts/phase7-prep.sh            # do it
#   DRY_RUN=1 ./deploy/scripts/phase7-prep.sh  # print actions, change nothing
#
# Prereqs: kubectl + helm context pointing at the Atlas cluster; run from repo root.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APPS_NS="atlas-apps"
DATA_NS="atlas-data"
CHART="deploy/helm/atlas-service"          # same chart CI deploys from
POOLER_MANIFEST="deploy/platform/cloudnative-pg/pooler.yaml"
SERVICES=("inventory-service" "search-service")
DRY_RUN="${DRY_RUN:-0}"

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '   [dry-run] %s\n' "$*"; else eval "$*"; fi; }

# ── 1. Restore HPA on the stateless services ────────────────────────────────
# The gitops values already carry autoscaling.enabled=true. A helm upgrade re-renders the
# HPA and, because the Deployment template omits `replicas` when autoscaling is on, hands
# replica control back to the HPA. We reuse the CURRENT live image tag so nothing else moves.
say "1. Restore HPA on stateless services"
for SVC in "${SERVICES[@]}"; do
  VALUES_KEY="${SVC%-service}"                      # inventory-service -> inventory
  VALUES_FILE="${CHART}/values/${VALUES_KEY}.yaml"

  if ! kubectl -n "$APPS_NS" get deploy "$SVC" >/dev/null 2>&1; then
    info "$SVC: deployment not found in $APPS_NS — skipping (deploy it first)."
    continue
  fi

  CUR_IMAGE="$(kubectl -n "$APPS_NS" get deploy "$SVC" \
                 -o jsonpath='{.spec.template.spec.containers[0].image}')"
  CUR_TAG="${CUR_IMAGE##*:}"
  HPA_EXISTS="$(kubectl -n "$APPS_NS" get hpa "$SVC" --ignore-not-found -o name || true)"
  info "$SVC: image=$CUR_IMAGE  hpa=${HPA_EXISTS:-<none>}"

  run "helm upgrade --install '$SVC' '$CHART' \
        -f '$VALUES_FILE' -n '$APPS_NS' \
        --set image.tag='$CUR_TAG' \
        --wait --timeout 5m"
done

# ── 2. Apply the PgBouncer Pooler ───────────────────────────────────────────
say "2. Apply PgBouncer Pooler"
run "kubectl apply -f '$POOLER_MANIFEST'"

# ── Verification ────────────────────────────────────────────────────────────
say "Verify — HPA"
# A healthy HPA shows real TARGETS (e.g. 12%/70%), not <unknown> (which means metrics-server
# isn't feeding it). REPLICAS should sit at/above minReplicas.
run "kubectl -n '$APPS_NS' get hpa ${SERVICES[*]}"

say "Verify — Pooler"
# status.phase should reach 'active'; 2 pgbouncer pods Running; the rw pooler Service exists.
run "kubectl -n '$DATA_NS' get pooler atlas-pg-pooler-rw -o wide || true"
run "kubectl -n '$DATA_NS' get pods -l cnpg.io/poolerName=atlas-pg-pooler-rw"
run "kubectl -n '$DATA_NS' get svc atlas-pg-pooler-rw"
run "kubectl -n '$DATA_NS' get podmonitor atlas-pg-pooler-rw"

cat <<'EOF'

Next (not automated — see README-phase7-prep.md):
  • Cut a service over to the pooler by repointing DB_URL to
    atlas-pg-pooler-rw.atlas-data:5432/<db>?prepareThreshold=0  (start with search).
  • Raise max-pods-per-node to ~30 via the OCI node pool (recycles nodes).
Done.
EOF
