import { ApiProperty, ApiPropertyOptional } from "@nestjs/swagger";
import { Type } from "class-transformer";
import { IsArray, IsInt, IsOptional, IsString, ValidateNested } from "class-validator";

export class SelectedCalendarItem {
  @IsString()
  @ApiProperty({ description: "Calendar integration type.", example: "google_calendar" })
  readonly integration!: string;

  @IsString()
  @ApiProperty({ description: "Calendar external id (email / calendar id in the provider).", example: "jane@gmail.com" })
  readonly externalId!: string;

  @IsInt()
  @ApiProperty({ description: "The cal Credential id this calendar belongs to.", example: 42 })
  readonly credentialId!: number;
}

export class SetSelectedCalendarsInput {
  @IsString()
  @ApiProperty({ description: "The provider's cal username.", example: "jane-ot" })
  readonly username!: string;

  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => SelectedCalendarItem)
  @ApiProperty({
    type: [SelectedCalendarItem],
    description: "Calendars to check for conflicts (replaces the provider's user-level selected calendars; may be empty).",
  })
  readonly calendars!: SelectedCalendarItem[];
}

export class SetDestinationCalendarInput {
  @IsString()
  @ApiProperty({ description: "The provider's cal username.", example: "jane-ot" })
  readonly username!: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({
    description: "Calendar integration type. Omit (with externalId) to turn OFF writing bookings to a calendar.",
    example: "google_calendar",
  })
  readonly integration?: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "Destination calendar external id. Omit to clear the destination.", example: "jane@gmail.com" })
  readonly externalId?: string;

  @IsOptional()
  @IsInt()
  @ApiPropertyOptional({ description: "The cal Credential id the destination calendar belongs to.", example: 42 })
  readonly credentialId?: number;
}
