import { countTodaysRequests, isUnderDailyLimit } from "./requestDailyQuota.js";

/**
 * W4-Q1 participant-authorized read of whether the currently verified
 * participant is presently eligible to attempt another request under the
 * existing best-effort three-per-NYU-campus-day quota. The result exposes
 * only the accepted binary product state — no count, remaining, or reset
 * time — and is advisory/current-as-of-read only: `POST /api/request`
 * remains the sole authoritative create-time quota enforcement, using the
 * same shared authority (`src/requestDailyQuota.ts`).
 */
export type RequestEligibility = "eligible" | "exhausted";

export interface RequestEligibilityState {
  eligibility: RequestEligibility;
}

export async function readRequestEligibilityState(
  principal: string,
  now: Date
): Promise<RequestEligibilityState> {
  const count = await countTodaysRequests(principal, now);
  return { eligibility: isUnderDailyLimit(count) ? "eligible" : "exhausted" };
}
