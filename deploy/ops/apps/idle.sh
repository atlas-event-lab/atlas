#!/usr/bin/env bash
# ops/apps/idle.sh — scale the business apps to 0 while KEEPING the cluster (and platform:
# DB/Kafka/Keycloak/observability) running. Frees ~app memory so you can, e.g., run
# Grafana/Kafka-UI or install Tempo without eviction.
#
# NOTE: this does NOT save credits — nodes stay powered on. For credit savings terminate
# workers instead (Oracle: ../oracle/cluster-down.sh · Civo: ../civo/cluster.sh down).
# Resume apps with ./resume.sh. This script is cloud-agnostic (pure kubectl).
#
# KEDA-aware: services scaled by a KEDA ScaledObject (e.g. payment, wiremock) must be pinned to
# 0 via the `autoscaling.keda.sh/paused-replicas=0` annotation FIRST — otherwise KEDA recreates
# its HPA and scales them straight back up after `scale ... --replicas=0`. resume.sh removes
# the pin.
set -euo pipefail
NS="${NS:-atlas-apps}"

if kubectl -n "$NS" get scaledobject >/dev/null 2>&1; then
  echo ">> Pausing KEDA ScaledObjects in ${NS} (pin to 0 so KEDA doesn't re-scale them up)..."
  kubectl -n "$NS" annotate scaledobject --all autoscaling.keda.sh/paused-replicas=0 --overwrite
fi

echo ">> Deleting HPAs in ${NS} (otherwise they re-scale deployments back up)..."
kubectl -n "$NS" delete hpa --all --ignore-not-found

echo ">> Scaling all ${NS} deployments to 0..."
kubectl -n "$NS" scale deploy --all --replicas=0

echo ">> Idle. Deployments remain defined (image tags preserved). Resume: ./resume.sh"
