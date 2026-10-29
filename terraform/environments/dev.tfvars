# ---- "dev" environment = THE live cal instance (production) --------------
# Despite the name, this stack is the single cal.diy deployment and it serves
# production booking traffic. It is co-located in the asksamie-prod project
# (owner decision); the prod.tfvars/prefix is unused. Every value below is the
# LIVE value as reconciled on 2026-10-29 (see ../README.md "Drift and the
# sizing rule"): a sizing change is a tfvars change + `terraform apply`, never
# a gcloud/console edit.

project_id  = "asksamie-prod"
region      = "us-central1"
environment = "dev"

# Public hostnames (PHI-free). In the headless model the web app is admin-only;
# these are still needed for NextAuth callbacks and the API base URL the proxy
# fronts.
webapp_url        = "https://cal.otconnected.com"
api_v2_public_url = "https://cal-api-dev.otconnected.com"

# Cross-cloud identity (OT Connected AWS account).
aws_account_id              = "463884832761"
aws_caller_assumed_role_arn = "arn:aws:sts::463884832761:assumed-role/ecsTaskExecutionRole"
github_repo                 = "AskSAMIE/cal.diy"

# AskSAMIE platform runtime SA on GCP Cloud Run (calls the proxy directly, no WIF).
# This stack serves production, so the platform-PROD SA belongs here.
platform_runtime_sa_email = "platform-run@asksamie-platform-prod.iam.gserviceaccount.com"

# Encryption / data stores.
use_cmek                = true
sql_tier                = "db-custom-1-3840"
sql_availability_type   = "ZONAL"
sql_disk_size_gb        = 10
sql_deletion_protection = false
redis_tier              = "BASIC"
redis_memory_gb         = 1

# Cloud Run sizing — live values (hand-set via gcloud/console 2026-06-22..24,
# reconciled into tfvars 2026-10-29). Change HERE, then apply.
web_min_instances   = 1
web_max_instances   = 4
api_min_instances   = 2
api_max_instances   = 20
api_memory          = "1Gi" # live; the variable default (2Gi) is NOT what runs
proxy_min_instances = 1
proxy_max_instances = 10

# Proxy revision-template rotation markers (bumped by hand during the June 2026
# key/OAuth-secret rotations). Bump one here + apply to roll a proxy revision.
proxy_revision_labels = {
  keyrev      = "1"
  oauthsecret = "v2"
}

# Admins allowed through IAP into the cal web (admin) UI.
admin_members = ["user:hello@asksamie.com"]

# Images — create-time/bootstrap values only. The app containers of web, api,
# proxy and the migrate + provision jobs are rolled out-of-band (CI
# `gcloud run deploy` / hand deploys) and are `ignore_changes`d, so the digests
# below are NOT what is live for those; read the live digest with
#   gcloud run services describe caldiy-dev-<svc> --region us-central1 \
#     --format='value(spec.template.spec.containers[].image)'
# web_image IS still authoritative for the provision-provider job (not ignored).
web_image   = "us-central1-docker.pkg.dev/asksamie-prod/caldiy-dev-images/web@sha256:6a353303e8237294f8f1af010c22ddf40493325042a9056d70ab53d94b6b8fa7"
api_image   = "us-central1-docker.pkg.dev/asksamie-prod/caldiy-dev-images/api@sha256:67bce1dda3ee401894dcb808ae035958db2f8dc7817d348c23afbf8c1b2a8d77"
proxy_image = "us-central1-docker.pkg.dev/asksamie-prod/caldiy-dev-images/proxy@sha256:e3f658edc8544cfa93688a21a62e8aaf19c31328286ce49adda9c908f1f9f8ce"

# Web ingress: only via the IAP'd HTTPS LB (run.app URL is dead).
web_ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

# web admin UI behind IAP'd HTTPS LB
web_domain    = "cal.otconnected.com"
enable_web_lb = true

# Platform OAuth client provisioning (provision job).
provision_redirect_uris = "https://cal.otconnected.com,https://otconnected.com"

provision_webhook_url = "https://dev.otconnected.com/api/webhooks/cal"
