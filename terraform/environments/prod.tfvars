# ---- prod environment ------------------------------------------------------
# DO NOT apply to prod until the GCP BAA is signed (see RUNBOOK gate).

project_id  = "<GCP_PROJECT_ID_PROD>"
region      = "us-central1"
environment = "prod"

webapp_url        = "https://cal.otconnected.com"
api_v2_public_url = "https://cal-api.otconnected.com"

aws_account_id              = "463884832761"
aws_caller_assumed_role_arn = "arn:aws:sts::463884832761:assumed-role/ecsTaskExecutionRole"
github_repo                 = "AskSAMIE/cal.diy"

# Encryption / data stores (prod: HA + deletion protection).
use_cmek                  = true
sql_tier                  = "db-custom-2-7680"
sql_availability_type     = "REGIONAL"
sql_disk_size_gb          = 20
sql_backup_retention_days = 30
sql_deletion_protection   = true
redis_tier                = "STANDARD_HA"
redis_memory_gb           = 1

web_min_instances = 1
web_max_instances = 4
api_min_instances = 1
api_max_instances = 10

admin_members = ["user:brandy@asksamie.com"]

web_image   = "us-central1-docker.pkg.dev/<GCP_PROJECT_ID_PROD>/caldiy-prod-images/web:bootstrap"
api_image   = "us-central1-docker.pkg.dev/<GCP_PROJECT_ID_PROD>/caldiy-prod-images/api:bootstrap"
proxy_image = "us-central1-docker.pkg.dev/<GCP_PROJECT_ID_PROD>/caldiy-prod-images/proxy:bootstrap"
