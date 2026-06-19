# Cloud SQL for PostgreSQL — cal.diy's OWN database (separate from the AWS RDS).
# Holds PHI: bookings (attendee name/email/phone/time), provider users, and
# encrypted third-party calendar OAuth tokens. Therefore: PRIVATE IP only,
# CMEK, PITR, automated backups, deletion protection.
#
# cal.diy expects a standard Postgres connection via DATABASE_URL. Migrations
# run with `prisma migrate deploy` (scripts/start.sh and the migrate job).

resource "google_sql_database_instance" "main" {
  name             = "${local.prefix}-pg"
  database_version = "POSTGRES_16"
  region           = var.region

  encryption_key_name = var.use_cmek ? google_kms_crypto_key.sql[0].id : null
  deletion_protection = var.sql_deletion_protection

  depends_on = [
    google_service_networking_connection.private_services,
    google_kms_crypto_key_iam_member.sql_cmek,
  ]

  settings {
    # ENTERPRISE edition supports db-custom-* shared/custom tiers; the project
    # defaults new instances to ENTERPRISE_PLUS (which only takes db-perf-optimized-*),
    # so pin it explicitly. (ENTERPRISE still supports REGIONAL HA for prod.)
    edition           = var.sql_edition
    tier              = var.sql_tier
    availability_type = var.sql_availability_type
    disk_type         = "PD_SSD"
    disk_size         = var.sql_disk_size_gb
    disk_autoresize   = true

    # PRIVATE IP only — no public IP. Reachable solely from the VPC.
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "07:00" # UTC, low-traffic window
      transaction_log_retention_days = local.is_prod ? 7 : 3
      backup_retention_settings {
        retained_backups = var.sql_backup_retention_days
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 8 # UTC
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = false # avoid capturing potentially-identifying tags
      record_client_address   = false # do not log client IPs as query metadata
    }

    user_labels = local.labels
  }
}

resource "google_sql_database" "app" {
  name     = var.db_name
  instance = google_sql_database_instance.main.name
}

# NOTE: the application DB user + password are intentionally NOT managed here.
# Any Terraform-managed password lands in state, which violates our "no secrets
# in state" rule. Instead, the user is created once during bootstrap and its
# password is stored in Secret Manager (and assembled into the DATABASE_URL /
# DATABASE_DIRECT_URL secrets). See RUNBOOK "Bootstrap the database user".
# var.db_user / var.db_name describe what that bootstrap step must create.
