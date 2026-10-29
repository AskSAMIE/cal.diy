# ---- dev environment -------------------------------------------------------
# Fill the <PLACEHOLDER> values. Image vars are normally overridden by CI; the
# values here are just the initial bootstrap tags.

project_id  = "asksamie-prod" # co-located in the prod project per owner decision; dev-sized, synthetic data only until BAA
region      = "us-central1"
environment = "dev"

# Public hostnames (PHI-free). In the headless model the web app is admin-only;
# these are still needed for NextAuth callbacks and the API base URL the proxy
# fronts. Use real DNS you control, or the eventual cal domains.
webapp_url        = "https://cal.otconnected.com"
api_v2_public_url = "https://cal-api-dev.otconnected.com"

# Cross-cloud identity (OT Connected AWS account).
aws_account_id              = "463884832761"
aws_caller_assumed_role_arn = "arn:aws:sts::463884832761:assumed-role/ecsTaskExecutionRole"
github_repo                 = "AskSAMIE/cal.diy"

# AskSAMIE platform runtime SA on GCP Cloud Run (calls the proxy directly, no WIF).
# This "dev"-named stack is the single live cal instance that serves production
# (co-located in the asksamie-prod project), so the platform-PROD SA belongs here.
platform_runtime_sa_email = "platform-run@asksamie-platform-prod.iam.gserviceaccount.com"

# Encryption / data stores.
use_cmek                = true
sql_tier                = "db-custom-1-3840"
sql_availability_type   = "ZONAL"
sql_disk_size_gb        = 10
sql_deletion_protection = false
redis_tier              = "BASIC"
redis_memory_gb         = 1

# Cloud Run sizing (dev: keep 1 warm to avoid cold starts, low ceilings).
web_min_instances = 1
web_max_instances = 2
api_min_instances = 1
api_max_instances = 3

# Admin who can tunnel to the internal web UI.
admin_members = ["user:hello@asksamie.com"]

# Images — CI overrides these via -var on deploy. Bootstrap placeholders:
web_image   = "us-central1-docker.pkg.dev/asksamie-prod/caldiy-dev-images/web@sha256:6a353303e8237294f8f1af010c22ddf40493325042a9056d70ab53d94b6b8fa7"
api_image   = "us-central1-docker.pkg.dev/asksamie-prod/caldiy-dev-images/api@sha256:67bce1dda3ee401894dcb808ae035958db2f8dc7817d348c23afbf8c1b2a8d77"
proxy_image = "us-central1-docker.pkg.dev/asksamie-prod/caldiy-dev-images/proxy@sha256:e3f658edc8544cfa93688a21a62e8aaf19c31328286ce49adda9c908f1f9f8ce"

# dev: reachable for `gcloud run services proxy` but still auth-required (403 for the public)
web_ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

# web admin UI behind IAP'd HTTPS LB
web_domain    = "cal.otconnected.com"
enable_web_lb = true

# platform oauth client provisioning
provision_redirect_uris = "https://cal.otconnected.com,https://otconnected.com"

provision_webhook_url   = "https://dev.otconnected.com/api/webhooks/cal"
