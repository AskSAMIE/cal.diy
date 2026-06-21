import { ProviderProvisioningController } from "@/modules/provider-provisioning/controllers/provider-provisioning.controller";
import { ProviderProvisioningService } from "@/modules/provider-provisioning/services/provider-provisioning.service";
import { PrismaModule } from "@/modules/prisma/prisma.module";
import { Module } from "@nestjs/common";

@Module({
  imports: [PrismaModule],
  providers: [ProviderProvisioningService],
  controllers: [ProviderProvisioningController],
})
export class ProviderProvisioningModule {}
