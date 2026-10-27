import type { Express, Request, Response } from "express";
import mongoose from "mongoose";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  ParticipantAccountFenceUnavailable,
  touchParticipantAccountsInSession,
} from "./participantAccountFence.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { unsubscribeSubscriberByPrincipal } from "./participantEmailUnsubscribe.js";
import { pausePublicAction } from "./publicActionsPause.js";

/**
 * W3-N2 participant-authorized email unsubscribe surface.
 *
 * The only new relationship this slice adds between Participant and
 * Subscriber identity: a valid participant credential may turn off email
 * alerts for the exact normalized address `resolveParticipantAuthority`
 * resolves it to, and nothing else. The request body carries no email and no
 * Subscriber ID — there is nothing here for a caller to supply beyond the
 * credential itself, so the route accepts (and needs) no body at all.
 *
 * Declarative and idempotent, exactly like `PUT /api/installations/push`: a
 * repeated call, a retry after a dropped response, or concurrent calls from
 * two devices holding the same credential all converge on the same result
 * with no special-casing.
 */
export const PARTICIPANT_EMAIL_UNSUBSCRIBE_ROUTE_PATH =
  "/api/participant/email-alerts/unsubscribe";

export const PARTICIPANT_EMAIL_UNSUBSCRIBE_UNAVAILABLE_MESSAGE =
  "Turning off email alerts is temporarily unavailable.";

// Its own bucket, matching the installation-push and claim mutation buckets:
// this action must not spend, or be spent by, another public action's
// allowance.
export const participantEmailUnsubscribeRateLimiter =
  createDay4MutationRateLimiter(10);

export interface ParticipantEmailUnsubscribeDependencies {
  now: () => Date;
}

const defaultDependencies: ParticipantEmailUnsubscribeDependencies = {
  now: () => new Date(),
};

export function createParticipantEmailUnsubscribeHandler(
  overrides: Partial<ParticipantEmailUnsubscribeDependencies> = {}
) {
  const dependencies = { ...defaultDependencies, ...overrides };

  return async function unsubscribeParticipantEmailAlerts(
    req: Request,
    res: Response
  ): Promise<Response> {
    // Resolved before anything else, so an unverified or stale caller learns
    // nothing about this operation beyond the shared refusal envelope, and no
    // database mutation is attempted on their behalf.
    const authority = await resolveParticipantAuthority(req);
    if (!authority.ok) {
      return sendParticipantAuthorityRefusal(res, authority.refusal);
    }

    const participantId = authority.participant.participantId;
    const session = await mongoose.startSession();
    try {
      await session.withTransaction(
        async () => {
          const fenced = await touchParticipantAccountsInSession(
            [participantId],
            session,
            new Map([[participantId, authority.participant.authorityVersion]])
          );
          const participant = fenced.get(participantId);
          if (!participant || participant.principal !== authority.participant.principal) {
            throw new ParticipantAccountFenceUnavailable();
          }
          await unsubscribeSubscriberByPrincipal(
            participant.principal,
            dependencies.now(),
            session
          );
        },
        {
          readConcern: { level: "snapshot" },
          writeConcern: { w: "majority" },
        }
      );
    } catch (error) {
      if (error instanceof ParticipantAccountFenceUnavailable) {
        return sendParticipantAuthorityRefusal(res, "invalid");
      }
      throw error;
    } finally {
      await session.endSession();
    }

    return res.json({ email: { unsubscribed: true } });
  };
}

export const unsubscribeParticipantEmailAlerts =
  createParticipantEmailUnsubscribeHandler();

/**
 * Registered ahead of the global body parsers alongside the other
 * participant-gated routes. There is no body to parse — the credential
 * travels entirely in `x-commonplate-participant` — but pause and the
 * participant-authority gate must still run before any global middleware
 * could otherwise see this request.
 */
export function registerParticipantEmailUnsubscribeRoute(app: Express): void {
  app.post(
    PARTICIPANT_EMAIL_UNSUBSCRIBE_ROUTE_PATH,
    pausePublicAction(
      PARTICIPANT_EMAIL_UNSUBSCRIBE_UNAVAILABLE_MESSAGE,
      "PUBLIC_ACTIONS_PAUSED"
    ),
    participantEmailUnsubscribeRateLimiter,
    unsubscribeParticipantEmailAlerts
  );
}
