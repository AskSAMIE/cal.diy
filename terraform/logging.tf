# Audit logging retained per HIPAA (6 years). We route Cloud Audit Logs to a
# dedicated bucket with long retention, and turn on Data Access audit logs for
# the services that touch PHI/secrets.
#
# PHI-safety: application logs are kept at ERROR level and the app code avoids
# logging payloads. Audit logs record WHO did WHAT to WHICH resource — not the
# attendee data itself.

resource "google_logging_project_bucket_config" "audit" {
  project        = var.project_id
  location       = var.region
  retention_days = var.log_retention_days # ~6 years
  bucket_id      = "${local.prefix}-audit-logs"
  description    = "cal.diy audit logs (HIPAA 6-year retention) for ${var.environment}"

  depends_on = [google_project_service.enabled]
}

# Route all Cloud Audit Logs into the long-retention bucket.
resource "google_logging_project_sink" "audit" {
  name        = "${local.prefix}-audit-sink"
  destination = "logging.googleapis.com/projects/${var.project_id}/locations/${var.region}/buckets/${google_logging_project_bucket_config.audit.bucket_id}"
  filter      = "logName:\"cloudaudit.googleapis.com\""

  unique_writer_identity = true
}

# Enable Data Access audit logs for the PHI/secret-bearing services.
resource "google_project_iam_audit_config" "phi_services" {
  for_each = toset([
    "secretmanager.googleapis.com",
    "cloudsql.googleapis.com",
    "run.googleapis.com",
  ])
  project = var.project_id
  service = each.value

  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
  audit_log_config {
    log_type = "ADMIN_READ"
  }
}
