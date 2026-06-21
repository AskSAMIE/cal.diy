# One-off Cloud Run Job that provisions a regular cal user for one OT provider
# (User + Working-Hours schedule + bookable event type). Runs
# scripts/provision-provider.ts in the web image through the cloud-sql-proxy
# sidecar. Idempotent.
#
# Provider details are set per-run (the job is reusable):
#   gcloud run jobs update caldiy-<env>-provision-provider --region <region> \
#     --update-env-vars PROVIDER_EMAIL=...,PROVIDER_USERNAME=...,PROVIDER_NAME=...
#   gcloud run jobs execute caldiy-<env>-provision-provider --region <region> --wait
# Then read PROVIDER_CAL_USERNAME / PROVIDER_EVENT_TYPE_ID from the logs for the
# AWS app's ProviderScheduling row.

resource "google_cloud_run_v2_job" "provision_provider" {
  name                = "${local.prefix}-provision-provider"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.provision.email
      max_retries     = 0
      timeout         = "600s"

      vpc_access {
        connector = google_vpc_access_connector.connector.id
        egress    = "PRIVATE_RANGES_ONLY"
      }

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
          limits = { cpu = "1", memory = "512Mi" }
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
        name       = "provision"
        image      = var.web_image
        command    = ["npx"]
        args       = ["ts-node", "--transpile-only", "/calcom/scripts/provision-provider.ts"]
        depends_on = ["cloudsql-proxy"]

        resources {
          limits = { cpu = "1", memory = "1Gi" }
        }

        env {
          name = "DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this["database_url"].secret_id
              version = "latest"
            }
          }
        }
        # PROVIDER_* are set per-run via `gcloud run jobs update ... --update-env-vars`.
      }
    }
  }

  labels = local.labels

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[1].env, # PROVIDER_* set per-run
      client,
      client_version,
    ]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.access,
    google_sql_database.app,
  ]
}
