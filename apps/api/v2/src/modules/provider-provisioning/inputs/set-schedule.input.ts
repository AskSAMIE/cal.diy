import { ApiProperty, ApiPropertyOptional } from "@nestjs/swagger";
import { Type } from "class-transformer";
import { IsArray, IsInt, IsOptional, IsString, Max, Min, ValidateNested } from "class-validator";

export class WeeklyHourInput {
  @IsInt()
  @Min(0)
  @Max(6)
  @ApiProperty({ description: "Day of week (0=Sun … 6=Sat).", example: 1 })
  readonly day!: number;

  @IsString()
  @ApiProperty({ description: "Start time, 24h HH:mm (wall-clock in the schedule timezone).", example: "09:00" })
  readonly start!: string;

  @IsString()
  @ApiProperty({ description: "End time, 24h HH:mm.", example: "17:00" })
  readonly end!: string;
}

export class DateOverrideInput {
  @IsString()
  @ApiProperty({ description: "Override date, YYYY-MM-DD.", example: "2026-06-27" })
  readonly date!: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "Start time HH:mm. Omit both start+end to block the whole day.", example: "09:00" })
  readonly start?: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "End time HH:mm.", example: "13:00" })
  readonly end?: string;
}

export class SetScheduleInput {
  @IsString()
  @ApiProperty({ description: "The provider's cal username.", example: "jane-ot" })
  readonly username!: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional({ description: "IANA timezone for the schedule.", example: "America/Chicago" })
  readonly timeZone?: string;

  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => WeeklyHourInput)
  @ApiProperty({ type: [WeeklyHourInput], description: "Recurring weekly hours (one entry per day-range; may be empty)." })
  readonly weeklyHours!: WeeklyHourInput[];

  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => DateOverrideInput)
  @ApiProperty({ type: [DateOverrideInput], description: "Date-specific overrides / time off (may be empty)." })
  readonly dateOverrides!: DateOverrideInput[];
}
