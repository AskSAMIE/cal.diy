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
| `cloud_run_proxy.tf` | auth-swap proxy — public, IAM-gated to the AWS caller (+ the platform's Cloud Run runtime SA when `platform_runtime_sa_email` is set) |
| `migrate_job.tf` | Cloud Run Job: `prisma migrate deploy` |
| `provision_job.tf` / `provision_provider_job.tf` | Cloud Run Jobs: platform OAuth client (+ outbound webhook) and per-provider user provisioning |
| `lb.tf` | external HTTPS LB + IAP in front of the web (admin) UI (`enable_web_lb`) |
| `logging.tf` | audit logs → 6-year bucket; Data Access logs |
| `outputs.tf` | URLs, WIF wiring, secret names (no secret values) |
| `environments/` | `dev.tfvars`, `prod.tfvars`, `backend-*.hcl` |

## Which environment is live

**The stack named `dev` is production.** There is exactly one cal.diy
deployment; it lives in project `asksamie-prod` under the `caldiy-dev-*` prefix
(state `gs://asksamie-prod-tfstate/caldiy/dev`) and serves real booking
traffic. `environments/dev.tfvars` holds the real, live values. `prod.tfvars` /
`backend-prod.hcl` are unused placeholders kept for a possible future
rename/split — do not apply them.

## Usage

```bash
ENV=dev   # the live stack; see above
terraform init -backend-config=environments/backend-${ENV}.hcl
terraform plan  -var-file=environments/${ENV}.tfvars
terraform apply -var-file=environments/${ENV}.tfvars   # requires approval; see RUNBOOK gate
```

`plan` must report **`No changes`** against the live stack (or only the change
you are about to make). If it reports anything else, someone changed the stack
by hand — reconcile per [RUNBOOK §11](../RUNBOOK.md) before applying anything.
Credentials: the project is owned by `hello@asksamie.com`; run Terraform with
`GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token hello@asksamie.com)`
exported in the same shell (ADC may be a different account).

> First-time provisioning is **two-phase** (secret containers → populate values → DB
> user → full apply) and gated on the **GCP BAA** for prod. Follow
> [`../RUNBOOK.md` §3](../RUNBOOK.md) exactly — do not `apply` to prod ahead of it.

## Guardrails

- **No secrets in state:** the DB password and all runtime secrets are in Secret
  Manager; the SQL user is created during bootstrap, not by Terraform.
- **Only the app-container image is `ignore_changes`d:** CI rolls images via
  `gcloud run deploy` / `gcloud run jobs update --container …`; Terraform owns
  everything else. The ignore is on the **app** container (`containers[1]` on
  web/api and the migrate/provision jobs — `[0]` is the cloudsql-proxy sidecar,
  which Terraform pins; `[0]` on the single-container proxy). The `*_image`
  values in tfvars are create-time bootstrap digests, not what is live (except
  for the provision-provider job, whose image Terraform still owns).
- **Service-level `scaling` is ignored on the three services.** The API reports a
  default `{manual_instance_count=0, min_instance_count=0}` block on any service
  touched by gcloud/console; it has no effect (`template.scaling` is what
  counts) and the provider cannot express "absent". Template scaling, memory,
  CPU, labels and the SQL tier are **not** ignored — they are encoded in tfvars.
- **Sizing lives in tfvars, nowhere else.** See "Drift and the sizing rule".
- **CMEK keys have `prevent_destroy`.** Cloud SQL prod has `deletion_protection`.
- Validated with `terraform validate` (offline). A real `plan` needs project creds.

## Drift and the sizing rule

**What happened.** The last Terraform apply of the June 2026 build was followed
by hand-resizing in gcloud/console (all current revisions were created by
`hello@` on 2026-06-22..24): api went to min 2 / max 20 and 1 Gi, web to max 4,
the proxy to min 1 / max 10, Cloud SQL to REGIONAL `db-custom-2-7680`, secret
rotations bumped `keyrev`/`oauthsecret` labels on the proxy (which gcloud mirrors
onto the revision template), and the provision job was applied from an unmerged
branch. Meanwhile the committed `dev.tfvars` still held `<PLACEHOLDER>` values,
so nobody could run a plan from a clean clone, and the image `ignore_changes`
pointed at the sidecar instead of the app container. By October a full plan
proposed to roll every service back to dev defaults, shrink the production
database, and re-pin images. Reconciled on 2026-10-29 by encoding the live values
(config was changed to match live; no resource was changed).

**The rule going forward.**

1. Every sizing change (instances, CPU, memory, SQL tier/HA, labels, env) is a
   change to `environments/dev.tfvars` (or a `.tf`) followed by `terraform apply`.
2. `gcloud run services update`, `gcloud run jobs update` (other than CI's
   `--container <app> --image …`) and console edits are **break-glass only**.
   If you must, write the same value into tfvars and `plan` to `No changes`
   **the same day**; a stale plan is an outage waiting for the next apply.
3. Image rolls stay with CI (`gcloud run deploy`) for now; the real fix is
   Terraform-as-deployer (CI runs `terraform apply -var api_image=…`), at which
   point the image `ignore_changes` go away. Track that as a follow-up.
4. Before any apply: `terraform plan` must show only the change you intend.
