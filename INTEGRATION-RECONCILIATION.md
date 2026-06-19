# cal.diy ↔ OT Connected — Integration Reconciliation

Reconciles the integration contract our AWS app (`as-platform`, FastAPI) **already
ships** against the **live Cal.com API v2 / webhook docs** (canonical for the
cal.diy MIT fork). For each item: what the docs say, what our app assumes, whether
they match, and the action needed.

> **Source-of-truth caveat.** Cal.com went closed-source in **April 2026**; the
> open fork is **cal.diy (MIT)**. API docs remain at **cal.com/docs**. The findings
> below were gathered from those canonical pages; a few **load-bearing details
> (HMAC signing input, attendee `phone`) MUST be confirmed against a real delivery
> from your instance** before flipping the consuming code from "unverified" to
> "verified" — they are flagged ⚠️ below.

Our app's ground truth (quoted from the repo):
- `server/src/services/scheduling/cal_client.py` — `HttpCalClient`
- `server/src/services/scheduling/webhook.py` — `verify_cal_signature`, payload parser
- `server/src/endpoints/rest/cal_webhooks.py` — `POST /api/webhooks/cal`
- `server/src/settings/base.py` — `cal_api_base_url`, `cal_api_key`, `cal_webhook_secret`

---

## 0. Auth headers & API version

| Item | Docs say | Our app assumes | Match? | Action |
|---|---|---|---|---|
| Bearer auth | `Authorization: Bearer <key>` (keys `cal_live_…` / prefix `cal_`) | sends `Authorization: Bearer {cal_api_key}` | ✅ | none (the **proxy** injects the real key; app sends its WIF ID token, proxy swaps it) |
| Version header | `cal-api-version` required; current pin for slots+bookings = **`2024-08-13`** | sends `cal-api-version: 2024-08-13` | ✅ | none — but it is **per-endpoint**; re-check when adding new endpoints |

Source: https://cal.com/docs/api-reference/v2/introduction

---

## 1. `GET /v2/slots/available` — available slots

| | |
|---|---|
| **Docs say** | Path is **`GET /v2/slots`** (NOT `/v2/slots/available`). Lookups: `eventTypeId` **or** (`eventTypeSlug`+`username`); `start`+`end` **required** (UTC ISO-8601); optional `timeZone`. Response groups by date: `{"status":"success","data":{"<date>":[{"start":"…"}]}}`. |
| **Our app assumes** | `GET /v2/slots/available?username=&eventTypeId=`, reads `data.slots[]`. |
| **Match?** | ❌ **Path wrong**, query model wrong, response shape wrong. |
| **Action** | In `HttpCalClient.get_availability`: change path to **`/v2/slots`**; send `start`+`end` (required); use `eventTypeId` alone **or** `eventTypeSlug`+`username` (don't mix `username`+`eventTypeId`); parse `data` as a **date→slots map**, not `data.slots`. |

Source: https://cal.com/docs/api-reference/v2/slots/get-available-time-slots-for-an-event-type

---

## 2. `POST /v2/bookings` — create booking

| | |
|---|---|
| **Docs say** | `POST /v2/bookings`. Required: `eventTypeId`, `start` (UTC, **offset stripped**), `attendee.email`. Attendee nests under a **singular `attendee`** object: `{name,email,timeZone, phoneNumber?, language?}`. `attendee.phoneNumber` becomes **required** if the event type has an SMS workflow. Success **201**; `data.uid` + `id,title,start,end,status`. |
| **Our app assumes** | `POST /v2/bookings` with body `{start, eventTypeId, attendee:{name,email,phoneNumber}, metadata:{visitReason}}`; reads `data`. |
| **Match?** | ✅ **mostly** — singular `attendee` ✅, `phoneNumber` key ✅, reads `data` ✅. |
| **Action** | (a) Ensure `start` is **UTC with no local offset**. (b) Add **`attendee.timeZone`** (docs treat it as expected; safest to send). (c) Confirm cal accepts custom `metadata.visitReason` (custom metadata is allowed; validate on your instance). |

Source: https://cal.com/docs/api-reference/v2/bookings/create-a-booking

---

## 3. `POST /v2/oauth-clients/managed-users` — provision managed user

| | |
|---|---|
| **Docs say** | Real path is **`POST /v2/oauth-clients/{clientId}/users`** (requires the OAuth **clientId** in the URL). Auth header is **`x-cal-secret-key: <client_secret>`** — **NOT** `Authorization: Bearer`. Body: `email` (req), `name`, `timeZone`, … Response **201**: top-level `accessToken`, `refreshToken`, `*ExpiresAt`, and nested **`user.id`**, `user.username`, … |
| **Our app assumes** | `POST /v2/oauth-clients/managed-users` (no clientId), Bearer auth, reads `data` for `managed_user_id`/`username`. |
| **Match?** | ❌ **Path, auth header, and response shape all differ.** |
| **Action** | (a) Path → **`/v2/oauth-clients/{clientId}/users`**; the app needs a new config **`CAL_OAUTH_CLIENT_ID`** (the clientId, non-secret). (b) Auth → the **proxy injects `x-cal-secret-key`** from Secret Manager (`*-cal-oauth-client-secret`); the app does NOT send it. (c) Read **`data.user.id`** + `data.user.username` (nested), and store `accessToken`/`refreshToken` if you later act as the managed user. |
| **Prereq (infra)** | A **Platform OAuth client** must exist in cal (created during bootstrap — see RUNBOOK "Provision the Platform OAuth client"). cal.diy is MIT/no-license-key, so the platform feature is available, but managed users still live under an **Organization** + OAuth client. |

Sources: https://cal.com/docs/api-reference/v2/platform-managed-users/create-a-managed-user · https://cal.com/docs/api-reference/v2/oauth-clients/create-an-oauth-client

---

## 4. Webhook signature

| | |
|---|---|
| **Docs say** | Header **`x-cal-signature-256`** (case-insensitive). Scheme: `HMAC-SHA256` **hex** digest, **no `sha256=` prefix**. The docs' verifier example hashes **`JSON.stringify(req.body)`** (the serialized payload), not necessarily the byte-exact raw request. Secret is set **per-webhook at creation**. |
| **Our app assumes** | Reads `X-Cal-Signature-256`; strips optional `sha256=`; `hmac.new(secret, raw_body, sha256).hexdigest()`; constant-time compare. |
| **Match?** | ✅ header name (case-insensitive), ✅ hex, ✅ prefix-tolerant, ✅ constant-time. ⚠️ **Signing input** is the open risk: we hash the **raw received bytes**, docs show `JSON.stringify`. |
| **Action** | Configure the cal webhook **secret = `*-cal-webhook-secret`** value. Then **send one real test delivery** and confirm our raw-body HMAC matches. If it doesn't, cal is signing a re-serialized body — adjust the verifier to hash the same canonical form. **Do not mark the parser "verified" until this passes against a live delivery.** |

Sources: https://cal.com/docs/developing/guides/automation/webhooks

---

## 5. Webhook trigger events

| Our app handles | Docs (exact string) | Match? |
|---|---|---|
| `BOOKING_CREATED` | `BOOKING_CREATED` | ✅ |
| `BOOKING_REQUESTED` | `BOOKING_REQUESTED` | ✅ |
| `BOOKING_PAID` | `BOOKING_PAID` | ✅ |
| `BOOKING_RESCHEDULED` | `BOOKING_RESCHEDULED` | ✅ |
| `BOOKING_CANCELLED` | `BOOKING_CANCELLED` | ✅ |
| `BOOKING_NO_SHOW` | **`BOOKING_NO_SHOW_UPDATED`** | ❌ **string differs** |
| `MEETING_ENDED` | `MEETING_ENDED` | ✅ (⚠️ flat payload — see §6) |

**Action:** rename the handled event `BOOKING_NO_SHOW` → **`BOOKING_NO_SHOW_UPDATED`**.

Source: https://cal.com/docs/developing/guides/automation/webhooks

---

## 6. Webhook payload shape

Standard wrapper: `{ "triggerEvent", "createdAt", "payload": { … } }`.

| Field our parser reads | Docs | Match? | Note |
|---|---|---|---|
| `triggerEvent` | ✅ present | ✅ | |
| `payload.uid` | ✅ | ✅ | |
| `payload.eventTypeId` | ✅ | ✅ | |
| `payload.organizer.username` | ✅ | ✅ | |
| `payload.attendees[0].name` / `.email` | ✅ | ✅ | |
| `payload.attendees[0].phone` | ⚠️ **not documented** on the attendee object | ⚠️ | phone may only appear under `responses`/booking fields, not as a first-class attendee field — **don't depend on it**; confirm on a live delivery |
| `payload.startTime` / `endTime` | ✅ | ✅ | |
| `payload.metadata.videoCallUrl` | ✅ (Cal Video / Google Meet only) | ✅ | other locations put the link under `location`/`responses` — our parser already falls back to `location`, good |

**⚠️ Flat-payload special case:** `MEETING_ENDED` (and `MEETING_STARTED`) deliver booking fields **at the top level — no `payload` wrapper**. Our parser reads `raw["payload"]`, so for these events `organizer`/`attendees`/`startTime` will be missing. **Action:** special-case `MEETING_*` to read from the top level (or ignore `MEETING_ENDED` if we don't need it).

Also worth logging: `x-cal-webhook-version` header conveys payload version.

Source: https://cal.com/docs/developing/guides/automation/webhooks

---

## Summary — changes needed on the AWS app (`as-platform`)

1. **Slots:** `/v2/slots/available` → `/v2/slots`; send `start`+`end`; parse date-map response. (§1)
2. **Bookings:** send `attendee.timeZone`; ensure `start` is UTC-no-offset. (§2)
3. **Managed users:** path `/v2/oauth-clients/{clientId}/users`; add `CAL_OAUTH_CLIENT_ID`; auth via proxy-injected `x-cal-secret-key`; read `data.user.id`. (§3)
4. **Webhook events:** `BOOKING_NO_SHOW` → `BOOKING_NO_SHOW_UPDATED`. (§5)
5. **Webhook flat payload:** special-case `MEETING_ENDED`/`MEETING_STARTED`. (§6)
6. ⚠️ **Verify against a live delivery:** HMAC signing input (raw vs JSON.stringify) and `attendees[0].phone` presence. (§4, §6)

## Changes on the deploy side (this repo) — already wired

- Proxy injects `Authorization: Bearer <cal_api_key>` + `x-cal-secret-key <client_secret>` and ensures `cal-api-version: 2024-08-13`. (`deploy/gcp/auth-proxy/server.js`)
- `CAL_API_BASE_URL` (AWS app) = the **proxy URL** (`terraform output proxy_url`).
- Webhook secret to set on the cal webhook = the `*-cal-webhook-secret` value (RUNBOOK).
- Platform OAuth client (clientId + secret) provisioned during bootstrap (RUNBOOK).
