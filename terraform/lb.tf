# External HTTPS load balancer + IAP in front of the cal WEB (admin) service.
#
# Public path:  browser -> HTTPS LB (Google-managed cert) -> IAP (Google login)
#               -> Cloud Run web (reachable ONLY via the LB).
# The run.app URL is blocked (web ingress = INTERNAL_AND_CLOUD_LOAD_BALANCING),
# so the only way in is the LB, and IAP gates it with your Google identity BEFORE
# cal loads. This is the "no public admin surface" posture.
#
# IAP uses Google-managed OAuth (the legacy IAP OAuth-brand APIs were shut down
# March 2026) — no oauth client to create.
#
# All resources are gated on var.enable_web_lb so the rest of the stack can be
# applied before the domain/DNS exists.

resource "google_compute_global_address" "web_lb_ip" {
  count = var.enable_web_lb ? 1 : 0
  name  = "${local.prefix}-web-lb-ip"
}

resource "google_compute_region_network_endpoint_group" "web_neg" {
  count                 = var.enable_web_lb ? 1 : 0
  name                  = "${local.prefix}-web-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_v2_service.web.name
  }
}

resource "google_compute_backend_service" "web" {
  count                 = var.enable_web_lb ? 1 : 0
  name                  = "${local.prefix}-web-be"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"

  backend {
    group = google_compute_region_network_endpoint_group.web_neg[0].id
  }

  # Google-managed IAP (no OAuth client needed).
  iap {
    enabled = true
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "web" {
  count           = var.enable_web_lb ? 1 : 0
  name            = "${local.prefix}-web-urlmap"
  default_service = google_compute_backend_service.web[0].id
}

resource "google_compute_managed_ssl_certificate" "web" {
  count = var.enable_web_lb ? 1 : 0
  name  = "${local.prefix}-web-cert"
  managed {
    domains = [var.web_domain]
  }
}

resource "google_compute_target_https_proxy" "web" {
  count            = var.enable_web_lb ? 1 : 0
  name             = "${local.prefix}-web-https-proxy"
  url_map          = google_compute_url_map.web[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.web[0].id]
}

resource "google_compute_global_forwarding_rule" "web_https" {
  count                 = var.enable_web_lb ? 1 : 0
  name                  = "${local.prefix}-web-fr-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.web[0].id
  port_range            = "443"
  ip_address            = google_compute_global_address.web_lb_ip[0].address
}

# HTTP :80 -> HTTPS redirect
resource "google_compute_url_map" "web_redirect" {
  count = var.enable_web_lb ? 1 : 0
  name  = "${local.prefix}-web-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "web" {
  count   = var.enable_web_lb ? 1 : 0
  name    = "${local.prefix}-web-http-proxy"
  url_map = google_compute_url_map.web_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "web_http" {
  count                 = var.enable_web_lb ? 1 : 0
  name                  = "${local.prefix}-web-fr-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_http_proxy.web[0].id
  port_range            = "80"
  ip_address            = google_compute_global_address.web_lb_ip[0].address
}

# Who may pass IAP into the admin UI.
resource "google_iap_web_backend_service_iam_member" "web_admins" {
  for_each            = var.enable_web_lb ? toset(var.admin_members) : []
  web_backend_service = google_compute_backend_service.web[0].name
  role                = "roles/iap.httpsResourceAccessor"
  member              = each.value
}

output "web_lb_ip" {
  description = "Static IP for the web LB. Point the web_domain A record (Cloudflare, DNS-only) at this."
  value       = var.enable_web_lb ? google_compute_global_address.web_lb_ip[0].address : null
}
