import type { Request, Response } from "express";
import mongoose from "mongoose";
import { z } from "zod";
import {
  Participant,
  ParticipantBlock,
  Request as MealRequest,
  type ParticipantBlockedRole,
} from "../models/db.js";
import {
  CLAIM_UNAVAILABLE_MESSAGE,
  createDay4MutationRateLimiter,
  readReleaseReservationVersion,
  releaseReservationWithinSession,
} from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  touchParticipantAccountsInSession,
  ParticipantAccountFenceUnavailable,
} from "./participantAccountFence.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { bumpBlockFence } from "./participantBlocks.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import {
  deriveParticipantIdentityAlias,
  deriveParticipantIdentityAliases,
  loadParticipantIdentityManifest,
  ParticipantIdentityConfigurationError,
} from "./participantIdentityKeys.js";
import { isPublicActionsPaused } from "./publicActionsPause.js";
import { isEffectivelyAvailable, isVisibleNow } from "./requestAvailability.js";
import { mintReportAuthorization } from "./reportAuthorization.js";
import {
  closeMessagingForPairInSession,
  grantMessagingReportLeaseInSession,
} from "./messagingLifecycle.js";
import { tryReadSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";

/**
 * Participant blocking (W4-U1.3).
 *
 * There is no way to name a participant here, and that is deliberate: a block
 * is created *from a request the caller legitimately holds context for*, and
 * the backend resolves the other party from that request's private participant
 * authority. No participant id, address, or search is accepted or returned.
 *
 * Reporting is a separate action and authority (U1.2); nothing here creates,
 * reads, or implies a report.
 */
export const REQUEST_BLOCK_ROUTE_PATH = "/api/request/:id/block";
export const PARTICIPANT_BLOCKS_ROUTE_PATH = "/api/participant/blocks";
export const PARTICIPANT_BLOCK_ROUTE_PATH = "/api/participant/blocks/:blockId";

export const BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED_CODE =
  "BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED";
export const BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED_MESSAGE =
  "Tell us whether you’ve already placed the Grubhub order.";

export const RESERVATION_STATE_CHANGED_CODE = "RESERVATION_STATE_CHANGED";
export const RESERVATION_STATE_CHANGED_MESSAGE =
  "Your reservation changed. Check its status and try again.";

export const BLOCK_NOT_FOUND_CODE = "BLOCK_NOT_FOUND";
export const BLOCK_NOT_FOUND_MESSAGE = "This blocked student could not be found.";

const BLOCK_LIST_LIMIT = 200;

export const createParticipantBlockRateLimiter =
  createDay4MutationRateLimiter(10);
export const deleteParticipantBlockRateLimiter =
  createDay4MutationRateLimiter(10);
export const listParticipantBlocksRateLimiter =
  createDay4MutationRateLimiter(30);

const createBlockBodySchema = z
  .object({
    /**
     * The helper's answer to "have you already placed the real Grubhub
     * order?". Required while the caller holds the live reservation on this
     * request. A `No` is ignored once that reservation has lapsed, because
     * there is nothing left to release. A `Yes` is never ignored: it commits
     * only together with the post-Yes authority on the caller's own
     * reservation, and is refused when the caller no longer holds it.
     */
    externalOrderPlaced: z.boolean().optional(),
  })
  .strict();

/** The target is not something this caller has contextual authority to block. */
class BlockTargetUnavailable extends Error {}
class ExternalOrderAnswerRequired extends Error {}
/**
 * The helper answered `No`, which requires ending the reservation, and
 * reservation release is paused by `PUBLIC_ACTIONS_PAUSED`. Raised before any
 * write in the transaction, so neither the Block nor the release commits.
 */
class ReservationReleasePaused extends Error {}
class ReservationStateChanged extends Error {}

interface BlockSourceRequest {
  _id: mongoose.Types.ObjectId;
  vendor: string;
  status: "open" | "claimed" | "placed";
  createdAt: Date;
  visibleFrom?: Date | null;
  expiresAt?: Date | null;
  deleteAt?: Date | null;
  claimExpiresAt?: Date | null;
  requesterParticipantId?: mongoose.Types.ObjectId | null;
  helperParticipantId?: mongoose.Types.ObjectId | null;
  requesterPickupConfirmedAt?: Date | null;
  moderationUnavailable?: boolean;
  reservationLapseHold?: boolean;
  externalOrderAffirmed?: boolean;
}

/** The only shape of a block that ever reaches a wire: context, never identity. */
export interface PublicParticipantBlock {
  id: string;
  blockedRole: ParticipantBlockedRole;
  diningLocation: string;
  interactionAt: Date;
  createdAt: Date;
}

function toPublicBlock(row: {
  _id: unknown;
  blockedRole: ParticipantBlockedRole;
  diningLocation: string;
  interactionAt: Date;
  createdAt: Date;
}): PublicParticipantBlock {
  return {
    id: String(row._id),
    blockedRole: row.blockedRole,
    diningLocation: row.diningLocation,
    interactionAt: row.interactionAt,
    createdAt: row.createdAt,
  };
}

function isDuplicateKeyError(error: unknown): boolean {
  return (
    Boolean(error) &&
    typeof error === "object" &&
    (error as { code?: unknown }).code === 11000
  );
}

interface CreateBlockOutcome {
  block: PublicParticipantBlock;
  reservationReleased: boolean;
  inserted: boolean;
  reportAuthorizationEligible: boolean;
  reportAuthorizationCounterpartId: string;
  reportAuthorization?: string;
}

async function attemptCreateBlock(input: {
  requestId: string;
  callerId: mongoose.Types.ObjectId;
  callerPrincipal: string;
  callerAuthorityVersion: number;
  externalOrderPlaced: boolean | undefined;
  now: Date;
}): Promise<CreateBlockOutcome> {
  const {
    requestId,
    callerId,
    callerPrincipal,
    callerAuthorityVersion,
    externalOrderPlaced,
    now,
  } = input;
  let session: mongoose.ClientSession | undefined;

  try {
    // Captured once, outside the transaction, exactly like `releaseClaim`: a
    // driver retry of the callback must never adopt an extension that landed
    // after this attempt began.
    const originalVersion = await readReleaseReservationVersion(requestId);

    session = await mongoose.startSession();
    const outcome = await session.withTransaction(
      async (): Promise<CreateBlockOutcome> => {
        let authorizationEligible = false;
        const request = (await MealRequest.findById(requestId, null, {
          session,
        })
          .select(
            "+requesterParticipantId +helperParticipantId +requesterPickupConfirmedAt +moderationUnavailable +reservationLapseHold +externalOrderAffirmed"
          )
          .lean()
          .exec()) as BlockSourceRequest | null;

        if (!request || !request.requesterParticipantId) {
          throw new BlockTargetUnavailable();
        }

        const requesterId = request.requesterParticipantId;
        const callerIsRequester = requesterId.equals(callerId);
        let targetId: mongoose.Types.ObjectId;
        let blockedRole: ParticipantBlockedRole;
        let heldReservation = false;
        // The caller is still the reservation's bound helper in this snapshot,
        // whether or not its deadline has passed. Expiry never clears the
        // binding, so this is the same reservation the Yes answer was given for.
        let boundToCaller = false;

        if (callerIsRequester) {
          // Requester → helper exists from the start of a live reservation
          // (accepted reservation-start Block) and through placement: a
          // retained request of the caller's own with a recorded helper.
          // A lapsed reservation has no live helper context, so it is excluded.
          const liveReservation =
            request.status === "claimed" &&
            Boolean(request.claimExpiresAt && request.claimExpiresAt.getTime() > now.getTime()) &&
            Boolean(request.expiresAt && request.expiresAt.getTime() > now.getTime());
          if (
            (request.status !== "placed" && !liveReservation) ||
            !request.helperParticipantId ||
            (request.deleteAt && request.deleteAt.getTime() <= now.getTime())
          ) {
            throw new BlockTargetUnavailable();
          }
          targetId = request.helperParticipantId;
          blockedRole = "helper";
          authorizationEligible =
            liveReservation ||
            (MealRequest.schema.path("requesterPickupConfirmedAt") !== undefined &&
              request.requesterPickupConfirmedAt == null &&
              (!request.deleteAt || request.deleteAt.getTime() > now.getTime()));
        } else {
          // Helper → requester: a request the caller could legitimately have
          // opened. A request not yet visible has not been shown to anyone.
          if (!isVisibleNow(request.visibleFrom ?? undefined, now)) {
            throw new BlockTargetUnavailable();
          }
          targetId = requesterId;
          blockedRole = "requester";
          boundToCaller =
            request.status === "claimed" &&
            Boolean(request.helperParticipantId) &&
            request.helperParticipantId!.equals(callerId) &&
            Boolean(request.claimExpiresAt);
          heldReservation =
            boundToCaller && request.claimExpiresAt!.getTime() > now.getTime();
          // Block may always happen, but a report-only handoff exists only
          // inside the helper's accepted report window: a live reservation, a
          // placed order with pickup unconfirmed, or a request still available.
          // A confirmed pickup is the cutoff; Block then never mints authority.
          const retained = !request.deleteAt || request.deleteAt.getTime() > now.getTime();
          authorizationEligible =
            retained &&
            (heldReservation ||
              (request.status === "placed" &&
                request.helperParticipantId?.equals(callerId) === true &&
                request.requesterPickupConfirmedAt == null) ||
              (request.status !== "placed" && isEffectivelyAvailable(request, now)));
        }

        if (targetId.equals(callerId)) {
          throw new BlockTargetUnavailable();
        }

        const [caller, target] = await Promise.all([
          Participant.findById(callerId)
            .select("email authorityVersion")
            .session(session!)
            .lean<{ email: string; authorityVersion: number } | null>()
            .exec(),
          Participant.findById(targetId)
            .select("email authorityVersion")
            .session(session!)
            .lean<{ email: string; authorityVersion: number } | null>()
            .exec(),
        ]);
        if (
          !caller ||
          caller.authorityVersion !== callerAuthorityVersion ||
          normalizeParticipantPrincipal(caller.email) !== callerPrincipal ||
          !target
        ) {
          throw new BlockTargetUnavailable();
        }
        const targetPrincipal = normalizeParticipantPrincipal(target.email);
        if (targetPrincipal === null) throw new BlockTargetUnavailable();
        const identity = await loadParticipantIdentityManifest(
          "block-safety",
          session
        );
        const aliases = deriveParticipantIdentityAliases(
          "block-safety",
          identity.ring,
          identity.entries,
          null,
          targetPrincipal
        );
        const priorBlock = await ParticipantBlock.findOne({
          blockerParticipantId: callerId,
          blockedParticipantId: targetId,
        })
          .select(
            "+blockedSafetyKeyVersion +blockedSafetyHmac"
          )
          .session(session!)
          .lean<{
            blockedSafetyKeyVersion?: number;
            blockedSafetyHmac?: string;
          } | null>()
          .exec();
        if (
          priorBlock &&
          !aliases.some(
            (alias) =>
              alias.version === priorBlock.blockedSafetyKeyVersion &&
              alias.digest === priorBlock.blockedSafetyHmac
          )
        ) {
          throw new ParticipantIdentityConfigurationError(
            "Participant block safety identity is inconsistent"
          );
        }
        const currentKey = identity.ring.keys.get(
          identity.ring.currentVersion
        );
        if (!currentKey) {
          throw new ParticipantIdentityConfigurationError(
            "Participant block safety identity is unavailable"
          );
        }
        const currentAlias = deriveParticipantIdentityAlias(
          "block-safety",
          identity.ring.currentVersion,
          currentKey,
          null,
          targetPrincipal
        );

        // Blocking while holding the live reservation is the one case that
        // must not guess: whether the real external order already exists
        // decides whether releasing is truthful.
        if (heldReservation && externalOrderPlaced === undefined) {
          throw new ExternalOrderAnswerRequired();
        }

        // Block and Unblock are safety controls and are not gated by the
        // operational pause (accepted U1.3 clarification, 2026-10-13). The one
        // thing the pause does govern here is *release*: a `No` answer is
        // Block plus truthful release as one logical transaction, so while
        // release is paused neither half may commit. Checked before the first
        // write, which is what keeps this atomic without any compensation — the
        // transaction simply never writes. `Yes`, and every Block with no live
        // reservation to end, never reach this check: they release nothing.
        if (
          heldReservation &&
          externalOrderPlaced === false &&
          isPublicActionsPaused()
        ) {
          throw new ReservationReleasePaused();
        }

        // A `Yes` is an answer about the caller's own reservation, and its only
        // accepted outcome is the Block *with* the post-Yes authority below. If
        // this snapshot says the caller no longer holds that reservation — it
        // was released, re-claimed by another helper, placed, retired by a
        // post-Yes Stop, or was never theirs — nothing is written: no Block
        // row, no fence bump, no marker, and nothing of anyone else's
        // reservation. A Block that answered Yes without the authority would be
        // a false "Block succeeded" implying order protection (C1). The request
        // itself having expired ends the reservation too. Checked inside the
        // transaction, against the same snapshot the marker write is pinned
        // to, so a release / re-claim / placement committing concurrently
        // either precedes this read (refused here) or collides with the marker
        // write and is retried against a fresh snapshot.
        if (
          !callerIsRequester &&
          externalOrderPlaced === true &&
          (!boundToCaller ||
            !request.expiresAt ||
            request.expiresAt.getTime() <= now.getTime())
        ) {
          throw new ReservationStateChanged();
        }

        // Idempotent per (owner, target): a repeat is a no-op that keeps the
        // original snapshot. The snapshot is only what the owner was already
        // shown — role, dining location, and the request's creation time.
        const existingBlock = await ParticipantBlock.exists({
          blockerParticipantId: callerId,
          blockedParticipantId: targetId,
        }).session(session!);
        const row = await ParticipantBlock.findOneAndUpdate(
          { blockerParticipantId: callerId, blockedParticipantId: targetId },
          {
            $setOnInsert: {
              blockedRole,
              diningLocation: request.vendor,
              interactionAt: request.createdAt,
              blockedSafetyKeyVersion: currentAlias.version,
              blockedSafetyHmac: currentAlias.digest,
            },
          },
          { upsert: true, new: true, session }
        )
          .lean()
          .exec();

        if (!row) {
          throw new Error("Block upsert returned no document");
        }

        const fencedParticipants = await touchParticipantAccountsInSession(
          [callerId, targetId],
          session!,
          new Map([[String(callerId), callerAuthorityVersion]])
        );
        if (
          fencedParticipants.get(String(callerId))?.principal !== callerPrincipal ||
          fencedParticipants.get(String(targetId))?.principal !== targetPrincipal
        ) {
          throw new BlockTargetUnavailable();
        }

        // The serialization anchor against a concurrent claim/extension. See
        // `src/participantBlocks.ts` for the invariant.
        if (await bumpBlockFence(callerId, targetId, session!) !== 2) {
          throw new BlockTargetUnavailable();
        }

        // Permanent closure of every conversation between the pair, in this
        // same transaction and before any release unsets the helper binding.
        // The report-only lease is granted only for a newly inserted Block that
        // is itself report-eligible, and never restores chat access.
        await closeMessagingForPairInSession(callerId, targetId, session!);
        const leaseHelperId = callerIsRequester ? targetId : callerId;
        if (existingBlock === null && authorizationEligible) {
          await grantMessagingReportLeaseInSession(session!, {
            requestId: request._id as mongoose.Types.ObjectId,
            helperId: leaseHelperId,
            holderId: callerId,
          });
        }

        // `Yes`: the real order already exists. The reservation is left exactly
        // as it is — still claimed under its existing authority until the normal
        // placement transaction records the order — but the request must also
        // never again be offered to anyone else, whether the helper later
        // Stops, lets the reservation lapse, or the pair is unblocked. That is
        // the private `externalOrderAffirmed` marker, written here, in the same
        // transaction as the Block itself, and pinned to the exact reservation
        // this snapshot just read as the caller's (same helper binding, same
        // deadline). It is never a separate step: a Block that answered Yes
        // without the marker would leave a window in which Stop or expiry
        // reopens a request whose order exists.
        //
        // A Yes that reaches the server just after the deadline, before anyone
        // has re-claimed, is still an answer about this same reservation:
        // expiry never clears the binding, and nothing else has touched it. It
        // is written too (spec section 5, Yes-Block vs concurrent expiry). A
        // Yes for a reservation that is no longer the caller's never gets
        // here: it was refused above, before the first write.
        if (boundToCaller && externalOrderPlaced === true) {
          const affirmed = await MealRequest.updateOne(
            {
              _id: requestId,
              status: "claimed",
              claimExpiresAt: request.claimExpiresAt,
              helperParticipantId: callerId,
            },
            { $set: { externalOrderAffirmed: true, updatedAt: now } },
            { session }
          ).exec();
          if (affirmed.matchedCount === 0) {
            // The snapshot said bound and the write says otherwise: refuse the
            // whole Block rather than commit a Yes with no durable authority.
            throw new ReservationStateChanged();
          }
        }

        let reservationReleased = false;
        if (heldReservation && externalOrderPlaced === false) {
          // `No`: the real order does not exist, so ending the reservation is
          // truthful, and it goes through the one accepted release mutation.
          // W4-U1.2 (boundary contract EO): this is the accepted confirmed No
          // — it reopens the request even under a suspended-helper L hold
          // (clearing L), while M still retires it in place.
          if (!originalVersion) {
            throw new ReservationStateChanged();
          }
          const released = await releaseReservationWithinSession(session!, {
            requestId,
            version: originalVersion,
            now,
            authorization: {
              mode: "participant",
              participantId: String(callerId),
              principal: callerPrincipal,
              authorityVersion: callerAuthorityVersion,
            },
            confirmedNo: true,
          });
          if (!released) {
            // The reservation moved after this attempt began (an extension,
            // typically). Nothing is committed: a block that claims to have
            // ended a reservation it did not end would be a fabricated state.
            throw new ReservationStateChanged();
          }
          reservationReleased = true;
        }

        return {
          block: toPublicBlock(
            row as unknown as Parameters<typeof toPublicBlock>[0]
          ),
          reservationReleased,
          inserted: existingBlock === null,
          reportAuthorizationEligible: authorizationEligible,
          reportAuthorizationCounterpartId: String(targetId),
        };
      },
      {
        readConcern: { level: "snapshot" },
        writeConcern: { w: "majority" },
      }
    );

    if (!outcome) {
      throw new Error("Block transaction produced no outcome");
    }
    if (outcome.inserted && outcome.reportAuthorizationEligible) {
      const keyring = tryReadSafetyIdentityKeyring();
      if (keyring) {
        outcome.reportAuthorization = mintReportAuthorization(
          keyring,
          String(callerId),
          requestId,
          now,
          undefined,
          outcome.reportAuthorizationCounterpartId
        );
      }
    }
    return outcome;
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        console.error("[route] MongoDB session cleanup failed after block attempt");
      }
    }
  }
}

/** `POST /api/request/:id/block` */
export async function createParticipantBlock(
  req: Request,
  res: Response
): Promise<Response> {
  const id = String(req.params.id);
  if (!mongoose.Types.ObjectId.isValid(id)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_REQUEST_ID",
      "The request ID is invalid."
    );
  }

  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const parsed = createBlockBodySchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return sendDay4Error(
      res,
      400,
      "INVALID_BLOCK_PAYLOAD",
      "The block request is invalid."
    );
  }

  const callerId = new mongoose.Types.ObjectId(authority.participant.participantId);
  const now = new Date();

  try {
    let outcome: CreateBlockOutcome;
    try {
      outcome = await attemptCreateBlock({
        requestId: id,
        callerId,
        callerPrincipal: authority.participant.principal,
        callerAuthorityVersion: authority.participant.authorityVersion,
        externalOrderPlaced: parsed.data.externalOrderPlaced,
        now,
      });
    } catch (error) {
      // Two first-time blocks for one pair can race on the unique index; the
      // loser re-runs once and simply finds the winner's row.
      if (!isDuplicateKeyError(error)) throw error;
      outcome = await attemptCreateBlock({
        requestId: id,
        callerId,
        callerPrincipal: authority.participant.principal,
        callerAuthorityVersion: authority.participant.authorityVersion,
        externalOrderPlaced: parsed.data.externalOrderPlaced,
        now,
      });
    }
    return res.json({
      block: outcome.block,
      reservationReleased: outcome.reservationReleased,
      ...(outcome.reportAuthorization
        ? { reportAuthorization: outcome.reportAuthorization }
        : {}),
    });
  } catch (error) {
    if (
      error instanceof ParticipantIdentityConfigurationError ||
      error instanceof ParticipantAccountFenceUnavailable
    ) {
      return sendDay4Error(
        res,
        503,
        "PARTICIPANT_VERIFICATION_UNAVAILABLE",
        "We couldn’t check your NYU verification right now. Please try again in a moment."
      );
    }
    if (error instanceof BlockTargetUnavailable) {
      return sendDay4Error(
        res,
        404,
        "REQUEST_NOT_FOUND",
        "This request could not be found."
      );
    }
    if (error instanceof ExternalOrderAnswerRequired) {
      return sendDay4Error(
        res,
        400,
        BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED_CODE,
        BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED_MESSAGE
      );
    }
    if (error instanceof ReservationReleasePaused) {
      // The same truthful paused-action outcome the release route itself gives.
      return sendDay4Error(
        res,
        503,
        "PUBLIC_ACTIONS_PAUSED",
        CLAIM_UNAVAILABLE_MESSAGE
      );
    }
    if (error instanceof ReservationStateChanged) {
      return sendDay4Error(
        res,
        409,
        RESERVATION_STATE_CHANGED_CODE,
        RESERVATION_STATE_CHANGED_MESSAGE
      );
    }
    console.error("[route] Participant block mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to block this student right now."
    );
  }
}

/**
 * `GET /api/participant/blocks` — the caller's own blocks only, as interaction
 * context. Never the other participant's id, address, or the reverse direction.
 */
export async function listParticipantBlocks(
  req: Request,
  res: Response
): Promise<Response> {
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  res.setHeader("Cache-Control", "private, no-store");
  try {
    const rows = await ParticipantBlock.find({
      blockerParticipantId: new mongoose.Types.ObjectId(
        authority.participant.participantId
      ),
    })
      .sort({ createdAt: -1 })
      .limit(BLOCK_LIST_LIMIT)
      .lean()
      .exec();

    return res.json({
      blocks: rows.map((row) =>
        toPublicBlock(row as unknown as Parameters<typeof toPublicBlock>[0])
      ),
    });
  } catch {
    console.error("[route] Participant block list failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to load blocked students right now."
    );
  }
}

/**
 * `DELETE /api/participant/blocks/:blockId` — removes one block the caller
 * owns. A row owned by someone else and a row that does not exist are the same
 * answer, so the route is no oracle for another participant's blocks.
 */
export async function deleteParticipantBlock(
  req: Request,
  res: Response
): Promise<Response> {
  const blockId = String(req.params.blockId);
  if (!mongoose.Types.ObjectId.isValid(blockId)) {
    return sendDay4Error(
      res,
      404,
      BLOCK_NOT_FOUND_CODE,
      BLOCK_NOT_FOUND_MESSAGE
    );
  }

  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  let session: mongoose.ClientSession | undefined;
  try {
    session = await mongoose.startSession();
    let removed = false;
    await session.withTransaction(async () => {
      const callerId = new mongoose.Types.ObjectId(
        authority.participant.participantId
      );
      await touchParticipantAccountsInSession(
        [callerId],
        session!,
        new Map([
          [
            authority.participant.participantId,
            authority.participant.authorityVersion,
          ],
        ])
      );
      const row = await ParticipantBlock.findOneAndDelete({
        _id: blockId,
        blockerParticipantId: callerId,
      })
        .select("_id")
        .session(session!)
        .lean()
        .exec();
      removed = Boolean(row);
    });

    if (!removed) {
      return sendDay4Error(
        res,
        404,
        BLOCK_NOT_FOUND_CODE,
        BLOCK_NOT_FOUND_MESSAGE
      );
    }
    return res.json({ removed: true });
  } catch (error) {
    if (
      error instanceof ParticipantIdentityConfigurationError ||
      error instanceof ParticipantAccountFenceUnavailable
    ) {
      return sendDay4Error(
        res,
        503,
        "PARTICIPANT_VERIFICATION_UNAVAILABLE",
        "We couldn’t check your NYU verification right now. Please try again in a moment."
      );
    }
    console.error("[route] Participant unblock mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to unblock this student right now."
    );
  } finally {
    if (session) await session.endSession();
  }
}
