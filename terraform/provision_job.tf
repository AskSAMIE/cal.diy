# One-off Cloud Run Job that provisions the headless platform layer:
# Organization + admin OWNER membership + PlatformOAuthClient (managed users).
# Runs scripts/provision-platform-oauth.ts in the web image, through the
# cloud-sql-proxy sidecar. Idempotent — safe to re-run (e.g. to update redirect
# URIs or rotate the client secret). Execute it manually after deploy:
#   gcloud run jobs execute caldiy-<env>-provision --region <region> --wait
# Then read PLATFORM_OAUTH_CLIENT_ID=<id> from the logs (that's the AWS app's
# CAL_OAUTH_CLIENT_ID; the secret is the cal-oauth-client-secret it also stores).

resource "google_cloud_run_v2_job" "provision" {
  name                = "${local.prefix}-provision"
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
        args       = ["ts-node", "--transpile-only", "/calcom/scripts/provision-platform-oauth.ts"]
        depends_on = ["cloudsql-proxy"]

        resources {
          limits = { cpu = "1", memory = "1Gi" }
        }

        env {
          name  = "PROVISION_ADMIN_EMAIL"
          value = var.provision_admin_email
        }
        env {
          name  = "PROVISION_ORG_NAME"
          value = var.provision_org_name
        }
        env {
          name  = "PROVISION_ORG_SLUG"
          value = var.provision_org_slug
        }
        env {
          name  = "PROVISION_CLIENT_NAME"
          value = var.provision_client_name
        }
        env {
          name  = "PROVISION_REDIRECT_URIS"
          value = var.provision_redirect_uris
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
        env {
          name = "CAL_OAUTH_CLIENT_SECRET"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this["cal_oauth_client_secret"].secret_id
              version = "latest"
            }
          }
        }
        env {
          name  = "PROVISION_WEBHOOK_URL"
          value = var.provision_webhook_url
        }
        env {
          name = "CAL_WEBHOOK_SECRET"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this["cal_webhook_secret"].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  labels = local.labels

  lifecycle {
    # Unlike the CI-rolled services, TF owns this job's image so a web_image bump
    # (the rebuild that bakes in the provisioning script) actually updates it.
    ignore_changes = [client, client_version]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.access,
    google_sql_database.app,
  ]
}
