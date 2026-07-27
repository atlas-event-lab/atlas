# Civo provider. Auth uses an API token — NEVER hardcode it. The provider reads the
# CIVO_TOKEN environment variable automatically:
#   export CIVO_TOKEN="your-civo-api-key"   (Dashboard → Account → Security → API keys)
# Or set var.civo_token in a gitignored terraform.tfvars.

terraform {
  required_version = ">= 1.5"
  required_providers {
    civo = {
      source  = "civo/civo"
      version = "~> 1.1"
    }
  }
}

provider "civo" {
  token  = var.civo_token != "" ? var.civo_token : null
  region = var.region
}
