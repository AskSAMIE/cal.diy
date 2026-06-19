# cal.diy GCP infrastructure (Terraform)

GCP infrastructure for the self-hosted **cal.diy** scheduling engine. Parameterized
for **dev** and **prod**. State lives in a GCS backend (per-env prefix). Full
operations in [`../RUNBOOK.md`](../RUNBOOK.md).

## Layout

| File | What it provisions |
|---|---|
| `versions.tf` | TF ≥ 1.11, google/google-beta ~> 6.13, GCS backend |
| `variables.tf` / `main.tf` | inputs, providers, locals, secret-name map |
| `apis.tf` | enable HIPAA-eligible service APIs |
| `network.tf` | VPC, subnet (flow logs), Serverless VPC connector, private services access |
| `kms.tf` | CMEK keyring + Cloud SQL key (toggle `use_cmek`) |
| `sql.tf` | Cloud SQL Postgres 16 — **private IP**, CMEK, PITR, backups |
| `redis.tf` | Memorystore Redis (private, AUTH, TLS) — required by API v2 |
| `secrets.tf` | Secret Manager **containers** (values populated out-of-band) |
| `artifact_registry.tf` | private Docker repo (web/api/proxy images) |
| `iam.tf` | runtime + federated SAs, **WIF** (AWS + GitHub), least-privilege bindings |
| `cloud_run_api.tf` | cal API v2 — **internal ingress** |
| `cloud_run_web.tf` | cal web — internal ingress, admin-only |
| `cloud_run_proxy.tf` | auth-swap proxy — public, IAM-gated to the AWS caller |
| `migrate_job.tf` | Cloud Run Job: `prisma migrate deploy` |
| `logging.tf` | audit logs → 6-year bucket; Data Access logs |
| `outputs.tf` | URLs, WIF wiring, secret names (no secret values) |
| `environments/` | `dev.tfvars`, `prod.tfvars`, `backend-*.hcl` |

## Usage

```bash
ENV=dev   # or prod
terraform init -backend-config=environments/backend-${ENV}.hcl
terraform plan  -var-file=environments/${ENV}.tfvars
terraform apply -var-file=environments/${ENV}.tfvars   # requires approval; see RUNBOOK gate
```

> First-time provisioning is **two-phase** (secret containers → populate values → DB
> user → full apply) and gated on the **GCP BAA** for prod. Follow
> [`../RUNBOOK.md` §3](../RUNBOOK.md) exactly — do not `apply` to prod ahead of it.

## Guardrails

- **No secrets in state:** the DB password and all runtime secrets are in Secret
  Manager; the SQL user is created during bootstrap, not by Terraform.
- **Images are `ignore_changes`d:** CI rolls image tags via `gcloud run deploy`;
  Terraform owns everything else. Don't fight it by setting image in tfvars beyond bootstrap.
- **CMEK keys have `prevent_destroy`.** Cloud SQL prod has `deletion_protection`.
- Validated with `terraform validate` (offline). A real `plan` needs project creds.
