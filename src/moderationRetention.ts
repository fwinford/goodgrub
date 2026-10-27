import {
  MODERATION_HISTORY_RETENTION_YEARS,
  REPORT_EVIDENCE_RETENTION_MS,
} from "./moderationConstants.js";

/**
 * Evidence and history clocks (boundary contract RH, "The one formula").
 *
 * ```
 * evidenceDeadline = max(anchor + 90 days, latest hold end)
 * historyDeadline  = max(anchor + 1 year,  latest hold end)
 * ```
 *
 * A hold that ends after the base deadline makes deletion due at the hold end,
 * not a fresh 90 days or year. While a record is held by live state (an Open
 * case, an Active suspension, a linked open case, or an active hold) it has no
 * deadline at all, which is what an absent `deleteAt` means.
 *
 * Everything here is pure: callers read the state and pass it in, then write
 * the result in the same transaction as the event that started the clock.
 */

export type SuspensionOriginForAnchor = "report" | "manual";

export interface RetentionAnchorInput {
  /** `closedAt` of the linked case, when there is one and it is closed. */
  closedAt?: Date | null;
  /** `liftedAt` of the linked suspension, when there is one and it is lifted. */
  liftedAt?: Date | null;
}

/**
 * The instant the base periods are measured from, or `null` when the anchor is
 * not yet established (the record stays held):
 * - case closed with no suspension (including removal-only closure): `closedAt`;
 * - report-linked suspension: `max(closedAt, liftedAt)` once both exist;
 * - manual suspension: `liftedAt`.
 */
export function retentionAnchor(input: RetentionAnchorInput): Date | null {
  const closedAt = input.closedAt ?? null;
  const liftedAt = input.liftedAt ?? null;
  if (closedAt && liftedAt) {
    return closedAt.getTime() >= liftedAt.getTime() ? closedAt : liftedAt;
  }
  return closedAt ?? liftedAt;
}

/**
 * Adds calendar years in UTC: the same month, day and UTC clock time in the
 * target year, so "one year" is one year and not 365 days.
 *
 * Week HQ clarification (2026-10-18, resolving review finding F7): when the
 * anchor is February 29 and the target year has no February 29, the result is
 * **February 28** at the same UTC clock time, never March 1
 * (2028-02-29T12:00Z + 1 y = 2029-02-28T12:00Z). Every other anchor maps to the
 * same month and day. Only the history deadline uses this; the 90-day evidence
 * deadline is fixed-duration arithmetic.
 */
export function addYearsUtc(date: Date, years: number): Date {
  const targetYear = date.getUTCFullYear() + years;
  const month = date.getUTCMonth();
  // Day 0 of the next month is the last day of this one, in the target year.
  const lastDayOfMonth = new Date(Date.UTC(targetYear, month + 1, 0)).getUTCDate();
  const result = new Date(date.getTime());
  // Setting the day to 1 first keeps `setUTCFullYear` from overflowing into the
  // next month before the clamped day is applied.
  result.setUTCDate(1);
  result.setUTCFullYear(targetYear);
  result.setUTCDate(Math.min(date.getUTCDate(), lastDayOfMonth));
  return result;
}

function laterOf(a: Date, b: Date | null): Date {
  return b && b.getTime() > a.getTime() ? b : a;
}

export function evidenceDeadline(anchor: Date, latestHoldEnd: Date | null): Date {
  return laterOf(new Date(anchor.getTime() + REPORT_EVIDENCE_RETENTION_MS), latestHoldEnd);
}

export function historyDeadline(anchor: Date, latestHoldEnd: Date | null): Date {
  return laterOf(addYearsUtc(anchor, MODERATION_HISTORY_RETENTION_YEARS), latestHoldEnd);
}

export interface RetentionClocks {
  /** `deleteAt` for detailed evidence, or `null` for "held by live state". */
  evidenceDeleteAt: Date | null;
  /** `deleteAt` for minimal history, or `null` for "held by live state". */
  historyDeleteAt: Date | null;
}

export interface RetentionClockInput extends RetentionAnchorInput {
  /** The record's own lifecycle has ended (case Closed, suspension Lifted). */
  ended: boolean;
  /**
   * Another live reason keeps the record: an active linked suspension, a
   * linked case that is still Open, or an active explicit hold.
   */
  heldByLiveState: boolean;
  /** The latest `endedAt` among released holds on the target, if any. */
  latestHoldEnd?: Date | null;
}

export const HELD: RetentionClocks = { evidenceDeleteAt: null, historyDeleteAt: null };

/** The clocks for one target, from its state. */
export function computeRetentionClocks(input: RetentionClockInput): RetentionClocks {
  if (!input.ended || input.heldByLiveState) return HELD;
  const anchor = retentionAnchor(input);
  if (!anchor) return HELD;
  const holdEnd = input.latestHoldEnd ?? null;
  return {
    evidenceDeleteAt: evidenceDeadline(anchor, holdEnd),
    historyDeleteAt: historyDeadline(anchor, holdEnd),
  };
}

/**
 * Reads treat a record whose `deleteAt` has passed as absent, because the TTL
 * monitor is periodic and a row can outlive its deadline by the monitor's lag.
 * This is the principle `reservationRoute` already applies to Request
 * retention. A record with no `deleteAt` is held, hence present.
 */
export function notPastDeleteAt(now: Date): Record<string, unknown> {
  return {
    $or: [{ deleteAt: { $exists: false } }, { deleteAt: { $gt: now } }],
  };
}

export function isPastDeleteAt(record: { deleteAt?: Date | null }, now: Date): boolean {
  return Boolean(record.deleteAt) && (record.deleteAt as Date).getTime() <= now.getTime();
}
