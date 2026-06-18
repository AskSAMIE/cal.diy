# Auth-swap proxy — the single public surface of hop #1, and the only caller of
# the internal cal API v2.
#
# Trust chain:
#   AWS ECS task role --(WIF)--> aws_caller SA --(run.invoker)--> THIS proxy
#   Cloud Run IAM validates the Google ID token in `Authorization: Bearer`.
#   The proxy then STRIPS that header, injects cal's real credentials from Secret
#   Manager (Authorization: Bearer <cal_api_key> + x-cal-secret-key for managed
#   users), and forwards over the VPC to the internal cal API.
#
# Net effect: the AWS app holds NO long-lived cal secret (only its own identity);
# cal never faces the public internet; no IP allowlist needed.

resource "google_cloud_run_v2_service" "proxy" {
  name     = "${local.prefix}-proxy"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL" # reachable from AWS, but IAM-gated to aws_caller

  deletion_protection = local.is_prod

  template {
    service_account = google_service_account.run_proxy.email

    scaling {
      min_instance_count = local.is_prod ? 1 : 0
      max_instance_count = 5
    }

    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "ALL_TRAFFIC" # route the call to the internal API's *.run.app via VPC
    }

    containers {
      image = var.proxy_image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        startup_cpu_boost = true
      }

      env {
        name  = "CAL_API_INTERNAL_URL"
        value = google_cloud_run_v2_service.api.uri
      }
      env {
        name  = "CAL_API_VERSION"
        value = "2024-08-13" # confirmed current pin for slots + bookings
      }
      env {
        name = "CAL_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.this["cal_api_key"].secret_id
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

      startup_probe {
        initial_delay_seconds = 3
        period_seconds        = 5
        failure_threshold     = 10
        http_get {
          path = "/healthz"
        }
      }
    }
  }

  labels = local.labels

  lifecycle {
    ignore_changes = [template[0].containers[0].image, client, client_version]
  }

  depends_on = [google_secret_manager_secret_iam_member.access]
}

# ONLY the federated AWS caller may invoke the proxy. No allUsers.
resource "google_cloud_run_v2_service_iam_member" "proxy_invoker" {
  name     = google_cloud_run_v2_service.proxy.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.aws_caller.email}"
}
