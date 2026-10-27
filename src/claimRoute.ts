import type { NextFunction, Request, Response } from "express";
import rateLimit from "express-rate-limit";
import mongoose from "mongoose";
import {
  Participant,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
import {
  touchParticipantAccountsInSession,
  ParticipantAccountFenceUnavailable,
} from "./participantAccountFence.js";
import {
  deriveParticipantIdentityAlias,
  loadParticipantIdentityManifest,
  ParticipantIdentityConfigurationError,
} from "./participantIdentityKeys.js";
import { findParticipatedRequestIds } from "./requestParticipation.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";
import {
  claimTokenDigestMatches,
  digestClaimToken,
  generateClaimToken,
  isValidRawClaimToken,
  readClaimTokenHmacSecret,
} from "./claimToken.js";
import { day4Error, sendDay4Error } from "./day4Errors.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  type ParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { isParticipantPairFenced } from "./participantBlocks.js";
import { isRequestActionPaused } from "./reviewRuntime.js";
import {
  RESERVATION_STATE_CHANGED_CODE,
  RESERVATION_STATE_CHANGED_MESSAGE,
} from "./participantBlockRoute.js";
import {
  PARTICIPANT_SUSPENDED_CODE,
  PARTICIPANT_SUSPENDED_MESSAGE,
} from "./moderationEnforcement.js";
import {
  buildMinimumRemainingTimeFilter,
  buildVisibleNowFilter,
  hasMinimumRemainingTime,
  isStoppedAfterAffirmedOrder,
  isVisibleNow,
  REQUEST_NOT_YET_AVAILABLE_CODE,
  REQUEST_NOT_YET_AVAILABLE_MESSAGE,
} from "./requestAvailability.js";

export const CLAIM_ROUTE_PATH = "/api/request/:id/claim";
export const CLAIM_EXTENSION_ROUTE_PATH = "/api/request/:id/claim/extend";
export const CLAIM_RELEASE_ROUTE_PATH = "/api/request/:id/claim/release";
export const CLAIM_DURATION_MS = 15 * 60 * 1000;
export const CLAIM_EXTENSION_MS = 5 * 60 * 1000;
export const CLAIM_UNAVAILABLE_MESSAGE =
  "Helping with meal requests is temporarily unavailable.";

export const HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE =
  "HELPER_ALREADY_HAS_ACTIVE_RESERVATION";
export const HELPER_ALREADY_HAS_ACTIVE_RESERVATION_MESSAGE =
  "You already have an active reservation. Finish or release it before starting another.";

// W3-H2: once a verified participant has successfully acquired this exact
// request, they can never successfully acquire it again — not after release,
// not after passive expiry, not from another device or reinstall. Distinct
// from `HELPER_ALREADY_HAS_ACTIVE_RESERVATION` above: that refusal is about a
// *different* request the caller is still holding; this one is about this
// exact request's own durable history with this caller, and applies even
// when the caller currently holds no reservation at all.
export const REQUEST_ALREADY_PARTICIPATED_CODE = "REQUEST_ALREADY_PARTICIPATED";
export const REQUEST_ALREADY_PARTICIPATED_MESSAGE =
  "You've already helped with this request and can't reserve it again.";

// W4-H2: a verified participant can never successfully acquire a reservation
// on their own request. Distinct from `REQUEST_ALREADY_PARTICIPATED` above,
// which is about this caller's own prior *helper* history on the request;
// this is about the caller being the request's own requester, and applies
// regardless of whether they have ever attempted to help with it.
export const REQUEST_OWN_REQUEST_CODE = "REQUEST_OWN_REQUEST";
export const REQUEST_OWN_REQUEST_MESSAGE =
  "You can't help with your own request.";

interface ClaimDiagnosticDocument {
  status?: string;
  visibleFrom?: Date | null;
  expiresAt?: Date | null;
  claimExpiresAt?: Date | null;
  claimExtendedAt?: Date | null;
  claimTokenDigest?: string | null;
  helperParticipantId?: mongoose.Types.ObjectId | null;
  externalOrderAffirmed?: boolean | null;
  moderationUnavailable?: boolean | null;
  reservationLapseHold?: boolean | null;
}

function isInvalidId(id: unknown): boolean {
  return !mongoose.Types.ObjectId.isValid(String(id));
}

function diagnosticRequest(id: string) {
  return MealRequest.findById(id)
    .select(
      "status visibleFrom expiresAt claimExpiresAt claimExtendedAt +claimTokenDigest +helperParticipantId +externalOrderAffirmed +moderationUnavailable +reservationLapseHold"
    )
    .lean()
    .exec() as Promise<ClaimDiagnosticDocument | null>;
}

function isExpired(value: Date | null | undefined, now: Date): boolean {
  return !value || value.getTime() <= now.getTime();
}

async function explainClaimFailure(
  id: string,
  now: Date,
  res: Response
): Promise<Response> {
  const document = await diagnosticRequest(id);
  if (!document) {
    return sendDay4Error(
      res,
      404,
      "REQUEST_NOT_FOUND",
      "This request could not be found."
    );
  }
  if (document.status === "placed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_PLACED",
      "This request has already been placed."
    );
  }
  // W4-R5: a request its requester withdrew is gone from ongoing work for good.
  // Answered with its own code (and the same sentence an expired request gets),
  // so a stale Request Detail can return Home truthfully instead of reporting a
  // reservation conflict or an outage.
  if (document.status === "withdrawn") {
    return sendDay4Error(
      res,
      410,
      "REQUEST_WITHDRAWN",
      "This request is no longer available."
    );
  }
  // Ahead of the expiration checks: a request whose start has not arrived is
  // not late, and telling a helper it is "no longer available" would be the
  // opposite of true. Code and sentence are shared with the public-detail
  // refusal, so one situation has one answer wherever it is met.
  if (!isVisibleNow(document.visibleFrom, now)) {
    return sendDay4Error(
      res,
      409,
      REQUEST_NOT_YET_AVAILABLE_CODE,
      REQUEST_NOT_YET_AVAILABLE_MESSAGE
    );
  }
  if (isExpired(document.expiresAt, now)) {
    return sendDay4Error(
      res,
      410,
      "REQUEST_EXPIRED",
      "This request is no longer available."
    );
  }
  if (!hasMinimumRemainingTime(document.expiresAt, now)) {
    return sendDay4Error(
      res,
      409,
      "REQUEST_INSUFFICIENT_TIME",
      "This request does not have five full minutes remaining."
    );
  }
  // W4-U1.3/W4-U1.2: a request carrying the post-Yes external-order-risk
  // authority (E), the moderation marker (M), or the suspended-helper hold
  // (L) is never claimable again. It is answered as the existing
  // reserved-request refusal — the same sentence a live reservation gets —
  // so a helper learns nothing new, and nothing about why or whose.
  if (
    document.externalOrderAffirmed === true ||
    document.moderationUnavailable === true ||
    document.reservationLapseHold === true ||
    (document.status === "claimed" &&
      document.claimExpiresAt &&
      document.claimExpiresAt.getTime() > now.getTime())
  ) {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_CLAIMED",
      "Someone else just started helping with this request."
    );
  }

  return sendDay4Error(
    res,
    500,
    "INTERNAL_FAILURE",
    "Unable to claim this request right now."
  );
}

class ConditionalClaimFailure extends Error {}
/**
 * The target request was successfully claimed, but this exact verified
 * helper already holds a different active reservation elsewhere (W3-H1). The
 * Request-side claim is rolled back with the rest of the transaction: a
 * helper never ends up holding two reservations because the second half of
 * this check failed.
 */
class ActiveReservationConflict extends Error {}

/**
 * The target request was successfully claimed, but this exact verified
 * participant already holds a durable one-successful-participation record for
 * it (W3-H2). Rolled back with the rest of the transaction exactly like
 * `ActiveReservationConflict`: a reacquisition never ends up granted.
 */
class AlreadyParticipatedConflict extends Error {}

/**
 * The target request is the caller's own request (W4-H2). Rolled back with
 * the rest of the transaction, exactly like `AlreadyParticipatedConflict`: a
 * self-claim is never granted.
 */
class SelfClaimConflict extends Error {}

/**
 * A block exists between the claimant and the request's requester, in either
 * direction (W4-U1.3). Rolled back with the rest of the transaction exactly
 * like `SelfClaimConflict`, and answered as an ordinary missing request so the
 * response cannot tell the claimant that a block, let alone whose, is why.
 */
class BlockedPairConflict extends Error {}

/**
 * The claimant's own Participant document is suspended (W4-U1.2, boundary
 * contract EO). Rolled back with the rest of the transaction exactly like
 * the conflicts above; answered with a refusal visible only to this caller,
 * never to the request's requester.
 */
class SuspendedParticipantConflict extends Error {}

export {
  PARTICIPANT_SUSPENDED_CODE,
  PARTICIPANT_SUSPENDED_MESSAGE,
} from "./moderationEnforcement.js";

function isDuplicateKeyError(error: unknown): boolean {
  return (
    Boolean(error) &&
    typeof error === "object" &&
    (error as { code?: unknown }).code === 11000
  );
}

/** W4-R4: `pickupName` is gone from the V1 request contract, so the
 * claimant-private half of a successful claim carries only the claim
 * authorization itself. */
interface ClaimedRequestDocument extends PublicRequestDocument {
  claimExpiresAt: Date;
}

export async function claimRequest(
  req: Request,
  res: Response
): Promise<Response> {
  const id = req.params.id;
  if (isInvalidId(id)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_REQUEST_ID",
      "The request ID is invalid."
    );
  }

  // The helper gate (W3-I1). Browsing requests stays open to anyone, but
  // reserving one is a participant action: it takes a real student's meal out
  // of everyone else's reach and commits a person to placing an order. Checked
  // before token generation and before the conditional mutation, so an
  // unverified caller reserves nothing and is told nothing about the request.
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }
  const participantId = new mongoose.Types.ObjectId(
    authority.participant.participantId
  );

  // This one captured instant drives the eligibility filter, all persisted
  // claim timestamps, failure classification, and the returned expiration.
  const now = new Date();
  const maximumClaimExpiration = new Date(now.getTime() + CLAIM_DURATION_MS);

  let session: mongoose.ClientSession | undefined;
  try {
    const secret = readClaimTokenHmacSecret();
    const rawToken = generateClaimToken();
    const tokenDigest = digestClaimToken(rawToken, secret);

    session = await mongoose.startSession();
    let claimedDocument: ClaimedRequestDocument | null = null;

    await session.withTransaction(
      async () => {
        // Rollout-compatibility gap (W3-H1): a claim granted before the
        // Participant lock below existed never wrote
        // `activeReservationRequestId`, so the lock-only check further down
        // cannot see it — that participant would read as lock-free even
        // while a real reservation is still live. This direct read closes
        // the gap by finding any *other* live claim already bound to this
        // participant, regardless of whether the lock was ever written for
        // it. Concurrency safety for two brand-new claims by the same
        // participant still comes from the Participant document's own
        // write-conflict detection below — this read only extends what
        // counts as "already reserved," it does not replace the lock.
        const existingActiveReservation = await MealRequest.findOne(
          {
            helperParticipantId: participantId,
            status: "claimed",
            claimExpiresAt: { $gt: now },
          },
          { _id: 1 },
          { session }
        )
          .lean()
          .exec();

        if (existingActiveReservation) {
          throw new ActiveReservationConflict();
        }

        // W4-U1.2 (boundary contract EO): suspension is server-enforced at
        // claim, never UI-only. Read inside the same transaction/session as
        // the grant and the one-active-reservation lock below, which also
        // carries this same condition as defense-in-depth — so a suspension
        // that commits concurrently either is seen here or conflicts with
        // the lock write and is retried against a fresh snapshot.
        const suspensionCheck = await Participant.findById(
          participantId,
          undefined,
          { session }
        )
          .select("+suspended")
          .lean()
          .exec();
        if ((suspensionCheck as { suspended?: boolean } | null)?.suspended) {
          throw new SuspendedParticipantConflict();
        }

        // The W4-H2 self-claim guard, consulted inside the same
        // transaction/session as the grant that follows: a verified
        // participant can never successfully acquire a reservation on their
        // own request. `requesterParticipantId` is immutable after creation
        // (only `createRequestRoute` ever writes it), so this read is the
        // authoritative answer for the entire transaction — nothing else can
        // change it out from under this check. `+requesterParticipantId` is
        // required because the field is `select: false` on the schema.
        const ownershipCheck = await MealRequest.findById(
          id,
          null,
          { session }
        )
          .select("+requesterParticipantId")
          .lean()
          .exec();

        if (
          ownershipCheck?.requesterParticipantId &&
          String(ownershipCheck.requesterParticipantId) ===
            authority.participant.participantId
        ) {
          throw new SelfClaimConflict();
        }

        // The W4-U1.3 participant-pair fence, read in the same snapshot as the
        // grant and serialized against a concurrent block by the participant
        // writes below (see `src/participantBlocks.ts`). Consulted ahead of the
        // participation check so a fenced pair is answered identically however
        // its history with this request looks. `requesterParticipantId` is
        // absent only on legacy rows, which have no participant to fence.
        if (
          ownershipCheck?.requesterParticipantId &&
          (await isParticipantPairFenced(
            participantId,
            ownershipCheck.requesterParticipantId,
            session
          ))
        ) {
          throw new BlockedPairConflict();
        }

        // Perform participant writes after the pair read. If a Block commits
        // while this transaction is paused between its read and grant, these
        // writes conflict and Mongo retries the whole transaction against the
        // committed block instead of making the Block wait on this claim.
        const fencedParticipants = await touchParticipantAccountsInSession(
          [
            participantId,
            ...(ownershipCheck?.requesterParticipantId
              ? [ownershipCheck.requesterParticipantId]
              : []),
          ],
          session!,
          new Map([
            [
              authority.participant.participantId,
              authority.participant.authorityVersion,
            ],
          ])
        );
        const liveHelper = fencedParticipants.get(
          authority.participant.participantId
        );
        if (!liveHelper || liveHelper.principal !== authority.participant.principal) {
          throw new ParticipantAccountFenceUnavailable();
        }

        // The W3-H2 one-successful-participation invariant, consulted before
        // the conditional grant below: a participant who has ever
        // successfully acquired this exact request is refused regardless of
        // the request's current status (open, claimed, or claim-expired) or
        // who granted this read the request last. Read inside the same
        // transaction/session as the grant that follows, and backstopped by
        // the unique-index insert after a successful grant below — so a
        // reacquisition can never be granted even if this pre-check and the
        // insert somehow disagreed.
        const existingParticipationIds = await findParticipatedRequestIds(
          authority.participant.participantId,
          liveHelper.principal,
          [id],
          session
        );
        if (existingParticipationIds.has(id)) {
          throw new AlreadyParticipatedConflict();
        }

        const document = await MealRequest.findOneAndUpdate(
          {
            _id: id,
            status: { $ne: "placed" },
            // The same start-of-visibility rule the list, digest, and alert
            // paths apply. A request nobody can see yet must not be
            // claimable either.
            visibleFrom: buildVisibleNowFilter(now),
            expiresAt: buildMinimumRemainingTimeFilter(now),
            // W4-U1.3: the post-Yes external-order-risk authority makes this
            // request permanently unclaimable. Evaluated inside the same
            // conditional mutation that grants, so a marker committed by a
            // concurrent Yes Block either is seen here or conflicts with this
            // write; there is no window that grants it afterwards.
            externalOrderAffirmed: { $ne: true },
            // W4-U1.2 (boundary contract EO): M and L make this request
            // permanently unclaimable the same way, evaluated in the same
            // conditional mutation for the same reason.
            moderationUnavailable: { $ne: true },
            reservationLapseHold: { $ne: true },
            $or: [
              { status: "open" },
              {
                status: "claimed",
                claimExpiresAt: { $lte: now },
              },
            ],
          },
          [
            {
              $set: {
                status: "claimed",
                claimedAt: now,
                claimExpiresAt: {
                  $min: [maximumClaimExpiration, "$expiresAt"],
                },
                claimExtendedAt: null,
                claimTokenDigest: tokenDigest,
                // The reservation's owner, written in the same conditional
                // mutation that grants it, so a claim never exists without
                // the verified helper it belongs to. A request re-claimed
                // after an expired reservation is rebound to whoever won it
                // this time. Fulfillment reads this instead of accepting a
                // helper address.
                helperParticipantId: participantId,
                updatedAt: now,
              },
            },
          ],
          { new: true, session }
        )
          .lean()
          .exec();

        if (!document) {
          throw new ConditionalClaimFailure();
        }

        // One-active-reservation-per-verified-helper (W3-H1). Pinned to this
        // exact participant document, whose per-`_id` write conflict
        // detection is what makes this safe against a second concurrent
        // claim by the same principal on a *different* request — the two
        // transactions cannot both win a conditional update against the same
        // document, so only one commits.
        const lock = await Participant.findOneAndUpdate(
          {
            _id: participantId,
            // W4-U1.2 (boundary contract EO) defense-in-depth: the early
            // `suspensionCheck` above already refuses the ordinary case with
            // a precise error; this condition closes the race where a
            // suspension commits between that read and this write, so the
            // lock can never be granted to a by-then-suspended participant
            // either way.
            suspended: { $ne: true },
            authorityVersion: authority.participant.authorityVersion,
            $or: [
              { activeReservationRequestId: null },
              { activeReservationClaimExpiresAt: { $lte: now } },
            ],
          },
          {
            $set: {
              activeReservationRequestId: document._id,
              activeReservationClaimExpiresAt: (
                document as ClaimedRequestDocument
              ).claimExpiresAt,
            },
          },
          { session }
        ).exec();

        if (!lock) {
          throw new ActiveReservationConflict();
        }

        // The durable W3-H2 participation record, written atomically in the
        // same transaction as the grant it belongs to. A duplicate-key error
        // here means a concurrent transaction already recorded this exact
        // (request, participant) pair — the final backstop for the pre-check
        // above — and aborts this entire grant along with it.
        const identityManifest = await loadParticipantIdentityManifest(
          "participation",
          session
        );
        const participationKey = identityManifest.ring.keys.get(
          identityManifest.ring.currentVersion
        );
        if (!participationKey) {
          throw new ParticipantIdentityConfigurationError(
            "Request participation identity data is unavailable"
          );
        }
        const participationAlias = deriveParticipantIdentityAlias(
          "participation",
          identityManifest.ring.currentVersion,
          participationKey,
          String(document._id),
          liveHelper.principal
        );
        try {
          await RequestParticipation.create(
            [
              {
                requestId: document._id,
                participantId,
                participationKeyVersion: participationAlias.version,
                participationHmac: participationAlias.digest,
              },
            ],
            { session }
          );
        } catch (participationError) {
          if (isDuplicateKeyError(participationError)) {
            throw new AlreadyParticipatedConflict();
          }
          throw participationError;
        }

        claimedDocument = document as unknown as ClaimedRequestDocument;
      },
      {
        readConcern: { level: "snapshot" },
        writeConcern: { w: "majority" },
      }
    );

    if (!claimedDocument) {
      throw new ConditionalClaimFailure();
    }
    // TypeScript cannot see through the transaction closure's assignment.
    const document = claimedDocument as ClaimedRequestDocument;

    const publicResponse = buildPublicRequestDetailResponse(document, now);
    return res.json({
      request: publicResponse.request,
      claim: {
        claimToken: rawToken,
        claimExpiresAt: document.claimExpiresAt,
      },
    });
  } catch (error) {
    if (error instanceof SuspendedParticipantConflict) {
      return sendDay4Error(
        res,
        403,
        PARTICIPANT_SUSPENDED_CODE,
        PARTICIPANT_SUSPENDED_MESSAGE
      );
    }
    if (
      error instanceof ParticipantIdentityConfigurationError ||
      error instanceof ParticipantAccountFenceUnavailable
    ) {
      return sendDay4Error(
        res,
        503,
        PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
        PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
      );
    }
    if (error instanceof ActiveReservationConflict) {
      return sendDay4Error(
        res,
        409,
        HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE,
        HELPER_ALREADY_HAS_ACTIVE_RESERVATION_MESSAGE
      );
    }
    if (error instanceof AlreadyParticipatedConflict) {
      return sendDay4Error(
        res,
        409,
        REQUEST_ALREADY_PARTICIPATED_CODE,
        REQUEST_ALREADY_PARTICIPATED_MESSAGE
      );
    }
    if (error instanceof SelfClaimConflict) {
      return sendDay4Error(
        res,
        409,
        REQUEST_OWN_REQUEST_CODE,
        REQUEST_OWN_REQUEST_MESSAGE
      );
    }
    if (error instanceof BlockedPairConflict) {
      // Byte-for-byte the answer for a request that does not exist.
      return sendDay4Error(
        res,
        404,
        "REQUEST_NOT_FOUND",
        "This request could not be found."
      );
    }
    if (error instanceof ConditionalClaimFailure) {
      return await explainClaimFailure(id, now, res);
    }
    console.error("[route] Claim mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to claim this request right now."
    );
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        console.error(
          "[route] MongoDB session cleanup failed after claim attempt"
        );
      }
    }
  }
}

/**
 * How a caller may authorize an action against an existing claim (extend,
 * release), once the raw claim token generated at claim time is no longer
 * available in-process (W3-H1 continuation).
 *
 * `token` is the original, unchanged authorization: the raw claim token
 * confirms possession of a specific reservation and is matched by digest,
 * exactly as before this slice.
 *
 * `participant` is additive: the caller's verified participant authority
 * (W3-I1), matched against the target request's own `helperParticipantId`.
 * It exists for the case the raw token is gone — after termination and
 * relaunch — and never replaces or weakens the token path, which stays
 * available for the still-in-process case.
 */
export type ClaimActionAuthorization =
  | { mode: "token"; digest: string }
  | {
      mode: "participant";
      participantId: string;
      principal: string;
      authorityVersion: number;
    };

export type ClaimActionAuthorizationRefusal =
  | { kind: "participant"; refusal: ParticipantAuthorityRefusal }
  | { kind: "invalidToken" }
  | { kind: "unavailable" };

/**
 * Distinguishes the two accepted request shapes for a claim action: a body
 * carrying exactly `{ claimToken }` (the original in-process path), or an
 * empty body carrying the participant-authority header (the continuation
 * path). Any other shape is refused before either credential is checked, the
 * same "answer nothing until the shape is right" posture `extendClaim`
 * already applied to the token-only body.
 *
 * `bodyOverride`, when provided, is resolved against instead of `req.body` —
 * used only by `releaseClaim`, which strips its own additional
 * `externalOrderPlaced` field (FD-1 Option B) before delegating here, so this
 * function's accepted shapes stay exactly as `extendClaim` also relies on
 * them.
 */
async function resolveClaimActionAuthorization(
  req: Request,
  bodyOverride?: unknown
): Promise<
  | { ok: true; authorization: ClaimActionAuthorization }
  | { ok: false; refusal: ClaimActionAuthorizationRefusal }
> {
  const body = bodyOverride !== undefined ? bodyOverride : req.body;
  const isPlainObject =
    Boolean(body) && typeof body === "object" && !Array.isArray(body);
  const keys = isPlainObject ? Object.keys(body as Record<string, unknown>) : [];

  if (isPlainObject && keys.length === 1 && keys[0] === "claimToken") {
    const candidate = (body as Record<string, unknown>).claimToken;
    if (!isValidRawClaimToken(candidate)) {
      return { ok: false, refusal: { kind: "invalidToken" } };
    }
    try {
      const secret = readClaimTokenHmacSecret();
      const digest = digestClaimToken(candidate, secret);
      return { ok: true, authorization: { mode: "token", digest } };
    } catch {
      console.error("[route] Claim token secret unavailable");
      return { ok: false, refusal: { kind: "unavailable" } };
    }
  }

  if (isPlainObject && keys.length === 0) {
    const authority = await resolveParticipantAuthority(req);
    if (!authority.ok) {
      return {
        ok: false,
        refusal: { kind: "participant", refusal: authority.refusal },
      };
    }
    return {
      ok: true,
      authorization: {
        mode: "participant",
        participantId: authority.participant.participantId,
        principal: authority.participant.principal,
        authorityVersion: authority.participant.authorityVersion,
      },
    };
  }

  return { ok: false, refusal: { kind: "invalidToken" } };
}

function sendClaimActionAuthorizationRefusal(
  res: Response,
  refusal: ClaimActionAuthorizationRefusal,
  unavailableMessage: string
): Response {
  switch (refusal.kind) {
    case "participant":
      return sendParticipantAuthorityRefusal(res, refusal.refusal);
    case "invalidToken":
      return sendDay4Error(
        res,
        400,
        "INVALID_CLAIM_TOKEN",
        "The claim token is missing or invalid."
      );
    case "unavailable":
      return sendDay4Error(res, 500, "INTERNAL_FAILURE", unavailableMessage);
  }
}

function claimActionAuthorizationMatches(
  authorization: ClaimActionAuthorization,
  document: ClaimDiagnosticDocument
): boolean {
  if (authorization.mode === "token") {
    return claimTokenDigestMatches(
      document.claimTokenDigest,
      authorization.digest
    );
  }
  return (
    document.helperParticipantId != null &&
    String(document.helperParticipantId) === authorization.participantId
  );
}

function claimActionFilter(
  authorization: ClaimActionAuthorization
): Record<string, unknown> {
  return authorization.mode === "token"
    ? { claimTokenDigest: authorization.digest }
    : {
        helperParticipantId: new mongoose.Types.ObjectId(
          authorization.participantId
        ),
      };
}

class ReservationFenceFailure extends Error {}

async function fenceReservationParticipants(
  relationshipIds: Array<mongoose.Types.ObjectId | null | undefined>,
  session: mongoose.ClientSession,
  authorization: ClaimActionAuthorization
): Promise<void> {
  const [requesterId, helperId] = relationshipIds;
  if (
    authorization.mode === "participant" &&
    (!helperId || String(helperId) !== authorization.participantId)
  ) {
    throw new ReservationFenceFailure();
  }
  const participantIds = [
    requesterId,
    helperId,
  ].filter(
    (participantId): participantId is mongoose.Types.ObjectId =>
      participantId != null
  );
  const expectedVersions = new Map<string, number>();
  if (authorization.mode === "participant") {
    expectedVersions.set(
      authorization.participantId,
      authorization.authorityVersion
    );
  }
  const fenced = await touchParticipantAccountsInSession(
    participantIds,
    session,
    expectedVersions
  );
  if (
    authorization.mode === "participant" &&
    fenced.get(authorization.participantId)?.principal !==
      authorization.principal
  ) {
    throw new ReservationFenceFailure();
  }
}

async function explainExtensionFailure(
  id: string,
  now: Date,
  res: Response,
  authorization: ClaimActionAuthorization
): Promise<Response> {
  const document = await diagnosticRequest(id);
  if (!document) {
    return sendDay4Error(
      res,
      404,
      "REQUEST_NOT_FOUND",
      "This request could not be found."
    );
  }
  if (document.status === "placed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_PLACED",
      "This request has already been placed."
    );
  }
  // Deliberately no start-of-visibility branch here, unlike the claim
  // diagnostic. Extension is only reachable by a caller who already holds a
  // claim, so a not-yet-visible request cannot legitimately arrive — and this
  // classification runs before authorization, so adding one would answer a
  // caller who has proved nothing.
  if (isExpired(document.expiresAt, now)) {
    return sendDay4Error(
      res,
      410,
      "REQUEST_EXPIRED",
      "This request is no longer available."
    );
  }
  // `isStoppedAfterAffirmedOrder` (W4-U1.3) is answered exactly like a request
  // that was ordinarily released: nothing about it reveals the private marker.
  if (document.status !== "claimed" || isStoppedAfterAffirmedOrder(document)) {
    return sendDay4Error(
      res,
      409,
      "REQUEST_NOT_CLAIMED",
      "This request does not have an active claim."
    );
  }
  // Expiration is classified before authorization. A claim that lapsed and
  // was replaced by another helper carries that helper's credential, so
  // checking authorization first would tell the original holder their
  // credential is wrong when the truth is that their claim ran out.
  // Authorization is unchanged for an active claim: it still gates every
  // non-expired path below.
  if (isExpired(document.claimExpiresAt, now)) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXPIRED",
      "This claim has expired."
    );
  }
  if (!claimActionAuthorizationMatches(authorization, document)) {
    return sendDay4Error(
      res,
      403,
      "INVALID_CLAIM_TOKEN",
      "The claim token is missing or invalid."
    );
  }
  if (document.claimExtendedAt) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXTENSION_ALREADY_USED",
      "This claim has already been extended."
    );
  }
  if (
    document.claimExpiresAt!.getTime() + CLAIM_EXTENSION_MS >
    document.expiresAt!.getTime()
  ) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXTENSION_INSUFFICIENT_TIME",
      "There is not enough time remaining for a full extension."
    );
  }

  return sendDay4Error(
    res,
    500,
    "INTERNAL_FAILURE",
    "Unable to extend this claim right now."
  );
}

class ConditionalExtensionFailure extends Error {}

interface ExtendedRequestDocument {
  _id: mongoose.Types.ObjectId;
  claimExpiresAt: Date;
  claimExtendedAt: Date;
  requesterParticipantId?: mongoose.Types.ObjectId | null;
  helperParticipantId?: mongoose.Types.ObjectId | null;
}

export async function extendClaim(
  req: Request,
  res: Response
): Promise<Response> {
  const id = req.params.id;
  if (isInvalidId(id)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_REQUEST_ID",
      "The request ID is invalid."
    );
  }

  const resolution = await resolveClaimActionAuthorization(req);
  if (!resolution.ok) {
    return sendClaimActionAuthorizationRefusal(
      res,
      resolution.refusal,
      "Unable to extend this claim right now."
    );
  }
  const authorization = resolution.authorization;

  // This one captured instant drives the active-claim filter, the persisted
  // extension timestamp, failure classification, and the response.
  const now = new Date();
  let session: mongoose.ClientSession | undefined;

  try {
    session = await mongoose.startSession();
    let extendedDocument: ExtendedRequestDocument | null = null;

    await session.withTransaction(
      async () => {
        const document = await MealRequest.findOneAndUpdate(
          {
            _id: id,
            status: "claimed",
            claimExpiresAt: { $gt: now },
            claimExtendedAt: null,
            ...claimActionFilter(authorization),
            $expr: {
              $lte: [
                { $add: ["$claimExpiresAt", CLAIM_EXTENSION_MS] },
                "$expiresAt",
              ],
            },
          },
          [
            {
              $set: {
                claimExpiresAt: {
                  $add: ["$claimExpiresAt", CLAIM_EXTENSION_MS],
                },
                claimExtendedAt: now,
                updatedAt: now,
              },
            },
          ],
          { new: true, session }
        )
          .select("+requesterParticipantId +helperParticipantId")
          .lean()
          .exec();

        if (!document) {
          throw new ConditionalExtensionFailure();
        }
        const extended = document as unknown as ExtendedRequestDocument;
        await fenceReservationParticipants(
          [extended.requesterParticipantId, extended.helperParticipantId],
          session!,
          authorization
        );

        // W4-U1.3: deliberately no participant-pair fence here. A Block fences
        // *new* interaction — a claim, another request, another helper — and
        // extending the reservation its holder already legitimately has begins
        // none. Extension is governed only by the ordinary timing and one-use
        // rules in the conditional update above, so it can never answer
        // differently because a Block exists, in either direction.

        // Mirrors the new deadline onto the one-active-reservation lock so a
        // just-extended claim cannot be mistaken for a stale one that no
        // longer blocks a fresh claim by the same principal. A
        // pre-W3-I1 legacy claim has no `helperParticipantId` and therefore
        // no lock to mirror; nothing here needs to run for it.
        if (extended.helperParticipantId) {
          // Owning the exact lock is now mandatory for the extension to
          // commit at all (independent-review MUST FIX 2), not merely a
          // best-effort mirror. A stale/delayed extension whose lock has
          // since moved to a later reservation — because the old claim
          // genuinely expired and this same participant reserved something
          // else in the meantime — must never durably renew this Request's
          // deadline; that would leave the participant holding two live
          // reservations at once. The `$or` accepts the lock either already
          // pointing at this exact request (the ordinary case) or never
          // having been written for it at all — a pre-H1 claim, self-healed
          // here rather than refused, matching the accepted rollout-
          // compatibility handling `claimRequest`'s own direct read applies.
          // It never accepts the lock pointing at a *different* request:
          // that is exactly the race this closes.
          const lockSync = await Participant.updateOne(
            {
              _id: extended.helperParticipantId,
              $or: [
                { activeReservationRequestId: extended._id },
                { activeReservationRequestId: null },
              ],
            },
            {
              $set: {
                activeReservationRequestId: extended._id,
                activeReservationClaimExpiresAt: extended.claimExpiresAt,
              },
            },
            { session }
          ).exec();

          if (lockSync.matchedCount === 0) {
            throw new ConditionalExtensionFailure();
          }
        }

        extendedDocument = extended;
      },
      {
        readConcern: { level: "snapshot" },
        writeConcern: { w: "majority" },
      }
    );

    if (!extendedDocument) {
      throw new ConditionalExtensionFailure();
    }
    const document = extendedDocument as ExtendedRequestDocument;

    return res.json({
      claim: {
        claimExpiresAt: document.claimExpiresAt,
        claimExtendedAt: document.claimExtendedAt,
      },
    });
  } catch (error) {
    if (error instanceof ReservationFenceFailure) {
      return await explainExtensionFailure(id, now, res, authorization);
    }
    if (error instanceof ConditionalExtensionFailure) {
      return await explainExtensionFailure(id, now, res, authorization);
    }
    console.error("[route] Claim extension mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to extend this claim right now."
    );
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        console.error(
          "[route] MongoDB session cleanup failed after extension attempt"
        );
      }
    }
  }
}

async function explainReleaseFailure(
  id: string,
  now: Date,
  res: Response,
  authorization: ClaimActionAuthorization,
  answeredOrderQuestion = false
): Promise<Response> {
  const document = await diagnosticRequest(id);
  if (!document) {
    return sendDay4Error(
      res,
      404,
      "REQUEST_NOT_FOUND",
      "This request could not be found."
    );
  }
  // FD-1: an answer is never applied outside its question. The caller still
  // holds a live reservation of their own that simply isn't (or is no longer)
  // asking it, or whose version moved: refused with no write.
  if (
    answeredOrderQuestion &&
    document.status === "claimed" &&
    !isExpired(document.claimExpiresAt, now) &&
    document.claimExpiresAt != null &&
    claimActionAuthorizationMatches(authorization, document)
  ) {
    return sendDay4Error(
      res,
      409,
      RESERVATION_STATE_CHANGED_CODE,
      RESERVATION_STATE_CHANGED_MESSAGE
    );
  }
  // Pinned by the release mutation's own filter (`status: "claimed"`): a
  // placed request can never be the row this update matched, so this is a
  // truthful classification of why release found nothing to do, never a
  // path that could itself reopen a placement.
  if (document.status === "placed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_PLACED",
      "This request has already been placed."
    );
  }
  // A request already stopped after an affirmed external order (W4-U1.3) is
  // classified as an ordinarily released one, so a retried Stop is
  // indistinguishable between the two.
  if (document.status !== "claimed" || isStoppedAfterAffirmedOrder(document)) {
    return sendDay4Error(
      res,
      409,
      "REQUEST_NOT_CLAIMED",
      "This request does not have an active claim."
    );
  }
  if (isExpired(document.claimExpiresAt, now)) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXPIRED",
      "This claim has expired."
    );
  }
  if (!claimActionAuthorizationMatches(authorization, document)) {
    return sendDay4Error(
      res,
      403,
      "INVALID_CLAIM_TOKEN",
      "The claim token is missing or invalid."
    );
  }

  return sendDay4Error(
    res,
    500,
    "INTERNAL_FAILURE",
    "Unable to release this reservation right now."
  );
}

class ConditionalReleaseFailure extends Error {}

export interface ReleaseReservationVersion {
  claimExpiresAt: Date;
  claimExtendedAt?: Date | null;
}

export interface ReleasedRequestDocument {
  _id: mongoose.Types.ObjectId;
  requesterParticipantId?: mongoose.Types.ObjectId | null;
  helperParticipantId?: mongoose.Types.ObjectId | null;
}

/**
 * Captures the reservation version this release attempt originally met.
 *
 * This read deliberately happens once, outside `withTransaction`: the Mongo
 * driver may invoke a transaction callback again after a transient write
 * conflict, but a retry must not silently adopt an extension that committed
 * after this release began. `claimExpiresAt` changes on every extension, and
 * `claimExtendedAt` records the one-use transition, so together they are the
 * existing reservation-version CAS without adding persistence or wire state.
 */
export async function readReleaseReservationVersion(
  id: string
): Promise<ReleaseReservationVersion | null> {
  const document = (await MealRequest.findById(id)
    .select("claimExpiresAt claimExtendedAt")
    .lean()
    .exec()) as ReleaseReservationVersion | null;

  if (!document?.claimExpiresAt) return null;
  return {
    claimExpiresAt: document.claimExpiresAt,
    ...(document.claimExtendedAt === undefined
      ? {}
      : { claimExtendedAt: document.claimExtendedAt }),
  };
}

function releaseVersionFilter(
  version: ReleaseReservationVersion,
  now: Date
): Record<string, unknown> {
  return {
    // `$gt` preserves the existing active-claim deadline gate while `$eq`
    // prevents a driver retry from releasing a newer extension.
    claimExpiresAt: {
      $gt: now,
      $eq: version.claimExpiresAt,
    },
    claimExtendedAt:
      version.claimExtendedAt === undefined
        ? { $exists: false }
        // MongoDB's bare `{ field: null }` also matches an absent field.
        // H1 rows write an explicit null, while pre-H1 rows may physically
        // omit this marker, so preserve the representation captured above.
        : version.claimExtendedAt === null
          ? { $eq: null, $exists: true }
          : version.claimExtendedAt,
  };
}

/**
 * The release mutation itself, shared by `releaseClaim` and the W4-U1.3
 * helper block-while-helping `No` branch so the two can never diverge: one
 * conditional, version-pinned, authorization-pinned update plus the matching
 * lock clear, inside the caller's transaction.
 *
 * `new: false` (the default) returns the pre-release document, which still
 * carries `helperParticipantId` — needed a moment later to clear that
 * participant's reservation lock. The unset fields put this request back
 * exactly where an unclaimed request already stands: nothing here
 * distinguishes a released request from one that was never claimed.
 *
 * ## Retire-in-place branch (W4-U1.3 E; generalized for W4-U1.2 M and L,
 * boundary contract EO)
 *
 * A request carrying `externalOrderAffirmed` (E) — written atomically with
 * the successful Yes Block — or `moderationUnavailable` (M), or
 * `reservationLapseHold` (L) without a confirmed No, must never return to
 * ordinary availability: a real external order may exist (E), the request
 * was permanently removed or its requester suspended (M), or a suspended
 * helper's order status is still Unknown (L). That is the one case the
 * ordinary update below deliberately does not match, so a request carrying
 * none of them releases byte-for-byte as it always has.
 *
 * For a marked request the same conditional, version-pinned,
 * authorization-pinned filter is applied, and the mutation instead *retires*
 * the reservation: it removes every piece of reservation authority (deadline,
 * claim-token digest, helper binding, one-use marker) and clears the helper's
 * lock, but leaves `status` as `claimed`, never `open`. With no deadline and
 * no binding no extension or fulfillment can match it; with a marker still set
 * the shared availability predicate and the claim filter never offer it again.
 * E and M are left untouched (nothing ever clears them); L is left untouched
 * too, because a plain Stop or a passive lapse is exactly the "Unknown stays
 * Unknown" case EO requires — only a confirmed No clears it.
 *
 * ## `confirmedNo` (EO: "the shared release mutation takes one new input,
 * `confirmedNo`")
 *
 * `confirmedNo: true` marks this call as the one accepted answer that no
 * external order exists — either the existing U1.3 `No` Block, or FD-1 Option
 * B's `No` answer to a suspended helper's Stop question. It is the one thing
 * that lets a reservation reopen *despite* carrying L: the ordinary branch's
 * filter requires L absent only when `confirmedNo` is not set, and when the
 * ordinary branch matches with `confirmedNo` true it also unsets L. It never
 * weakens the E/M requirement: both must still be absent for the ordinary
 * branch to reopen the request, exactly as EO's scenario table requires
 * ("Block → No on a request carrying M... retires in place").
 *
 * `requireLapseHold: true` is FD-1's own precondition, used only by the
 * release route's `externalOrderPlaced` answer path: an answer is never
 * applied outside its question, so when set, *neither* branch may match
 * unless L is genuinely `true` and E is absent on this exact reservation —
 * folded into `pinned` itself so a reservation without L, or one already
 * carrying E, matches neither attempt and the call refuses with no write at
 * all, never silently falling back to an ordinary Stop.
 *
 * Returns `null` when neither update matched; the caller owns what that means.
 */
export async function releaseReservationWithinSession(
  session: mongoose.ClientSession,
  input: {
    requestId: string;
    version: ReleaseReservationVersion;
    now: Date;
    authorization: ClaimActionAuthorization;
    confirmedNo?: boolean;
    requireLapseHold?: boolean;
  }
): Promise<ReleasedRequestDocument | null> {
  const { requestId, version, now, authorization, confirmedNo, requireLapseHold } = input;
  const pinned = {
    _id: requestId,
    status: "claimed",
    // The exact version captured before the transaction started.
    ...releaseVersionFilter(version, now),
    ...claimActionFilter(authorization),
    // FD-1's own precondition (see doc comment above): folded into the base
    // pin so an answer outside its question matches neither branch below.
    ...(requireLapseHold
      ? { reservationLapseHold: true, externalOrderAffirmed: { $ne: true } }
      : {}),
  };
  const retiredFields = {
    claimedAt: 1,
    claimExpiresAt: 1,
    claimExtendedAt: 1,
    claimTokenDigest: 1,
    helperParticipantId: 1,
  } as const;

  const reopenFilter: Record<string, unknown> = {
    ...pinned,
    externalOrderAffirmed: { $ne: true },
    moderationUnavailable: { $ne: true },
    // L must be absent for an ordinary Stop; a confirmed No is the one thing
    // that may reopen a reservation that still carries it, and does so by
    // also unsetting it below.
    ...(confirmedNo ? {} : { reservationLapseHold: { $ne: true } }),
  };
  const reopenUnset: Record<string, 1> = {
    ...retiredFields,
    ...(confirmedNo ? { reservationLapseHold: 1 } : {}),
  };

  let document = await MealRequest.findOneAndUpdate(
    reopenFilter,
    {
      $set: { status: "open", updatedAt: now },
      $unset: reopenUnset,
    },
    { session }
  )
    .select("+requesterParticipantId +helperParticipantId")
    .lean()
    .exec();

  if (!document) {
    document = await MealRequest.findOneAndUpdate(
      {
        ...pinned,
        $or: [
          { externalOrderAffirmed: true },
          { moderationUnavailable: true },
          // Matches only when NOT a confirmed No, mirroring the reopen
          // branch's own exclusion above: a confirmed No must never retire a
          // reservation in place merely because it carries L.
          ...(confirmedNo ? [] : [{ reservationLapseHold: true }]),
        ],
      },
      {
        // `status` is deliberately untouched: it stays `claimed`.
        $set: { updatedAt: now },
        $unset: retiredFields,
      },
      { session }
    )
      .select("+requesterParticipantId +helperParticipantId")
      .lean()
      .exec();
  }

  if (!document) return null;
  const releasedDocument = document as unknown as ReleasedRequestDocument;

  await fenceReservationParticipants(
    [
      releasedDocument.requesterParticipantId,
      releasedDocument.helperParticipantId,
    ],
    session,
    authorization
  );

  if (releasedDocument.helperParticipantId) {
    await Participant.updateOne(
      {
        _id: releasedDocument.helperParticipantId,
        activeReservationRequestId: releasedDocument._id,
      },
      {
        $set: {
          activeReservationRequestId: null,
          activeReservationClaimExpiresAt: null,
        },
      },
      { session }
    ).exec();
  }

  return releasedDocument;
}

/**
 * Explicit release (W3-H1, new). Atomically invalidates only the caller's
 * still-active reservation and restores the request to `open`, pinned to
 * `status: "claimed"` plus the matching authorization exactly as
 * `claimRequest`, `extendClaim`, and `fulfillmentRoute`'s placement mutation
 * already pin their own conditional updates — so release can never reopen a
 * `placed` request and can never release a different helper's reservation.
 *
 * Because release and fulfillment both pivot on the same
 * `status: "claimed"` → terminal-state conditional mutation, whichever
 * mutation's filter matches first simply wins; the other's conditional
 * update misses and is classified by `explainReleaseFailure` /
 * `explainConditionalFailure` exactly as any other lost race already is. No
 * new concurrency primitive is required.
 */
export async function releaseClaim(
  req: Request,
  res: Response
): Promise<Response> {
  const id = req.params.id;
  if (isInvalidId(id)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_REQUEST_ID",
      "The request ID is invalid."
    );
  }

  // W4-U1.2 FD-1 Option B: the optional strict boolean `externalOrderPlaced`
  // is stripped before delegating, so the accepted authorization shapes stay
  // exactly as `extendClaim` also relies on them.
  let externalOrderPlaced: boolean | undefined;
  let authorizationBody: unknown = undefined;
  const rawBody = req.body;
  if (
    rawBody &&
    typeof rawBody === "object" &&
    !Array.isArray(rawBody) &&
    Object.prototype.hasOwnProperty.call(rawBody, "externalOrderPlaced")
  ) {
    const { externalOrderPlaced: answer, ...rest } = rawBody as Record<
      string,
      unknown
    >;
    if (typeof answer !== "boolean") {
      return sendDay4Error(
        res,
        400,
        "INVALID_RELEASE_PAYLOAD",
        "The release request is invalid."
      );
    }
    externalOrderPlaced = answer;
    authorizationBody = rest;
  }

  const resolution = await resolveClaimActionAuthorization(
    req,
    authorizationBody
  );
  if (!resolution.ok) {
    return sendClaimActionAuthorizationRefusal(
      res,
      resolution.refusal,
      "Unable to release this reservation right now."
    );
  }
  const authorization = resolution.authorization;

  const now = new Date();
  let session: mongoose.ClientSession | undefined;

  try {
    // Immutable across every callback invocation `withTransaction` may make.
    // If extension moves the reservation to a new deadline after this read,
    // the release CAS below misses on retry instead of adopting that version.
    const originalVersion = await readReleaseReservationVersion(id);
    if (!originalVersion) {
      throw new ConditionalReleaseFailure();
    }

    session = await mongoose.startSession();
    let released: ReleasedRequestDocument | null = null;
    let affirmed = false;

    await session.withTransaction(
      async () => {
        if (externalOrderPlaced === true) {
          // FD-1 Option B `Yes`: E pinned to the exact reservation, nothing
          // else touched (no release, retire, extension, Block or fence).
          const marked = await MealRequest.findOneAndUpdate(
            {
              _id: id,
              status: "claimed",
              ...releaseVersionFilter(originalVersion, now),
              ...claimActionFilter(authorization),
              reservationLapseHold: true,
              externalOrderAffirmed: { $ne: true },
            },
            { $set: { externalOrderAffirmed: true, updatedAt: now } },
            { session }
          )
            .select("_id")
            .lean()
            .exec();
          if (!marked) throw new ConditionalReleaseFailure();
          affirmed = true;
          return;
        }
        const releasedDocument = await releaseReservationWithinSession(
          session as mongoose.ClientSession,
          {
            requestId: id,
            version: originalVersion,
            now,
            authorization,
            ...(externalOrderPlaced === false
              ? { confirmedNo: true, requireLapseHold: true }
              : {}),
          }
        );
        if (!releasedDocument) {
          throw new ConditionalReleaseFailure();
        }
        released = releasedDocument;
      },
      {
        readConcern: { level: "snapshot" },
        writeConcern: { w: "majority" },
      }
    );

    if (affirmed) {
      // The reservation is untouched: iOS clears local state only on
      // `released: true`.
      return res.json({ released: false });
    }
    if (!released) {
      throw new ConditionalReleaseFailure();
    }

    return res.json({ released: true });
  } catch (error) {
    if (error instanceof ReservationFenceFailure) {
      return await explainReleaseFailure(id, now, res, authorization);
    }
    if (error instanceof ConditionalReleaseFailure) {
      return await explainReleaseFailure(
        id,
        now,
        res,
        authorization,
        externalOrderPlaced !== undefined
      );
    }
    console.error("[route] Claim release mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to release this reservation right now."
    );
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        console.error(
          "[route] MongoDB session cleanup failed after release attempt"
        );
      }
    }
  }
}

export function pauseDay4Mutation(
  req: Request,
  res: Response,
  next: NextFunction
): void {
  if (!isRequestActionPaused(req)) {
    next();
    return;
  }

  res
    .status(503)
    .json(day4Error("PUBLIC_ACTIONS_PAUSED", CLAIM_UNAVAILABLE_MESSAGE));
}

export function createDay4MutationRateLimiter(max: number) {
  return rateLimit({
    windowMs: 60_000,
    max,
    standardHeaders: true,
    legacyHeaders: false,
    handler: (_req, res) =>
      res
        .status(429)
        .json(
          day4Error(
            "RATE_LIMITED",
            "Too many attempts. Please wait a moment and try again."
          )
        ),
  });
}

// Separate buckets prevent one step in a normal claim workflow from consuming
// the other mutation's allowance.
export const claimRateLimiter = createDay4MutationRateLimiter(10);
export const claimExtensionRateLimiter = createDay4MutationRateLimiter(10);
export const claimReleaseRateLimiter = createDay4MutationRateLimiter(10);
