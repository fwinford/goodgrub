/**
 * W4-R5 revision authorities for an existing Request. Two separate counters,
 * deliberately never conflated:
 *
 * - `contentRevision` controls edit concurrency (compare-and-swap) and the
 *   truthful updated-since-notification notice. It advances by one on every
 *   committed content or timing edit.
 * - `notificationGeneration` fences rescheduling-eligibility work. It advances
 *   only on an explicit rescheduling and on withdrawal, never on an ordinary
 *   edit, and is never part of any delivery-deduplication key.
 *
 * A row persisted before these fields existed carries neither. Notification
 * paths read the missing generation as the initial one (a dispatch started for
 * such a row is for generation 1 and nothing has rescheduled it); the Edit
 * mutation refuses a row with no revision instead of inventing one.
 */
export const INITIAL_CONTENT_REVISION = 1;
export const INITIAL_NOTIFICATION_GENERATION = 1;

/** The generation a stored row is at, reading absence as the initial one. */
export function notificationGenerationOf(
  document: { notificationGeneration?: number | null }
): number {
  const stored = document.notificationGeneration;
  return typeof stored === "number" && Number.isInteger(stored) && stored >= 1
    ? stored
    : INITIAL_NOTIFICATION_GENERATION;
}

/**
 * MongoDB clause matching a row that is still at `expected`. The initial
 * generation also matches a row that never stored one, which is exactly what
 * `notificationGenerationOf` reads for it.
 */
export function buildNotificationGenerationFilter(expected: number) {
  if (expected === INITIAL_NOTIFICATION_GENERATION) {
    return {
      $or: [
        { notificationGeneration: INITIAL_NOTIFICATION_GENERATION },
        { notificationGeneration: { $exists: false } },
      ],
    };
  }
  return { notificationGeneration: expected };
}
