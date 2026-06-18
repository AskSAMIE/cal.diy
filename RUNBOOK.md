# cal.diy on GCP — Runbook

Operating the self-hosted **cal.diy** scheduling engine for **OT Connected**.
cal.diy runs on **GCP** (Cloud Run + Cloud SQL + Memorystore); the main app stays
on **AWS** (ECS + RDS) and remains the system of record. This is the first service
in the AWS→GCP migration.

- Infra: [`terraform/`](terraform) — see [`terraform/README.md`](terraform/README.md)
- CI: [`.github/workflows/caldiy-deploy.yml`](.github/workflows/caldiy-deploy.yml) (deploy), [`caldiy-terraform.yml`](.github/workflows/caldiy-terraform.yml) (infra)
- Auth-swap proxy: [`deploy/gcp/auth-proxy/`](deploy/gcp/auth-proxy)
- Integration contract: [`INTEGRATION-RECONCILIATION.md`](INTEGRATION-RECONCILIATION.md)

---

## 1. Architecture & trust boundaries

```
                         GCP project (HIPAA-eligible services only)
  ┌────────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  │   ┌──────────────┐   internal     ┌──────────────┐   private IP         │
  │   │ Cloud Run    │   ingress      │ Cloud Run    │──────────────┐       │
  │   │ auth-proxy   │──────────────▶ │ cal API v2   │              ▼       │
  │   │ (public,     │   VPC          │ (INTERNAL    │      ┌───────────────┐│
  │   │  IAM-gated)  │                │  only)       │      │ Cloud SQL PG  ││
  │   └──────▲───────┘                └──────────────┘      │ (PRIVATE IP,  ││
  │          │ run.invoker                  │ private IP    │  CMEK, PHI)   ││
  │          │ (aws_caller SA)              ▼               └───────────────┘│
  │          │                       ┌──────────────┐      ┌───────────────┐│
  │          │                       │ Memorystore  │      │ Secret Manager││
  │          │                       │ Redis (priv) │      │ (secrets)     ││
  │          │                       └──────────────┘      └───────────────┘│
  │          │                                                               │
  │   ┌──────────────┐  internal ingress + IAP/tunnel (admin only)          │
  │   │ Cloud Run    │  ◀── Brandy via `gcloud run services proxy`          │
  │   │ cal web app  │                                                       │
  │   └──────────────┘                                                       │
  └──────────┼───────────────────────────────────────────────────────────────┘
             │ hop #1: HTTPS + Google ID token (WIF)            hop #2: HTTPS + HMAC
   ┌─────────┴──────────┐                                ┌──────────────────────────┐
   │ AWS ECS (FastAPI)  │  cal → AWS webhook ───────────▶│ POST /api/webhooks/cal    │
   │ OT Connected app   │  X-Cal-Signature-256 (HMAC)    │ (HMAC-verified, AWS RDS)  │
   └────────────────────┘                                └──────────────────────────┘
```

**Two — and only two — cross-cloud paths:**

| Hop | Direction | Auth | Notes |
|---|---|---|---|
| #1 | AWS app → cal API v2 | **WIF**: AWS task role → Google ID token → Cloud Run IAM gates the **proxy**; proxy injects cal's key | cal API never faces the internet; AWS holds **no** long-lived cal secret |
| #2 | cal → AWS webhook | **HMAC-SHA256** over raw body, header `X-Cal-Signature-256` | AWS app verifies; secret = `*-cal-webhook-secret` |

**PHI lives in:** Cloud SQL (bookings = attendee name/email/phone/time; encrypted calendar OAuth tokens), Secret Manager (secrets), and short-lived Cloud Run request logs (kept PHI-free by design). Memorystore holds transient cache only.

**Why the proxy "allows unauthenticated" on the API:** cal reads its key from
`Authorization: Bearer`, which would collide with a Cloud Run IAM ID token. So the
**API** is locked down by **network** (internal ingress — only the proxy can reach
it over the VPC) + cal's **own** API-key check, while the **proxy** is the IAM-gated
public surface. See `terraform/cloud_run_api.tf` and `cloud_run_proxy.tf`.

---

## 2. HIPAA / compliance

> **⚠️ GATE — BAA before prod PHI.** A **Google Cloud BAA is not yet signed.** Do
> **not** route real patient bookings through the **prod** stack until it is.
> Accept the BAA in the Cloud Console: **IAM & Admin → Compliance → Business
> Associate Agreement** (Google Workspace/Cloud admin). dev may be stood up first
> with synthetic data only.

- **HIPAA-eligible services only:** Cloud Run, Cloud SQL, Memorystore, Secret Manager, Cloud KMS, Artifact Registry, Cloud Logging, VPC/Cloud Armor. (Enabled in `terraform/apis.tf`.) Do not add a service to this stack without confirming it is BAA-covered.
- **Encryption at rest:** Cloud SQL uses **CMEK** (`var.use_cmek = true`, Cloud KMS, 90-day rotation). Memorystore + Secret Manager use Google-managed keys (BAA-covered). Flip `use_cmek=false` only with a logged risk decision.
- **Encryption in transit:** TLS on both cross-cloud hops; Cloud SQL `ssl_mode = ENCRYPTED_ONLY`; Memorystore `transit_encryption_mode = SERVER_AUTHENTICATION` (set `var.redis_transit_encryption = "DISABLED"` only if the cal Redis client can't present TLS, and log the residual risk).
- **Network:** Cloud SQL + Memorystore have **no public IP** (private services access). cal API + web are **internal ingress**. Least-privilege service accounts, one per workload.
- **Audit logging — 6 years:** Cloud Audit Logs routed to a dedicated bucket with `log_retention_days = 2192`; Data Access logs on Secret Manager / Cloud SQL / Cloud Run (`terraform/logging.tf`).
- **PHI out of logs:** app log level `ERROR`; the proxy logs only `method path status latency` (never headers/query/body). Cloud SQL query insights run with `record_application_tags=false`, `record_client_address=false`. Keep example payloads in docs PHI-free.
- **Dedicated task role (follow-up):** AWS currently reuses `ecsTaskExecutionRole` as the task role. Create a dedicated least-privilege **task role**, then update `var.aws_caller_assumed_role_arn` and the WIF binding.

---

## 3. Bootstrap (one-time per environment)

Run from a workstation authenticated as a project **Owner/Editor** (`gcloud auth login`).
`PROJECT=<your dev or prod project id>`, `REGION=us-central1`, `ENV=dev|prod`.

### 3.1 State bucket (remote backend)

```bash
gcloud storage buckets create "gs://${PROJECT}-tfstate" \
  --project "$PROJECT" --location "$REGION" \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update "gs://${PROJECT}-tfstate" --versioning
```
Put `${PROJECT}-tfstate` into `terraform/environments/backend-${ENV}.hcl`.

### 3.2 Terraform admin identity for CI (optional, for the TF workflow)

Terraform creates IAM/SQL/KMS, so its SA is privileged and must be created before
the first run (it can't grant its own rights). Create it once, bind GitHub WIF, and
set `GCP_TF_*` env vars on the GitHub environment. (For the very first apply you can
instead run Terraform locally as yourself.)

### 3.3 Fill variables

Edit `terraform/environments/${ENV}.tfvars` — replace every `<PLACEHOLDER>`
(`project_id`, the `webapp_url`/`api_v2_public_url`, the image bootstrap paths).

### 3.4 Provision base infra (two-phase, because secrets aren't in state)

```bash
cd terraform
terraform init -backend-config=environments/backend-${ENV}.hcl

# Phase 1 — create the secret containers + APIs first
terraform apply -var-file=environments/${ENV}.tfvars \
  -target=google_project_service.enabled \
  -target=google_secret_manager_secret.this
```

Now **populate the secret values** (§4). Then:

```bash
# Phase 2 — full apply (Cloud Run needs secret versions + images to exist)
terraform apply -var-file=environments/${ENV}.tfvars
```

> First full apply will fail to bring up Cloud Run if the **images** don't exist yet.
> Either run the **Deploy** workflow once to build+push images first, or build/push
> the three images manually, then re-apply. (Cloud Run image is `ignore_changes`d, so
> CI owns it thereafter.)

### 3.5 Bootstrap the database user

Cloud SQL has no app user yet (we never put a password in TF state). Create it using
the password you stored in the `*-db-password` secret (§4):

```bash
DBPASS="$(gcloud secrets versions access latest --secret=caldiy-${ENV}-db-password --project $PROJECT)"
gcloud sql users create calcom --instance="caldiy-${ENV}-pg" --password="$DBPASS" --project $PROJECT
```

Then assemble the URL secrets (§4, `database-url` / `database-url-direct`) using
`terraform output sql_private_ip`.

### 3.6 Provision the Platform OAuth client (for managed users)

After the web app is up, sign in (admin), create an **Organization** and a **Platform
OAuth client**. Store the client **secret** in `*-cal-oauth-client-secret`, and give
the **clientId** to the AWS app as `CAL_OAUTH_CLIENT_ID` (non-secret). See
INTEGRATION-RECONCILIATION §3.

### 3.7 Configure the outbound webhook in cal

In the cal admin UI (or via API), create a webhook:
- URL: `https://<otconnected-app>/api/webhooks/cal`
- Secret: the `*-cal-webhook-secret` value
- Events: `BOOKING_CREATED, BOOKING_REQUESTED, BOOKING_PAID, BOOKING_RESCHEDULED, BOOKING_CANCELLED, BOOKING_NO_SHOW_UPDATED, MEETING_ENDED`
- **Then send a test delivery** and confirm the AWS app's raw-body HMAC verifies (INTEGRATION-RECONCILIATION §4).

### 3.8 Wire the AWS app

Set on the OT Connected ECS task:
- `CAL_API_BASE_URL` = `terraform output proxy_url`
- `CAL_WEBHOOK_SECRET` = the `*-cal-webhook-secret` value
- `CAL_OAUTH_CLIENT_ID` = the Platform OAuth clientId
- Configure the task to mint a Google **ID token** (audience = proxy URL) via WIF using
  `terraform output wif_provider_aws` + `aws_caller_service_account`, and send it as
  `Authorization: Bearer`. The proxy swaps in cal's real key. (`CAL_API_KEY` is **no
  longer needed on the AWS side** — the proxy holds it.)

---

## 4. Populate / rotate secrets

All values live in **Secret Manager**, never in the repo or TF state. List them:
`terraform output secret_ids`. Add a version (example pattern — **use real generated
values, never commit them**):

```bash
gen() { openssl rand -base64 32; }      # generic 32-byte secret
add() { printf %s "$2" | gcloud secrets versions add "caldiy-${ENV}-$1" --data-file=- --project $PROJECT; }

add nextauth-secret                "$(gen)"
add calendso-encryption-key        "$(openssl rand -base64 24)"   # 24 bytes per docs
add service-account-encryption-key "$(openssl rand -base64 24)"
add jwt-secret                     "$(gen)"
add db-password                    "$(gen)"
add cal-api-key                    "<the cal API key you create in the cal admin UI>"
add cal-oauth-client-secret        "<Platform OAuth client secret>"
add cal-webhook-secret             "$(gen)"        # also set as the cal webhook secret

# Assembled URLs (use terraform output sql_private_ip / redis_host / redis_port +
# the Memorystore AUTH string from `gcloud redis instances get-auth-string`):
add database-url        "postgresql://calcom:${DBPASS}@${SQL_IP}:5432/calendso?sslmode=require"
add database-url-direct "postgresql://calcom:${DBPASS}@${SQL_IP}:5432/calendso?sslmode=require"
add redis-url           "rediss://:${REDIS_AUTH}@${REDIS_HOST}:${REDIS_PORT}"
```

Cloud Run env refs use `version = "latest"`, so a new version is picked up on the
**next revision**. To apply immediately, redeploy the affected service (§6).

### Rotation playbooks

- **`CAL_WEBHOOK_SECRET`** (zero-downtime): the AWS verifier accepts only one secret,
  so coordinate: (1) `add cal-webhook-secret <new>`; (2) update the cal webhook's
  secret to `<new>`; (3) set the AWS app `CAL_WEBHOOK_SECRET=<new>` and redeploy.
  Brief mismatch window → expect a few `401`s; cal retries.
- **`CAL_API_KEY`**: (1) create a new key in cal; (2) `add cal-api-key <new>`;
  (3) redeploy the **proxy** (`gcloud run deploy caldiy-${ENV}-proxy …` or re-run the
  deploy workflow); (4) revoke the old key in cal. The AWS app is unaffected (it never
  holds the key).
- **`db-password`**: `gcloud sql users set-password calcom --instance caldiy-${ENV}-pg`,
  `add db-password <new>`, re-assemble `database-url`/`database-url-direct`, redeploy
  api + web + run the migrate job.

---

## 5. Deploy / update (one-click)

**GitHub → Actions → "cal.diy Deploy" → Run workflow** (pick `dev`/`prod`, optional
ref), **or** push a tag `caldiy-v*`. The workflow:

1. Builds **web**, **api-v2**, **auth-proxy** from the pinned ref → Artifact Registry.
2. Resolves image **digests** (immutable) and points the migrate job + services at them.
3. Runs `prisma migrate deploy` as the **migrate job** (before rolling services).
4. Rolls `api` → `web` → `proxy`.

Prod is a **protected GitHub environment** — add required reviewers so prod deploys
need manual approval.

**Pinning:** production should deploy a **vetted tag** of our fork (`caldiy-vX.Y.Z`),
not a branch. Services are deployed **by digest**, so a tag can never silently drift.

---

## 6. Rollback

Cloud Run keeps prior revisions. To roll back instantly:

```bash
gcloud run services update-traffic caldiy-${ENV}-api \
  --region $REGION --to-revisions <previous-revision>=100
# repeat for -web and -proxy as needed
```

Or re-run the **Deploy** workflow with `ref` = the last-good tag. **DB note:** a
rollback does **not** revert migrations — if the bad release shipped a migration,
restore from a Cloud SQL backup/PITR (§7) rather than just rolling the image.

---

## 7. Database migrations & recovery

- **Normal path:** handled by the deploy workflow (migrate job runs first). The web
  container's `start.sh` also runs `prisma migrate deploy` on boot (idempotent,
  advisory-locked) — a no-op once the job has run.
- **Manual run:** `gcloud run jobs execute caldiy-${ENV}-migrate --region $REGION --wait`.
- **Always review** generated migrations before tagging a release — Prisma can drop
  columns (per cal's own docs). Migrations come from upstream; review on fork-merge.
- **Backups / PITR:** automated backups (`sql_backup_retention_days`) + point-in-time
  recovery are on. Restore: `gcloud sql instances clone` or Console → restore to a
  timestamp. Test restores periodically.

---

## 8. Admin access to the web UI (internal-only)

The web app has **no public URL**. Brandy (or any `admin_members` principal) reaches it
through an authenticated tunnel:

```bash
gcloud run services proxy caldiy-${ENV}-web --region $REGION --port 8080
# then open http://localhost:8080  (cal's own NextAuth login still applies)
```

Grant access by adding the user to `var.admin_members` and re-applying Terraform.

---

## 9. Fork-maintenance flow (pull upstream cal.diy selectively)

We track `upstream = https://github.com/calcom/cal.diy` but **never auto-merge**.

```bash
git fetch upstream
git log --oneline main..upstream/main          # review what's new
git checkout -b chore/upstream-sync-$(date +%Y%m%d)
git merge upstream/main                          # or cherry-pick specific fixes
#   - resolve conflicts; pay attention to: Dockerfile, scripts/start.sh,
#     packages/prisma/**, apps/api/v2/** (our deploy assumes these shapes)
#   - DO NOT pull anything that re-introduces a license/enterprise gate
yarn && yarn build                               # sanity build locally
```
Then open a PR. CI builds all three images. Merge → tag `caldiy-vX.Y.Z` → the Deploy
workflow ships it to dev; promote to prod after smoke-testing. Keep diffs small and
frequent; re-run INTEGRATION-RECONCILIATION checks if anything under `apps/api/v2`
or the webhook payloads changed.

Our deployment-only files live **outside** the upstream tree to minimize conflicts:
`terraform/`, `deploy/gcp/auth-proxy/`, `.github/workflows/caldiy-*.yml`, the two
root `*.md` deliverables.

---

## 10. Quick reference

| Thing | Command / location |
|---|---|
| Proxy URL (AWS `CAL_API_BASE_URL`) | `terraform output proxy_url` |
| WIF provider for AWS app | `terraform output wif_provider_aws` |
| AWS caller SA | `terraform output aws_caller_service_account` |
| Secret names | `terraform output secret_ids` |
| Run migrations | `gcloud run jobs execute caldiy-${ENV}-migrate --region $REGION --wait` |
| Tail proxy logs | `gcloud run services logs read caldiy-${ENV}-proxy --region $REGION` |
| Roll back a service | `gcloud run services update-traffic …` (§6) |
