#!/usr/bin/env bash
# cluster-up.sh [SIZE] — scale the OKE node pool back up (default 3) and wait for Ready.
#
# Cold start is ~10-15 min end to end: provision nodes -> pull images -> operators
# recover stateful workloads from PVCs (CNPG/Kafka/Keycloak) -> apps start.
set -euo pipefail

NODEPOOL_OCID="${NODEPOOL_OCID:-ocid1.nodepool.oc1.iad.aaaaaaaab5ki4j7n7vwogptofq3po343re2h7ftilv3d3eir7nka6nhv6iwa}"
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
