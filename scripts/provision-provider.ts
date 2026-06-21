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
 *   CAL_WEBHOOK_URL       AWS webhook receiver (optional; creates a user-scoped webhook)
 *   CAL_WEBHOOK_SECRET    HMAC secret for that webhook
 *
 * Prints PROVIDER_CAL_USERNAME=<username> and PROVIDER_EVENT_TYPE_ID=<id> for the
 * AWS app's ProviderScheduling row.
 */
import { DEFAULT_SCHEDULE, getAvailabilityFromSchedule } from "@calcom/lib/availability";
import prisma from "@calcom/prisma";
import { randomUUID } from "crypto";

async function main() {
  const email = process.env.PROVIDER_EMAIL;
  const username = process.env.PROVIDER_USERNAME;
  const name = process.env.PROVIDER_NAME || username || "";
  const timeZone = process.env.PROVIDER_TIMEZONE || "America/Chicago";
  const eventTitle = process.env.PROVIDER_EVENT_TITLE || "OT Consultation";
  const eventSlug = process.env.PROVIDER_EVENT_SLUG || "ot-consult";
  const eventLength = parseInt(process.env.PROVIDER_EVENT_LENGTH || "30", 10);

  if (!email || !username) throw new Error("PROVIDER_EMAIL and PROVIDER_USERNAME are required");

  // 1. User (regular cal account).
  const user = await prisma.user.upsert({
    where: { email_username: { email, username } },
    update: { name, timeZone, emailVerified: new Date(), completedOnboarding: true, locale: "en" },
    create: { email, username, name, timeZone, emailVerified: new Date(), completedOnboarding: true, locale: "en" },
  });
  console.log(`✓ user id=${user.id} username=${user.username}`);

  // 2. Working-Hours schedule — rebuilt cleanly each run so timezone + availability
  //    are always correct (an upsert's update branch would never fix an existing one).
  //    Detach references first to satisfy FKs, then recreate.
  await prisma.user.update({ where: { id: user.id }, data: { defaultScheduleId: null } });
  await prisma.eventType.updateMany({ where: { userId: user.id }, data: { scheduleId: null } });
  await prisma.schedule.deleteMany({ where: { userId: user.id, name: "Working Hours" } });
  const schedule = await prisma.schedule.create({
    data: {
      userId: user.id,
      name: "Working Hours",
      timeZone, // slots cannot be computed without the schedule's timezone
      availability: { createMany: { data: getAvailabilityFromSchedule(DEFAULT_SCHEDULE) } },
    },
    include: { availability: true },
  });
  await prisma.user.update({ where: { id: user.id }, data: { defaultScheduleId: schedule.id } });
  console.log(`✓ schedule id=${schedule.id} tz=${schedule.timeZone} availability=${schedule.availability.length}`);

  // 3. Bookable event type (idempotent by userId + slug), pinned to the schedule.
  //    The user MUST be connected as a host (eventType.users) or availability
  //    computes against zero hosts and the event returns no slots.
  let eventType = await prisma.eventType.findFirst({ where: { userId: user.id, slug: eventSlug } });
  if (!eventType) {
    eventType = await prisma.eventType.create({
      data: {
        title: eventTitle,
        slug: eventSlug,
        length: eventLength,
        userId: user.id,
        scheduleId: schedule.id,
        users: { connect: { id: user.id } },
      },
    });
    console.log(`✓ created eventType id=${eventType.id}`);
  } else {
    eventType = await prisma.eventType.update({
      where: { id: eventType.id },
      data: { scheduleId: schedule.id, length: eventLength, users: { connect: { id: user.id } } },
    });
    console.log(`✓ eventType id=${eventType.id} (scheduleId=${eventType.scheduleId})`);
  }

  // 4. Per-user webhook so cal notifies the AWS app of this provider's bookings
  //    (regular users aren't covered by the platform-client webhook). Idempotent
  //    by [userId, subscriberUrl].
  const webhookUrl = process.env.CAL_WEBHOOK_URL;
  const webhookSecret = process.env.CAL_WEBHOOK_SECRET;
  if (webhookUrl && webhookSecret) {
    const triggers = [
      "BOOKING_CREATED",
      "BOOKING_RESCHEDULED",
      "BOOKING_CANCELLED",
      "BOOKING_NO_SHOW_UPDATED",
      "MEETING_ENDED",
    ];
    const existing = await prisma.webhook.findFirst({
      where: { userId: user.id, subscriberUrl: webhookUrl },
    });
    if (!existing) {
      await prisma.webhook.create({
        data: {
          id: randomUUID(),
          userId: user.id,
          subscriberUrl: webhookUrl,
          secret: webhookSecret,
          active: true,
          eventTriggers: triggers as never,
        },
      });
      console.log(`✓ created user-scoped webhook -> ${webhookUrl}`);
    } else {
      await prisma.webhook.update({
        where: { id: existing.id },
        data: { secret: webhookSecret, active: true, eventTriggers: triggers as never },
      });
      console.log(`✓ webhook exists -> ${webhookUrl}`);
    }
  } else {
    console.log("• CAL_WEBHOOK_URL/SECRET not set — skipping webhook");
  }

  // Debug: confirm what slots will resolve against.
  console.log(
    `DEBUG userTz=${user.timeZone} defaultScheduleId=${schedule.id} ` +
      `availSample=${JSON.stringify(schedule.availability[0])}`
  );

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
