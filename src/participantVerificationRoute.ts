import express, { type NextFunction, type Request, type Response } from "express";
import { z } from "zod";
import { NYU_EMAIL_REQUIRED_MESSAGE } from "./allowedEmailDomains.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import { sendParticipantVerificationEmail } from "./emailHelpers.js";
import {
  defaultEmailReplacementGateDependencies,
  refuseBlockedEmailReplacement,
  type EmailReplacementGateDependencies,
} from "./emailReplacementGate.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import {
  VERIFICATION_CODE_LIFETIME_MS,
  defaultParticipantVerificationDependencies,
  issueParticipantAuthority,
  issueParticipantVerificationChallenge,
  redeemParticipantVerificationCode,
  type ParticipantVerificationDependencies,
} from "./participantVerification.js";

export const PARTICIPANT_VERIFICATION_ROUTE_PATH = "/api/participant/verification";
export const PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH =
  "/api/participant/verification/redeem";

export const PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE =
  "Verifying your NYU email is temporarily unavailable.";

/**
 * Separate buckets, because the two halves of one normal verification are not
 * interchangeable. Requesting a code is deliberately tight — it mails a real
 * inbox, and the per-address cooldown already bounds one address, so this bounds
 * one source across addresses. Submitting a code is looser because a person
 * mistyping six digits is ordinary, and the five-attempt challenge bound is what
 * actually stops guessing.
 */
export const participantVerificationRateLimiter = createDay4MutationRateLimiter(5);
export const participantVerificationRedeemRateLimiter =
  createDay4MutationRateLimiter(10);

/**
 * Route-local body parsing, mounted after the pause guard and the limiter and
 * registered ahead of the global parsers in `app.ts` — the same arrangement the
 * emailed confirmation and unsubscribe routes already use, and for a stricter
 * version of the same reason.
 *
 * A global parser runs before any route middleware, so a body it rejects is
 * answered by the global error handler in `app.ts`, which logs the error. A
 * body-parser error carries the offending body, and *this* route's body is the
 * one place in the service where a raw verification code arrives from the wire.
 * A single malformed redemption would therefore print a live six-digit code
 * into the process log. Parsing here instead keeps every malformed-body outcome
 * inside this route, where nothing is logged at all.
 *
 * The limit is deliberately far below the global 100kb: these two payloads are
 * an address and six digits, so anything larger is not a verification attempt.
 */
export const PARTICIPANT_VERIFICATION_BODY_LIMIT = "4kb";

export const participantVerificationBodyParser = express.json({
  limit: PARTICIPANT_VERIFICATION_BODY_LIMIT,
});

export const PARTICIPANT_VERIFICATION_MALFORMED_BODY_MESSAGE =
  "That request could not be read. Please try again.";

/**
 * Final error boundary for both endpoints: a rejected body — malformed JSON,
 * oversized, wrongly encoded — is an unusable verification attempt, so it gets
 * one fixed structured refusal.
 *
 * Nothing is logged, and the refusal deliberately carries no parser detail:
 * both the error and the body it quotes can contain the raw code.
 */
export function participantVerificationParserError(
  _error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (res.headersSent) {
    next(_error);
    return;
  }

  sendDay4Error(
    res,
    400,
    "INVALID_REQUEST",
    PARTICIPANT_VERIFICATION_MALFORMED_BODY_MESSAGE
  );
}

const startVerificationSchema = z.object({ email: z.string() }).strict();
const redeemVerificationSchema = z
  .object({ email: z.string(), code: z.string() })
  .strict();

const VERIFICATION_LIFETIME_MINUTES = Math.round(
  VERIFICATION_CODE_LIFETIME_MS / 60_000
);

function defaultDependencies(): ParticipantVerificationDependencies {
  return {
    ...defaultParticipantVerificationDependencies,
    sendVerificationEmail: (principal, code) =>
      sendParticipantVerificationEmail(
        principal,
        code,
        VERIFICATION_LIFETIME_MINUTES
      ),
  };
}

function invalidEmail(res: Response): Response {
  return sendDay4Error(res, 400, "INVALID_EMAIL", NYU_EMAIL_REQUIRED_MESSAGE);
}

/**
 * `POST /api/participant/verification`
 *
 * Starts or resends the emailed-code challenge. Answers only about the
 * challenge — when it expires and when another may be requested — and never
 * about the address: whether a Participant already exists for it is not
 * something an unauthenticated caller may learn from here.
 */
export function createStartParticipantVerificationHandler(
  overrides: Partial<ParticipantVerificationDependencies> = {},
  gate: EmailReplacementGateDependencies = defaultEmailReplacementGateDependencies
) {
  return async function startParticipantVerification(
    req: Request,
    res: Response
  ): Promise<Response> {
    const dependencies = { ...defaultDependencies(), ...overrides };

    const parsed = startVerificationSchema.safeParse(req.body);
    if (!parsed.success) return invalidEmail(res);

    const principal = normalizeParticipantPrincipal(parsed.data.email);
    if (!principal) return invalidEmail(res);

    if (await refuseBlockedEmailReplacement(req, res, principal, gate)) {
      return res;
    }

    let result;
    try {
      result = await issueParticipantVerificationChallenge(
        principal,
        dependencies
      );
    } catch {
      console.error("[participant] Verification challenge could not be issued");
      return sendDay4Error(
        res,
        503,
        "VERIFICATION_UNAVAILABLE",
        PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
      );
    }

    switch (result.outcome) {
      case "issued":
        return res.status(202).json({
          verification: {
            expiresAt: result.expiresAt.toISOString(),
            resendAvailableAt: result.resendAvailableAt.toISOString(),
          },
        });
      case "cooldown":
        // A refusal that carries the moment it stops being a refusal. Without
        // it the app can only guess when to re-enable Resend, and a guess is
        // either a dead button or a request that is refused again.
        return res.status(429).json({
          error: {
            code: "VERIFICATION_RESEND_TOO_SOON",
            message:
              "A code was just sent. Check your email, then try again in a moment.",
            fields: null,
            resendAvailableAt: result.resendAvailableAt.toISOString(),
          },
        });
      case "emailUnavailable":
        return sendDay4Error(
          res,
          503,
          "VERIFICATION_EMAIL_UNAVAILABLE",
          "We couldn’t send your verification code. Please try again in a moment."
        );
    }
  };
}

/**
 * `POST /api/participant/verification/redeem`
 *
 * The only way participant authority is established. A successful response
 * carries the credential once; nothing derived from it is stored server-side,
 * and the raw code is never echoed back.
 */
export function createRedeemParticipantVerificationHandler(
  overrides: Partial<ParticipantVerificationDependencies> = {},
  gate: EmailReplacementGateDependencies = defaultEmailReplacementGateDependencies
) {
  return async function redeemParticipantVerification(
    req: Request,
    res: Response
  ): Promise<Response> {
    const dependencies = { ...defaultDependencies(), ...overrides };

    const parsed = redeemVerificationSchema.safeParse(req.body);
    if (!parsed.success) return invalidEmail(res);

    const principal = normalizeParticipantPrincipal(parsed.data.email);
    if (!principal) return invalidEmail(res);

    // Checked before the code is consumed, so a refusal burns nothing.
    if (await refuseBlockedEmailReplacement(req, res, principal, gate)) {
      return res;
    }

    let result;
    try {
      result = await redeemParticipantVerificationCode(
        principal,
        parsed.data.code,
        dependencies
      );
    } catch {
      console.error("[participant] Verification redemption failed");
      return sendDay4Error(
        res,
        503,
        "VERIFICATION_UNAVAILABLE",
        PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
      );
    }

    if (result.outcome === "verified") {
      // Rechecked at the transition itself: activity that began while the code
      // was being typed or redeemed must still stop the replacement. The
      // redemption receipt lets the same code succeed once the activity ends.
      if (await refuseBlockedEmailReplacement(req, res, principal, gate)) {
        return res;
      }
      let authority: string;
      try {
        authority = issueParticipantAuthority(
          result.participant,
          dependencies.readSecret()
        );
      } catch {
        // The mailbox proof already committed. Refusing here is honest — the
        // app has no credential and must not pretend otherwise — and the
        // redemption receipt means submitting the same code again succeeds.
        console.error("[participant] Participant authority could not be signed");
        return sendDay4Error(
          res,
          503,
          "VERIFICATION_UNAVAILABLE",
          PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
        );
      }

      return res.status(200).json({
        participant: { email: result.principal },
        authority,
      });
    }

    switch (result.outcome) {
      case "tooManyAttempts":
        return sendDay4Error(
          res,
          429,
          "VERIFICATION_ATTEMPTS_EXCEEDED",
          "Too many incorrect codes. Request a new code to try again."
        );
      case "expired":
        return sendDay4Error(
          res,
          410,
          "VERIFICATION_CODE_EXPIRED",
          "That code has expired. Request a new one."
        );
      case "noChallenge":
        return sendDay4Error(
          res,
          409,
          "VERIFICATION_CODE_NOT_REQUESTED",
          "Request a code for this email first."
        );
      case "invalidCode":
        return sendDay4Error(
          res,
          400,
          "VERIFICATION_CODE_INVALID",
          "That code is incorrect. Check your email and try again."
        );
    }
  };
}

export const startParticipantVerification =
  createStartParticipantVerificationHandler();
export const redeemParticipantVerification =
  createRedeemParticipantVerificationHandler();
