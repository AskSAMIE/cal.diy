import { ApiProperty, ApiPropertyOptional } from "@nestjs/swagger";
import { Type } from "class-transformer";
import { IsArray, IsInt, IsOptional, IsString, Max, Min, ValidateNested } from "class-validator";

export class ReconcileServiceInput {
  @IsString()
  @ApiProperty({ description: "Stable service key (slug).", example: "free-discovery-call" })
  readonly key!: string;

  @IsString()
  @ApiProperty({ description: "Event type title shown to bookers.", example: "Free Discovery Call" })
  readonly title!: string;

  @IsInt()
  @Min(1)
  @Max(1440)
  @ApiProperty({ description: "Visit length in minutes.", example: 30 })
  readonly lengthMinutes!: number;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "Visit modality.", example: "virtual" })
  readonly modality?: string;
}

export class ReconcileEventTypesInput {
  @IsString()
  @ApiProperty({ description: "The provider's cal username.", example: "jane-ot" })
  readonly username!: string;

  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => ReconcileServiceInput)
  @ApiProperty({ type: [ReconcileServiceInput], description: "Desired bookable services (may be empty)." })
  readonly services!: ReconcileServiceInput[];
}
