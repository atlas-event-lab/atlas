# Oracle Cloud provider. The OKE module needs a second provider aliased `oci.home`
# pointed at your tenancy's HOME region (identity/policies live there), plus the normal
# provider for the region you deploy into.

terraform {
  required_version = ">= 1.5"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.0"
    }
  }
}

# Authentication: the cleanest for a laptop is API-key auth from ~/.oci/config.
# `terraform` then needs no secrets in code. See README for `oci setup config`.
provider "oci" {
  region = var.region
}

provider "oci" {
  alias  = "home"
  region = var.home_region
}
