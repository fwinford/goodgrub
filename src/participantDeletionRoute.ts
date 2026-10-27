import express, { type NextFunction, type Request, type Response } from "express";
import rateLimit, { ipKeyGenerator } from "express-rate-limit";
import mongoose from "mongoose";
import { z } from "zod";
import { Participant } from "../models/db.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { ParticipantAccountFenceUnavailable } from "./participantAccountFence.js";
import { ParticipantIdentityConfigurationError } from "./participantIdentityKeys.js";
import {
  cancelParticipantDeletionOperation,
  createOrResolveParticipantDeletionOperation,
  issueParticipantDeletionChallenge,
  readParticipantDeletionStatus,
  redeemParticipantDeletionChallenge,
  type DeletionOwner,
  type ParticipantDeletionStatus,
} from "./participantDeletionOperations.js";
import {
  classifyDeletionHelperObservation,
  type HelperLockSnapshot,
} from "./participantDeletionHelperAdapter.js";
import { classifyDeletionRequesterObservation } from "./participantDeletionRequesterAdapter.js";
import { evaluateParticipantDeletionReadiness } from "./participantDeletionReadinessEvaluator.js";
import { completeParticipantDeletionOperation } from "./participantDeletionCompletion.js";
import { readCompletedDeletionRecovery } from "./participantDeletionRecovery.js";
import { DELETION_CHALLENGE_LIFETIME_MS } from "./participantDeletionSecurity.js";
import { sendParticipantDeletionChallengeEmail } from "./emailHelpers.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  DELETION_NAMESPACE_HEADER,
  DeletionNamespaceUnavailable,
  isDeletionNamespaceBinding,
} from "./participantDeletionNamespace.js";
import { compareDeletionRecordedLedger } from "./participantDeletionProvenance.js";
import { isValidOperationAuthorityId } from "./requestOperationAuthority.js";

const DELETION_CHALLENGE_LIFETIME_MINUTES = Math.round(
  DELETION_CHALLENGE_LIFETIME_MS / 60_000
);

/**
 * Checkpoint 8's public account-deletion surface (W4-P2).
 *
 * Every mutating route resolves the caller's current live authority first and
 * builds its `DeletionOwner` only from that resolved identity — never from a
 * client-supplied participant id or email. Every response uses the same
 * generic refusal vocabulary the internal lifecycle functions already return;
 * none of them is told which specific blocker, moderation state, or retained
 * identity caused a refusal.
 */

export const PARTICIPANT_DELETION_ELIGIBILITY_ROUTE_PATH =
  "/api/participant/deletion/eligibility";
export const PARTICIPANT_DELETION_ROUTE_PATH = "/api/participant/deletion";
export const PARTICIPANT_DELETION_STATUS_ROUTE_PATH =
  "/api/participant/deletion/status";
export const PARTICIPANT_DELETION_CANCEL_ROUTE_PATH =
  "/api/participant/deletion/cancel";
export const PARTICIPANT_DELETION_CHALLENGE_ROUTE_PATH =
  "/api/participant/deletion/challenge";
export const PARTICIPANT_DELETION_REDEEM_ROUTE_PATH =
  "/api/participant/deletion/redeem";
export const PARTICIPANT_DELETION_COMPLETE_ROUTE_PATH =
  "/api/participant/deletion/complete";
export const PARTICIPANT_DELETION_RECOVERY_ROUTE_PATH =
  "/api/participant/deletion/recovery";
export const PARTICIPANT_DELETION_PROVENANCE_ROUTE_PATH =
  "/api/participant/deletion/provenance";

export const PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE =
  "Account deletion is temporarily unavailable. Please try again in a moment.";

const DELETION_OPERATION_NOT_FOUND_CODE = "DELETION_OPERATION_NOT_FOUND";
const DELETION_OPERATION_NOT_FOUND_MESSAGE =
  "We couldn’t find that account-deletion request.";
const DELETION_OPERATION_STALE_CODE = "DELETION_OPERATION_STALE";
const DELETION_OPERATION_STALE_MESSAGE =
  "This account-deletion request changed. Check its current status and try again.";
const DELETION_BLOCKED_CODE = "DELETION_BLOCKED";
const DELETION_BLOCKED_MESSAGE =
  "You have something in progress that must be resolved before deleting your account.";
const DELETION_NOT_READY_CODE = "DELETION_NOT_READY";
const DELETION_NOT_READY_MESSAGE =
  "This account-deletion request isn’t ready for that step yet.";
const DELETION_CHALLENGE_COOLDOWN_CODE = "DELETION_CHALLENGE_COOLDOWN";
const DELETION_CHALLENGE_COOLDOWN_MESSAGE =
  "Please wait before requesting another code.";
const DELETION_EMAIL_UNAVAILABLE_CODE = "DELETION_EMAIL_UNAVAILABLE";
const DELETION_EMAIL_UNAVAILABLE_MESSAGE =
  "We couldn’t send your deletion code. Please try again in a moment.";
const DELETION_CODE_INVALID_CODE = "DELETION_CODE_INVALID";
const DELETION_CODE_INVALID_MESSAGE = "That code is incorrect.";
const DELETION_CODE_EXPIRED_CODE = "DELETION_CODE_EXPIRED";
const DELETION_CODE_EXPIRED_MESSAGE =
  "That code expired. Request a new one.";
const DELETION_AUTHORIZATION_EXPIRED_CODE = "DELETION_AUTHORIZATION_EXPIRED";
const DELETION_AUTHORIZATION_EXPIRED_MESSAGE =
  "Your deletion authorization expired. Start the code step again.";
const DELETION_CAPABILITY_INVALID_CODE = "DELETION_CAPABILITY_INVALID";
const DELETION_CAPABILITY_INVALID_MESSAGE =
  "We couldn’t confirm this deletion request on this device.";
const DELETION_TERMINAL_CODE = "DELETION_TERMINAL";
const DELETION_TERMINAL_MESSAGE =
  "This account-deletion request already finished.";

export const participantDeletionReadRateLimiter = createDay4MutationRateLimiter(30);
export const participantDeletionMutationRateLimiter = createDay4MutationRateLimiter(10);
export const participantDeletionChallengeRateLimiter = createDay4MutationRateLimiter(5);

/**
 * The accepted design (P2 slice, section F) requires the recovery lookup to
 * be rate-limited per operationId/IP, not per IP alone: a capability is
 * unguessable, but the accepted boundary is still named that way, so the key
 * composes both. Requires the body parser to run first so `operationId` is
 * already parsed; a missing/malformed body still buckets by IP alone rather
 * than failing the limiter itself.
 */
export const participantDeletionRecoveryRateLimiter = rateLimit({
  windowMs: 60_000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => {
    const operationId = (req.body as { operationId?: unknown } | undefined)?.operationId;
    const ip = ipKeyGenerator(req.ip ?? "unknown");
    return typeof operationId === "string" ? `${ip}:${operationId}` : ip;
  },
  handler: (_req, res) =>
    res.status(429).json({
      error: { code: "RATE_LIMITED", message: "Too many attempts. Please wait a moment and try again.", fields: null },
    }),
});

/**
 * Route-local body parsing for every POST route here, mounted ahead of the
 * global body parser in `app.ts` for the same reason verification's redeem
 * route is: a bodies here can carry a live deletion code or the one-time
 * recovery capability, and a global parser's error path logs the offending
 * body. Parsing locally keeps every malformed-body outcome inside this
 * module, which never logs a body.
 */
export const PARTICIPANT_DELETION_BODY_LIMIT = "4kb";
export const participantDeletionBodyParser = express.json({
  limit: PARTICIPANT_DELETION_BODY_LIMIT,
});

export const PARTICIPANT_DELETION_MALFORMED_BODY_MESSAGE =
  "That request could not be read. Please try again.";

export function participantDeletionParserError(
  error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (res.headersSent) {
    next(error);
    return;
  }
  sendDay4Error(res, 400, "INVALID_REQUEST", PARTICIPANT_DELETION_MALFORMED_BODY_MESSAGE);
}

function sendUnavailable(res: Response): Response {
  return sendDay4Error(res, 503, "PARTICIPANT_VERIFICATION_UNAVAILABLE", PARTICIPANT_DELETION_UNAVAILABLE_MESSAGE);
}

function isConfigurationUnavailable(error: unknown): boolean {
  return (
    error instanceof ParticipantAccountFenceUnavailable ||
    error instanceof DeletionNamespaceUnavailable ||
    error instanceof ParticipantIdentityConfigurationError
  );
}

const operationIdSchema = z.string().uuid();

function statusPayload(status: ParticipantDeletionStatus) {
  return {
    operationId: status.operationId,
    ...(status.namespaceBinding ? { namespaceBinding: status.namespaceBinding } : {}),
    phase: status.phase,
    readinessGeneration: status.readinessGeneration,
    ...(status.challenge
      ? {
          challenge: {
            expiresAt: status.challenge.expiresAt,
            cooldownEndsAt: status.challenge.cooldownEndsAt,
            attemptsRemaining: status.challenge.attemptsRemaining,
          },
        }
      : {}),
    ...(status.authorization
      ? { authorization: { expiresAt: status.authorization.expiresAt } }
      : {}),
  };
}

/**
 * `GET /api/participant/deletion/eligibility` — read-only, no operation
 * required. Reports only the accepted user-actionable categories (an active
 * request obligation, an active helping/pickup obligation, or an unreadable
 * state), never moderation/safety data: it reuses only the two accepted
 * requester/helper classifiers, which never read moderation collections.
 */
export async function getParticipantDeletionEligibility(
  req: Request,
  res: Response
): Promise<Response> {
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);

  try {
    const participantId = new mongoose.Types.ObjectId(authority.participant.participantId);
    const row = await Participant.findOne({
      _id: participantId,
      authorityVersion: authority.participant.authorityVersion,
    })
      .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
      .lean<HelperLockSnapshot | null>()
      .exec();
    if (!row) return sendUnavailable(res);

    const now = new Date();
    const [requester, helper] = await Promise.all([
      classifyDeletionRequesterObservation(participantId, now),
      classifyDeletionHelperObservation(
        participantId,
        authority.participant.principal,
        {
          activeReservationRequestId: row.activeReservationRequestId,
          activeReservationClaimExpiresAt: row.activeReservationClaimExpiresAt,
        },
        now.getTime()
      ),
    ]);

    const categories = new Set<string>();
    if (requester === "withdrawalRequired") categories.add("activeRequest");
    if (requester === "helperOrPickup" || helper === "helperOrPickup") {
      categories.add("activeHelpingOrPickup");
    }
    if (requester === "unknown" || helper === "unknown") categories.add("unknown");

    return res.json({ eligible: categories.size === 0, categories: [...categories] });
  } catch (error) {
    if (isConfigurationUnavailable(error)) return sendUnavailable(res);
    console.error("[route] Participant deletion eligibility check failed");
    return sendUnavailable(res);
  }
}

/**
 * `POST /api/participant/deletion` — creates a new deletion operation in
 * `waiting` or `ready`, as determined by the same classifiers eligibility
 * uses. Never sends a code. Idempotent: an existing active operation is
 * returned as-is, never recreated or reset.
 */
export async function createParticipantDeletion(
  req: Request,
  res: Response
): Promise<Response> {
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);

  try {
    const participantId = new mongoose.Types.ObjectId(authority.participant.participantId);
    const row = await Participant.findOne({
      _id: participantId,
      authorityVersion: authority.participant.authorityVersion,
    })
      .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
      .lean<HelperLockSnapshot | null>()
      .exec();
    if (!row) return sendUnavailable(res);

    const now = new Date();
    const [requester, helper] = await Promise.all([
      classifyDeletionRequesterObservation(participantId, now),
      classifyDeletionHelperObservation(
        participantId,
        authority.participant.principal,
        {
          activeReservationRequestId: row.activeReservationRequestId,
          activeReservationClaimExpiresAt: row.activeReservationClaimExpiresAt,
        },
        now.getTime()
      ),
    ]);
    const clear = requester === "clear" && helper === "clear";

    const created = await createOrResolveParticipantDeletionOperation({
      participantId,
      canonicalEmail: authority.participant.principal,
      authorityVersion: authority.participant.authorityVersion,
      initialPhase: clear ? "ready" : "waiting",
    });
    return res.status(created.outcome === "created" ? 201 : 200).json(statusPayload(created.status));
  } catch (error) {
    if (isConfigurationUnavailable(error)) return sendUnavailable(res);
    console.error("[route] Participant deletion creation failed");
    return sendUnavailable(res);
  }
}

function readOperationId(body: unknown): string | null {
  const parsed = operationIdSchema.safeParse((body as { operationId?: unknown } | null)?.operationId);
  return parsed.success ? parsed.data : null;
}

function ownerOf(
  authority: { participantId: string; principal: string; authorityVersion: number },
  operationId: string,
  req: Request
): DeletionOwner {
  const namespaceBinding = req.headers?.[DELETION_NAMESPACE_HEADER];
  if (!isDeletionNamespaceBinding(namespaceBinding)) throw new DeletionNamespaceUnavailable();
  return {
    operationId,
    namespaceBinding,
    participantId: new mongoose.Types.ObjectId(authority.participantId),
    canonicalEmail: authority.principal,
    authorityVersion: authority.authorityVersion,
  };
}

const provenanceBodySchema = z.object({
  operationId: z.string().uuid(),
  recordedLedger: z.string().refine(isValidOperationAuthorityId),
}).strict();

export async function compareParticipantDeletionProvenance(
  req: Request,
  res: Response
): Promise<Response> {
  const parsed = provenanceBodySchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return sendDay4Error(res, 400, "INVALID_REQUEST", "This request is invalid.");
  }
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);
  try {
    const matches = await compareDeletionRecordedLedger(
      ownerOf(authority.participant, parsed.data.operationId, req),
      parsed.data.recordedLedger
    );
    res.setHeader("Cache-Control", "no-store");
    return res.json({ matches });
  } catch (error) {
    if (!isConfigurationUnavailable(error)) {
      console.error("[route] Participant deletion provenance comparison failed");
    }
    return sendUnavailable(res);
  }
}

/**
 * `GET /api/participant/deletion/status?operationId=...` — minimum necessary
 * projection for reconciliation. Never reveals another participant's
 * operation: ownership is proven by the caller's own resolved authority.
 */
export async function getParticipantDeletionStatus(
  req: Request,
  res: Response
): Promise<Response> {
  const parsed = operationIdSchema.safeParse(req.query.operationId);
  if (!parsed.success) {
    return sendDay4Error(res, 400, "INVALID_OPERATION_ID", "The deletion operation ID is invalid.");
  }
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);

  try {
    const owner = ownerOf(authority.participant, parsed.data, req);
    let status = await readParticipantDeletionStatus(owner);
    if (!status) {
      return sendDay4Error(res, 404, DELETION_OPERATION_NOT_FOUND_CODE, DELETION_OPERATION_NOT_FOUND_MESSAGE);
    }
    if (status.phase !== "completed" && status.phase !== "canceled") {
      const readiness = await evaluateParticipantDeletionReadiness(owner, status.readinessGeneration, {});
      if (readiness.outcome === "notOwned") {
        return sendDay4Error(res, 404, DELETION_OPERATION_NOT_FOUND_CODE, DELETION_OPERATION_NOT_FOUND_MESSAGE);
      }
      // Re-read even after a stale/inactive evaluation: a concurrent lifecycle
      // transition must not be replaced by the pre-evaluation snapshot.
      status = await readParticipantDeletionStatus(owner);
      if (!status) {
        return sendDay4Error(res, 404, DELETION_OPERATION_NOT_FOUND_CODE, DELETION_OPERATION_NOT_FOUND_MESSAGE);
      }
    }
    res.setHeader("Cache-Control", "private, no-store");
    return res.json(statusPayload(status));
  } catch (error) {
    if (isConfigurationUnavailable(error)) return sendUnavailable(res);
    console.error("[route] Participant deletion status check failed");
    return sendUnavailable(res);
  }
}

/** `POST /api/participant/deletion/cancel` — cancels any eligible nonterminal operation. */
export async function cancelParticipantDeletion(
  req: Request,
  res: Response
): Promise<Response> {
  const operationId = readOperationId(req.body);
  if (!operationId) {
    return sendDay4Error(res, 400, "INVALID_OPERATION_ID", "The deletion operation ID is invalid.");
  }
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);

  try {
    const result = await cancelParticipantDeletionOperation(ownerOf(authority.participant, operationId, req));
    if (result.outcome === "terminal") {
      return sendDay4Error(res, 409, DELETION_TERMINAL_CODE, DELETION_TERMINAL_MESSAGE);
    }
    return res.json(statusPayload(result.status));
  } catch (error) {
    if (error instanceof Error && error.message.includes("not found for its owner binding")) {
      return sendDay4Error(res, 404, DELETION_OPERATION_NOT_FOUND_CODE, DELETION_OPERATION_NOT_FOUND_MESSAGE);
    }
    if (isConfigurationUnavailable(error)) return sendUnavailable(res);
    console.error("[route] Participant deletion cancellation failed");
    return sendUnavailable(res);
  }
}

const challengeBodySchema = z.object({
  operationId: z.string().uuid(),
  readinessGeneration: z.number().int().min(0),
}).strict();

/**
 * `POST /api/participant/deletion/challenge` — rechecks readiness for this
 * explicit user action, then issues the code only if the operation is ready.
 */
export async function issueParticipantDeletionChallengeRoute(
  req: Request,
  res: Response
): Promise<Response> {
  const parsed = challengeBodySchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return sendDay4Error(res, 400, "INVALID_DELETION_CHALLENGE_REQUEST", "This request is invalid.");
  }
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);

  try {
    const owner = ownerOf(authority.participant, parsed.data.operationId, req);
    const readiness = await evaluateParticipantDeletionReadiness(
      owner,
      parsed.data.readinessGeneration,
      {}
    );
    if (readiness.outcome === "notOwned") {
      return sendDay4Error(res, 404, DELETION_OPERATION_NOT_FOUND_CODE, DELETION_OPERATION_NOT_FOUND_MESSAGE);
    }
    if (readiness.outcome === "stale" || readiness.outcome === "inactive") {
      return sendDay4Error(res, 409, DELETION_OPERATION_STALE_CODE, DELETION_OPERATION_STALE_MESSAGE);
    }
    if (readiness.outcome === "waiting") {
      return sendDay4Error(res, 409, DELETION_NOT_READY_CODE, DELETION_NOT_READY_MESSAGE);
    }
    if (readiness.outcome !== "ready") {
      return sendDay4Error(res, 409, DELETION_OPERATION_STALE_CODE, DELETION_OPERATION_STALE_MESSAGE);
    }
    const result = await issueParticipantDeletionChallenge(owner, readiness.status.readinessGeneration, {
      sendChallengeEmail: (principal, code) =>
        sendParticipantDeletionChallengeEmail(
          principal,
          code,
          DELETION_CHALLENGE_LIFETIME_MINUTES
        ),
    });
    if (result.outcome === "issued") {
      return res.status(202).json(statusPayload(result.status));
    }
    if (result.outcome === "cooldown") {
      return sendDay4Error(res, 429, DELETION_CHALLENGE_COOLDOWN_CODE, DELETION_CHALLENGE_COOLDOWN_MESSAGE);
    }
    if (result.outcome === "notReady") {
      return sendDay4Error(res, 409, DELETION_NOT_READY_CODE, DELETION_NOT_READY_MESSAGE);
    }
    if (result.outcome === "emailUnavailable") {
      return sendDay4Error(res, 503, DELETION_EMAIL_UNAVAILABLE_CODE, DELETION_EMAIL_UNAVAILABLE_MESSAGE);
    }
    return sendDay4Error(res, 409, DELETION_OPERATION_STALE_CODE, DELETION_OPERATION_STALE_MESSAGE);
  } catch (error) {
    if (error instanceof Error && error.message.includes("not found for its owner binding")) {
      return sendDay4Error(res, 404, DELETION_OPERATION_NOT_FOUND_CODE, DELETION_OPERATION_NOT_FOUND_MESSAGE);
    }
    if (isConfigurationUnavailable(error)) return sendUnavailable(res);
    console.error("[route] Participant deletion challenge issue failed");
    return sendUnavailable(res);
  }
}

const redeemBodySchema = z.object({
  operationId: z.string().uuid(),
  readinessGeneration: z.number().int().min(0),
  code: z.string(),
}).strict();

/** `POST /api/participant/deletion/redeem` — redeems the code into the five-minute authorization. */
export async function redeemParticipantDeletionChallengeRoute(
  req: Request,
  res: Response
): Promise<Response> {
  const parsed = redeemBodySchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return sendDay4Error(res, 400, "INVALID_DELETION_REDEEM_REQUEST", "This request is invalid.");
  }
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);

  try {
    const owner = ownerOf(authority.participant, parsed.data.operationId, req);
    const result = await redeemParticipantDeletionChallenge(owner, parsed.data.readinessGeneration, parsed.data.code);
    if (result.outcome === "authorized") {
      return res.json({ ...statusPayload(result.status), recoveryCapability: result.recoveryCapability });
    }
    if (result.outcome === "invalidCode") {
      return sendDay4Error(res, 401, DELETION_CODE_INVALID_CODE, DELETION_CODE_INVALID_MESSAGE);
    }
    if (result.outcome === "expired") {
      return sendDay4Error(res, 409, DELETION_CODE_EXPIRED_CODE, DELETION_CODE_EXPIRED_MESSAGE);
    }
    if (result.outcome === "notRedeemable") {
      return sendDay4Error(res, 409, DELETION_NOT_READY_CODE, DELETION_NOT_READY_MESSAGE);
    }
    return sendDay4Error(res, 409, DELETION_OPERATION_STALE_CODE, DELETION_OPERATION_STALE_MESSAGE);
  } catch (error) {
    if (error instanceof Error && error.message.includes("not found for its owner binding")) {
      return sendDay4Error(res, 404, DELETION_OPERATION_NOT_FOUND_CODE, DELETION_OPERATION_NOT_FOUND_MESSAGE);
    }
    if (isConfigurationUnavailable(error)) return sendUnavailable(res);
    console.error("[route] Participant deletion redemption failed");
    return sendUnavailable(res);
  }
}

const completeBodySchema = z.object({
  operationId: z.string().uuid(),
  readinessGeneration: z.number().int().min(0),
  capability: z.string(),
}).strict();

/**
 * `POST /api/participant/deletion/complete` — requires the exact final
 * authorization and capability, rechecks whole-operation safety immediately
 * before running the irreversible transaction.
 */
export async function completeParticipantDeletionRoute(
  req: Request,
  res: Response
): Promise<Response> {
  const parsed = completeBodySchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return sendDay4Error(res, 400, "INVALID_DELETION_COMPLETE_REQUEST", "This request is invalid.");
  }
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);

  try {
    const owner = ownerOf(authority.participant, parsed.data.operationId, req);
    const outcome = await completeParticipantDeletionOperation(
      owner,
      parsed.data.readinessGeneration,
      parsed.data.capability
    );
    switch (outcome) {
      case "completed":
        return res.json({ outcome: "completed" });
      case "notOwned":
        return sendDay4Error(res, 404, DELETION_OPERATION_NOT_FOUND_CODE, DELETION_OPERATION_NOT_FOUND_MESSAGE);
      case "stale":
        return sendDay4Error(res, 409, DELETION_OPERATION_STALE_CODE, DELETION_OPERATION_STALE_MESSAGE);
      case "notAuthorized":
        return sendDay4Error(res, 409, DELETION_NOT_READY_CODE, DELETION_NOT_READY_MESSAGE);
      case "expired":
        return sendDay4Error(res, 409, DELETION_AUTHORIZATION_EXPIRED_CODE, DELETION_AUTHORIZATION_EXPIRED_MESSAGE);
      case "invalidCapability":
        return sendDay4Error(res, 401, DELETION_CAPABILITY_INVALID_CODE, DELETION_CAPABILITY_INVALID_MESSAGE);
      case "blocked":
        return sendDay4Error(res, 409, DELETION_BLOCKED_CODE, DELETION_BLOCKED_MESSAGE);
      case "safetyIdentityUnavailable":
        return sendUnavailable(res);
      default:
        return sendUnavailable(res);
    }
  } catch (error) {
    if (isConfigurationUnavailable(error)) return sendUnavailable(res);
    console.error("[route] Participant deletion completion failed");
    return sendUnavailable(res);
  }
}

const recoveryBodySchema = z.object({
  operationId: z.string().uuid(),
  capability: z.string(),
}).strict();

/**
 * `POST /api/participant/deletion/recovery` — completion-only, and
 * deliberately unauthenticated by ordinary participant credential: by the
 * time this is called the account may already be gone. Authorized purely by
 * possession of the opaque capability. Every refusal is the same generic
 * `unavailable` answer, so operation existence is never probed.
 */
export async function recoverParticipantDeletionCompletion(
  req: Request,
  res: Response
): Promise<Response> {
  const parsed = recoveryBodySchema.safeParse(req.body ?? {});
  if (!parsed.success) return sendUnavailable(res);
  const namespaceBinding = req.headers?.[DELETION_NAMESPACE_HEADER];
  if (!isDeletionNamespaceBinding(namespaceBinding)) return sendUnavailable(res);

  try {
    const result = await readCompletedDeletionRecovery(
      parsed.data.operationId,
      parsed.data.capability,
      namespaceBinding
    );
    if (result.outcome === "completed") return res.json({ outcome: "completed" });
    return sendUnavailable(res);
  } catch (error) {
    console.error("[route] Participant deletion recovery lookup failed");
    return sendUnavailable(res);
  }
}
