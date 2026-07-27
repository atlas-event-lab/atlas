output "cluster_name" {
  value = civo_kubernetes_cluster.atlas.name
}

output "api_endpoint" {
  value = civo_kubernetes_cluster.atlas.api_endpoint
}

# Raw kubeconfig for the cluster (sensitive). Save it and point kubectl at it:
#   terraform output -raw kubeconfig > ~/.kube/civo-atlas.yaml
#   export KUBECONFIG=~/.kube/civo-atlas.yaml
output "kubeconfig" {
  value     = civo_kubernetes_cluster.atlas.kubeconfig
  sensitive = true
}

output "save_kubeconfig_hint" {
  value = "terraform output -raw kubeconfig > ~/.kube/civo-atlas.yaml && export KUBECONFIG=~/.kube/civo-atlas.yaml && kubectl get nodes"
}
