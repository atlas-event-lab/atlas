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
#   ./cluster.sh reset   # recover a dirty/half-applied state, back to a clean slate
#   ./cluster.sh sweep   # list block volumes left by PREVIOUS clusters (--yes to delete)
#   ./cluster.sh status  # show the cluster (civo CLI) or the Terraform state
#
# ⚠️  DATA: `down` destroys the cluster, so dynamically-provisioned PVCs (Postgres/Kafka)
#     are deleted with it unless their PVs use reclaimPolicy: Retain. Treat the cluster as
#     ephemeral and re-seed on `up`, or set Retain if you must keep data across sessions.
#
# COST HYGIENE on `down`: the PVCs are deleted first so Civo's CSI driver frees their block
# volumes, and only then does Terraform run. Terraform no longer manages the network (the
# cluster runs on Civo's default network), so `destroy` cannot fail on it — leftover volumes
# are only wasted spend, not a teardown blocker. `down` sweeps any that linger; `reset`
# sweeps them too and additionally clears a corrupted local state (see cmd_reset).
#
# ⚠️  ALWAYS tear down with `./cluster.sh down`, NEVER a bare `terraform destroy`. Terraform did
#     not create the CSI block volumes, so it cannot delete them: a bare destroy leaves one
#     orphan per PVC, each still billing AND still consuming the account's disk-GB and
#     disk-volume-count quota. Enough of them and the NEXT cluster cannot provision at all —
#     PVCs sit Pending with "would exceed volume space quota" (TS-CIVO-03). `./cluster.sh sweep`
#     finds orphans an earlier teardown already left behind.
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

log()  { printf '>> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

preflight() {
  command -v terraform >/dev/null 2>&1 || die "terraform not found. Install: https://developer.hashicorp.com/terraform/install"
  [ -n "${CIVO_TOKEN:-}" ] || die "CIVO_TOKEN is not set. Run: export CIVO_TOKEN=your-civo-api-key"
  [ -d "$TF_DIR" ] || die "Terraform dir not found: $TF_DIR (override with TF_DIR in config.env)"
}

# The Civo region, lowercase (the CLI rejects uppercase — TS-CIVO-01): from terraform.tfvars,
# else whatever the CLI has as current. Echoes an empty string if neither is available.
civo_region() {
  local region
  region="$(grep -E '^[[:space:]]*region' "$TF_DIR/terraform.tfvars" 2>/dev/null \
            | sed -E 's/.*=[[:space:]]*"?([A-Za-z0-9]+)"?.*/\1/' | tr '[:upper:]' '[:lower:]' || true)"
  [ -z "$region" ] && region="$(civo region current 2>/dev/null || true)"
  printf '%s' "$region"
}

# This cluster's Civo id (a UUID). MUST be called while the cluster STILL EXISTS — `civo
# kubernetes show` is the only way to get it, and it fails once the cluster is gone. Callers
# therefore resolve it BEFORE tearing anything down and hand it to sweep_orphaned_volumes.
civo_cluster_id() {
  local region="$1"
  command -v civo >/dev/null 2>&1 || return 0
  civo kubernetes show "$CLUSTER_NAME" --region "$region" -o custom -f id 2>/dev/null \
    | tr -d '[:space:]' || true
}

cmd_up() {
  log "Creating the Civo cluster via Terraform ($TF_DIR)..."
  terraform -chdir="$TF_DIR" init -upgrade -input=false
  # Guard: a state left over from the old config still manages a civo_network. Applying the
  # current (network-less) config against it would try to DELETE that network — which orphaned
  # CSI volumes can block, recreating the exact dirty state we designed this away from. Stop and
  # point at `reset`, which cleans it up safely. A fresh user has no state and never sees this.
  if terraform -chdir="$TF_DIR" state list 2>/dev/null | grep -q '^civo_network\.'; then
    die "Stale state: it still manages a civo_network (old config). Run './cluster.sh reset' first, then 'up'."
  fi
  terraform -chdir="$TF_DIR" apply
  # Save the kubeconfig reliably (the civo provider often returns an empty one right after apply —
  # the helper falls back to the Civo CLI). Then point kubectl at it.
  if bash "$TF_DIR/save-kubeconfig.sh"; then
    log "Run:  export KUBECONFIG=~/.kube/civo-atlas.yaml && kubectl get nodes"
  else
    warn "Could not save the kubeconfig automatically — see TROUBLESHOOTING TS-CIVO-01."
  fi
}

# Release the CSI-provisioned block volumes BEFORE destroying the cluster.
#
# Civo's CSI driver creates a block volume per PVC (Postgres, the Kafka brokers, Prometheus,
# Loki, Tempo…). Terraform did not create them, so it does not know they exist, and destroying
# the cluster leaves them behind — detached, but still billing. Deleting the PVCs first, while the
# cluster is still reachable, lets the CSI driver release each volume cleanly (the cheap, tidy
# path). Anything that slips through is caught afterwards by sweep_orphaned_volumes.
release_volumes() {
  if ! command -v kubectl >/dev/null 2>&1; then
    log "kubectl not found — skipping PVC cleanup (sweep_orphaned_volumes will catch leftovers)."
    return 0
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log "No reachable cluster for the current kubeconfig — skipping PVC cleanup."
    log "Leftover volumes (if any) are swept afterwards via the Civo API; or list: civo volume ls"
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
  log "The post-destroy sweep will try to remove them; or clean up by hand: civo volume ls"
  log "A PV stuck here usually has reclaimPolicy: Retain (deliberately kept) or a finalizer."
}

# Cost-hygiene sweep: the CSI driver creates a block volume per PVC and Terraform never sees
# them, so a bare `terraform destroy`, an unreachable kubectl, or PVCs stuck Terminating can
# leave them behind — attached to nothing, quietly billing. Delete them through the Civo API.
# (This no longer unblocks a destroy — the cluster runs on the default network, which Terraform
# never deletes — it just stops the waste. See TS-CIVO-03.)
#
# ⚠️  Takes the cluster id as $1. It CANNOT be resolved here: this runs after the cluster is
#     gone, and `civo kubernetes show` needs it alive. Callers resolve it first (see cmd_down /
#     cmd_reset). Passing nothing degrades this to the --dangling pass only, which is NOT
#     enough on its own — see the note below.
sweep_orphaned_volumes() {
  local cid="${1:-}"
  if ! command -v civo >/dev/null 2>&1; then
    log "civo CLI not installed — delete leftover volumes by hand: civo volume ls ; civo volume delete <id>"
    return 0
  fi
  local region
  region="$(civo_region)"

  # Match this cluster's volumes by cluster_id (a UUID), NOT by network — the cluster shares
  # Civo's default network, so a network-name match would be wrong and could touch other
  # clusters. `civo volume ls -o custom` output is comma-separated, lowercase fields, no header.
  #
  # WHY the cluster_id pass carries the weight, and --dangling alone does not: when a cluster is
  # torn down without releasing its PVCs, Civo keeps recording those volumes as ATTACHED to nodes
  # that no longer exist. They are orphans, but `--dangling` (= attached to nothing) does not list
  # them, so a --dangling-only sweep silently leaves them behind — billing, and eating both the
  # disk-GB and the disk-volume-count quota. That is exactly how ~195 GB across 11 volumes
  # accumulated and wedged a later cluster (PVCs Pending, "would exceed volume space quota").
  # Matching on cluster_id catches them regardless of the recorded attachment state.
  if [ -z "$cid" ]; then
    warn "No cluster id given — sweeping only volumes Civo reports as dangling."
    warn "Volumes still recorded as attached to the destroyed nodes will SURVIVE. Check by hand:"
    warn "  civo volume ls --region ${region:-<region>}    # compare against: kubectl get pv"
  fi

  log "Sweeping this cluster's block volumes (region '${region:-?}', cluster_id '${cid:-none}')..."
  {
    [ -n "$cid" ] && civo volume ls --region "$region" -o custom -f id,cluster_id 2>/dev/null \
      | awk -F, -v c="$cid" '$2==c{print $1}'
    civo volume ls --region "$region" --dangling -o custom -f id 2>/dev/null
  } | awk 'NF' | sort -u \
    | while read -r id; do
        [ -n "$id" ] && { log "  deleting volume $id"; civo volume delete "$id" --region "$region" -y >/dev/null 2>&1 || true; }
      done
}

cmd_down() {
  log "This will DESTROY cluster '$CLUSTER_NAME' and stop all billing."
  log "PVC data is lost unless volumes use reclaimPolicy: Retain."

  # Resolve the cluster id FIRST. `civo kubernetes show` only works while the cluster exists, and
  # the post-destroy sweep needs this id to find volumes Civo still records as attached to the
  # (by then deleted) nodes. Resolving it inside the sweep would always come back empty.
  local region cid
  region="$(civo_region)"
  cid="$(civo_cluster_id "$region")"

  release_volumes            # delete PVCs first so the CSI driver frees their block volumes
  if ! terraform -chdir="$TF_DIR" destroy; then
    log "terraform destroy reported an error — retrying once. Terraform only manages the firewall"
    log "and cluster now (both always deletable), so this is rare; a transient API hiccup usually."
    terraform -chdir="$TF_DIR" destroy -auto-approve
  fi
  # Cluster is gone; Terraform never managed the CSI block volumes, so sweep any that outlived it
  # (unreachable kubectl, PVCs stuck Terminating). Pure cost hygiene — nothing was blocking.
  sweep_orphaned_volumes "$cid"
}

# Recover from a dirty / half-applied state and return to a clean slate a fresh user would have.
# Bypasses Terraform on purpose: a corrupted state (e.g. an orphaned civo_network with an empty
# name, the artefact of an interrupted destroy) makes `terraform destroy` itself fail, so we tear
# the leftovers down through the Civo API instead, then wipe the local state. After `reset`, a
# plain `./cluster.sh up` builds everything from zero. Every step is guarded ("if it exists"),
# so reset is idempotent and safe to run on an already-clean environment.
cmd_reset() {
  local region net_id cid
  region="$(civo_region)"

  if command -v civo >/dev/null 2>&1; then
    log "Reset: clearing any leftover Civo resources for '$CLUSTER_NAME' (region '${region:-?}')..."
    # 0) Cluster id BEFORE removing the cluster — same reason as in cmd_down: the sweep needs it
    #    and it is unresolvable afterwards.
    cid="$(civo_cluster_id "$region")"
    # 1) Cluster first — frees nodes and drops firewall/network associations.
    if civo kubernetes show "$CLUSTER_NAME" --region "$region" >/dev/null 2>&1; then
      log "  removing cluster $CLUSTER_NAME"; civo kubernetes remove "$CLUSTER_NAME" --region "$region" -y >/dev/null 2>&1 || true
    fi
    # 2) Volumes — must go before the (legacy) network can be removed.
    sweep_orphaned_volumes "$cid"
    # 3) Firewall left over from either the old or the new config.
    if civo firewall ls --region "$region" -o custom -f name 2>/dev/null | grep -qx "${CLUSTER_NAME}-fw"; then
      log "  removing firewall ${CLUSTER_NAME}-fw"; civo firewall remove "${CLUSTER_NAME}-fw" --region "$region" -y >/dev/null 2>&1 || true
    fi
    # 4) Legacy dedicated network from the OLD config (the new config never creates one).
    net_id="$(civo network ls --region "$region" -o custom -f id,label 2>/dev/null \
              | awk -F, -v n="${CLUSTER_NAME}-net" '$2==n{print $1}' | head -1)"
    if [ -n "$net_id" ]; then
      log "  removing legacy network ${CLUSTER_NAME}-net ($net_id)"; civo network remove "$net_id" --region "$region" -y >/dev/null 2>&1 || true
    fi
  else
    log "civo CLI not installed — cannot sweep Civo resources. Install it or delete by hand:"
    log "  civo kubernetes remove $CLUSTER_NAME ; civo firewall ls ; civo network ls ; civo volume ls"
  fi

  # 5) Drop the local Terraform state (gitignored) so the next `up` starts from zero.
  log "  removing local Terraform state"
  rm -f "$TF_DIR/terraform.tfstate" "$TF_DIR/terraform.tfstate.backup"
  log "Reset complete. Run: ./cluster.sh up"
}

# Sweep orphans left by PREVIOUS clusters, from a machine pointed at the CURRENT live one.
#
# Neither pass in sweep_orphaned_volumes can find these: they carry the cluster_id of a cluster
# that no longer exists, and Civo still records them as attached, so --dangling skips them. The
# only reliable identification is a diff against the PVs the live cluster actually uses.
#
# Dry-run by default — prints what it would delete. Pass --yes to actually delete.
cmd_sweep() {
  local apply="${1:-}"
  command -v civo >/dev/null 2>&1    || die "civo CLI not installed."
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found — a PV diff needs it."
  kubectl cluster-info >/dev/null 2>&1 || die "No reachable cluster; a PV diff needs the live one (TS-CIVO-01)."

  local region live live_n
  region="$(civo_region)"
  [ -n "$region" ] || die "Could not resolve the Civo region (terraform.tfvars / civo region current)."

  # GUARD: only PVs backed by civo-volume count. If kubectl is pointed at a NON-Civo cluster
  # (an OKE kubeconfig, say) this comes back empty — and an empty 'in use' list would make every
  # Civo volume look orphaned. Refuse rather than delete the live cluster's storage.
  live="$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="civo-volume")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk 'NF' | sort -u)"
  live_n="$(printf '%s\n' "$live" | awk 'NF' | wc -l | tr -d ' ')"
  [ "${live_n:-0}" -gt 0 ] || die "No civo-volume PVs found. Is kubectl pointed at the Civo cluster? Refusing to sweep."

  log "Live cluster is using ${live_n} civo-volume PersistentVolume(s); everything else is an orphan."
  local orphans
  orphans="$(civo volume ls --region "$region" -o custom -f id,name 2>/dev/null \
             | awk -F, 'NF' | while IFS=, read -r id name; do
                 printf '%s\n' "$live" | grep -qxF "$name" || printf '%s,%s\n' "$id" "$name"
               done)"

  if [ -z "$orphans" ]; then log "No orphaned volumes. Nothing to do."; return 0; fi
  printf '%s\n' "$orphans" | while IFS=, read -r id name; do log "  ORPHAN  $id  $name"; done

  if [ "$apply" != "--yes" ]; then
    log "Dry run. Re-run with:  ./cluster.sh sweep --yes"
    return 0
  fi
  printf '%s\n' "$orphans" | while IFS=, read -r id _; do
    log "  deleting $id"
    civo volume detach "$id" --region "$region" >/dev/null 2>&1 || true
    civo volume delete "$id" --region "$region" -y >/dev/null 2>&1 \
      || warn "  could not delete $id — delete it from the Civo console."
  done
  log "Done. Check the quota:  civo quota"
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
  up|down|reset|sweep|status) preflight ;;
  *)                          usage ;;
esac
case "$1" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  reset)  cmd_reset ;;
  sweep)  cmd_sweep "${2:-}" ;;
  status) cmd_status ;;
esac
