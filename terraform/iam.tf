# Service accounts, Workload Identity Federation, and least-privilege bindings.
#
# Runtime SAs (one per service, no keys):
#   run_web   - cal.diy web app
#   run_api   - cal.diy API v2
#   run_proxy - auth-swap proxy (the only thing that may call the internal API)
#   migrate   - Cloud Run Job that runs `prisma migrate deploy`
#
# Federated SAs (no keys; identity comes from AWS/GitHub OIDC):
#   aws_caller - AWS ECS task role assumes this to invoke the proxy (hop #1)
#   ci_deployer - GitHub Actions assumes this to push images + deploy

data "google_project" "this" {
  project_id = var.project_id
}

# ---------------------------------------------------------------------------
# Runtime service accounts
# ---------------------------------------------------------------------------
resource "google_service_account" "run_web" {
  account_id   = "${local.prefix}-web"
  display_name = "cal.diy web runtime (${var.environment})"
}

resource "google_service_account" "run_api" {
  account_id   = "${local.prefix}-api"
  display_name = "cal.diy API v2 runtime (${var.environment})"
}

resource "google_service_account" "run_proxy" {
  account_id   = "${local.prefix}-proxy"
  display_name = "cal.diy auth-swap proxy runtime (${var.environment})"
}

resource "google_service_account" "migrate" {
  account_id   = "${local.prefix}-migrate"
  display_name = "cal.diy migration job (${var.environment})"
}

resource "google_service_account" "provision" {
  account_id   = "${local.prefix}-provision"
  display_name = "cal.diy platform-oauth provisioning job (${var.environment})"
}

# ---------------------------------------------------------------------------
# Federated service accounts
# ---------------------------------------------------------------------------
resource "google_service_account" "aws_caller" {
  account_id   = "${local.prefix}-aws-caller"
  display_name = "AWS ECS -> cal proxy invoker (${var.environment})"
}

resource "google_service_account" "ci_deployer" {
  account_id   = "${local.prefix}-ci"
  display_name = "GitHub Actions deployer (${var.environment})"
}

# ---------------------------------------------------------------------------
# Workload Identity Federation pool + providers
# ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "main" {
  workload_identity_pool_id = "${local.prefix}-wif"
  display_name              = "cal.diy WIF (${var.environment})"
  description               = "Federates AWS ECS (app runtime) and GitHub Actions (CI). No service-account keys."
  depends_on                = [google_project_service.enabled]
}

# --- AWS provider: the OT Connected ECS task role ---
resource "google_iam_workload_identity_pool_provider" "aws" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.main.workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-ecs"
  display_name                       = "AWS ECS"

  aws {
    account_id = var.aws_account_id
  }

  # Map the assumed-role ARN to a stable attribute we can bind on.
  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.aws_role" = "assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
  }

  # Only this AWS account may present tokens to this provider.
  attribute_condition = "attribute.aws_role.startsWith('arn:aws:sts::${var.aws_account_id}:assumed-role/')"
}

# Bind: the AWS ECS task role may impersonate aws_caller.
resource "google_service_account_iam_member" "aws_caller_wif" {
  service_account_id = google_service_account.aws_caller.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.main.name}/attribute.aws_role/${var.aws_caller_assumed_role_arn}"
}

# Let aws_caller mint ID tokens for ITSELF — the AWS app federates in, impersonates
# aws_caller, then needs generateIdToken (audience = proxy URL) to call the proxy.
resource "google_service_account_iam_member" "aws_caller_self_token" {
  service_account_id = google_service_account.aws_caller.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.aws_caller.email}"
}

# --- GitHub provider: CI deploys ---
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.main.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only our repo may present tokens.
  attribute_condition = "assertion.repository == '${var.github_repo}'"
}

# Bind: GitHub Actions from our repo may impersonate ci_deployer.
resource "google_service_account_iam_member" "ci_wif" {
  service_account_id = google_service_account.ci_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.main.name}/attribute.repository/${var.github_repo}"
}

# ---------------------------------------------------------------------------
# Project-level roles for the CI deployer (scoped to what a deploy needs)
# ---------------------------------------------------------------------------
locals {
  ci_roles = [
    "roles/artifactregistry.writer", # push images
    "roles/run.developer",           # deploy revisions + execute jobs
    "roles/iam.serviceAccountUser",  # actAs the runtime SAs on deploy
  ]
}

resource "google_project_iam_member" "ci_deployer" {
  for_each = toset(local.ci_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.ci_deployer.email}"
}

# ---------------------------------------------------------------------------
# Secret access — least privilege, per (service account, secret) pair
# ---------------------------------------------------------------------------
locals {
  # Which runtime SA may read which secret.
  secret_access = merge(
    # API v2 runtime
    { for s in [
      "database_url", "database_url_direct", "redis_url", "nextauth_secret",
      "encryption_key", "service_account_encryption_key", "jwt_secret", "redis_ca",
    ] : "api-${s}" => { sa = google_service_account.run_api.email, secret = s } },
    # Web runtime
    { for s in [
      "database_url", "database_url_direct", "nextauth_secret", "encryption_key",
      "service_account_encryption_key",
    ] : "web-${s}" => { sa = google_service_account.run_web.email, secret = s } },
    # Auth-swap proxy: only the two cal credentials it injects
    { for s in [
      "cal_api_key", "cal_oauth_client_secret",
    ] : "proxy-${s}" => { sa = google_service_account.run_proxy.email, secret = s } },
    # Migration job: the direct (non-pooled) DB URL
    { "migrate-database_url_direct" = { sa = google_service_account.migrate.email, secret = "database_url_direct" } },
    # Provisioning job: DB + the OAuth client secret it writes into the DB
    { "provision-database_url" = { sa = google_service_account.provision.email, secret = "database_url" } },
    { "provision-cal_oauth_client_secret" = { sa = google_service_account.provision.email, secret = "cal_oauth_client_secret" } },
  )
}

resource "google_secret_manager_secret_iam_member" "access" {
  for_each  = local.secret_access
  secret_id = google_secret_manager_secret.this[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value.sa}"
}

# ---------------------------------------------------------------------------
# Cloud SQL client role for runtimes that connect (web, api, migrate)
# (private IP is the network path; this role is required for the connector/IAM.)
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "cloudsql_client" {
  for_each = toset([
    google_service_account.run_web.email,
    google_service_account.run_api.email,
    google_service_account.migrate.email,
    google_service_account.provision.email,
  ])
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${each.value}"
}
