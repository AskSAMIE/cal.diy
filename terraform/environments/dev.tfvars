# ---- dev environment -------------------------------------------------------
# Fill the <PLACEHOLDER> values. Image vars are normally overridden by CI; the
# values here are just the initial bootstrap tags.

project_id  = "<GCP_PROJECT_ID_DEV>"
region      = "us-central1"
environment = "dev"

# Public hostnames (PHI-free). In the headless model the web app is admin-only;
# these are still needed for NextAuth callbacks and the API base URL the proxy
# fronts. Use real DNS you control, or the eventual cal domains.
webapp_url        = "https://cal-dev.otconnected.com"
api_v2_public_url = "https://cal-api-dev.otconnected.com"

# Cross-cloud identity (OT Connected AWS account).
aws_account_id              = "463884832761"
aws_caller_assumed_role_arn = "arn:aws:sts::463884832761:assumed-role/ecsTaskExecutionRole"
github_repo                 = "AskSAMIE/cal.diy"

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
admin_members = ["user:brandy@asksamie.com"]

# Images — CI overrides these via -var on deploy. Bootstrap placeholders:
web_image   = "us-central1-docker.pkg.dev/<GCP_PROJECT_ID_DEV>/caldiy-dev-images/web:bootstrap"
api_image   = "us-central1-docker.pkg.dev/<GCP_PROJECT_ID_DEV>/caldiy-dev-images/api:bootstrap"
proxy_image = "us-central1-docker.pkg.dev/<GCP_PROJECT_ID_DEV>/caldiy-dev-images/proxy:bootstrap"
