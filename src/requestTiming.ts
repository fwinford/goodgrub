import { endOfCampusDay, NYU_TIME_ZONE } from "./utils/date.js";

export { NYU_TIME_ZONE };

/**
 * How long a request stays available to helpers, measured from the instant it
 * becomes visible.
 *
 * This is an absolute duration between two instants, not a calendar offset, so
 * it is unaffected by day boundaries and by DST transitions: a request that
 * becomes visible at 1:00 AM on a fall-back night still stops being available
 * exactly three hours later, even though the New York wall clock advances by
 * only two.
 */
export const REQUEST_VISIBLE_DURATION_MS = 3 * 60 * 60 * 1000;

/**
 * The two backend-owned timing instants of a request, and the only definition
 * of either. Both are absolute instants; neither is a wall-clock reading and
 * neither depends on the requester's device clock or device timezone.
 *
 * `visibleFrom` is when helpers begin seeing the request. `expiresAt` is when
 * it stops being available. Availability filtering
 * (`src/requestAvailability.ts`) reads both; nothing else may recompute them.
 */
export interface RequestTimingWindow {
  visibleFrom: Date;
  expiresAt: Date;
}

function windowStartingAt(visibleFrom: Date): RequestTimingWindow {
  return {
    visibleFrom,
    expiresAt: new Date(visibleFrom.getTime() + REQUEST_VISIBLE_DURATION_MS),
  };
}

/**
 * ASAP: visible from the backend creation instant, for three hours.
 *
 * The requester supplies nothing here — not the start, not the end — so an
 * ASAP request's whole lifetime is decided by server time.
 */
export function resolveAsapTiming(createdAt: Date): RequestTimingWindow {
  return windowStartingAt(createdAt);
}

/**
 * Later: visible from the accepted scheduled start, for three hours.
 *
 * The requester selects one instant. The end is derived from it and is never
 * accepted from a client, so the time a helper is shown and the time the
 * request actually stops being claimable cannot disagree.
 */
export function resolveScheduledTiming(windowStart: Date): RequestTimingWindow {
  return windowStartingAt(windowStart);
}

/**
 * Whether a requester-selected Later start may be accepted, judged against the
 * backend handler's own `now`.
 *
 * A start that has already passed is refused outright. The earlier rule only
 * required that *some* of the three hours remained, which accepted a start the
 * requester could no longer mean: a 1 PM pickup posted at 3 PM would have been
 * written as a request helpers saw immediately, advertising a pickup time two
 * hours gone. "Later" has to be later.
 *
 * The bound is inclusive, and matches `isVisibleNow` in
 * `src/requestAvailability.ts`: a start exactly equal to `now` is the first
 * instant the request is visible, so it is accepted and is visible at once. One
 * millisecond before `now` is refused.
 *
 * Refusal is definitive and happens before any write, email, or notification —
 * the requester's Later selection is never rewritten into an ASAP request on
 * their behalf.
 */
export function isAcceptableScheduledStart(
  windowStart: Date,
  now: Date
): boolean {
  const start = windowStart.getTime();
  return Number.isFinite(start) && start >= now.getTime();
}

/**
 * W4-R5: how long before the end of a request's *original creation day* (NYU
 * campus time) the latest permitted Later start falls. 11:30 PM
 * `America/New_York` is exactly thirty minutes before the next local midnight.
 */
export const LATEST_SCHEDULED_START_BEFORE_DAY_END_MS = 30 * 60 * 1000;

/**
 * The latest start an edit may give a request: 11:30 PM `America/New_York` on
 * the campus day the request was **originally created**. It is derived from the
 * immutable `createdAt`, so editing a request never rolls the horizon forward,
 * and a DST transition day (23 or 25 hours long) still lands on 11:30 PM wall
 * clock because it is measured back from the next local midnight.
 */
export function latestEditableScheduledStart(createdAt: Date): Date {
  return new Date(
    endOfCampusDay(createdAt).getTime() - LATEST_SCHEDULED_START_BEFORE_DAY_END_MS
  );
}
