# Providers + shared locals.

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

locals {
  prefix = "${var.name_prefix}-${var.environment}"

  labels = merge(var.labels, {
    environment = var.environment
  })

  # Names of the Secret Manager secrets this stack reads. Values are populated
  # out-of-band (RUNBOOK) and never appear in Terraform state.
  secret_names = {
    # cal.diy app secrets
    nextauth_secret                = "${local.prefix}-nextauth-secret"
    encryption_key                 = "${local.prefix}-calendso-encryption-key"
    service_account_encryption_key = "${local.prefix}-service-account-encryption-key"
    jwt_secret                     = "${local.prefix}-jwt-secret"
    db_password                    = "${local.prefix}-db-password"
    # contract with the AWS app
    cal_api_key        = "${local.prefix}-cal-api-key"        # AWS app -> cal (Bearer)
    cal_webhook_secret = "${local.prefix}-cal-webhook-secret" # cal -> AWS webhook HMAC
  }

  is_prod = var.environment == "prod"
}
