# The OKE module exposes the created ids. Names below follow the v5 module; if a name is
# rejected on `terraform apply`, check the module's Outputs tab on the registry.

output "cluster_id" {
  description = "OKE cluster OCID."
  value       = try(module.oke.cluster_id, null)
}

output "worker_pool_ids" {
  description = "Node pool OCIDs (use one as NODEPOOL_OCID for deploy/ops/cluster-*.sh)."
  value       = try(module.oke.worker_pool_ids, null)
}

output "get_credentials_hint" {
  description = "How to point kubectl at the cluster."
  value       = "oci ce cluster create-kubeconfig --cluster-id <cluster_id> --file ~/.kube/config --region ${var.region} --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT"
}
