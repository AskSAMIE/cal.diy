import { PrismaReadService } from "@/modules/prisma/prisma-read.service";
import { PrismaWriteService } from "@/modules/prisma/prisma-write.service";
import { Injectable, NotFoundException } from "@nestjs/common";

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
      const common = {
        title: svc.title,
        length: svc.lengthMinutes,
        hidden: false,
        ...(scheduleId ? { scheduleId } : {}),
        users: { connect: { id: user.id } },
      };
      const eventType = existing
        ? await this.dbWrite.prisma.eventType.update({ where: { id: existing.id }, data: common })
        : await this.dbWrite.prisma.eventType.create({
            data: { ...common, slug: svc.key, userId: user.id },
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
}
