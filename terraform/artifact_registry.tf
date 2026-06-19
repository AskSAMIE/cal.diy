# Artifact Registry: private Docker repo for the pinned, vetted images
# (web, api-v2, auth-proxy). CI builds and pushes here; Cloud Run pulls from here.
# Images are pinned to a vetted tag/digest of our fork — we never auto-track upstream.
#
# Encryption: Google-managed keys. The image layers are not PHI (they're our
# container builds), so we don't take on the CMEK service-agent plumbing here.
# CMEK is reserved for the Cloud SQL data store (the PHI at rest).

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "${local.prefix}-images"
  format        = "DOCKER"
  description   = "cal.diy container images (web, api-v2, auth-proxy) for ${var.environment}"
  labels        = local.labels

  depends_on = [google_project_service.enabled]
}
