# Enable the GCP APIs this stack needs. All listed services are HIPAA-eligible
# under the Google Cloud BAA (see RUNBOOK "HIPAA-eligible services").
#
# disable_on_destroy = false so a `terraform destroy` of this stack does not
# yank APIs out from under other workloads in the project.

locals {
  required_apis = [
    "run.googleapis.com",               # Cloud Run
    "sqladmin.googleapis.com",          # Cloud SQL
    "redis.googleapis.com",             # Memorystore
    "secretmanager.googleapis.com",     # Secret Manager
    "artifactregistry.googleapis.com",  # Artifact Registry (image store)
    "cloudkms.googleapis.com",          # CMEK
    "vpcaccess.googleapis.com",         # Serverless VPC Access connector
    "servicenetworking.googleapis.com", # Private services access (Cloud SQL/Redis private IP)
    "compute.googleapis.com",           # VPC, LB, Cloud Armor
    "iam.googleapis.com",
    "iamcredentials.googleapis.com", # WIF / token minting (alt auth path)
    "sts.googleapis.com",            # Workload Identity Federation
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
