#!/usr/bin/env bash
# ops/oracle/cluster-down.sh — Oracle OKE only. Scale the node pool to 0 to STOP paying
# for worker compute.
#
# This is the real credit-saver: OCI bills worker nodes while they are RUNNING,
# regardless of how many pods sit on them. Scaling replicas frees memory but saves
# nothing; terminating the workers does.
#
# What survives: all data on PVCs (OCI Block Volumes) — Postgres (CNPG), Kafka (Strimzi),
# Keycloak — reattaches on the next cluster-up. The LoadBalancer and block storage keep
# billing a small amount; do NOT delete the LB (its IP is pinned in the Keycloak issuer).
set -euo pipefail

# Config: NODEPOOL_OCID must be YOUR node pool. Provide it via the environment or a
# gitignored config.env next to this script (see config.env.example). No value is
# hardcoded on purpose — these scripts are reproducible on any tenancy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"
NODEPOOL_OCID="${NODEPOOL_OCID:-}"
[ -n "$NODEPOOL_OCID" ] || { echo "ERROR: NODEPOOL_OCID is not set. Export it or set it in $SCRIPT_DIR/config.env (see config.env.example)." >&2; exit 1; }

echo ">> Scaling node pool to 0 (workers terminate in ~1-2 min)..."
oci ce node-pool update --node-pool-id "$NODEPOOL_OCID" --size 0 --force

echo ">> Done. Compute billing stops once instances terminate."
echo "   PVC data is retained. Bring it back with: ./cluster-up.sh"
