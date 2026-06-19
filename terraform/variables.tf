# ---------------------------------------------------------------------------
# Inputs. Per-environment values live in environments/<env>.tfvars.
# Secret *values* are never passed here — only the names of Secret Manager
# secrets, whose versions are populated out-of-band (see RUNBOOK).
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "Existing GCP project ID that hosts the cal.diy deployment."
  type        = string
}

variable "region" {
  description = "Primary GCP region (Cloud Run, Cloud SQL, Memorystore, Artifact Registry)."
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Deployment environment label: dev | prod. Drives resource naming and sizing."
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be one of: dev, prod."
  }
}

variable "name_prefix" {
  description = "Resource name prefix. Combined with environment, e.g. caldiy-dev-*."
  type        = string
  default     = "caldiy"
}

# ---- Public URLs (PHI-free; these are hostnames, not secrets) -------------

variable "webapp_url" {
  description = <<-EOT
    Public base URL of the cal.diy WEB app (e.g. https://cal-dev.internal.example.com).
    This is baked at image BUILD time (NEXT_PUBLIC_WEBAPP_URL) and re-asserted at
    runtime via scripts/start.sh. In the headless-API model the web app is admin-only
    (IAP-gated); this URL is still required for NextAuth callbacks and email links.
    Docs: apps/docs/content/docker.mdx (Build-time variables).
  EOT
  type        = string
}

variable "api_v2_public_url" {
  description = <<-EOT
    Public base URL of the cal.diy API v2 service (e.g. https://cal-api-dev.example.com).
    This is what the AWS app's CAL_API_BASE_URL points at (server-to-server). The API
    serves /v2/* (REWRITE_API_V2_PREFIX=1 rewrites /api/v2 -> /v2).
  EOT
  type        = string
}

# ---- Cross-cloud ingress lockdown (hop #1: AWS -> cal API v2) --------------

variable "api_ingress_mode" {
  description = <<-EOT
    How the cal API v2 is exposed and locked down:
      "armor"    - external HTTPS LB + Cloud Armor IP allowlist (aws_nat_egress_cidrs)
                   + cal's own Bearer key. Simplest defensible cross-cloud option.
                   Migration-clean: flip to "internal" once the AWS app moves to GCP.
      "internal" - Cloud Run ingress = INTERNAL_AND_CLOUD_LOAD_BALANCING, no public
                   LB. Only reachable from within the GCP VPC. Use after the app is
                   co-located on GCP (or fronted by VPN/Interconnect).
  EOT
  type        = string
  default     = "armor"
  validation {
    condition     = contains(["armor", "internal"], var.api_ingress_mode)
    error_message = "api_ingress_mode must be one of: armor, internal."
  }
}

variable "aws_nat_egress_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach the cal API v2 when api_ingress_mode = "armor".
    These MUST be your AWS ECS NAT gateway egress IP(s) as /32s (allocate stable EIPs).
    Empty list => Cloud Armor denies all (fail closed). Never use 0.0.0.0/0 with PHI.
  EOT
  type        = list(string)
  default     = []
}

variable "api_domain" {
  description = "FQDN for the managed cert on the API LB (armor mode). e.g. cal-api-dev.example.com."
  type        = string
  default     = ""
}

# ---- Encryption -----------------------------------------------------------

variable "use_cmek" {
  description = "Use customer-managed encryption keys (Cloud KMS) for Cloud SQL. false = Google-managed."
  type        = bool
  default     = true
}

variable "kms_key_rotation_period" {
  description = "CMEK rotation period (seconds). 90 days default."
  type        = string
  default     = "7776000s"
}

# ---- Cloud SQL ------------------------------------------------------------

variable "sql_ssl_mode" {
  description = <<-EOT
    Cloud SQL ssl_mode. ENCRYPTED_ONLY (prod) requires TLS — but cal's Prisma JS
    driver adapter verifies the server cert and has no CA, so it fails unless the
    Cloud SQL CA is injected (prod follow-up). For dev, ALLOW_UNENCRYPTED_AND_ENCRYPTED
    lets Prisma connect plaintext over the PRIVATE VPC (acceptable for synthetic data).
  EOT
  type        = string
  default     = "ENCRYPTED_ONLY"
}

variable "sql_edition" {
  description = "Cloud SQL edition. ENTERPRISE supports db-custom-* tiers; ENTERPRISE_PLUS needs db-perf-optimized-*."
  type        = string
  default     = "ENTERPRISE"
}

variable "sql_tier" {
  description = "Cloud SQL machine tier (ENTERPRISE). dev: db-custom-1-3840, prod: db-custom-2-7680 (set per-env)."
  type        = string
  default     = "db-custom-1-3840"
}

variable "sql_availability_type" {
  description = "ZONAL (dev) or REGIONAL (prod HA)."
  type        = string
  default     = "ZONAL"
}

variable "sql_disk_size_gb" {
  description = "Cloud SQL data disk size (GB). Autoresize is enabled."
  type        = number
  default     = 10
}

variable "sql_backup_retention_days" {
  description = "Cloud SQL automated backup retention. HIPAA: keep generous; PITR enabled."
  type        = number
  default     = 14
}

variable "sql_deletion_protection" {
  description = "Block accidental Cloud SQL deletion. Keep true in prod."
  type        = bool
  default     = true
}

variable "db_name" {
  description = "Application database name inside Cloud SQL."
  type        = string
  default     = "calendso"
}

variable "db_user" {
  description = "Application DB user cal.diy connects as."
  type        = string
  default     = "calcom"
}

# ---- Memorystore (Redis) — REQUIRED for API v2 to boot --------------------

variable "redis_tier" {
  description = "Memorystore tier: BASIC (dev) or STANDARD_HA (prod)."
  type        = string
  default     = "BASIC"
}

variable "redis_memory_gb" {
  description = "Memorystore capacity (GB)."
  type        = number
  default     = 1
}

# ---- Cloud Run sizing -----------------------------------------------------

variable "web_min_instances" {
  description = "Web service min instances. >=1 avoids Prisma/Next cold starts (brief requirement)."
  type        = number
  default     = 1
}

variable "web_max_instances" {
  description = "Web service max instances."
  type        = number
  default     = 4
}

variable "api_min_instances" {
  description = "API v2 min instances. >=1 keeps Prisma/Redis connections warm."
  type        = number
  default     = 1
}

variable "api_max_instances" {
  description = "API v2 max instances."
  type        = number
  default     = 10
}

variable "web_cpu" {
  description = "Web container CPU."
  type        = string
  default     = "2"
}

variable "web_memory" {
  description = "Web container memory."
  type        = string
  default     = "2Gi"
}

variable "api_cpu" {
  description = "API v2 container CPU."
  type        = string
  default     = "1"
}

variable "api_memory" {
  description = "API v2 container memory."
  type        = string
  default     = "2Gi"
}

# ---- Images (set by CI to the pinned, vetted tag) -------------------------

variable "web_image" {
  description = "Fully-qualified web image (Artifact Registry). Set by CI to a pinned tag/digest."
  type        = string
}

variable "api_image" {
  description = "Fully-qualified API v2 image (Artifact Registry). Set by CI to a pinned tag/digest."
  type        = string
}

variable "proxy_image" {
  description = "Fully-qualified auth-swap proxy image (Artifact Registry). Set by CI to a pinned tag/digest."
  type        = string
}

variable "web_domain" {
  description = "Public hostname for the cal web (admin) UI behind the IAP'd HTTPS load balancer, e.g. cal.otconnected.com. Add an A record -> the LB static IP in Cloudflare (DNS-only)."
  type        = string
  default     = ""
}

variable "enable_web_lb" {
  description = "Create the external HTTPS LB + IAP in front of the web service. Requires web_domain set + DNS pointed at the LB IP."
  type        = bool
  default     = false
}

variable "web_ingress" {
  description = <<-EOT
    Ingress for the web (admin) service. Default INTERNAL_ONLY (no public surface).
    Set to INGRESS_TRAFFIC_ALL for dev so `gcloud run services proxy` can reach it —
    the service still requires authentication (no allUsers), so unauthenticated
    requests get 403; only admin Google identities get in. Prod should use IAP +
    internal LB instead of ALL.
  EOT
  type        = string
  default     = "INGRESS_TRAFFIC_INTERNAL_ONLY"
}

variable "admin_members" {
  description = <<-EOT
    IAM members granted run.invoker on the internal web app, so an admin can reach
    the booking/admin UI via `gcloud run services proxy` (authenticated tunnel; the
    web app is internal-ingress and never public). e.g. ["user:brandy@asksamie.com"].
  EOT
  type        = list(string)
  default     = []
}

# ---- Logging / audit ------------------------------------------------------

variable "log_retention_days" {
  description = <<-EOT
    Retention (days) for the dedicated cal.diy log bucket. HIPAA requires 6 years
    (audit). 2192 days ~= 6 years. Applies to access/audit logs routed to the bucket.
  EOT
  type        = number
  default     = 2192
}

# ---- Cross-cloud identity (WIF) -------------------------------------------

variable "aws_account_id" {
  description = "AWS account ID whose ECS task role federates in to call the cal API. (OT Connected: 463884832761)"
  type        = string
}

variable "aws_caller_assumed_role_arn" {
  description = <<-EOT
    The STS assumed-role ARN of the AWS ECS task role that calls cal, WITHOUT the
    session suffix. Used in the WIF principalSet binding. For OT Connected today:
    arn:aws:sts::463884832761:assumed-role/ecsTaskExecutionRole
    NOTE: ecsTaskExecutionRole is currently reused as the task role — see RUNBOOK
    for the recommendation to split out a dedicated, least-privilege task role.
  EOT
  type        = string
}

variable "github_repo" {
  description = "owner/repo allowed to deploy via GitHub Actions WIF. e.g. AskSAMIE/cal.diy"
  type        = string
  default     = "AskSAMIE/cal.diy"
}

variable "labels" {
  description = "Common resource labels."
  type        = map(string)
  default = {
    app        = "caldiy"
    managed-by = "terraform"
    compliance = "hipaa"
  }
}
