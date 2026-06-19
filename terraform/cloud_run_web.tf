# cal.diy web app (Next.js). INTERNAL ingress — admin-only in the headless model.
# No public booking UI; the AWS app drives bookings via the API v2. Admin (Brandy)
# reaches the UI via `gcloud run services proxy` (authenticated tunnel) — invoker
# is limited to var.admin_members, NOT allUsers.
#
# scripts/start.sh runs `prisma migrate deploy` + app-store seed on boot. CI runs
# the migrate job first, so this is normally a no-op. NEXT_PUBLIC_WEBAPP_URL is
# baked at build and re-asserted at runtime by start.sh (placeholder replace).

resource "google_cloud_run_v2_service" "web" {
  name     = "${local.prefix}-web"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  deletion_protection = local.is_prod

  template {
    service_account                  = google_service_account.run_web.email
    max_instance_request_concurrency = 80
    timeout                          = "300s"

    scaling {
      min_instance_count = var.web_min_instances
      max_instance_count = var.web_max_instances
    }

    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = var.web_image

      ports {
        container_port = 3000
      }

      resources {
        limits = {
          cpu    = var.web_cpu
          memory = var.web_memory
        }
        cpu_idle          = false
        startup_cpu_boost = true
      }

      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "NEXT_PUBLIC_WEBAPP_URL"
        value = var.webapp_url
      }
      env {
        name  = "NEXT_PUBLIC_API_V2_URL"
        value = var.api_v2_public_url
      }
      # Help NextAuth loop back to itself inside the container (see docker.mdx).
      env {
        name  = "NEXTAUTH_URL"
        value = "${var.webapp_url}/api/auth"
      }
      env {
        name  = "DATABASE_HOST"
        value = "${google_sql_database_instance.main.private_ip_address}:5432"
      }

      dynamic "env" {
        for_each = {
          DATABASE_URL                          = "database_url"
          DATABASE_DIRECT_URL                   = "database_url_direct"
          NEXTAUTH_SECRET                       = "nextauth_secret"
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
        initial_delay_seconds = 20
        period_seconds        = 15
        failure_threshold     = 40 # migrate + seed + Next boot on first deploy is slow
        timeout_seconds       = 5
        http_get {
          path = "/auth/login"
          port = 3000
        }
      }
    }
  }

  labels = local.labels

  lifecycle {
    ignore_changes = [template[0].containers[0].image, client, client_version]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.access,
    google_sql_database.app,
  ]
}

# Admin-only invoker (authenticated tunnel). Empty admin_members => no one but
# project IAM admins can reach it.
resource "google_cloud_run_v2_service_iam_member" "web_admin" {
  for_each = toset(var.admin_members)
  name     = google_cloud_run_v2_service.web.name
  location = var.region
  role     = "roles/run.invoker"
  member   = each.value
}
