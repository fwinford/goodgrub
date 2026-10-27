import type { Express, Request, Response } from "express";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { readEmailAlertState } from "./emailAlertState.js";

/**
 * `GET /api/participant/email-alerts/state` (W4-N0).
 *
 * Pulled-forward narrow Email-state prerequisite for the final W4-H2
 * Settings Email-toggle. Reports whether the participant's CURRENT verified
 * NYU email — derived only from participant authority, never a
 * caller-supplied address — is presently an active/confirmed Email Request
 * Alerts subscriber. Read-only and side-effect free: it does not create,
 * confirm, unsubscribe, or otherwise mutate Subscriber state.
 */
export const EMAIL_ALERT_STATE_ROUTE_PATH = "/api/participant/email-alerts/state";

// A read of the caller's own current Subscriber truth, not a new mutation —
// matching `GET /api/participant/active-reservation`, this is not gated by
// `PUBLIC_ACTIONS_PAUSED` and gets its own generous read-sized bucket rather
// than sharing or spending any mutation route's allowance.
export const emailAlertStateRateLimiter = createDay4MutationRateLimiter(30);

export async function getEmailAlertState(
  req: Request,
  res: Response
): Promise<Response> {
  // Set before any authority resolution or database work, so success,
  // authority-refusal, and lookup-failure responses are all isolated the
  // same way `GET /api/requests` isolates its own caller-specific response:
  // this result is specific to whichever principal (if any) the presented
  // credential resolves to, and must never be cached or reused across a
  // different credential or no credential at all.
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);

  // Resolved before any database work, so an unverified or unusable caller
  // learns nothing beyond the shared refusal envelope and no Subscriber
  // lookup is attempted on their behalf.
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  try {
    const state = await readEmailAlertState(authority.participant.principal);
    return res.json({ email: { active: state.active } });
  } catch {
    console.error("[route] Email alert state lookup failed");
    return sendDay4Error(
      res,
      503,
      PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
      PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
    );
  }
}

export function registerEmailAlertStateRoute(app: Express): void {
  app.get(
    EMAIL_ALERT_STATE_ROUTE_PATH,
    emailAlertStateRateLimiter,
    getEmailAlertState
  );
}
