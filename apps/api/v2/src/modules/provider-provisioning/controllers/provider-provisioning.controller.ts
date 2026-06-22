import { API_VERSIONS_VALUES } from "@/lib/api-versions";
import { ApiAuthGuard } from "@/modules/auth/guards/api-auth/api-auth.guard";
import {
  ConnectCalendarInput,
  DisconnectCalendarInput,
} from "@/modules/provider-provisioning/inputs/connect-calendar.input";
import { ProvisionUserInput } from "@/modules/provider-provisioning/inputs/provision-user.input";
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

  @Post("/user")
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: "Provision a regular cal user (+ working hours + webhook)" })
  async provisionUser(
    @Body() body: ProvisionUserInput
  ): Promise<ApiResponse<{ username: string; userId: number }>> {
    const data = await this.providerProvisioningService.provisionUser(body);
    return {
      status: SUCCESS_STATUS,
      data,
    };
  }

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

  @Post("/calendar-credential")
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: "Inject a provider's calendar credential" })
  async connectCalendar(
    @Body() body: ConnectCalendarInput
  ): Promise<ApiResponse<{ credentialId: string }>> {
    const data = await this.providerProvisioningService.connectCalendar(body);
    return {
      status: SUCCESS_STATUS,
      data,
    };
  }

  @Post("/calendar-credential/disconnect")
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: "Remove a provider's calendar credential" })
  async disconnectCalendar(
    @Body() body: DisconnectCalendarInput
  ): Promise<ApiResponse<{ deleted: number }>> {
    const data = await this.providerProvisioningService.disconnectCalendar(body);
    return {
      status: SUCCESS_STATUS,
      data,
    };
  }
}
