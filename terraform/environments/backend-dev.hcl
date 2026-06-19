# terraform init -backend-config=environments/backend-dev.hcl
# The bucket must exist first (create once per RUNBOOK "Bootstrap state bucket").
bucket = "<GCP_PROJECT_ID_DEV>-tfstate"
prefix = "caldiy/dev"
