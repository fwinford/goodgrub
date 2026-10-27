const MODERATOR_TIME_ZONE = "America/New_York";

const formatter = new Intl.DateTimeFormat("en-US", {
  timeZone: MODERATOR_TIME_ZONE,
  month: "short",
  day: "numeric",
  year: "numeric",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
  timeZoneName: "short",
});

/** Readable label such as "Oct 19, 2026 · 2:32 PM EDT"; "" when not a valid Date. */
export function formatModeratorDate(value: unknown): string {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) return "";
  const parts = Object.fromEntries(
    formatter.formatToParts(value).map((part) => [part.type, part.value])
  ) as Record<string, string>;
  const period = (parts.dayPeriod ?? "").replace(/\s+/g, " ");
  return `${parts.month} ${parts.day}, ${parts.year} · ${parts.hour}:${parts.minute} ${period} ${parts.timeZoneName}`;
}
