# Customer-managed encryption keys (CMEK) for Cloud SQL.
# Toggle with var.use_cmek (false => Google-managed encryption, still HIPAA-eligible).
#
# The Cloud SQL service agent must be granted encrypt/decrypt on the key BEFORE
# the instance is created, or the create fails.

resource "google_kms_key_ring" "keyring" {
  count    = var.use_cmek ? 1 : 0
  name     = "${local.prefix}-keyring"
  location = var.region
  project  = var.project_id

  depends_on = [google_project_service.enabled]
}

resource "google_kms_crypto_key" "sql" {
  count           = var.use_cmek ? 1 : 0
  name            = "${local.prefix}-sql-cmek"
  key_ring        = google_kms_key_ring.keyring[0].id
  rotation_period = var.kms_key_rotation_period
  purpose         = "ENCRYPT_DECRYPT"

  labels = local.labels

  lifecycle {
    prevent_destroy = true
  }
}

# Cloud SQL service agent identity (per-project, per-service).
resource "google_project_service_identity" "sql_sa" {
  count    = var.use_cmek ? 1 : 0
  provider = google-beta
  project  = var.project_id
  service  = "sqladmin.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "sql_cmek" {
  count         = var.use_cmek ? 1 : 0
  crypto_key_id = google_kms_crypto_key.sql[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.sql_sa[0].email}"
}
