import { PrismaReadService } from "@/modules/prisma/prisma-read.service";
import { PrismaWriteService } from "@/modules/prisma/prisma-write.service";
import { Injectable, NotFoundException } from "@nestjs/common";

import type { Prisma } from "@calcom/prisma/client";

import type { ReconcileServiceInput } from "@/modules/provider-provisioning/inputs/reconcile-event-types.input";

@Injectable()
export class ProviderProvisioningService {
  constructor(
    private readonly dbRead: PrismaReadService,
    private readonly dbWrite: PrismaWriteService
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
}
