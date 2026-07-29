# All inputs parameterized — no OCIDs or account specifics hardcoded. Set the required
# ones in terraform.tfvars (copy from terraform.tfvars.example).

# --- Required: your tenancy ---
variable "compartment_id" {
  description = "OCID of the compartment to deploy into."
  type        = string
}
variable "tenancy_id" {
  description = "OCID of your tenancy."
  type        = string
}
variable "region" {
  description = "Region to deploy into, e.g. us-ashburn-1."
  type        = string
}
variable "home_region" {
  description = "Your tenancy's HOME region (Identity → Tenancy details)."
  type        = string
}
variable "ssh_public_key_path" {
  description = "Path to an SSH public key for worker node access, e.g. ~/.ssh/id_rsa.pub."
  type        = string
}

# --- Cluster ---
variable "cluster_name" {
  type    = string
  default = "atlas-oke"
}
variable "kubernetes_version" {
  description = "Must be a version with an available OKE node image in your region. List: oci ce node-pool-options get --node-pool-option-id all --query 'data.\"kubernetes-versions\"'"
  type        = string
  default     = "v1.34.2"
}
variable "services_cidr" {
  type    = string
  default = "10.96.0.0/16"
}
variable "control_plane_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the PUBLIC Kubernetes API endpoint (TCP 6443). The OKE module
    opens no ingress by default, so with an empty list kubectl times out ("i/o timeout")
    even though the endpoint is public. ["0.0.0.0/0"] makes it reachable from anywhere
    (still protected by OCI-signed token auth + TLS). To restrict it to your workstation,
    set ["<your-public-ip>/32"] — find it with:  curl -s ifconfig.me
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- Network ---
variable "vcn_name" {
  type    = string
  default = "atlas-oke-vcn"
}
variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# --- Worker pool (3 x E5.Flex, 2 OCPU / 16 GB) ---
variable "worker_shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}
variable "worker_ocpus" {
  description = "OCPUs per node. Note: 1 OCPU = 2 vCPU on this x86 shape."
  type        = number
  default     = 2
}
variable "worker_memory_gb" {
  type    = number
  default = 16
}
variable "worker_count" {
  type    = number
  default = 3
}
variable "worker_boot_volume_gb" {
  type    = number
  default = 50
}
variable "max_pods_per_node" {
  type    = number
  default = 30
}

variable "worker_image_id" {
  description = <<-EOT
    Explicit OKE node-image OCID for the workers. Leave null to let the module auto-resolve
    from kubernetes_version; set it if that resolution returns no image (empty node-pool
    sources). Find the OCID for your version/region with:
      oci ce node-pool-options get --node-pool-option-id all --query 'data.sources' --output table
  EOT
  type        = string
  default     = null
}
