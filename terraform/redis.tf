# Memorystore for Redis — REQUIRED for the cal.diy API v2 to boot (caching,
# rate-limiting, background workers). Private IP, AUTH, TLS in transit.
#
# The full REDIS_URL (which embeds the AUTH string) is assembled out-of-band and
# stored in the redis-url secret — see RUNBOOK. We expose only host/port here.

variable "redis_transit_encryption" {
  description = <<-EOT
    SERVER_AUTHENTICATION (TLS, recommended) or DISABLED. If the cal API v2 Redis
    client cannot present TLS, fall back to DISABLED (traffic stays on the private
    VPC) and record the residual risk in the compliance log.
  EOT
  type        = string
  default     = "SERVER_AUTHENTICATION"
}

resource "google_redis_instance" "cache" {
  name           = "${local.prefix}-redis"
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_gb
  region         = var.region

  authorized_network      = google_compute_network.vpc.id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  transit_encryption_mode = var.redis_transit_encryption
  auth_enabled            = true

  redis_version = "REDIS_7_0"
  labels        = local.labels

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 8
        minutes = 0
      }
    }
  }

  depends_on = [google_service_networking_connection.private_services]
}
