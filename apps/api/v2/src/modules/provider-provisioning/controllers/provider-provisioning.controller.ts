import { API_VERSIONS_VALUES } from "@/lib/api-versions";
import { ApiAuthGuard } from "@/modules/auth/guards/api-auth/api-auth.guard";
import { ReconcileEventTypesInput } from "@/modules/provider-provisioning/inputs/reconcile-event-types.input";
import { ProviderProvisioningService } from "@/modules/provider-provisioning/services/provider-provisioning.service";
import { Body, Controller, HttpCode, HttpStatus, Post, UseGuards } from "@nestjs/common";
import { ApiExcludeController, ApiOperation } from "@nestjs/swagger";

import { SUCCESS_STATUS } from "@calcom/platform-constants";
import { ApiResponse } from "@calcom/platform-types";

// Internal endpoint: the AskSAMIE app (server-to-server, via the auth-swap proxy)
// reconciles a provider's bookable services to cal event types. Not part of the
// public docs.
@Controller({
  path: "/v2/provider-provisioning",
  version: API_VERSIONS_VALUES,
})
@UseGuards(ApiAuthGuard)
@ApiExcludeController()
export class ProviderProvisioningController {
  constructor(private readonly providerProvisioningService: ProviderProvisioningService) {}

  @Post("/event-types")
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: "Reconcile a provider's bookable event types" })
  async reconcileEventTypes(
    @Body() body: ReconcileEventTypesInput
  ): Promise<ApiResponse<{ eventTypeIds: Record<string, string> }>> {
    const eventTypeIds = await this.providerProvisioningService.reconcileEventTypes(
      body.username,
      body.services
    );
    return {
      status: SUCCESS_STATUS,
      data: { eventTypeIds },
    };
  }
}
