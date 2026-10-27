import express, {
  type Express,
  type NextFunction,
  type Request,
  type Response,
} from "express";
import mongoose, { type ClientSession, type Types } from "mongoose";
import { z } from "zod";
import {
  Fulfillment,
  PlacementEvidence,
  Request as MealRequest,
  Participant,
  type IRequest,
} from "../models/db.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import {
  claimTokenDigestMatches,
  digestClaimToken,
  isValidRawClaimToken,
  readClaimTokenHmacSecret,
} from "./claimToken.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { isStoppedAfterAffirmedOrder } from "./requestAvailability.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  INVALID_PLACED_ORDER_SCREENSHOT_CODE,
  INVALID_PLACED_ORDER_SCREENSHOT_MESSAGE,
  validatePlacedOrderScreenshot,
  type ValidatedPlacedOrderScreenshot,
} from "./placedOrderEvidence.js";
import { sendFulfillmentEmail } from "./emailHelpers.js";
import { isParticipantPairFenced } from "./participantBlocks.js";
import { isEitherParticipantSuspended } from "./moderationEnforcement.js";
import { isParticipantTextAllowed } from "./participantTextFilter.js";
import { startRequesterFulfillmentPush } from "./requesterFulfillmentPush.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import {
  ParticipantAccountFenceUnavailable,
  touchParticipantAccountsInSession,
} from "./participantAccountFence.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";
import {
  deriveParticipantIdentityAlias,
  loadParticipantIdentityManifest,
} from "./participantIdentityKeys.js";

export const FULFILLMENT_ROUTE_PATH = "/api/request/:id/fulfill";
export const PLACED_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const fulfillmentRateLimiter = createDay4MutationRateLimiter(10);

/**
 * The route-owned JSON ceiling (W4-H1a). A fulfillment now carries one
 * base64-encoded placed-order screenshot, which the shared 100 KB parser in
 * `app.ts` cannot hold. The decoded image is capped at 1.5 MB
 * (`PLACEMENT_EVIDENCE_MAX_BYTES`); base64 expands that by a third, so this
 * larger HTTP ceiling exists only to carry it. The decoded cap, not this limit,
 * is what bounds the image — and the shared parser stays at 100 KB for every
 * other route.
 */
export const FULFILLMENT_BODY_LIMIT = "3mb";

// A CommonPlate Grubhub order number contains digits only. Validated as a
// string and stored as one — never coerced to a number — so a leading zero
// survives and a long value is not reshaped by numeric conversion. The 50-digit
// cap is a length bound on that string, not a magnitude bound.
const orderNumberFormat = /^[0-9]{1,50}$/;
const requiredText = z.string().trim().min(1);
/**
 * The only Pickup ETA values a helper may submit: the fixed options the iOS
 * picker offers, sent verbatim. Surrounding whitespace is trimmed first, so the
 * accepted value is still exactly one canonical option; anything else (blank,
 * free text, a different case) is refused before any fulfillment work.
 */
const pickupEtaOptions = [
  "ASAP",
  "15 minutes",
  "30 minutes",
  "45 minutes",
  "60 minutes",
] as const;
const pickupEta = z.string().trim().pipe(z.enum(pickupEtaOptions));
/**
 * The historical `fulfillment.fulfillerEmail` key, tolerated and discarded.
 *
 * Since W3-I1 the helper is whoever the claim is bound to, read from
 * `helperParticipantId`, and no payload value may name them. But an app build
 * that predates this slice sends this key on every fulfillment, and the
 * grandfathered claims this slice must keep recordable are held by exactly
 * those builds — so a strict schema that rejects the key would refuse the
 * compatibility path before it could be reached, and a helper holding a real
 * Grubhub order would be unable to record it.
 *
 * It is therefore accepted as *wire shape only* and then dropped by the
 * allowlisting transform below, so it is absent from
 * `FulfillmentRequestPayload` and unreadable by anything downstream — not as
 * identity, not as a helper address, not as a Reply-To. That is a type-level
 * guarantee rather than a convention someone has to remember. Its declared type
 * is deliberately `unknown`: nothing validates a value nothing consumes, and
 * validating it would suggest it means something.
 */
const legacyFulfillerEmailWireKey = z.unknown().optional();

const fulfillmentPayloadSchema = z
  .object({
    fulfillerEmail: legacyFulfillerEmailWireKey,
    orderNumber: requiredText.regex(orderNumberFormat),
    eta: pickupEta,
    contactMessage: z
      .string()
      .trim()
      .optional()
      .transform((value) => value || undefined),
    // W4-H1a: the placed-order screenshot's wire value. Deliberately only a key
    // allowlist entry here: its absence or malformation must answer with the
    // dedicated evidence code rather than `INVALID_FULFILLMENT_PAYLOAD`, so the
    // value is checked on its own by `validatePlacedOrderScreenshot` right
    // after this schema, before any filter or mutation.
    placedOrderScreenshot: z.unknown().optional(),
  })
  .strict()
  // The explicit allowlist of what a fulfillment payload actually supplies.
  .transform((fulfillment) => ({
    orderNumber: fulfillment.orderNumber,
    eta: fulfillment.eta,
    contactMessage: fulfillment.contactMessage,
    placedOrderScreenshot: fulfillment.placedOrderScreenshot,
  }));

const tokenFulfillmentRequestSchema = z
  .object({
    claimToken: z.string(),
    fulfillment: fulfillmentPayloadSchema,
  })
  .strict();

/**
 * The W3-H1 continuation wire shape: no `claimToken` at all. A relaunched
 * process never persisted the raw token (system contract §3.1, §4), so this
 * shape carries only the fulfillment details; authorization comes from the
 * verified participant-authority header instead, checked before this schema
 * ever runs (see `fulfillRequest`). Mirrors the same additive-not-replacing
 * pattern `claimRoute.ts`'s `resolveClaimActionAuthorization` already applies
 * to extend/release.
 */
const continuationFulfillmentRequestSchema = z
  .object({
    fulfillment: fulfillmentPayloadSchema,
  })
  .strict();

interface FulfillmentRequestPayload {
  fulfillment: z.infer<typeof fulfillmentPayloadSchema>;
}

interface FulfillmentDiagnosticDocument {
  status?: string;
  claimExpiresAt?: Date | null;
  claimTokenDigest?: string | null;
  helperParticipantId?: Types.ObjectId | null;
  externalOrderAffirmed?: boolean | null;
}

/**
 * How a fulfillment caller proves ownership of the reservation (W3-H1
 * continuation).
 *
 * `token` is the original, unchanged authorization: the raw claim token
 * generated at claim time, matched by digest, exactly as before this slice.
 *
 * `participant` is additive, mirroring `ClaimActionAuthorization` in
 * `claimRoute.ts`: the caller's verified participant authority, for the case
 * a relaunch already discarded the raw token. `participantId` and `email`
 * both come directly from the verified gate — never from the payload — so
 * the persisted `fulfillerEmail` and the conditional mutation's
 * `helperParticipantId` pin are both the authenticated caller's own identity,
 * never a value some other resolution step independently looked up.
 */
type FulfillmentAuthorization =
  | { mode: "token"; digest: string }
  | {
      mode: "participant";
      participantId: string;
      email: string;
      authorityVersion: number;
    };

function fulfillmentAuthorizationMatches(
  authorization: FulfillmentAuthorization,
  document: FulfillmentDiagnosticDocument
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

/**
 * The helper this reservation belongs to (W3-I1).
 *
 * `verified` is every claim granted since this slice: the participant the
 * claim mutation bound, and that participant's current principal.
 *
 * `legacyCompatible` is the pre-I1 fulfillment-safety carve-out: a claim whose
 * conditional grant predates `helperParticipantId` entirely, so the field is
 * absent rather than null. `claimRoute.ts` writes `helperParticipantId` in the
 * same conditional mutation that grants every claim since this slice shipped,
 * so an unexpired claim reaching here with the field absent cannot be a
 * post-I1 caller bypassing the helper gate — the mutation that would have
 * created such a row does not exist. It can only be a claim issued before this
 * slice existed.
 */
type BoundHelper =
  | {
      kind: "verified";
      participantId: Types.ObjectId;
      email: string;
      authorityVersion: number;
    }
  | { kind: "legacyCompatible" };

export const CLAIM_IDENTITY_UNAVAILABLE_CODE = "CLAIM_IDENTITY_UNAVAILABLE";
/**
 * Deliberately does not suggest placing another order. A helper reaching this
 * may already hold a real Grubhub order, and no recovery path in CommonPlate
 * may ever imply that a second one is the fix.
 */
export const CLAIM_IDENTITY_UNAVAILABLE_MESSAGE =
  "CommonPlate can’t confirm who reserved this request. Don’t place another Grubhub order.";

class ConditionalPlacementFailure extends Error {}
/**
 * Raised only when a claim names a `helperParticipantId` that no longer
 * resolves to a usable participant principal — a data-integrity case, not the
 * ordinary pre-I1 absence, which takes the `legacyCompatible` path instead.
 */
class MissingHelperIdentity extends Error {}

function isInvalidId(id: unknown): boolean {
  return !mongoose.Types.ObjectId.isValid(String(id));
}

function transactionUnsupported(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const candidate = error as { code?: number; message?: string };
  return (
    candidate.code === 20 ||
    /transaction numbers are only allowed on a replica set member or mongos/i.test(
      candidate.message || ""
    )
  );
}

async function diagnosticRequest(
  id: string
): Promise<FulfillmentDiagnosticDocument | null> {
  return (await MealRequest.findById(id)
    .select(
      "status claimExpiresAt +claimTokenDigest +helperParticipantId +externalOrderAffirmed"
    )
    .lean()
    .exec()) as FulfillmentDiagnosticDocument | null;
}

/**
 * What to answer when every specific classification below has been ruled out.
 *
 * Two callers need different terminals for the same walk through the same
 * diagnostic. A rejected conditional update that reaches the end is a genuine
 * internal failure; a reservation whose verified-helper binding is missing has
 * reached the end for a known reason, and saying "internal failure" to a helper
 * who may already be holding a real order would be both wrong and unactionable.
 */
type TerminalExplanation = { status: number; code: string; message: string };

const INTERNAL_TERMINAL: TerminalExplanation = {
  status: 500,
  code: "INTERNAL_FAILURE",
  message: "Unable to record this placement right now.",
};

const MISSING_HELPER_IDENTITY_TERMINAL: TerminalExplanation = {
  status: 409,
  code: CLAIM_IDENTITY_UNAVAILABLE_CODE,
  message: CLAIM_IDENTITY_UNAVAILABLE_MESSAGE,
};

async function explainConditionalFailure(
  id: string,
  authorization: FulfillmentAuthorization,
  now: Date,
  res: Response,
  terminal: TerminalExplanation = INTERNAL_TERMINAL
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
  // A request stopped after an affirmed external order (W4-U1.3) keeps
  // `claimed` but carries no reservation authority; it is answered exactly like
  // an ordinarily released request so the private marker is never revealed.
  if (document.status !== "claimed" || isStoppedAfterAffirmedOrder(document)) {
    return sendDay4Error(
      res,
      409,
      "REQUEST_NOT_CLAIMED",
      "This request does not have an active claim."
    );
  }
  if (
    !document.claimExpiresAt ||
    document.claimExpiresAt.getTime() <= now.getTime()
  ) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXPIRED",
      "This claim has expired."
    );
  }
  // Same code and sentence regardless of mode, mirroring
  // `claimActionAuthorizationMatches`'s already-accepted precedent in
  // `claimRoute.ts` for extend/release: a mismatched participant credential
  // is refused exactly like a mismatched raw token, never told apart.
  if (!fulfillmentAuthorizationMatches(authorization, document)) {
    return sendDay4Error(
      res,
      403,
      "INVALID_CLAIM_TOKEN",
      "The claim token is missing or invalid."
    );
  }

  return sendDay4Error(res, terminal.status, terminal.code, terminal.message);
}

async function persistCorePlacement(
  id: string,
  payload: FulfillmentRequestPayload,
  authorization: FulfillmentAuthorization,
  helper: BoundHelper,
  placedAt: Date,
  /**
   * W4-U1.1: whether the optional helper Message was refused by the
   * participant-text filter. Persisted only as this content-free marker, in
   * the same atomic conditional update that commits placement.
   */
  messageSuppressed: boolean,
  /** Whether the helper submitted an optional Message at all. */
  messageSubmitted: boolean,
  /**
   * W4-H1a: the already-validated placed-order screenshot, committed with the
   * placement and its ledger row in this same transaction.
   */
  evidence: ValidatedPlacedOrderScreenshot,
  session: ClientSession
): Promise<{
  placedRequest: IRequest;
  /**
   * W4-U1.3: a block existed between this helper and the requester in the
   * placement snapshot. Placement itself is never refused or altered by it;
   * only optional direct participant contact is.
   */
  pairFenced: boolean;
  messageSuppressed: boolean;
  helperEmail?: string;
}> {
  let placedRequest: IRequest | null = null;
  let pairFenced = false;
  let effectiveMessageSuppressed = messageSuppressed;
  let verifiedHelperEmail: string | undefined;
  let helperParticipationIdentity:
    | { version: number; digest: string }
    | undefined;
  // One horizon, computed once: the placed Request and its evidence expire
  // together, so evidence is never retained longer or shorter than the
  // placement it supports.
  const retainUntil = new Date(placedAt.getTime() + PLACED_RETENTION_MS);

  await session.withTransaction(
    async () => {
      // W4-U1.3: read inside the placement snapshot so the durable marker below
      // is decided against the same state placement commits against. This
      // never gates placement — a block does not reverse or refuse a real
      // order — it only decides whether optional direct contact is withheld.
      // Reset on every callback invocation, because the driver may re-run it.
      pairFenced = false;
      effectiveMessageSuppressed = messageSuppressed;
      verifiedHelperEmail = undefined;
      helperParticipationIdentity = undefined;
      const owner = await MealRequest.findById(id, null, { session })
        .select("+requesterParticipantId +helperParticipantId")
        .lean<{
          requesterParticipantId?: Types.ObjectId | null;
          helperParticipantId?: Types.ObjectId | null;
        }>()
        .exec();
      if (!owner) throw new ConditionalPlacementFailure();
      const boundHelperId = owner.helperParticipantId ?? null;
      if (
        helper.kind === "verified" &&
        (!boundHelperId || !boundHelperId.equals(helper.participantId))
      ) {
        throw new ConditionalPlacementFailure();
      }
      const accountIds: Types.ObjectId[] = [];
      if (owner.requesterParticipantId) {
        accountIds.push(owner.requesterParticipantId);
      }
      if (boundHelperId) accountIds.push(boundHelperId);
      const expectedVersions = new Map<string, number>();
      if (helper.kind === "verified") {
        expectedVersions.set(
          String(helper.participantId),
          helper.authorityVersion
        );
      }
      let fencedAccounts: Awaited<
        ReturnType<typeof touchParticipantAccountsInSession>
      >;
      try {
        fencedAccounts = await touchParticipantAccountsInSession(
          accountIds,
          session,
          expectedVersions
        );
      } catch (error) {
        if (error instanceof ParticipantAccountFenceUnavailable) {
          throw new ConditionalPlacementFailure();
        }
        throw error;
      }
      if (boundHelperId) {
        const fencedHelper = fencedAccounts.get(String(boundHelperId));
        if (!fencedHelper) throw new ConditionalPlacementFailure();
        if (helper.kind === "verified") {
          if (
            fencedHelper.participantId !== String(helper.participantId) ||
            fencedHelper.principal !== helper.email
          ) {
            throw new ConditionalPlacementFailure();
          }
        }
        verifiedHelperEmail = fencedHelper.principal;
        const identity = await loadParticipantIdentityManifest(
          "participation",
          session
        );
        const currentKey = identity.ring.keys.get(
          identity.ring.currentVersion
        );
        if (!currentKey) {
          throw new Error("Fulfillment helper identity is unavailable");
        }
        helperParticipationIdentity = deriveParticipantIdentityAlias(
          "participation",
          identity.ring.currentVersion,
          currentKey,
          id,
          verifiedHelperEmail
        );
      } else if (helper.kind === "verified") {
        throw new ConditionalPlacementFailure();
      }
      if (owner.requesterParticipantId && boundHelperId) {
        // W4-U1.2 (boundary contract EO): either party's suspension withholds
        // optional direct contact exactly like a blocked pair.
        pairFenced =
          (await isParticipantPairFenced(
            boundHelperId,
            owner.requesterParticipantId,
            session
          )) ||
          (await isEitherParticipantSuspended(
            boundHelperId,
            owner.requesterParticipantId,
            session
          ));
      }
      if (pairFenced && messageSubmitted) {
        effectiveMessageSuppressed = true;
      }

      const setFields: Record<string, unknown> = {
        status: "placed",
        placedAt,
        deleteAt: retainUntil,
        orderNumber: payload.fulfillment.orderNumber,
        etaText: payload.fulfillment.eta,
        notificationStatus: "pending",
        updatedAt: placedAt,
      };
      if (helper.kind === "verified") {
        // The claim-bound helper's verified principal, resolved from the
        // request's own `helperParticipantId`. Never a payload value.
        if (!verifiedHelperEmail) throw new ConditionalPlacementFailure();
        setFields.fulfillerEmail = verifiedHelperEmail;
      }
      // A legacyCompatible claim has no verified principal to derive an
      // address from and the payload carries none (W3-I1 removed that field).
      // `fulfillerEmail` is optional on the schema, so leaving it unset is a
      // truthful placement, not a defect.
      // The helper Message is never written here, allowed or not: it is
      // transient fulfillment/email-only context (W4-U1.1) that exists only in
      // request memory for the immediate requester email attempt. Only the
      // content-free suppression marker is durable, and only when set — written
      // in this same conditional update so it can never disagree with
      // committed placement.
      if (effectiveMessageSuppressed) {
        setFields.contactMessageSuppressed = true;
      }
      // W4-U1.3: a Message not shared because of the blocked-pair restriction is
      // told apart from a filter refusal by this second content-free marker,
      // written in the same update. The restriction takes precedence: a
      // blocked pair never gets a filter verdict about a Message that would not
      // have been shared whatever it said.
      if (pairFenced && messageSubmitted) {
        setFields.contactMessageWithheld = true;
      }

      const unsetFields: Record<string, 1> = {
        claimedAt: 1,
        claimExpiresAt: 1,
        claimExtendedAt: 1,
        claimTokenDigest: 1,
        // W4-U1.2 (EO): a committed placement settles the helper-suspension
        // "order status Unknown" hold. M and E are deliberately left alone.
        reservationLapseHold: 1,
      };

      placedRequest = await MealRequest.findOneAndUpdate(
        {
          _id: id,
          status: "claimed",
          claimExpiresAt: { $gt: placedAt },
          // Token mode additionally pins the exact raw-token digest. Participant
          // mode has no raw token to pin — the `helperParticipantId` condition
          // below is already the full authorization, since `helper.participantId`
          // is the authenticated caller's own verified identity in that mode
          // (never an independently looked-up value), so a match there already
          // proves this exact caller owns this exact reservation.
          ...(authorization.mode === "token"
            ? { claimTokenDigest: authorization.digest }
            : {}),
          // Pins the placement to the exact binding the helper address was
          // read from. If the reservation lapsed and another verified helper
          // re-claimed between that read and this write, this condition fails
          // and the ordinary conditional-failure classifier answers — rather
          // than recording the new helper's order under the old helper's
          // address. A legacyCompatible claim never had the field at all, so
          // its pin is exact absence, not a value — matching the same
          // `$exists: false` pattern already accepted for legacy rows in
          // `resolveUnsubscribeCredentialVersion`.
          helperParticipantId:
            helper.kind === "verified"
              ? helper.participantId
              : { $exists: false },
        },
        {
          $set: setFields,
          $unset: unsetFields,
        },
        { new: true, runValidators: true, session }
      )
        // `installationId` is `select: false`; the requester-fulfillment push
        // dispatched after this transaction commits needs it to find the
        // originating installation, so it must be requested explicitly here.
        // `requesterParticipantId` is requested for the same reason: the
        // post-commit contact re-check below needs the pair, and it is never
        // projected onto any response.
        .select("+installationId +requesterParticipantId +helperParticipantId")
        .exec();

      if (!placedRequest) {
        throw new ConditionalPlacementFailure();
      }

      // A placed reservation stops blocking this helper's next one (W3-H1).
      // Pinned to the exact request the lock was reserved for, like every
      // other conditional mutation in this transaction, so a lock a
      // different, still-active claim now legitimately holds is never
      // touched. A legacyCompatible helper never held this lock, so there is
      // nothing to clear.
      if (helper.kind === "verified") {
        await Participant.updateOne(
          {
            _id: helper.participantId,
            activeReservationRequestId: placedRequest._id,
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

      await Fulfillment.create(
        [
          {
            requestId: placedRequest._id,
            orderNumber: payload.fulfillment.orderNumber,
            etaText: payload.fulfillment.eta,
            placedAt,
            ...(helperParticipationIdentity
              ? {
                  helperParticipationKeyVersion:
                    helperParticipationIdentity.version,
                  helperParticipationHmac:
                    helperParticipationIdentity.digest,
                }
              : {}),
          },
        ],
        { session }
      );

      // W4-H1a: the private evidence row, bound to the exact placed Request and
      // inserted with the same session immediately after the ledger row, so
      // Request placed + Fulfillment + PlacementEvidence commit or abort
      // together. A failure here (including a unique-index violation) aborts the
      // whole transaction: a placed Request never exists without its evidence.
      await PlacementEvidence.create(
        [
          {
            requestId: placedRequest._id,
            image: evidence.image,
            mimeType: evidence.mimeType,
            byteLength: evidence.byteLength,
            deleteAt: retainUntil,
          },
        ],
        { session }
      );
    },
    {
      readConcern: { level: "snapshot" },
      writeConcern: { w: "majority" },
    }
  );

  if (!placedRequest) {
    throw new ConditionalPlacementFailure();
  }
  return {
    placedRequest,
    pairFenced,
    messageSuppressed: effectiveMessageSuppressed,
    helperEmail: verifiedHelperEmail,
  };
}

/**
 * Reads the reservation's bound helper.
 *
 * Two documents, both private: `helperParticipantId` is `select: false` on the
 * Request, and the principal itself lives on the Participant. Read before the
 * transaction rather than inside it because the address has to be part of the
 * placement `$set`, and the conditional filter re-pins the same binding, so the
 * read cannot go stale between here and the write without the write failing.
 *
 * An absent binding takes the `legacyCompatible` path (see `BoundHelper`)
 * rather than being refused: it can only be a claim issued before this slice,
 * and the existing fulfillment-safety contract requires such a claim to
 * remain recordable. A binding that is present but no longer resolves to a
 * usable participant is a different, narrower failure — see
 * `MissingHelperIdentity` — and is refused.
 */
async function resolveBoundHelper(id: string): Promise<BoundHelper> {
  const reservation = await MealRequest.findById(id)
    .select("+helperParticipantId")
    .lean<{ helperParticipantId?: Types.ObjectId | null }>()
    .exec();
  const participantId = reservation?.helperParticipantId;
  if (!participantId) return { kind: "legacyCompatible" };

  const participant = await Participant.findById(participantId)
    .select("email authorityVersion")
    .lean<{ email: string; authorityVersion: number }>()
    .exec();
  const email = normalizeParticipantPrincipal(participant?.email);
  if (!participant || !email || !Number.isInteger(participant.authorityVersion)) {
    throw new MissingHelperIdentity();
  }

  return {
    kind: "verified",
    participantId,
    email,
    authorityVersion: participant.authorityVersion,
  };
}

async function recordNotificationOutcome(
  requestId: string,
  placedAt: Date,
  status: "sent" | "failed"
): Promise<void> {
  const attemptedAt = new Date();
  try {
    await MealRequest.updateOne(
      { _id: requestId, status: "placed", placedAt },
      {
        $set: {
          notificationStatus: status,
          notificationAttemptedAt: attemptedAt,
          updatedAt: attemptedAt,
        },
      }
    ).exec();
  } catch {
    // The transaction already committed. A verification-state write failure
    // must never reverse placement or turn this into another order attempt.
    console.error(
      `[fulfillment] Requester email provider result could not be recorded (${status})`
    );
  }
}

export async function fulfillRequest(
  req: Request,
  res: Response
): Promise<Response> {
  const id = String(req.params.id);
  if (isInvalidId(id)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_REQUEST_ID",
      "The request ID is invalid."
    );
  }

  // Two accepted wire shapes (W3-H1 continuation), distinguished by whether
  // `claimToken` is present at all — the same "answer nothing until the
  // shape is right" posture `resolveClaimActionAuthorization` already applies
  // to extend/release. A body carrying the key (even a malformed one) always
  // takes the original token path; only a body that omits it entirely is
  // eligible for participant-authority continuation.
  const body = req.body;
  const hasClaimTokenKey =
    typeof body === "object" &&
    body !== null &&
    !Array.isArray(body) &&
    Object.prototype.hasOwnProperty.call(body, "claimToken");

  let authorization: FulfillmentAuthorization;
  let validation:
    | ReturnType<typeof tokenFulfillmentRequestSchema.safeParse>
    | ReturnType<typeof continuationFulfillmentRequestSchema.safeParse>;

  if (hasClaimTokenKey) {
    const candidate = (body as Record<string, unknown>).claimToken;
    if (!isValidRawClaimToken(candidate)) {
      return sendDay4Error(
        res,
        400,
        "INVALID_CLAIM_TOKEN",
        "The claim token is missing or invalid."
      );
    }
    try {
      authorization = {
        mode: "token",
        digest: digestClaimToken(candidate, readClaimTokenHmacSecret()),
      };
    } catch {
      console.error("[fulfillment] Claim token secret unavailable");
      return sendDay4Error(
        res,
        500,
        "INTERNAL_FAILURE",
        "Unable to record this placement right now."
      );
    }
    validation = tokenFulfillmentRequestSchema.safeParse(body);
  } else {
    // The helper gate (W3-I1), matching `claimRequest`/`resolveClaimActionAuthorization`:
    // checked before any payload validation or database work, so an
    // unverified caller learns nothing about whether their payload would
    // otherwise have been accepted.
    const authority = await resolveParticipantAuthority(req);
    if (!authority.ok) {
      return sendParticipantAuthorityRefusal(res, authority.refusal);
    }
    authorization = {
      mode: "participant",
      participantId: authority.participant.participantId,
      email: authority.participant.principal,
      authorityVersion: authority.participant.authorityVersion,
    };
    validation = continuationFulfillmentRequestSchema.safeParse(body);
  }

  if (!validation.success) {
    return sendDay4Error(
      res,
      400,
      "INVALID_FULFILLMENT_PAYLOAD",
      "The fulfillment details are invalid."
    );
  }
  const payload: FulfillmentRequestPayload = validation.data;

  // W4-H1a: every NEW fulfillment needs exactly one valid placed-order
  // screenshot. Checked here — after participant authority and the ordinary
  // payload, before the U1.1 Message filter and before any mutation — so a
  // missing, malformed, oversized, or wrong-type image is a definitive 400 that
  // touches nothing, in both authorization shapes. Content-free by design: the
  // response never says which check failed, and nothing is logged.
  const evidenceCheck = validatePlacedOrderScreenshot(
    payload.fulfillment.placedOrderScreenshot
  );
  if (!evidenceCheck.ok) {
    return sendDay4Error(
      res,
      400,
      INVALID_PLACED_ORDER_SCREENSHOT_CODE,
      INVALID_PLACED_ORDER_SCREENSHOT_MESSAGE
    );
  }
  const evidence = evidenceCheck.evidence;

  // W4-U1.1: the optional helper Message is filtered after fulfillment
  // authority/payload validation and before the durable placement mutation.
  // A match is NOT a fulfillment failure: the real Grubhub order is already
  // placed, so placement commits exactly once as if no Message existed, the
  // Message is neither stored nor emailed, and the response carries a private
  // content-free suppression signal. The filter is pure and reads/writes
  // nothing, so no caller learns the verdict before authority is checked.
  const submittedMessage = payload.fulfillment.contactMessage;
  const messageSuppressed =
    submittedMessage !== undefined && !isParticipantTextAllowed(submittedMessage);
  const emailedMessage = messageSuppressed ? undefined : submittedMessage;

  const placedAt = new Date();
  // Declared here so the failure classifier and `finally` can see it, but
  // produced inside the try: an unavailable session must answer in the
  // structured error envelope rather than escape as a rejected promise into
  // the generic handler.
  let session: ClientSession | undefined;
  let placedRequest: IRequest;
  let helper: BoundHelper;
  let placedHelperEmail: string | undefined;
  let pairFenced = false;
  let finalMessageSuppressed = messageSuppressed;

  try {
    // Token mode re-reads the current binding, exactly as before this slice.
    // Participant mode already has the caller's verified identity from the
    // gate above — never independently looked up — so it is used directly;
    // see `FulfillmentAuthorization`.
    helper =
      authorization.mode === "token"
        ? await resolveBoundHelper(id)
        : {
            kind: "verified",
            participantId: new mongoose.Types.ObjectId(
              authorization.participantId
            ),
            email: authorization.email,
            authorityVersion: authorization.authorityVersion,
          };
    session = await mongoose.startSession();
    const placement = await persistCorePlacement(
      id,
      payload,
      authorization,
      helper,
      placedAt,
      messageSuppressed,
      submittedMessage !== undefined,
      evidence,
      session
    );
    placedRequest = placement.placedRequest;
    pairFenced = placement.pairFenced;
    finalMessageSuppressed = placement.messageSuppressed;
    placedHelperEmail = placement.helperEmail;
  } catch (error) {
    if (error instanceof MissingHelperIdentity) {
      // The named participant no longer resolves, so the conditional update
      // would have been rejected anyway — its filter pins the same binding —
      // so this walks the ordinary classifier and keeps every existing
      // answer: not found, already placed, not claimed, claim expired, wrong
      // token. Only the case none of those explain, a live reservation whose
      // bound participant has vanished, reaches the dedicated terminal.
      return await explainConditionalFailure(
        id,
        authorization,
        placedAt,
        res,
        MISSING_HELPER_IDENTITY_TERMINAL
      );
    }
    if (error instanceof ConditionalPlacementFailure) {
      return await explainConditionalFailure(
        id,
        authorization,
        placedAt,
        res
      );
    }
    if (transactionUnsupported(error)) {
      console.error(
        "[fulfillment] MongoDB transactions require a replica set or mongos"
      );
      return sendDay4Error(
        res,
        503,
        "TRANSACTIONS_UNAVAILABLE",
        "Placement recording requires a transaction-capable database."
      );
    }
    console.error("[fulfillment] Transactional placement failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to record this placement right now."
    );
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        // The transaction outcome is already known here. Cleanup cannot change
        // placement truth or prevent the committed response path from running.
        // Deliberately omit request, token, order, and contact details.
        console.error("[fulfillment] MongoDB session cleanup failed after placement attempt");
      }
    }
  }

  // W4-U1.3: the latest knowledge wins. A block committed after the placement
  // snapshot but before the email is built still withholds direct contact, and
  // an unreadable answer withholds it too — failing closed here costs a
  // Reply-To, failing open would disclose a helper's address across a block.
  // This never touches placement, which has already durably committed.
  if (!pairFenced && helper.kind === "verified") {
    const requesterId = (
      placedRequest as unknown as {
        requesterParticipantId?: Types.ObjectId | null;
      }
    ).requesterParticipantId;
    if (requesterId) {
      try {
        pairFenced =
          (await isParticipantPairFenced(helper.participantId, requesterId)) ||
          (await isEitherParticipantSuspended(helper.participantId, requesterId));
      } catch {
        pairFenced = true;
      }
    }
  }
  const contactWithheld = pairFenced;
  // Reported to the helper only, and only when a Message was actually
  // submitted: there is nothing to say about a Message that never existed.
  const messageWithheld = contactWithheld && submittedMessage !== undefined;
  if (messageWithheld) {
    finalMessageSuppressed = true;
  }

  let notificationStatus: "sent" | "failed" = "sent";
  try {
    await sendFulfillmentEmail(
      placedRequest,
      validation.data.fulfillment.orderNumber,
      validation.data.fulfillment.eta,
      // The Message is withheld for the same two reasons it is ever withheld:
      // the participant-text filter (U1.1) or a blocked pair (U1.3).
      finalMessageSuppressed ? undefined : emailedMessage,
      // The Reply-To the requester sees is the claim-bound helper's verified
      // address — the same value persisted above — so the coordination address
      // in that email is one CommonPlate has actually proved. A
      // legacyCompatible placement has no verified address to offer; the
      // payload carries none either, since W3-I1 removed that field, so
      // omitting Reply-To here is the only truthful choice.
      // A blocked pair never receives a helper address: direct
      // participant-to-participant contact is exactly what a block ends, and
      // the order facts in the email are complete without it.
      helper.kind === "verified" && !contactWithheld
        ? placedHelperEmail
        : undefined
    );
    console.info("[fulfillment] Requester email submitted to provider");
  } catch {
    notificationStatus = "failed";
    console.error("[fulfillment] Requester email provider submission failed");
  }

  await recordNotificationOutcome(id, placedAt, notificationStatus);
  const publicResponse = buildPublicRequestDetailResponse(
    placedRequest as unknown as PublicRequestDocument,
    placedAt
  );
  res.json({
    request: publicResponse.request,
    notification: { status: notificationStatus },
    // Present only when the optional Message was suppressed (W4-U1.1): the
    // private, content-free signal the helper client needs to say the order was
    // recorded but the Message was not sent. Absent otherwise, so every stale
    // client keeps decoding the unchanged success shape.
    ...(finalMessageSuppressed ? { messageSuppressed: true } : {}),
    // W4-U1.3: additional, affirmative-only refinement of the signal above for
    // a Message withheld by the blocked-pair restriction. Absent for a filter
    // refusal, so U1.1's presentation is unchanged.
    ...(messageWithheld ? { messageWithheld: true } : {}),
  });
  // Started after the response is sent and deliberately not awaited, matching
  // `startHelperNewRequestPush`: a slow, timed-out, or misconfigured APNs
  // submission must not delay this response, and placement has already
  // durably committed by this point regardless of what push does next. The
  // start function is total — it neither throws nor returns anything to
  // await — so nothing here can reach a `catch` after the headers are
  // flushed.
  startRequesterFulfillmentPush(placedRequest);
  return res;
}

/**
 * Whether `error` is something the body parser itself raised (`body-parser` /
 * `raw-body` errors are `http-errors` carrying a string `type` and a 4xx
 * status). Anything else — notably a rejection from the async handler, which
 * Express 5 also forwards to this route's error middleware — is NOT a parse
 * failure and must never be answered as one: it can follow a committed
 * placement, so calling it a definitive 400 would be false.
 */
function isBodyParserError(error: unknown): error is { type: string } {
  if (typeof error !== "object" || error === null) return false;
  const candidate = error as { type?: unknown; status?: unknown };
  return (
    typeof candidate.type === "string" &&
    typeof candidate.status === "number" &&
    candidate.status >= 400 &&
    candidate.status < 500
  );
}

/**
 * Final error boundary for this route's own body parser. A malformed or
 * oversized body makes `express.json` call `next(err)` instead of running the
 * handler; without this, that error would reach the global error handler in
 * `app.ts`, which logs the error object — and a body-parser error can carry a
 * slice of the raw request body, which here may be screenshot bytes. Nothing
 * about the error is logged. An over-limit body can only be an oversized image
 * (a legitimate client stays far under the ceiling), so it answers with the
 * evidence code; any other unreadable body is an ordinary invalid payload. A
 * non-parser error is passed on untouched (see `isBodyParserError`).
 */
export function fulfillmentParserError(
  error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (res.headersSent || !isBodyParserError(error)) {
    next(error);
    return;
  }
  if (error.type === "entity.too.large") {
    sendDay4Error(
      res,
      400,
      INVALID_PLACED_ORDER_SCREENSHOT_CODE,
      INVALID_PLACED_ORDER_SCREENSHOT_MESSAGE
    );
    return;
  }
  sendDay4Error(
    res,
    400,
    "INVALID_FULFILLMENT_PAYLOAD",
    "The fulfillment details are invalid."
  );
}

/**
 * Registers the fulfillment route with its own bounded JSON parser. Must be
 * called BEFORE the global `express.json({ limit: "100kb" })` in `app.ts`: a
 * global parser runs ahead of route middleware and would refuse this body (and
 * answer through the global error handler) before this route's larger ceiling
 * could apply. Order here is the rate limiter first — so a throttled caller
 * costs no body parsing — then the route-scoped parser, the handler, and the
 * content-free parser-error boundary. The route is deliberately not paused by
 * `PUBLIC_ACTIONS_PAUSED`: a helper holding a real order must be able to
 * record it.
 */
export function registerFulfillmentRoute(app: Express): void {
  app.post(
    FULFILLMENT_ROUTE_PATH,
    fulfillmentRateLimiter,
    express.json({ limit: FULFILLMENT_BODY_LIMIT }),
    fulfillRequest,
    fulfillmentParserError
  );
}
