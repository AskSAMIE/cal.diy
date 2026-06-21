import { ApiProperty } from "@nestjs/swagger";
import { IsObject, IsString } from "class-validator";

export class ConnectCalendarInput {
  @IsString()
  @ApiProperty({ description: "The provider's cal username.", example: "jane-ot" })
  readonly username!: string;

  @IsString()
  @ApiProperty({ description: "Credential type.", example: "google_calendar" })
  readonly type!: string;

  @IsString()
  @ApiProperty({ description: "App-store slug (FK App.slug).", example: "google-calendar" })
  readonly appSlug!: string;

  @IsObject()
  @ApiProperty({
    description: "The OAuth token payload stored on the credential.",
    type: Object,
  })
  readonly key!: Record<string, unknown>;

  @IsString()
  @ApiProperty({ description: "The connected calendar's external id (email).", example: "jane@gmail.com" })
  readonly externalId!: string;
}

export class DisconnectCalendarInput {
  @IsString()
  @ApiProperty({ description: "The provider's cal username.", example: "jane-ot" })
  readonly username!: string;

  @IsString()
  @ApiProperty({ description: "Credential type to remove.", example: "google_calendar" })
  readonly type!: string;
}
