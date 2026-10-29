# terraform init -backend-config=environments/backend-dev.hcl
# The bucket must exist first (create once per RUNBOOK "Bootstrap state bucket").
bucket = "asksamie-prod-tfstate"
prefix = "caldiy/dev"
