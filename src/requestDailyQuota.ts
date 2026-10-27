import { Request as MealRequest } from "../models/db.js";
import { startOfCampusDay } from "./utils/date.js";

/**
 * Shared W3-R1/W4-Q1 daily-request quota authority. `POST /api/request`
 * (`src/createRequestRoute.ts`) and the W4-Q1 participant-authorized
 * eligibility read (`src/requestEligibilityRoute.ts`) both derive their
 * quota answer from this exact count and threshold, so the two paths cannot
 * drift into different eligibility semantics. This remains unchanged
 * best-effort abuse control (system-contract section 7) — a serial
 * read-before-write, not an atomic quota transaction.
 */
export const DAILY_REQUEST_LIMIT = 3;

/**
 * Counts today's requests for the exact verified principal against the NYU
 * campus calendar day (`America/New_York`), never the host process's local
 * timezone. `principal` must already be the exact normalized address
 * `resolveParticipantAuthority` resolved; this function performs no
 * normalization of its own.
 */
export async function countTodaysRequests(
  principal: string,
  now: Date
): Promise<number> {
  const startOfDay = startOfCampusDay(now);
  return MealRequest.countDocuments({
    email: principal,
    createdAt: { $gte: startOfDay },
  });
}

export function isUnderDailyLimit(count: number): boolean {
  return count < DAILY_REQUEST_LIMIT;
}
