# Secret Manager: secret CONTAINERS only. Their versions (the actual secret
# values) are populated out-of-band — see RUNBOOK "Populate secrets". Values
# never appear in this Terraform config, plan, or state.
#
# Secrets held here:
#   nextauth-secret, calendso-encryption-key, service-account-encryption-key,
#   jwt-secret, db-password           -> cal.diy app secrets
#   database-url, database-url-direct -> full Postgres URLs (contain the password)
#   cal-api-key                       -> Bearer key the AWS app uses to call cal
#   cal-webhook-secret                -> HMAC-SHA256 key for cal -> AWS webhook
#
# Optional CMEK on the secret payloads: Secret Manager supports CMEK, but the
# default Google-managed encryption is HIPAA-eligible; we keep Google-managed
# here to avoid per-region KMS plumbing and reserve CMEK for the Cloud SQL data
# store (the bulk of PHI at rest).

locals {
  all_secret_names = merge(local.secret_names, {
    database_url            = "${local.prefix}-database-url"            # postgres URL w/ password
    database_url_direct     = "${local.prefix}-database-url-direct"     # non-pooled URL for migrations
    redis_url               = "${local.prefix}-redis-url"               # rediss://:auth@host:port
    cal_oauth_client_secret = "${local.prefix}-cal-oauth-client-secret" # proxy injects as x-cal-secret-key
  })
}

resource "google_secret_manager_secret" "this" {
  for_each  = local.all_secret_names
  secret_id = each.value
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.enabled]

  # Guard the crown jewels: a stray `terraform destroy` must not delete these
  # containers (which would take their versions — incl. the DB-encryption keys —
  # with them). Remove deliberately only when decommissioning the environment.
  lifecycle {
    prevent_destroy = true
  }
}
