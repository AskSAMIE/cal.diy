# Cloud Run Job: run `prisma migrate deploy` as a controlled, reviewable step
# BEFORE rolling a new web/api revision (rather than racing on container boot).
# Reuses the web image (it contains the Prisma schema + CLI) with an overridden
# command. Uses the DIRECT (non-pooled) DB URL — the right connection for DDL.

resource "google_cloud_run_v2_job" "migrate" {
  name     = "${local.prefix}-migrate"
  location = var.region

  deletion_protection = false

  template {
    template {
      service_account = google_service_account.migrate.email
      max_retries     = 1
      timeout         = "1200s"

      vpc_access {
        connector = google_vpc_access_connector.connector.id
        egress    = "PRIVATE_RANGES_ONLY"
      }

      # cloud-sql-proxy sidecar (verified mTLS). --exit-zero-on-sigterm so the
      # sidecar shuts down cleanly when the migration container finishes the task.
      containers {
        name  = "cloudsql-proxy"
        image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1"
        args = [
          "--private-ip",
          "--port=5432",
          "--exit-zero-on-sigterm",
          "--health-check",
          "--http-address=0.0.0.0",
          "--http-port=9090",
          google_sql_database_instance.main.connection_name,
        ]
        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
        startup_probe {
          http_get {
            path = "/startup"
            port = 9090
          }
          period_seconds    = 5
          failure_threshold = 20
          timeout_seconds   = 3
        }
      }

      containers {
        name       = "migrate"
        image      = var.web_image
        command    = ["npx"]
        args       = ["prisma", "migrate", "deploy", "--schema", "/calcom/packages/prisma/schema.prisma"]
        depends_on = ["cloudsql-proxy"]

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        # Prisma reads the datasource URL. Provide both; the schema's directUrl
        # (if set) uses DATABASE_DIRECT_URL, otherwise DATABASE_URL.
        env {
          name = "DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this["database_url_direct"].secret_id
              version = "latest"
            }
          }
        }
        env {
          name = "DATABASE_DIRECT_URL"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this["database_url_direct"].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  labels = local.labels

  lifecycle {
    ignore_changes = [template[0].template[0].containers[0].image, client, client_version]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.access,
    google_sql_database.app,
  ]
}
