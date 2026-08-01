# Atlas — Civo Kubernetes cluster (provisioning).
#
# Single FIXED pool sized for the experiments: 3 × g4p.kube.small (4 vCPU / 16 GB) =
# 12 vCPU / 48 GB. No base/burst split — the lab keeps the cluster hot whenever it's up,
# so it always runs at experiment size. Save credit by turning the whole cluster off when
# idle (see deploy/ops/civo), not by autoscaling nodes.
#
#   terraform init
#   terraform plan
#   terraform apply     # cluster is Ready in ~2 min
#   terraform destroy   # full off — stops all billing
#
# Note: Civo's control plane is free; you pay only for the worker nodes and any volumes.
# Verify resource argument names against the provider docs for the version you pin:
#   https://registry.terraform.io/providers/civo/civo/latest/docs
#
# NETWORK: Terraform does NOT manage a dedicated civo_network. The firewall and the cluster
# both leave `network_id` unset, so Civo places them on the account's default network
# (`network_id` is Optional in the provider). This is deliberate robustness, not laziness:
#   - A managed network's only writable field is its label, so any drift makes the provider
#     call Civo's flaky "rename network" API — the failure this whole setup used to hit.
#   - `terraform destroy` never tries to delete a network, so orphaned CSI block volumes
#     (one per PVC: Kafka/Postgres/observability) can't block teardown with
#     DatabaseNetworkInUseByVolumes. Destroy only removes the firewall + cluster, both
#     always deletable — so a half-torn-down state can't happen. Leftover volumes are pure
#     cost, swept by `deploy/ops/civo/cluster.sh` (down/reset), not a teardown blocker.

resource "civo_firewall" "atlas" {
  name = "${var.cluster_name}-fw"
  # network_id unset -> Civo's default network.
  # Opens the ports a public Kubernetes cluster needs (API 6443, 80/443 for Ingress).
  # For a locked-down setup, set this false and add explicit civo_firewall_rule blocks.
  create_default_rules = true
}

resource "civo_kubernetes_cluster" "atlas" {
  name               = var.cluster_name
  firewall_id        = civo_firewall.atlas.id
  cni                = var.cni
  kubernetes_version = var.kubernetes_version != "" ? var.kubernetes_version : null
  # network_id unset -> Civo's default network (see the NETWORK note above).

  pools {
    label      = "atlas-experiments"
    size       = var.node_size  # g4p.kube.small = 4 vCPU / 16 GB
    node_count = var.node_count # 3 -> 12 vCPU / 48 GB, fixed
  }
}
