#!/usr/bin/env bash
# ops/apps/resume.sh — bring the business apps back after idle.sh by re-running
# helm upgrade per service. This restores replicas + recreates the HPAs, and reapplies
# the current chart defaults (metrics, prod profile, probes). Each service keeps the
# image tag it was last running (read off the live Deployment) so we never revert to 0.0.1.
#
# KEDA-aware: idle.sh pins KEDA-scaled workloads (payment, wiremock) to 0 with the
# `autoscaling.keda.sh/paused-replicas` annotation. This script removes that pin so KEDA
# recreates its HPA and takes back ownership of their replica count. Deployments owned by a
# KEDA ScaledObject are NOT manually scaled here (that would fight KEDA).
set -euo pipefail
NS="${NS:-atlas-apps}"
# Default to the self-contained chart in this repo (deploy/helm/atlas-service). Override
# CHART_DIR to point at the GitOps mirror if you deploy from there instead.
CHART_DIR="${CHART_DIR:-$(cd "$(dirname "$0")/../../helm/atlas-service" && pwd)}"

cd "$CHART_DIR"
for s in user flight hotel inventory travel-cart booking payment search; do
  TAG=$(kubectl -n "$NS" get deploy "${s}-service" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
  echo ">> ${s}-service (tag=${TAG:-<from values>})"
  helm upgrade --install "${s}-service" . -f "values/${s}.yaml" -n "$NS" \
    ${TAG:+--set image.tag="$TAG"}
done

# Non-helm deployments (wiremock) — idle.sh's `scale deploy --all --replicas=0` took it down
# too. Without it, payment-service's provider calls hang/timeout. Only nudge it to 1 if it is NOT
# KEDA-managed; if a ScaledObject owns it, KEDA restores the count once un-paused below.
for extra in wiremock; do
  if kubectl -n "$NS" get deploy "$extra" >/dev/null 2>&1; then
    if kubectl -n "$NS" get scaledobject "$extra" >/dev/null 2>&1; then
      echo ">> ${extra} is KEDA-managed — leaving its replica count to KEDA (un-paused below)."
    else
      echo ">> Restoring ${extra} -> 1 replica (non-helm dependency)"
      kubectl -n "$NS" scale deploy "$extra" --replicas=1
    fi
  fi
done

# KEDA: remove the paused pin idle.sh set, so KEDA recreates its HPA and takes back the
# replica count (payment, wiremock). The ScaledObjects themselves are applied during rollout
# (deploy/platform/keda), not here — this only lifts the pause on whatever exists.
if kubectl -n "$NS" get scaledobject >/dev/null 2>&1; then
  echo ">> Un-pausing KEDA ScaledObjects in ${NS}..."
  kubectl -n "$NS" annotate scaledobject --all autoscaling.keda.sh/paused-replicas- 2>/dev/null || true
fi

# CPU-HPA services (autoscaling.enabled) render WITHOUT spec.replicas — the HPA owns the count.
# idle.sh scaled them to 0, and an HPA will NOT lift a Deployment off 0 replicas (it can't
# read per-pod metrics with 0 pods), so the helm upgrade above leaves them stuck at 0. Nudge each
# CPU-HPA-managed Deployment up to its HPA minReplicas. Skip KEDA HPAs (keda-hpa-*) — KEDA already
# took those over via the un-pause above.
echo ">> Nudging CPU-HPA-managed deployments off 0 replicas..."
kubectl -n "$NS" get hpa \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.scaleTargetRef.name}{" "}{.spec.minReplicas}{"\n"}{end}' \
  | while read -r hpa dep min; do
      [[ -z "$dep" ]] && continue
      [[ "$hpa" == keda-hpa-* ]] && continue      # owned by KEDA
      min="${min:-1}"
      cur="$(kubectl -n "$NS" get deploy "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
      if [[ "${cur:-0}" -lt "$min" ]]; then
        echo "   scaling $dep -> ${min} (was ${cur:-0})"
        kubectl -n "$NS" scale deploy "$dep" --replicas="$min"
      fi
    done

echo ">> Resumed. Check: kubectl -n ${NS} get deploy,hpa,scaledobject"
