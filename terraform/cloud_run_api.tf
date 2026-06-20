# cal.diy API v2 (NestJS). INTERNAL ingress only — never faces the public
# internet. The only thing that reaches it is the auth-swap proxy, over the VPC.
# Platform-level auth is "allow unauthenticated" ON PURPOSE: cal reads its API
# key from `Authorization: Bearer`, which would collide with a Cloud Run IAM ID
# token. Security therefore comes from (a) internal ingress (network isolation)
# and (b) cal's own API-key check at the app layer. See RUNBOOK trust boundary.
#
# Required-to-boot env (apps/api/v2/.env.example): NODE_ENV, API_PORT, REDIS_URL,
# DATABASE_URL, DATABASE_READ_URL, DATABASE_WRITE_URL, NEXTAUTH_SECRET, JWT_SECRET,
# STRIPE_API_KEY, STRIPE_WEBHOOK_SECRET, CALENDSO_ENCRYPTION_KEY.
# Stripe is presence-checked only (billing unused in our headless flow) -> dummies.

resource "google_cloud_run_v2_service" "api" {
  name     = "${local.prefix}-api"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  deletion_protection = local.is_prod

  template {
    service_account                  = google_service_account.run_api.email
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = var.api_min_instances
      max_instance_count = var.api_max_instances
    }

    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY" # SQL/Redis via VPC; public (Google APIs) direct
    }

    # cloud-sql-proxy sidecar: fully-verified mTLS to Cloud SQL. The app connects
    # to it over in-container localhost (127.0.0.1:5432), so the instance stays
    # ENCRYPTED_ONLY and no TLS verification is skipped.
    containers {
      name  = "cloudsql-proxy"
      image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1"
      args = [
        "--private-ip",
        "--port=5432",
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
      name       = "app"
      image      = var.api_image
      depends_on = ["cloudsql-proxy"]

      ports {
        container_port = 5555
      }

      resources {
        limits = {
          cpu    = var.api_cpu
          memory = var.api_memory
        }
        cpu_idle          = false # keep CPU allocated (warm Prisma/Redis pools)
        startup_cpu_boost = true
      }

      # ---- Non-secret config ----
      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "API_PORT"
        value = "5555"
      }
      env {
        name  = "REWRITE_API_V2_PREFIX"
        value = "1" # /api/v2 -> /v2
      }
      env {
        name  = "API_KEY_PREFIX"
        value = "cal_"
      }
      env {
        name  = "WEB_APP_URL"
        value = var.webapp_url
      }
      env {
        name  = "LOG_LEVEL"
        value = "ERROR" # keep PHI out of logs
      }
      env {
        name  = "LOGGER_BRIDGE_LOG_LEVEL"
        value = "3" # ERROR
      }
      env {
        name  = "DATABASE_HOST"
        value = "127.0.0.1:5432" # via the cloud-sql-proxy sidecar
      }
      # Stripe: required-to-boot presence check only; billing unused. Dummy values.
      env {
        name  = "STRIPE_API_KEY"
        value = "sk_test_unused_billing_disabled"
      }
      env {
        name  = "STRIPE_WEBHOOK_SECRET"
        value = "whsec_unused_billing_disabled"
      }

      # ---- Secrets (Secret Manager refs; values never in state) ----
      dynamic "env" {
        for_each = {
          DATABASE_URL                          = "database_url"
          DATABASE_READ_URL                     = "database_url"
          DATABASE_WRITE_URL                    = "database_url"
          DATABASE_DIRECT_URL                   = "database_url_direct"
          REDIS_URL                             = "redis_url"
          NEXTAUTH_SECRET                       = "nextauth_secret"
          JWT_SECRET                            = "jwt_secret"
          CALENDSO_ENCRYPTION_KEY               = "encryption_key"
          CALCOM_SERVICE_ACCOUNT_ENCRYPTION_KEY = "service_account_encryption_key"
        }
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this[env.value].secret_id
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        initial_delay_seconds = 10
        period_seconds        = 10
        failure_threshold     = 30 # NestJS + Prisma generate can be slow to first-listen
        timeout_seconds       = 5
        tcp_socket {
          port = 5555
        }
      }
    }
  }

  labels = local.labels

  lifecycle {
    # Image tag is rolled by CI via `gcloud run deploy`; don't let TF revert it.
    ignore_changes = [template[0].containers[0].image, client, client_version]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.access,
    google_redis_instance.cache,
    google_sql_database.app,
  ]
}

# Internal-only + app-layer key auth => allow unauthenticated at the platform.
resource "google_cloud_run_v2_service_iam_member" "api_invoker" {
  name     = google_cloud_run_v2_service.api.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}
