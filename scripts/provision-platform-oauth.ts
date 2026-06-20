/**
 * Provision the Platform OAuth client for headless managed users.
 * --------------------------------------------------------------
 * Self-hosted cal.diy doesn't expose a Platform dashboard, so we create the
 * Organization + OWNER membership + PlatformOAuthClient directly. Run as a
 * one-off Cloud Run Job (web image + cloud-sql-proxy sidecar). Idempotent.
 *
 * Env:
 *   PROVISION_ADMIN_EMAIL    admin user (created in the setup wizard) -> org OWNER
 *   PROVISION_ORG_NAME       organization display name        (default "OT Connected")
 *   PROVISION_ORG_SLUG       organization slug                (default "otconnected")
 *   PROVISION_CLIENT_NAME    OAuth client name                (default "asksamie-platform")
 *   PROVISION_REDIRECT_URIS  comma-separated allowed redirect URIs
 *   CAL_OAUTH_CLIENT_SECRET  the client secret (also stored in Secret Manager and
 *                            injected by the auth-proxy as x-cal-secret-key)
 *
 * Prints PLATFORM_OAUTH_CLIENT_ID=<clientId> (NOT secret) for the AWS app config.
 */
import { randomUUID } from "crypto";

import prisma from "@calcom/prisma";
import { MembershipRole } from "@calcom/prisma/enums";

async function main() {
  const adminEmail = process.env.PROVISION_ADMIN_EMAIL;
  const orgName = process.env.PROVISION_ORG_NAME || "OT Connected";
  const orgSlug = process.env.PROVISION_ORG_SLUG || "otconnected";
  const clientName = process.env.PROVISION_CLIENT_NAME || "asksamie-platform";
  const clientSecret = process.env.CAL_OAUTH_CLIENT_SECRET;
  const redirectUris = (process.env.PROVISION_REDIRECT_URIS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  if (!clientSecret) throw new Error("CAL_OAUTH_CLIENT_SECRET is required");
  if (redirectUris.length === 0) throw new Error("PROVISION_REDIRECT_URIS is required");

  // Prefer the explicit email; otherwise fall back to the first instance ADMIN
  // (the user created by the setup wizard).
  const admin = adminEmail
    ? await prisma.user.findFirst({ where: { email: adminEmail } })
    : await prisma.user.findFirst({ where: { role: "ADMIN" }, orderBy: { id: "asc" } });
  if (!admin) throw new Error(`admin user not found (email=${adminEmail || "<first ADMIN>"})`);
  console.log(`✓ admin user id=${admin.id} email=${admin.email}`);

  // 1. Organization (a Team marked isOrganization). Idempotent by slug.
  let org = await prisma.team.findFirst({
    where: { slug: orgSlug, parentId: null, isOrganization: true },
  });
  if (!org) {
    org = await prisma.team.create({
      data: { name: orgName, slug: orgSlug, isOrganization: true },
    });
    console.log(`✓ created organization id=${org.id}`);
  } else {
    console.log(`✓ organization already exists id=${org.id}`);
  }

  // 2. Org settings — enable the admin API + mark configured/reviewed so platform
  //    operations (managed users) are allowed.
  await prisma.organizationSettings.upsert({
    where: { organizationId: org.id },
    update: { isAdminAPIEnabled: true, isOrganizationConfigured: true, isAdminReviewed: true },
    create: {
      organizationId: org.id,
      orgAutoAcceptEmail: adminEmail.split("@")[1] || "otconnected.com",
      isAdminAPIEnabled: true,
      isOrganizationConfigured: true,
      isAdminReviewed: true,
    },
  });
  console.log(`✓ org settings (admin API enabled)`);

  // 3. Admin as OWNER of the org.
  const membership = await prisma.membership.findFirst({
    where: { userId: admin.id, teamId: org.id },
  });
  if (!membership) {
    await prisma.membership.create({
      data: { userId: admin.id, teamId: org.id, role: MembershipRole.OWNER, accepted: true },
    });
    console.log(`✓ admin added as org OWNER`);
  } else {
    console.log(`✓ admin already a member (role=${membership.role})`);
  }

  // 4. Platform OAuth client. Idempotent by name+org. id is an auto cuid = clientId.
  //    permissions=1023 = all bits; secret is stored plaintext (cal compares the
  //    x-cal-secret-key header to this value).
  let client = await prisma.platformOAuthClient.findFirst({
    where: { name: clientName, organizationId: org.id },
  });
  if (!client) {
    client = await prisma.platformOAuthClient.create({
      data: {
        name: clientName,
        secret: clientSecret,
        permissions: 1023,
        redirectUris,
        organizationId: org.id,
        areCalendarEventsEnabled: true,
        areDefaultEventTypesEnabled: true,
      },
    });
    console.log(`✓ created PlatformOAuthClient`);
  } else {
    client = await prisma.platformOAuthClient.update({
      where: { id: client.id },
      data: { secret: clientSecret, redirectUris, permissions: 1023 },
    });
    console.log(`✓ updated existing PlatformOAuthClient`);
  }

  // 5. Outbound webhook on the OAuth client — fires for all its managed users'
  //    bookings. The secret matches what the AWS app verifies (HMAC-SHA256).
  const webhookUrl = process.env.PROVISION_WEBHOOK_URL;
  const webhookSecret = process.env.CAL_WEBHOOK_SECRET;
  if (webhookUrl && webhookSecret) {
    const triggers = [
      "BOOKING_CREATED",
      "BOOKING_REQUESTED",
      "BOOKING_PAID",
      "BOOKING_RESCHEDULED",
      "BOOKING_CANCELLED",
      "BOOKING_NO_SHOW_UPDATED",
      "MEETING_ENDED",
    ];
    const existing = await prisma.webhook.findFirst({
      where: { platformOAuthClientId: client.id, subscriberUrl: webhookUrl },
    });
    if (!existing) {
      await prisma.webhook.create({
        data: {
          id: randomUUID(),
          platformOAuthClientId: client.id,
          subscriberUrl: webhookUrl,
          secret: webhookSecret,
          active: true,
          eventTriggers: triggers as never,
        },
      });
      console.log(`✓ created webhook -> ${webhookUrl}`);
    } else {
      await prisma.webhook.update({
        where: { id: existing.id },
        data: { secret: webhookSecret, active: true, eventTriggers: triggers as never },
      });
      console.log(`✓ updated webhook -> ${webhookUrl}`);
    }
  } else {
    console.log("• webhook skipped (PROVISION_WEBHOOK_URL / CAL_WEBHOOK_SECRET unset)");
  }

  console.log(`PLATFORM_OAUTH_CLIENT_ID=${client.id}`);
  console.log("done");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error("provisioning failed:", e);
    process.exit(1);
  });
