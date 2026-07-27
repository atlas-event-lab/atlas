# All inputs parameterized; defaults produce the 12 vCPU / 48 GB experiment cluster.

variable "civo_token" {
  description = "Civo API key. Prefer the CIVO_TOKEN env var; leave empty here to use it."
  type        = string
  default     = ""
  sensitive   = true
}

variable "region" {
  description = "Civo region: NYC1, LON1, FRA1, PHX1, ... (civo region ls)."
  type        = string
  default     = "NYC1"
}

variable "cluster_name" {
  type    = string
  default = "atlas-civo"
}

variable "kubernetes_version" {
  description = "Pin for reproducibility (k3s format, e.g. \"1.30.5-k3s1\"). Empty = Civo default. List: civo kubernetes versions"
  type        = string
  default     = ""
}

variable "cni" {
  description = "Cluster CNI: flannel (default) or cilium."
  type        = string
  default     = "flannel"
}

# --- The fixed experiment pool: 3 × 4 vCPU / 16 GB = 12 vCPU / 48 GB ---
variable "node_size" {
  description = "Civo node size. g4p.kube.small = 4 vCPU / 16 GB (Performance family). List: civo kubernetes size"
  type        = string
  default     = "g4p.kube.small"
}

variable "node_count" {
  description = "Number of nodes. 3 × g4p.kube.small = 12 vCPU / 48 GB."
  type        = number
  default     = 3
}
