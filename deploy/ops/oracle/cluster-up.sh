#!/usr/bin/env bash
# ops/oracle/cluster-up.sh [SIZE] — Oracle OKE only. Scale the node pool back up
# (default 3) and wait for Ready.
#
# Cold start is ~10-15 min end to end: provision nodes -> pull images -> operators
# recover stateful workloads from PVCs (CNPG/Kafka/Keycloak) -> apps start.
set -euo pipefail

# Config: NODEPOOL_OCID must be YOUR node pool. Provide it via the environment or a
# gitignored config.env next to this script (see config.env.example). No value is
# hardcoded on purpose — these scripts are reproducible on any tenancy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"
NODEPOOL_OCID="${NODEPOOL_OCID:-}"
[ -n "$NODEPOOL_OCID" ] || { echo "ERROR: NODEPOOL_OCID is not set. Export it or set it in $SCRIPT_DIR/config.env (see config.env.example)." >&2; exit 1; }
SIZE="${1:-3}"

echo ">> Scaling node pool to ${SIZE}..."
oci ce node-pool update --node-pool-id "$NODEPOOL_OCID" --size "$SIZE" --force

echo ">> Waiting for ${SIZE} node(s) to become Ready (~5-10 min)..."
for i in $(seq 1 80); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  echo "   Ready nodes: ${ready}/${SIZE}"
  [ "${ready:-0}" -ge "$SIZE" ] && break
  sleep 15
done

echo ">> Nodes:"
kubectl get nodes
echo ""
echo ">> Platform recovers from PVCs. Watch anything not yet healthy with:"
echo "   kubectl get pods -A | grep -vE 'Running|Completed'"
echo "   (CNPG/Kafka/Keycloak may take a couple of minutes to recover their volumes.)"
