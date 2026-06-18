# Private VPC for cal.diy. Cloud SQL and Memorystore get PRIVATE IPs only
# (no public IP). Cloud Run reaches them through a Serverless VPC Access
# connector. This keeps the database off the public internet (HIPAA: network
# isolation, least privilege).

resource "google_compute_network" "vpc" {
  name                    = "${local.prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.enabled]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${local.prefix}-subnet"
  ip_cidr_range = "10.20.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id

  # Flow logs for audit/forensics (no payload, metadata only — PHI-safe).
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
  private_ip_google_access = true
}

# --- Serverless VPC Access connector: Cloud Run -> private SQL/Redis --------
resource "google_vpc_access_connector" "connector" {
  name          = "${local.prefix}-vpcc"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.21.0.0/28" # /28 dedicated to the connector
  min_instances = 2
  max_instances = local.is_prod ? 6 : 3
  depends_on    = [google_project_service.enabled]
}

# --- Private Services Access: VPC peering range for managed services -------
resource "google_compute_global_address" "private_services" {
  name          = "${local.prefix}-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
  depends_on              = [google_project_service.enabled]
}

# --- Egress to the AWS app (webhooks) flows over the public internet via the
# default route; no NAT needed for Cloud Run egress unless we pin egress IPs.
# If you later require a STABLE source IP for cal -> AWS webhook calls (e.g. to
# allowlist on the AWS WAF), add a Cloud Router + Cloud NAT here and set the
# Cloud Run service vpc egress to ALL_TRAFFIC. Left out by default (the webhook
# is HMAC-authenticated, so source-IP pinning is defense-in-depth, not required).
