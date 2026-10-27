/**
 * W4-R3 post-placement Home visibility (Faith, 2026-10-21).
 *
 * Presentation only: these cutoffs decide whether a placed request is shown on
 * an active Home surface. They never change `status`, `deleteAt`, evidence
 * retention or `requesterPickupConfirmedAt`, and they are deliberately not part
 * of `unfinishedPlacedObligationFilter` (the B1 seam).
 *
 * Every instant derives from the persisted `placedAt` plus the accepted ETA
 * vocabulary and is compared with backend time. Nothing parses display text on
 * the client and nothing falls back to another instant when the ETA is missing.
 */

export const ETA_MINUTES: Readonly<Record<string, number>> = {
  ASAP: 15,
  "15 minutes": 15,
  "30 minutes": 30,
  "45 minutes": 45,
  "60 minutes": 60,
};

export const HELPER_PASSIVE_AWARENESS_MS = 60 * 60 * 1000;
export const CAMPUS_TIME_ZONE = "America/New_York";

export function estimatedReadyAt(
  placedAt: Date | string | null | undefined,
  etaText: string | null | undefined
): Date | null {
  const minutes =
    typeof etaText === "string" &&
    Object.prototype.hasOwnProperty.call(ETA_MINUTES, etaText)
      ? ETA_MINUTES[etaText]
      : undefined;
  const timestamp = placedAt == null ? Number.NaN : new Date(placedAt).getTime();
  if (minutes === undefined || !Number.isFinite(timestamp)) return null;
  return new Date(timestamp + minutes * 60_000);
}

const campusParts = new Intl.DateTimeFormat("en-US", {
  timeZone: CAMPUS_TIME_ZONE,
  hourCycle: "h23",
  year: "numeric",
  month: "numeric",
  day: "numeric",
  hour: "numeric",
  minute: "numeric",
  second: "numeric",
});

function campusOffsetMs(instant: Date): number {
  const values: Record<string, number> = {};
  for (const part of campusParts.formatToParts(instant)) {
    if (part.type !== "literal") values[part.type] = Number(part.value);
  }
  const wallClockAsUtc = Date.UTC(
    values.year,
    values.month - 1,
    values.day,
    values.hour,
    values.minute,
    values.second
  );
  return wallClockAsUtc - Math.floor(instant.getTime() / 1000) * 1000;
}

/**
 * The first instant of the next `America/New_York` calendar day after the one
 * containing `instant`. A request stays visible while backend now is strictly
 * before it. Midnight is never inside a DST transition (they occur at 02:00),
 * so one offset lookup is exact.
 */
export function campusDayEnd(instant: Date): Date {
  const offset = campusOffsetMs(instant);
  const local = new Date(instant.getTime() + offset);
  const nextMidnightAsUtc = Date.UTC(
    local.getUTCFullYear(),
    local.getUTCMonth(),
    local.getUTCDate() + 1
  );
  // The offset at the next local midnight can differ from `instant`'s only
  // when a transition falls between; recompute once at the candidate.
  const candidate = new Date(nextMidnightAsUtc - offset);
  return new Date(nextMidnightAsUtc - campusOffsetMs(candidate));
}

export interface PlacedHomeVisibility {
  estimatedReadyAt: Date;
  helperVisibleUntil: Date;
  requesterVisibleUntil: Date;
}

/**
 * `null` is the required-ETA invariant failure: the caller must exclude the
 * row from active Home and emit the content-free diagnostic.
 */
export function placedHomeVisibility(document: {
  placedAt?: Date | string | null;
  etaText?: string | null;
}): PlacedHomeVisibility | null {
  const readyAt = estimatedReadyAt(document.placedAt, document.etaText);
  if (!readyAt) return null;
  return {
    estimatedReadyAt: readyAt,
    helperVisibleUntil: new Date(
      readyAt.getTime() + HELPER_PASSIVE_AWARENESS_MS
    ),
    requesterVisibleUntil: campusDayEnd(readyAt),
  };
}

export function reportPlacedHomeInvariantFailure(): void {
  console.error("[route] Placed-order fulfillment invariant failed");
}
