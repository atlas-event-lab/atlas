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

resource "civo_network" "atlas" {
  label = "${var.cluster_name}-net"
}

resource "civo_firewall" "atlas" {
  name       = "${var.cluster_name}-fw"
  network_id = civo_network.atlas.id
  # Opens the ports a public Kubernetes cluster needs (API 6443, 80/443 for Ingress).
  # For a locked-down setup, set this false and add explicit civo_firewall_rule blocks.
  create_default_rules = true
}

resource "civo_kubernetes_cluster" "atlas" {
  name               = var.cluster_name
  network_id         = civo_network.atlas.id
  firewall_id        = civo_firewall.atlas.id
  cni                = var.cni
  kubernetes_version = var.kubernetes_version != "" ? var.kubernetes_version : null

  pools {
    label      = "atlas-experiments"
    size       = var.node_size  # g4p.kube.small = 4 vCPU / 16 GB
    node_count = var.node_count # 3 -> 12 vCPU / 48 GB, fixed
  }
}
