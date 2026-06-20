/**
 * Provision a regular cal user for one OT provider (headless, MIT-native).
 * --------------------------------------------------------------------------
 * The Platform/managed-user path depends on an enterprise feature stubbed out in
 * the MIT fork, and we don't need it (cal is internal; providers auth via OTC; we
 * book server-to-server). So each provider is a plain cal user with their own
 * Working-Hours schedule + a bookable event type. Idempotent.
 *
 * Run as a one-off Cloud Run Job (web image + cloud-sql-proxy sidecar).
 *
 * Env:
 *   PROVIDER_EMAIL        (required) the provider's cal account email
 *   PROVIDER_USERNAME     (required) stable handle (maps to ProviderScheduling.cal_username)
 *   PROVIDER_NAME         display name        (default: username)
 *   PROVIDER_TIMEZONE     IANA tz             (default: America/Chicago)
 *   PROVIDER_EVENT_TITLE  event type title    (default: "OT Consultation")
 *   PROVIDER_EVENT_SLUG   event type slug     (default: "ot-consult")
 *   PROVIDER_EVENT_LENGTH minutes             (default: 30)
 *
 * Prints PROVIDER_CAL_USERNAME=<username> and PROVIDER_EVENT_TYPE_ID=<id> for the
 * AWS app's ProviderScheduling row.
 */
import { DEFAULT_SCHEDULE, getAvailabilityFromSchedule } from "@calcom/lib/availability";
import prisma from "@calcom/prisma";

async function main() {
  const email = process.env.PROVIDER_EMAIL;
  const username = process.env.PROVIDER_USERNAME;
  const name = process.env.PROVIDER_NAME || username || "";
  const timeZone = process.env.PROVIDER_TIMEZONE || "America/Chicago";
  const eventTitle = process.env.PROVIDER_EVENT_TITLE || "OT Consultation";
  const eventSlug = process.env.PROVIDER_EVENT_SLUG || "ot-consult";
  const eventLength = parseInt(process.env.PROVIDER_EVENT_LENGTH || "30", 10);

  if (!email || !username) throw new Error("PROVIDER_EMAIL and PROVIDER_USERNAME are required");

  // 1. User + a default "Working Hours" schedule (created once).
  const user = await prisma.user.upsert({
    where: { email_username: { email, username } },
    update: { name, timeZone, emailVerified: new Date(), completedOnboarding: true, locale: "en" },
    create: {
      email,
      username,
      name,
      timeZone,
      emailVerified: new Date(),
      completedOnboarding: true,
      locale: "en",
      schedules: {
        create: {
          name: "Working Hours",
          availability: { createMany: { data: getAvailabilityFromSchedule(DEFAULT_SCHEDULE) } },
        },
      },
    },
    include: { schedules: { orderBy: { id: "asc" } } },
  });
  console.log(`✓ user id=${user.id} username=${user.username}`);

  // 2. Point the user's default schedule at Working Hours (so slots resolve).
  let scheduleId = user.defaultScheduleId;
  if (!scheduleId && user.schedules[0]) {
    scheduleId = user.schedules[0].id;
    await prisma.user.update({ where: { id: user.id }, data: { defaultScheduleId: scheduleId } });
    console.log(`✓ defaultScheduleId=${scheduleId}`);
  }

  // 3. Bookable event type (idempotent by userId + slug).
  let eventType = await prisma.eventType.findFirst({
    where: { userId: user.id, slug: eventSlug },
  });
  if (!eventType) {
    eventType = await prisma.eventType.create({
      data: {
        title: eventTitle,
        slug: eventSlug,
        length: eventLength,
        userId: user.id,
        ...(scheduleId ? { scheduleId } : {}),
      },
    });
    console.log(`✓ created eventType id=${eventType.id}`);
  } else {
    console.log(`✓ eventType exists id=${eventType.id}`);
  }

  console.log(`PROVIDER_CAL_USERNAME=${user.username}`);
  console.log(`PROVIDER_EVENT_TYPE_ID=${eventType.id}`);
  console.log("done");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error("provisioning failed:", e);
    process.exit(1);
  });
