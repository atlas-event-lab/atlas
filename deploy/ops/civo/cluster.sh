#!/usr/bin/env bash
#
# ops/civo/cluster.sh — Civo lifecycle (cost control).
#
# Civo has NO "stop"/"deallocate" like OKE (node pool -> 0): a
# running worker node bills whether or not it holds pods, and a cluster needs >= 1 node.
# So the real "off" switch is tearing the cluster down with Terraform — that stops ALL
# billing, and Civo recreates it in ~2 min. This fits the experiments workflow, which
# seeds/resets state on each run anyway.
#
#   ./cluster.sh up      # terraform apply   -> cluster live (12 vCPU / 48 GB)
#   ./cluster.sh down    # release PVCs, then terraform destroy -> $0
#   ./cluster.sh status  # show the cluster (civo CLI) or the Terraform state
#
# ⚠️  DATA: `down` destroys the cluster, so dynamically-provisioned PVCs (Postgres/Kafka)
#     are deleted with it unless their PVs use reclaimPolicy: Retain. Treat the cluster as
#     ephemeral and re-seed on `up`, or set Retain if you must keep data across sessions.
#
# ORDER MATTERS on `down`: the PVCs are deleted first so Civo frees their block volumes,
# and only then does Terraform run. Destroying the other way round leaves orphaned volumes
# attached to the network and Terraform fails with `DatabaseNetworkInUseByVolumes`.
#
# Requires: terraform, a CIVO_TOKEN in the environment (export CIVO_TOKEN=...), kubectl on
# PATH pointing at the cluster (for the PVC cleanup on `down`), and optionally the civo CLI
# for `status`.
#
# Env: TF_DIR, CLUSTER_NAME, VOLUME_WAIT (180 — seconds to wait for volumes to be released).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"

TF_DIR="${TF_DIR:-$SCRIPT_DIR/../../cluster/civo/terraform}"
CLUSTER_NAME="${CLUSTER_NAME:-atlas-civo}"
# Seconds to wait for the CSI driver to actually delete the block volumes on `down`.
VOLUME_WAIT="${VOLUME_WAIT:-180}"

log() { printf '>> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

preflight() {
  command -v terraform >/dev/null 2>&1 || die "terraform not found. Install: https://developer.hashicorp.com/terraform/install"
  [ -n "${CIVO_TOKEN:-}" ] || die "CIVO_TOKEN is not set. Run: export CIVO_TOKEN=your-civo-api-key"
  [ -d "$TF_DIR" ] || die "Terraform dir not found: $TF_DIR (override with TF_DIR in config.env)"
}

cmd_up() {
  log "Creating the Civo cluster via Terraform ($TF_DIR)..."
  terraform -chdir="$TF_DIR" init -input=false
  terraform -chdir="$TF_DIR" apply
  log "Save kubeconfig: terraform -chdir=$TF_DIR output -raw kubeconfig > ~/.kube/civo-atlas.yaml"
}

# Release the CSI-provisioned block volumes BEFORE Terraform touches the network.
#
# Civo's CSI driver creates a block volume per PVC (Postgres, the Kafka brokers, Prometheus,
# Loki, Tempo…). Terraform did not create them, so it does not know they exist — but they stay
# attached to the cluster's network, and `terraform destroy` then fails on the last step:
#
#   Error: error waiting for network (...) to be deleted: DatabaseNetworkInUseByVolumes:
#   Failed to delete the network because it's in use by volumes ... Please delete the volumes
#   first in order to delete the network.
#
# By then the cluster is usually already gone, so the PVCs are unreachable via kubectl and the
# volumes have to be cleaned up by hand through the Civo API. Deleting the PVCs first lets the
# CSI driver release each volume properly, which is both cleaner and recoverable.
release_volumes() {
  if ! command -v kubectl >/dev/null 2>&1; then
    log "kubectl not found — skipping PVC cleanup."
    log "If destroy fails on the network, delete the leftover volumes: civo volume ls / civo volume delete <id>"
    return 0
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log "No reachable cluster for the current kubeconfig — skipping PVC cleanup."
    log "If the cluster is already gone and destroy fails on the network, the volumes are orphaned:"
    log "  civo volume ls    # then: civo volume delete <id> for each pvc-* on this cluster's network"
    return 0
  fi

  local pvcs
  pvcs="$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${pvcs:-0}" -eq 0 ]; then
    log "No PVCs to release."
    return 0
  fi

  log "Releasing ${pvcs} PVC(s) so Civo can free their block volumes..."
  kubectl delete pvc --all -A --wait=false >/dev/null 2>&1 || true

  # Wait on the PVs, not the PVCs: the PV is what maps to the Civo volume, and it only
  # disappears once the driver has actually deleted it. A PVC can vanish while its volume lives.
  log "Waiting for the underlying PersistentVolumes to be released (up to ${VOLUME_WAIT}s)..."
  local waited=0 remaining
  while [ "$waited" -lt "$VOLUME_WAIT" ]; do
    remaining="$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [ "${remaining:-0}" -eq 0 ] && { log "All volumes released."; return 0; }
    sleep 5
    waited=$((waited + 5))
  done

  log "WARNING: ${remaining} PersistentVolume(s) still present after ${VOLUME_WAIT}s."
  log "Terraform may fail to delete the network. If it does, clean up with: civo volume ls"
  log "A PV stuck here usually has reclaimPolicy: Retain (deliberately kept) or a finalizer."
}

cmd_down() {
  log "This will DESTROY cluster '$CLUSTER_NAME' and stop all billing."
  log "PVC data is lost unless volumes use reclaimPolicy: Retain."
  release_volumes            # MUST run first — see the note above
  terraform -chdir="$TF_DIR" destroy
}

cmd_status() {
  if command -v civo >/dev/null 2>&1; then
    civo kubernetes show "$CLUSTER_NAME" 2>/dev/null || echo "Cluster '$CLUSTER_NAME' not found on Civo."
  else
    log "civo CLI not installed; showing Terraform state instead."
    terraform -chdir="$TF_DIR" state list 2>/dev/null || echo "No Terraform state (cluster not created?)."
  fi
}

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  up|down|status) preflight ;;
  *)              usage ;;
esac
case "$1" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
esac
