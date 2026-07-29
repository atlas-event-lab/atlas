output "cluster_name" {
  value = civo_kubernetes_cluster.atlas.name
}

output "api_endpoint" {
  value = civo_kubernetes_cluster.atlas.api_endpoint
}

# Raw kubeconfig for the cluster (sensitive). NOTE: the civo provider often returns this EMPTY
# right after apply (TS-CIVO-01) — prefer `./save-kubeconfig.sh`, which falls back to the Civo CLI.
output "kubeconfig" {
  value     = civo_kubernetes_cluster.atlas.kubeconfig
  sensitive = true
}

output "save_kubeconfig_hint" {
  value = "./save-kubeconfig.sh && export KUBECONFIG=~/.kube/civo-atlas.yaml && kubectl get nodes"
}
