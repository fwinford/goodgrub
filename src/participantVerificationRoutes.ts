import type { Express } from "express";
import {
  EMAIL_REPLACEMENT_ELIGIBILITY_ROUTE_PATH,
  createEmailReplacementEligibilityHandler,
  emailReplacementEligibilityRateLimiter,
} from "./emailReplacementGate.js";
import { pausePublicAction } from "./publicActionsPause.js";
import {
  PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
  PARTICIPANT_VERIFICATION_ROUTE_PATH,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  participantVerificationBodyParser,
  participantVerificationParserError,
  participantVerificationRateLimiter,
  participantVerificationRedeemRateLimiter,
  redeemParticipantVerification,
  startParticipantVerification,
} from "./participantVerificationRoute.js";

/**
 * Registers the complete participant-verification HTTP surface (W3-I1).
 *
 * Call this before any application-wide body parser. Each chain deliberately
 * owns pause → limiter → route-local parser → handler → sanitized parser-error
 * handling so malformed bytes carrying a live code never reach a global error
 * handler that may log the parser error or its body.
 */
export function registerParticipantVerificationRoutes(app: Express): void {
  app.post(
    PARTICIPANT_VERIFICATION_ROUTE_PATH,
    pausePublicAction(
      PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
      "PUBLIC_ACTIONS_PAUSED"
    ),
    participantVerificationRateLimiter,
    participantVerificationBodyParser,
    startParticipantVerification,
    participantVerificationParserError
  );
  app.post(
    PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
    pausePublicAction(
      PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
      "PUBLIC_ACTIONS_PAUSED"
    ),
    participantVerificationRedeemRateLimiter,
    participantVerificationBodyParser,
    redeemParticipantVerification,
    participantVerificationParserError
  );
  app.get(
    EMAIL_REPLACEMENT_ELIGIBILITY_ROUTE_PATH,
    pausePublicAction(
      PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
      "PUBLIC_ACTIONS_PAUSED"
    ),
    emailReplacementEligibilityRateLimiter,
    createEmailReplacementEligibilityHandler()
  );
}
