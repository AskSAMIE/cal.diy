# terraform init -backend-config=environments/backend-prod.hcl
# The bucket must exist first (create once per RUNBOOK "Bootstrap state bucket").
bucket = "<GCP_PROJECT_ID_PROD>-tfstate"
prefix = "caldiy/prod"
