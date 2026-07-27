# Atlas — Oracle OKE cluster (provisioning) via the official OKE module.
#
# The module builds the whole network stack (VCN, gateways, route tables, and the
# security rules OKE requires) plus the cluster and worker pool — the same topology the
# console's "Quick Create" produces, but reproducibly.
#
#   terraform init
#   terraform plan
#   terraform apply
#   terraform destroy
#
# ┌──────────────────────────────────────────────────────────────────────────────────┐
# │ VERIFY THE MODULE INPUTS FOR THE VERSION YOU PIN.                                   │
# │ This module's variable schema changes between major versions. After `terraform     │
# │ init`, run `terraform plan`; if any argument is rejected, reconcile it against the  │
# │ module docs for the pinned version:                                                 │
# │   https://registry.terraform.io/modules/oracle-terraform-modules/oke/oci/latest     │
# │ The block below targets the v5 line and its documented core inputs.                 │
# └──────────────────────────────────────────────────────────────────────────────────┘

module "oke" {
  source  = "oracle-terraform-modules/oke/oci"
  version = "~> 5.2"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  # --- Identity / placement ---
  compartment_id = var.compartment_id
  tenancy_id     = var.tenancy_id
  region         = var.region
  home_region    = var.home_region

  # --- SSH into workers ---
  ssh_public_key_path = var.ssh_public_key_path

  # --- Network (module creates the VCN + subnets + security rules) ---
  create_vcn = true
  vcn_name   = var.vcn_name
  vcn_cidrs  = [var.vcn_cidr]

  # --- Bastion & operator: not needed for this lab (public API endpoint). The module
  # creates both by default; disabling them removes two VMs (and their image lookups). ---
  create_bastion  = false
  create_operator = false

  # --- Control plane ---
  create_cluster                    = true
  cluster_name                      = var.cluster_name
  cluster_type                      = "enhanced"
  kubernetes_version                = var.kubernetes_version
  control_plane_is_public           = true
  assign_public_ip_to_control_plane = true
  # VCN-native pod networking (each pod gets a VCN IP), matching the original cluster.
  # Switch to "flannel" for an overlay if you prefer to conserve VCN IPs.
  cni_type = "npn"

  services_cidr = var.services_cidr

  # --- Worker node image ---
  # The module can auto-resolve the OKE node image from the k8s version, but that data
  # source returns empty in some tenancies/regions. Setting worker_image_id (an explicit
  # OKE node-image OCID) switches to a "custom" image and bypasses the auto-resolution.
  # Find it with:  oci ce node-pool-options get --node-pool-option-id all \
  #                  --query 'data.sources' --output table
  worker_image_type = var.worker_image_id != null ? "custom" : "oke"
  worker_image_id   = var.worker_image_id

  # --- Worker pool: 3 x E5.Flex, 2 OCPU / 16 GB (= 12 vCPU / 48 GB) ---
  worker_pools = {
    base = {
      description      = "Atlas baseline pool"
      shape            = var.worker_shape
      ocpus            = var.worker_ocpus
      memory           = var.worker_memory_gb
      size             = var.worker_count
      boot_volume_size = var.worker_boot_volume_gb
      # Raise the per-node pod cap so scheduling, not the cap, is the limit.
      max_pods_per_node = var.max_pods_per_node
    }
  }
}
