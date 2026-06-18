# Artifact Registry: private Docker repo for the pinned, vetted images
# (web, api-v2, auth-proxy). CI builds and pushes here; Cloud Run pulls from here.
# Images are pinned to a vetted tag/digest of our fork — we never auto-track upstream.

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "${local.prefix}-images"
  format        = "DOCKER"
  description   = "cal.diy container images (web, api-v2, auth-proxy) for ${var.environment}"
  labels        = local.labels

  # Optional CMEK on the image layers; reuse the SQL keyring when CMEK is on.
  kms_key_name = var.use_cmek ? google_kms_crypto_key.sql[0].id : null

  depends_on = [
    google_project_service.enabled,
    google_kms_crypto_key_iam_member.artifact_registry_cmek,
  ]
}

# Artifact Registry service agent needs encrypt/decrypt when CMEK is on.
resource "google_project_service_identity" "artifact_registry_sa" {
  count    = var.use_cmek ? 1 : 0
  provider = google-beta
  project  = var.project_id
  service  = "artifactregistry.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "artifact_registry_cmek" {
  count         = var.use_cmek ? 1 : 0
  crypto_key_id = google_kms_crypto_key.sql[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.artifact_registry_sa[0].email}"
}
