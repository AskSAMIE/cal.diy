import { ApiProperty, ApiPropertyOptional } from "@nestjs/swagger";
import { IsEmail, IsOptional, IsString } from "class-validator";

export class ProvisionUserInput {
  @IsEmail()
  @ApiProperty({ description: "The provider's cal account email.", example: "jane-ot@otconnected.com" })
  readonly email!: string;

  @IsString()
  @ApiProperty({ description: "Stable cal username for the provider.", example: "jane-ot" })
  readonly username!: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "Display name.", example: "Jane OT" })
  readonly name?: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "IANA timezone for the working-hours schedule.", example: "America/Chicago" })
  readonly timeZone?: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "Per-user booking webhook subscriber URL." })
  readonly webhookUrl?: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "HMAC secret for the booking webhook." })
  readonly webhookSecret?: string;
}
