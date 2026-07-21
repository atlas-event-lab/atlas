#!/usr/bin/env bash
# cluster-down.sh — scale the OKE node pool to 0 to STOP paying for worker compute.
#
# This is the real credit-saver: OCI bills worker nodes while they are RUNNING,
# regardless of how many pods sit on them. Scaling replicas frees memory but saves
# nothing; terminating the workers does.
#
# What survives: all data on PVCs (OCI Block Volumes) — Postgres (CNPG), Kafka (Strimzi),
# Keycloak — reattaches on the next cluster-up. The LoadBalancer and block storage keep
# billing a small amount; do NOT delete the LB (its IP is pinned in the Keycloak issuer).
set -euo pipefail

# OCIDs for this cluster (override via env if they change).
NODEPOOL_OCID="${NODEPOOL_OCID:-ocid1.nodepool.oc1.iad.aaaaaaaab5ki4j7n7vwogptofq3po343re2h7ftilv3d3eir7nka6nhv6iwa}"

echo ">> Scaling node pool to 0 (workers terminate in ~1-2 min)..."
oci ce node-pool update --node-pool-id "$NODEPOOL_OCID" --size 0 --force

echo ">> Done. Compute billing stops once instances terminate."
echo "   PVC data is retained. Bring it back with: ./cluster-up.sh"
