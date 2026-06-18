# Non-sensitive outputs. NO secret values are ever output (brief constraint).

output "proxy_url" {
  description = "Public URL of the auth-swap proxy. This is the AWS app's CAL_API_BASE_URL (hop #1)."
  value       = google_cloud_run_v2_service.proxy.uri
}

output "api_internal_url" {
  description = "Internal-only URL of the cal API v2 (reachable only via the proxy over the VPC)."
  value       = google_cloud_run_v2_service.api.uri
}

output "web_internal_url" {
  description = "Internal-only URL of the cal web app (admin via `gcloud run services proxy`)."
  value       = google_cloud_run_v2_service.web.uri
}

output "sql_instance_connection_name" {
  description = "Cloud SQL instance connection name."
  value       = google_sql_database_instance.main.connection_name
}

output "sql_private_ip" {
  description = "Cloud SQL private IP (used to assemble the DATABASE_URL secret — see RUNBOOK)."
  value       = google_sql_database_instance.main.private_ip_address
}

output "redis_host" {
  description = "Memorystore host (used to assemble the REDIS_URL secret — see RUNBOOK)."
  value       = google_redis_instance.cache.host
}

output "redis_port" {
  description = "Memorystore port."
  value       = google_redis_instance.cache.port
}

output "artifact_registry_repo" {
  description = "Artifact Registry Docker repo path for CI pushes."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "migrate_job_name" {
  description = "Cloud Run Job name for `prisma migrate deploy` (CI executes this before deploy)."
  value       = google_cloud_run_v2_job.migrate.name
}

# ---- WIF wiring for the AWS app and for CI ----
output "wif_provider_aws" {
  description = "Full resource name of the AWS WIF provider (audience for the AWS app's STS exchange)."
  value       = "projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.main.workload_identity_pool_id}/providers/aws-ecs"
}

output "wif_provider_github" {
  description = "Full resource name of the GitHub Actions WIF provider (for the deploy workflow)."
  value       = "projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.main.workload_identity_pool_id}/providers/github-actions"
}

output "aws_caller_service_account" {
  description = "SA the AWS ECS task role impersonates to invoke the proxy."
  value       = google_service_account.aws_caller.email
}

output "ci_deployer_service_account" {
  description = "SA GitHub Actions impersonates to push images + deploy."
  value       = google_service_account.ci_deployer.email
}

output "secret_ids" {
  description = "Names of the Secret Manager secrets to populate out-of-band (see RUNBOOK)."
  value       = { for k, v in google_secret_manager_secret.this : k => v.secret_id }
}
