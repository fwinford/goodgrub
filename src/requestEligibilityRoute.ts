import type { Express, NextFunction, Request, Response } from "express";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { readRequestEligibilityState } from "./requestEligibility.js";

/**
 * `GET /api/participant/request-eligibility` (W4-Q1).
 *
 * Bounded participant-authorized prerequisite for a future requester-entry
 * eligibility check (R2). Reports whether the currently verified
 * participant is presently `eligible` or `exhausted` under the existing
 * best-effort three-per-NYU-campus-day quota (`src/requestDailyQuota.ts`),
 * the same shared authority `POST /api/request` uses as its own final
 * create-time check. Read-only and side-effect free: it performs no
 * Request, RequestOperation, participant, notification, subscription, or
 * installation mutation. The result is advisory and current only as of the
 * read; it never reserves quota and never makes a later `POST /api/request`
 * outcome certain.
 */
export const REQUEST_ELIGIBILITY_ROUTE_PATH =
  "/api/participant/request-eligibility";

// A read of the caller's own current quota state, not a new mutation —
// matching `GET /api/participant/email-alerts/state`, this is not gated by
// `PUBLIC_ACTIONS_PAUSED` and gets its own generous read-sized bucket rather
// than sharing or spending `POST /api/request`'s own create allowance.
export const requestEligibilityRateLimiter = createDay4MutationRateLimiter(30);

/**
 * Sets Q1's participant-cache-isolation headers ahead of the rate limiter.
 *
 * `requestEligibilityRateLimiter` is mounted before `getRequestEligibility`
 * ever runs, so a mounted request that trips the limiter answers `429`
 * straight from the shared `createDay4MutationRateLimiter` handler — which
 * never sets `Cache-Control`/`Vary` — without this route's own response ever
 * executing. Without this middleware that limiter-generated `429` would be
 * the one Q1 outcome not isolated per participant credential, breaking the
 * "success, authority refusal, and lookup failure" isolation guarantee for
 * the rate-limited case too. `getRequestEligibility` still sets the same two
 * headers itself on every path it reaches, so calling it directly (as the
 * focused unit tests do) remains fully covered without this middleware.
 */
export function requestEligibilityCacheIsolation(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);
  next();
}

/**
 * The single source of truth for Q1's mounted middleware ordering:
 * `requestEligibilityCacheIsolation` MUST run before anything that can
 * terminate the request, including the rate limiter, so a limiter-owned 429
 * is isolated exactly like every other Q1 outcome. `app.ts`'s registration,
 * `registerRequestEligibilityRoute` below, and the mounted rate-limit proof
 * in `requestEligibilityRoute.test.ts` all build their middleware array from
 * this one function rather than each separately restating the order, so
 * they cannot silently drift apart. Generic over `limiter`/`handler` rather
 * than fixed to the production limiter and handler so the mounted test can
 * substitute a cheap limiter and a trivial final handler while still proving
 * the real production ordering.
 */
export function buildRequestEligibilityMiddlewareChain<
  Limiter extends (...args: any[]) => any,
  Handler extends (...args: any[]) => any
>(limiter: Limiter, handler: Handler) {
  return [requestEligibilityCacheIsolation, limiter, handler] as const;
}

export async function getRequestEligibility(
  req: Request,
  res: Response
): Promise<Response> {
  // Set before any authority resolution or database work, matching the N0
  // Email-alert-state read: this result is specific to whichever principal
  // (if any) the presented credential resolves to, and must never be cached
  // or reused across a different credential or no credential at all.
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);

  // Resolved before any database work, so an unverified or unusable caller
  // learns nothing beyond the shared refusal envelope and no quota lookup is
  // attempted on their behalf.
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  try {
    const now = new Date();
    const state = await readRequestEligibilityState(
      authority.participant.principal,
      now
    );
    return res.json({ eligibility: state.eligibility });
  } catch {
    console.error("[route] Request eligibility lookup failed");
    return sendDay4Error(
      res,
      503,
      PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
      PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
    );
  }
}

export function registerRequestEligibilityRoute(app: Express): void {
  app.get(
    REQUEST_ELIGIBILITY_ROUTE_PATH,
    ...buildRequestEligibilityMiddlewareChain(
      requestEligibilityRateLimiter,
      getRequestEligibility
    )
  );
}
