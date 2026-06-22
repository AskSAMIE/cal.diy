import { PrismaReadService } from "@/modules/prisma/prisma-read.service";
import { PrismaWriteService } from "@/modules/prisma/prisma-write.service";
import { CalendarsService } from "@/platform/calendars/services/calendars.service";
import { Injectable, NotFoundException } from "@nestjs/common";
import { randomUUID } from "crypto";

import type { Prisma } from "@calcom/prisma/client";

// Inlined Mon–Fri 9–5 working hours (== getAvailabilityFromSchedule(DEFAULT_SCHEDULE)).
// We can't import @calcom/lib/availability here: it resolves at compile time but is
// not bundled into the api-v2 runtime dist (MODULE_NOT_FOUND at boot).
const WORKING_HOURS_AVAILABILITY = [
  {
    days: [1, 2, 3, 4, 5],
    startTime: new Date(Date.UTC(1970, 0, 1, 9, 0, 0)),
    endTime: new Date(Date.UTC(1970, 0, 1, 17, 0, 0)),
  },
];

import type { ReconcileServiceInput } from "@/modules/provider-provisioning/inputs/reconcile-event-types.input";

const WEBHOOK_TRIGGERS = [
  "BOOKING_CREATED",
  "BOOKING_RESCHEDULED",
  "BOOKING_CANCELLED",
  "BOOKING_NO_SHOW_UPDATED",
  "MEETING_ENDED",
];

@Injectable()
export class ProviderProvisioningService {
  constructor(
    private readonly dbRead: PrismaReadService,
    private readonly dbWrite: PrismaWriteService,
    private readonly calendarsService: CalendarsService
  ) {}

  /**
   * Reconcile a regular (headless) provider's bookable event types to `services`:
   * upsert one EventType per service (host-connected, pinned to their schedule) and
   * HIDE the user's event types no longer offered. This user's event types are all
   * provisioned by us, so hiding non-desired ones is safe and preserves historical
   * bookings. Returns { service_key: cal_event_type_id }.
   */
  async reconcileEventTypes(
    username: string,
    services: ReconcileServiceInput[]
  ): Promise<Record<string, string>> {
    const user = await this.dbRead.prisma.user.findFirst({
      where: { username },
      include: { schedules: { orderBy: { id: "asc" }, take: 1 } },
    });
    if (!user) {
      throw new NotFoundException(`No cal user with username '${username}'`);
    }
    const scheduleId = user.defaultScheduleId ?? user.schedules[0]?.id ?? null;

    const eventTypeIds: Record<string, string> = {};
    for (const svc of services) {
      const existing = await this.dbRead.prisma.eventType.findFirst({
        where: { userId: user.id, slug: svc.key },
      });
      // Separate literals for update vs create — Prisma's generated input types
      // are strict and reject a shared object spread across both.
      const eventType = existing
        ? await this.dbWrite.prisma.eventType.update({
            where: { id: existing.id },
            data: {
              title: svc.title,
              length: svc.lengthMinutes,
              hidden: false,
              ...(scheduleId ? { scheduleId } : {}),
              users: { connect: { id: user.id } },
            },
          })
        : await this.dbWrite.prisma.eventType.create({
            data: {
              title: svc.title,
              slug: svc.key,
              length: svc.lengthMinutes,
              hidden: false,
              userId: user.id,
              ...(scheduleId ? { scheduleId } : {}),
              users: { connect: { id: user.id } },
            },
          });
      eventTypeIds[svc.key] = String(eventType.id);
    }

    // Hide event types no longer offered. `notIn: []` is unreliable, so when there
    // are no desired services hide everything (sentinel slug never matches).
    const desiredKeys = services.map((s) => s.key);
    await this.dbWrite.prisma.eventType.updateMany({
      where: {
        userId: user.id,
        hidden: false,
        slug: { notIn: desiredKeys.length ? desiredKeys : ["__none__"] },
      },
      data: { hidden: true },
    });

    return eventTypeIds;
  }

  /**
   * Inject a calendar credential for a regular provider (we run the OAuth in our
   * own app and pass the token payload here). Upserts the Credential and the
   * user-level SelectedCalendar so cal reads busy times + writes bookings.
   */
  async connectCalendar(params: {
    username: string;
    type: string;
    appSlug: string;
    key: Record<string, unknown>;
    externalId: string;
  }): Promise<{ credentialId: string }> {
    const { username, type, appSlug, key, externalId } = params;
    const user = await this.dbRead.prisma.user.findFirst({ where: { username } });
    if (!user) {
      throw new NotFoundException(`No cal user with username '${username}'`);
    }

    const existingCred = await this.dbRead.prisma.credential.findFirst({
      where: { userId: user.id, type, appId: appSlug },
    });
    const credential = existingCred
      ? await this.dbWrite.prisma.credential.update({
          where: { id: existingCred.id },
          data: { key: key as Prisma.InputJsonValue, invalid: false },
        })
      : await this.dbWrite.prisma.credential.create({
          data: { type, key: key as Prisma.InputJsonValue, userId: user.id, appId: appSlug },
        });

    const existingSel = await this.dbRead.prisma.selectedCalendar.findFirst({
      where: { userId: user.id, integration: type, externalId, eventTypeId: null },
    });
    if (existingSel) {
      await this.dbWrite.prisma.selectedCalendar.update({
        where: { id: existingSel.id },
        data: { credentialId: credential.id },
      });
    } else {
      await this.dbWrite.prisma.selectedCalendar.create({
        data: { userId: user.id, integration: type, externalId, credentialId: credential.id },
      });
    }

    return { credentialId: String(credential.id) };
  }

  /**
   * Remove a provider's calendar credential of `type`. Deleting the Credential
   * cascades to its SelectedCalendar rows.
   */
  async disconnectCalendar(params: { username: string; type: string }): Promise<{ deleted: number }> {
    const { username, type } = params;
    const user = await this.dbRead.prisma.user.findFirst({ where: { username } });
    if (!user) {
      throw new NotFoundException(`No cal user with username '${username}'`);
    }
    const result = await this.dbWrite.prisma.credential.deleteMany({
      where: { userId: user.id, type },
    });
    return { deleted: result.count };
  }

  /**
   * Provision a regular (headless) cal user for a provider: upsert the User, rebuild
   * a clean "Working Hours" schedule (timezone + availability), and optionally create
   * a per-user booking webhook. Idempotent. Event types are created separately via
   * reconcileEventTypes. Mirrors scripts/provision-provider.ts.
   */
  async provisionUser(params: {
    email: string;
    username: string;
    name?: string;
    timeZone?: string;
    webhookUrl?: string;
    webhookSecret?: string;
  }): Promise<{ username: string; userId: number }> {
    const { email, username, webhookUrl, webhookSecret } = params;
    const name = params.name || username;
    const timeZone = params.timeZone || "America/Chicago";

    const user = await this.dbWrite.prisma.user.upsert({
      where: { email_username: { email, username } },
      update: { name, timeZone, emailVerified: new Date(), completedOnboarding: true, locale: "en" },
      create: { email, username, name, timeZone, emailVerified: new Date(), completedOnboarding: true, locale: "en" },
    });

    // Rebuild the Working-Hours schedule cleanly (an upsert's update branch can't fix
    // an existing one). Detach references first to satisfy FKs.
    await this.dbWrite.prisma.user.update({ where: { id: user.id }, data: { defaultScheduleId: null } });
    await this.dbWrite.prisma.eventType.updateMany({ where: { userId: user.id }, data: { scheduleId: null } });
    await this.dbWrite.prisma.schedule.deleteMany({ where: { userId: user.id, name: "Working Hours" } });
    const schedule = await this.dbWrite.prisma.schedule.create({
      data: {
        userId: user.id,
        name: "Working Hours",
        timeZone,
        availability: { createMany: { data: WORKING_HOURS_AVAILABILITY } },
      },
    });
    await this.dbWrite.prisma.user.update({
      where: { id: user.id },
      data: { defaultScheduleId: schedule.id },
    });

    // Per-user booking webhook (regular users aren't covered by a platform webhook).
    if (webhookUrl && webhookSecret) {
      const existing = await this.dbRead.prisma.webhook.findFirst({
        where: { userId: user.id, subscriberUrl: webhookUrl },
      });
      if (existing) {
        await this.dbWrite.prisma.webhook.update({
          where: { id: existing.id },
          data: { secret: webhookSecret, active: true, eventTriggers: WEBHOOK_TRIGGERS as never },
        });
      } else {
        await this.dbWrite.prisma.webhook.create({
          data: {
            id: randomUUID(),
            userId: user.id,
            subscriberUrl: webhookUrl,
            secret: webhookSecret,
            active: true,
            eventTriggers: WEBHOOK_TRIGGERS as never,
          },
        });
      }
    }

    // user.username is nullable in the schema; we just set it from the (non-null) input.
    return { username: user.username ?? username, userId: user.id };
  }

  /**
   * Replace a provider's availability: recurring weekly hours + date overrides
   * (time off). Writes cal's own Availability rows (delete-all-then-recreate) on
   * the provider's default "Working Hours" schedule — entirely separate from any
   * connected external calendar, which stays read-only.
   */
  async setSchedule(params: {
    username: string;
    timeZone?: string;
    weeklyHours: { day: number; start: string; end: string }[];
    dateOverrides: { date: string; start?: string; end?: string }[];
  }): Promise<{ scheduleId: number; weeklyHours: number; dateOverrides: number }> {
    const { username, timeZone, weeklyHours, dateOverrides } = params;
    const user = await this.dbRead.prisma.user.findFirst({
      where: { username },
      include: { schedules: { where: { name: "Working Hours" }, take: 1 } },
    });
    if (!user) {
      throw new NotFoundException(`No cal user with username '${username}'`);
    }

    let scheduleId = user.defaultScheduleId ?? user.schedules[0]?.id;
    if (!scheduleId) {
      const created = await this.dbWrite.prisma.schedule.create({
        data: { userId: user.id, name: "Working Hours", timeZone: timeZone ?? "America/Chicago" },
      });
      scheduleId = created.id;
      await this.dbWrite.prisma.user.update({
        where: { id: user.id },
        data: { defaultScheduleId: created.id },
      });
    } else if (timeZone) {
      await this.dbWrite.prisma.schedule.update({ where: { id: scheduleId }, data: { timeZone } });
    }

    // Times are stored as @db.Time, wall-clock in the schedule's timezone (1970 date dropped).
    const hhmmToDate = (s: string) => {
      const [h, m] = s.split(":");
      return new Date(Date.UTC(1970, 0, 1, parseInt(h, 10) || 0, parseInt(m, 10) || 0, 0));
    };
    const ymdToDate = (s: string) => new Date(`${s}T00:00:00.000Z`);

    const rows = [
      ...weeklyHours.map((w) => ({
        scheduleId,
        days: [w.day],
        startTime: hhmmToDate(w.start),
        endTime: hhmmToDate(w.end),
        date: null,
      })),
      ...dateOverrides.map((o) => ({
        scheduleId,
        days: [] as number[],
        startTime: hhmmToDate(o.start ?? "00:00"),
        endTime: hhmmToDate(o.end ?? "00:00"),
        date: ymdToDate(o.date),
      })),
    ];

    // Cal's own pattern: replace the schedule's availability wholesale.
    await this.dbWrite.prisma.availability.deleteMany({ where: { scheduleId } });
    if (rows.length) {
      await this.dbWrite.prisma.availability.createMany({ data: rows });
    }

    return { scheduleId, weeklyHours: weeklyHours.length, dateOverrides: dateOverrides.length };
  }

  /**
   * List a provider's connected calendars (across all connected accounts), flattened,
   * with whether each is currently checked for conflicts (isSelected) and whether it's
   * the booking write target (isDestination). Reuses cal's own connected-calendars path.
   */
  async listCalendars(username: string): Promise<{
    calendars: {
      integration: string;
      externalId: string;
      name: string;
      primary: boolean;
      readOnly: boolean;
      credentialId: number | null;
      isSelected: boolean;
      isDestination: boolean;
    }[];
  }> {
    if (!username) {
      throw new NotFoundException("username query param is required");
    }
    const user = await this.dbRead.prisma.user.findFirst({ where: { username } });
    if (!user) {
      throw new NotFoundException(`No cal user with username '${username}'`);
    }

    const connected = await this.calendarsService.getCalendars(user.id);

    // The upstream platform-libraries types are loose at this boundary; read only
    // the fields we surface.
    type CalItem = {
      externalId: string;
      name?: string;
      primary?: boolean | null;
      readOnly?: boolean;
      isSelected?: boolean;
      credentialId?: number | null;
      integration?: string;
    };
    type ConnItem = {
      integration?: { type?: string };
      credentialId?: number | null;
      calendars?: CalItem[];
    };
    const destination = connected.destinationCalendar as unknown as
      | { integration?: string; externalId?: string }
      | null
      | undefined;

    const calendars: {
      integration: string;
      externalId: string;
      name: string;
      primary: boolean;
      readOnly: boolean;
      credentialId: number | null;
      isSelected: boolean;
      isDestination: boolean;
    }[] = [];
    for (const conn of (connected.connectedCalendars as unknown as ConnItem[] | undefined) ?? []) {
      const connIntegration = conn.integration?.type ?? "";
      for (const cal of conn.calendars ?? []) {
        const integration = cal.integration ?? connIntegration;
        calendars.push({
          integration,
          externalId: cal.externalId,
          name: cal.name ?? cal.externalId,
          primary: !!cal.primary,
          readOnly: !!cal.readOnly,
          credentialId: cal.credentialId ?? conn.credentialId ?? null,
          isSelected: !!cal.isSelected,
          isDestination:
            !!destination &&
            destination.externalId === cal.externalId &&
            destination.integration === integration,
        });
      }
    }

    return { calendars };
  }

  /**
   * Replace which calendars are checked for conflicts (user-level SelectedCalendar
   * rows). Multiple allowed; empty array clears them. cal's availability path reads
   * these rows directly, so the change takes effect on the next slot query.
   */
  async setSelectedCalendars(params: {
    username: string;
    calendars: { integration: string; externalId: string; credentialId: number }[];
  }): Promise<{ selected: number }> {
    const user = await this.dbRead.prisma.user.findFirst({ where: { username: params.username } });
    if (!user) {
      throw new NotFoundException(`No cal user with username '${params.username}'`);
    }

    await this.dbWrite.prisma.selectedCalendar.deleteMany({
      where: { userId: user.id, eventTypeId: null },
    });
    if (params.calendars.length) {
      await this.dbWrite.prisma.selectedCalendar.createMany({
        data: params.calendars.map((c) => ({
          userId: user.id,
          integration: c.integration,
          externalId: c.externalId,
          credentialId: c.credentialId,
        })),
        skipDuplicates: true,
      });
    }
    await this.calendarsService.deleteCalendarsCache(user.id);

    return { selected: params.calendars.length };
  }

  /**
   * Set (or clear) the ONE destination calendar that receives booking events. Provide
   * integration+externalId to enable writing to that calendar; omit them to turn off
   * writing (bookings then stay only in cal). One destination per user (@unique userId).
   */
  async setDestinationCalendar(params: {
    username: string;
    integration?: string;
    externalId?: string;
    credentialId?: number;
  }): Promise<{ destination: string | null }> {
    const user = await this.dbRead.prisma.user.findFirst({ where: { username: params.username } });
    if (!user) {
      throw new NotFoundException(`No cal user with username '${params.username}'`);
    }

    if (params.integration && params.externalId) {
      const existing = await this.dbRead.prisma.destinationCalendar.findFirst({
        where: { userId: user.id },
      });
      if (existing) {
        await this.dbWrite.prisma.destinationCalendar.update({
          where: { id: existing.id },
          data: {
            integration: params.integration,
            externalId: params.externalId,
            credentialId: params.credentialId ?? null,
          },
        });
      } else {
        await this.dbWrite.prisma.destinationCalendar.create({
          data: {
            userId: user.id,
            integration: params.integration,
            externalId: params.externalId,
            credentialId: params.credentialId ?? null,
          },
        });
      }
      await this.calendarsService.deleteCalendarsCache(user.id);
      return { destination: params.externalId };
    }

    await this.dbWrite.prisma.destinationCalendar.deleteMany({ where: { userId: user.id } });
    await this.calendarsService.deleteCalendarsCache(user.id);
    return { destination: null };
  }
}
