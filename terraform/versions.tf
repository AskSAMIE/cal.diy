# Terraform + provider version pins and remote state backend.
#
# State lives in a GCS bucket (one bucket, per-env prefix). The bucket itself is
# NOT created by this config (chicken/egg) — create it once per the RUNBOOK, then
# `terraform init -backend-config=environments/backend-<env>.hcl`.
#
# Docs: https://www.cal.diy/deployments/gcp (deployment target)
#       https://cloud.google.com/run/docs (Cloud Run runtime)

terraform {
  # >= 1.11 required for write-only arguments (password_wo) + ephemeral resources,
  # which keep the DB password out of Terraform state entirely.
  required_version = ">= 1.11.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.13"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend config — values supplied via -backend-config=environments/backend-<env>.hcl
  backend "gcs" {}
}
