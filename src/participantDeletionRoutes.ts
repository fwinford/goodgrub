import type { Express } from "express";
import { pausePublicAction } from "./publicActionsPause.js";
import {
  PARTICIPANT_DELETION_CANCEL_ROUTE_PATH,
  PARTICIPANT_DELETION_CHALLENGE_ROUTE_PATH,
  PARTICIPANT_DELETION_COMPLETE_ROUTE_PATH,
  PARTICIPANT_DELETION_ELIGIBILITY_ROUTE_PATH,
  PARTICIPANT_DELETION_RECOVERY_ROUTE_PATH,
  PARTICIPANT_DELETION_PROVENANCE_ROUTE_PATH,
  PARTICIPANT_DELETION_REDEEM_ROUTE_PATH,
  PARTICIPANT_DELETION_ROUTE_PATH,
  PARTICIPANT_DELETION_STATUS_ROUTE_PATH,
  PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE,
  cancelParticipantDeletion,
  completeParticipantDeletionRoute,
  createParticipantDeletion,
  compareParticipantDeletionProvenance,
  getParticipantDeletionEligibility,
  getParticipantDeletionStatus,
  issueParticipantDeletionChallengeRoute,
  participantDeletionBodyParser,
  participantDeletionChallengeRateLimiter,
  participantDeletionMutationRateLimiter,
  participantDeletionParserError,
  participantDeletionReadRateLimiter,
  participantDeletionRecoveryRateLimiter,
  recoverParticipantDeletionCompletion,
  redeemParticipantDeletionChallengeRoute,
} from "./participantDeletionRoute.js";

/**
 * Registers the complete W4-P2 account-deletion HTTP surface (Checkpoint 8).
 *
 * Every route except recovery sits behind `pausePublicAction`, following the
 * existing participant-verification/block convention: an account-lifecycle
 * mutation must fail closed the same way an ordinary public action does when
 * deployment configuration pauses it. Recovery is deliberately excluded: by
 * the time it is called the account that `PUBLIC_ACTIONS_PAUSED` protects may
 * already be gone, and recovery performs no mutation of its own — it is a
 * read-only, capability-gated lookup, already fail-closed on every other
 * axis (digest match, 7-day expiry, generic refusal).
 */
export function registerParticipantDeletionRoutes(app: Express): void {
  app.post(
    PARTICIPANT_DELETION_PROVENANCE_ROUTE_PATH,
    pausePublicAction(PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    participantDeletionReadRateLimiter,
    participantDeletionBodyParser,
    compareParticipantDeletionProvenance,
    participantDeletionParserError
  );
  app.get(
    PARTICIPANT_DELETION_ELIGIBILITY_ROUTE_PATH,
    pausePublicAction(PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    participantDeletionReadRateLimiter,
    getParticipantDeletionEligibility
  );
  app.post(
    PARTICIPANT_DELETION_ROUTE_PATH,
    pausePublicAction(PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    participantDeletionMutationRateLimiter,
    createParticipantDeletion
  );
  app.get(
    PARTICIPANT_DELETION_STATUS_ROUTE_PATH,
    pausePublicAction(PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    participantDeletionReadRateLimiter,
    getParticipantDeletionStatus
  );
  app.post(
    PARTICIPANT_DELETION_CANCEL_ROUTE_PATH,
    pausePublicAction(PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    participantDeletionMutationRateLimiter,
    participantDeletionBodyParser,
    cancelParticipantDeletion,
    participantDeletionParserError
  );
  app.post(
    PARTICIPANT_DELETION_CHALLENGE_ROUTE_PATH,
    pausePublicAction(PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    participantDeletionChallengeRateLimiter,
    participantDeletionBodyParser,
    issueParticipantDeletionChallengeRoute,
    participantDeletionParserError
  );
  app.post(
    PARTICIPANT_DELETION_REDEEM_ROUTE_PATH,
    pausePublicAction(PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    participantDeletionMutationRateLimiter,
    participantDeletionBodyParser,
    redeemParticipantDeletionChallengeRoute,
    participantDeletionParserError
  );
  app.post(
    PARTICIPANT_DELETION_COMPLETE_ROUTE_PATH,
    pausePublicAction(PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    participantDeletionMutationRateLimiter,
    participantDeletionBodyParser,
    completeParticipantDeletionRoute,
    participantDeletionParserError
  );
  app.post(
    PARTICIPANT_DELETION_RECOVERY_ROUTE_PATH,
    // Body parsed first so the recovery rate limiter's operationId/IP key
    // can read it; the parser's own 4kb limit keeps this cheap even before
    // any rate limiting runs.
    participantDeletionBodyParser,
    participantDeletionRecoveryRateLimiter,
    recoverParticipantDeletionCompletion,
    participantDeletionParserError
  );
}
