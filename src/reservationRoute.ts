import type { Request, Response } from "express";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import { isParticipantPairFenced } from "./participantBlocks.js";
import { isEitherParticipantSuspended } from "./moderationEnforcement.js";
import {
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import {
  placedHomeVisibility,
  reportPlacedHomeInvariantFailure,
} from "./placedHomeVisibility.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";

export const ACTIVE_RESERVATION_ROUTE_PATH = "/api/participant/active-reservation";

// A read, not a mutation: more generous than the claim/extend/release
// buckets, and — like `GET /api/request/:id` — not gated by
// `PUBLIC_ACTIONS_PAUSED`, which exists to stop new mutations, not to hide a
// helper's own already-granted reservation from them.
export const activeReservationRateLimiter = createDay4MutationRateLimiter(30);

interface ActiveReservationDocument extends PublicRequestDocument {
  claimExpiresAt?: Date | null;
  claimExtendedAt?: Date | null;
}

/**
 * A request this participant most recently placed, still existing within its
 * `PLACED_RETENTION_MS` retention horizon (W3-H2 fulfillment re-entry).
 * `notificationStatus` mirrors the persisted lifecycle value; `"pending"` and
 * absent both mean the outcome never settled (e.g. the process ended before
 * `recordNotificationOutcome` ran) and are reported the same way `fulfillRequest`
 * already treats an unsettled outcome — as unknown, never guessed.
 */
interface PlacedParticipationDocument extends PublicRequestDocument {
  orderNumber: string;
  etaText: string;
  notificationStatus?: "pending" | "sent" | "failed";
  /**
   * W4-U1.1 content-free marker, `select: false` on the model and requested
   * explicitly below. Reported to the placing helper only, and only
   * affirmatively; never part of any public projection.
   */
  contactMessageSuppressed?: boolean;
  /** W4-U1.3 content-free refinement; see `IRequest.contactMessageWithheld`. */
  contactMessageWithheld?: boolean;
}

/**
 * W4-R3: every placed request this helper must still be shown as
 * `Waiting for pickup`, newest placement first (request ID tiebreak). Never
 * newest-only and never conditional on an active claim. A row leaves when the
 * requester has confirmed pickup, when retention has lapsed, or when backend
 * now reaches `estimatedReadyAt` + 1 hour. A row without a valid ETA violates
 * the placement invariant and fails closed with the content-free diagnostic.
 */
async function findHelperPlacements(
  participantId: mongoose.Types.ObjectId,
  now: Date
) {
  // `deleteAt` is authoritative retention, not the physical TTL sweep: Mongo's
  // TTL monitor does not delete a document the instant `deleteAt` passes, so
  // compare it with backend `now` rather than trusting the sweep.
  const documents = await MealRequest.find({
    helperParticipantId: participantId,
    status: "placed",
    requesterPickupConfirmedAt: { $exists: false },
    deleteAt: { $gt: now },
  })
    .sort({ placedAt: -1, _id: -1 })
    // Private and `select: false`: only this participant-scoped read, which is
    // already bound to the placing helper by `helperParticipantId`, may ask for
    // the W4-U1.1 suppression marker.
    .select("+contactMessageSuppressed +contactMessageWithheld")
    .lean()
    .exec();

  const placements = [];
  for (const document of documents as unknown as (PlacedParticipationDocument & {
    placedAt?: Date | string | null;
  })[]) {
    const visibility = placedHomeVisibility(document);
    if (!visibility) {
      reportPlacedHomeInvariantFailure();
      continue;
    }
    if (now.getTime() >= visibility.helperVisibleUntil.getTime()) continue;
    placements.push({
      request: buildPublicRequestDetailResponse(document, now).request,
      orderNumber: document.orderNumber,
      etaText: document.etaText,
      estimatedReadyAt: visibility.estimatedReadyAt,
      helperVisibleUntil: visibility.helperVisibleUntil,
      notification:
        document.notificationStatus === "sent" ||
        document.notificationStatus === "failed"
          ? { status: document.notificationStatus }
          : null,
      // W4-U1.1: affirmative-only, like `alreadyParticipated` and
      // `isOwnRequest`. Present and `true` only when the durable, content-free
      // marker proves the optional Message was suppressed at placement.
      ...(document.contactMessageSuppressed === true
        ? { messageSuppressed: true }
        : {}),
      // W4-U1.3: affirmative-only refinement for a Message withheld by the
      // blocked-pair restriction. Never present for a filter refusal.
      ...(document.contactMessageWithheld === true
        ? { messageWithheld: true }
        : {}),
    });
  }
  return placements;
}

/**
 * Pickup confirmations the placing helper may be told about once. A requester
 * pickup is the only thing that sets `requesterPickupConfirmedAt`, so this is
 * the authoritative "requester confirmed pickup" fact and never inferred from
 * a row disappearing. It is content-free (request identity only) and bound to
 * the placing helper, and it is offered only inside the same helper-visibility
 * window a Waiting row would have had, so it never outlives R3's cutoff.
 */
async function findHelperPickupConfirmations(
  participantId: mongoose.Types.ObjectId,
  now: Date
) {
  const documents = await MealRequest.find({
    helperParticipantId: participantId,
    status: "placed",
    requesterPickupConfirmedAt: { $exists: true },
    deleteAt: { $gt: now },
  })
    .sort({ placedAt: -1, _id: -1 })
    // `select: false` on the schema: it must be asked for explicitly.
    .select("+requesterPickupConfirmedAt")
    .lean()
    .exec();

  const confirmations: { requestId: string }[] = [];
  for (const document of documents as unknown as (PlacedParticipationDocument & {
    _id: unknown;
    requesterPickupConfirmedAt?: Date | string | null;
  })[]) {
    if (!document.requesterPickupConfirmedAt) continue;
    const visibility = placedHomeVisibility(document);
    if (!visibility) continue;
    if (now.getTime() >= visibility.helperVisibleUntil.getTime()) continue;
    confirmations.push({ requestId: String(document._id) });
  }
  return confirmations;
}

/**
 * `GET /api/participant/active-reservation` (W3-H1 continuation, extended by
 * W3-H2 fulfillment re-entry).
 *
 * Resolves "does this verified participant currently hold an active
 * reservation, and which one" directly from `Request.helperParticipantId` —
 * the same binding `claimRequest` writes and `fulfillmentRoute` already
 * reads — rather than from the Participant-side enforcement lock, which
 * exists only to make the claim transaction safe and is not itself exposed.
 * Never returns the raw claim token: it was never persisted, and continuation
 * consumes participant authority for extend/release instead. Client
 * presentation state is not authoritative; this response is what is.
 *
 * When this participant holds no active claimed reservation, the same
 * authoritative read additionally reports whether they most recently placed
 * a still-existing request (W3-H2): `Request.status === "placed"` plus this
 * `helperParticipantId` binding, retained until the existing `deleteAt`/
 * `PLACED_RETENTION_MS` TTL, is already durable proof that "this participant
 * placed this request" — `Fulfillment` carries no `participantId` and is not
 * the right anchor. This never recreates reservation authority and never
 * implies a second external order is available: it is a read of settled
 * placement truth only, so a relaunched client can restore Got It/
 * already-placed presentation instead of silently discarding it.
 */
export async function getActiveReservation(
  req: Request,
  res: Response
): Promise<Response> {
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const now = new Date();
  const participantId = new mongoose.Types.ObjectId(
    authority.participant.participantId
  );
  try {
    const document = await MealRequest.findOne({
      helperParticipantId: participantId,
      status: "claimed",
      claimExpiresAt: { $gt: now },
    })
      // Private and `select: false`: read only to answer whether direct
      // contact is restricted for this participant's own reservation, and
      // where a Stop of it ends.
      .select(
        "+requesterParticipantId +externalOrderAffirmed +reservationLapseHold"
      )
      .lean()
      .exec();

    const placements = await findHelperPlacements(participantId, now);
    const pickupConfirmations = await findHelperPickupConfirmations(
      participantId,
      now
    );

    if (document) {
      const reservation = document as unknown as ActiveReservationDocument;
      const publicResponse = buildPublicRequestDetailResponse(
        reservation,
        now
      );
      // W4-U1.3: truthful contact eligibility from authoritative state, so a
      // reconstructed reservation (after relaunch, with no in-memory record of
      // the original Block) does not regain optional direct contact. Either
      // direction produces the same affirmative-only answer — it states that
      // contact is unavailable, never who blocked whom — and the requester's
      // identity is only ever an input here, never an output.
      const requesterId = (
        document as unknown as { requesterParticipantId?: unknown }
      ).requesterParticipantId;
      // W4-U1.2 (boundary contract EO): either party being suspended reuses
      // this same channel, byte-identical to the Block case.
      const directContactRestricted = requesterId
        ? (await isParticipantPairFenced(participantId, String(requesterId))) ||
          (await isEitherParticipantSuspended(participantId, String(requesterId)))
        : false;
      // W4-U1.3 (C3): a Stop of a reservation carrying the post-Yes authority
      // ends at Home, and that must survive the helper's own Unblock and a
      // relaunch. The one consequence is reported, never the authority itself,
      // and only when no pair restriction remains: while one does, Stop already
      // ends at Home and this read stays exactly as it is with or without the
      // authority, so a helper the requester blocked learns nothing by
      // comparison. Only the helper who answered Yes can ever be bound to a
      // request carrying it (it is never claimable again), so this tells that
      // helper only what they did themselves. Affirmative-only.
      const stopReturnsHome =
        !directContactRestricted &&
        (document as unknown as { externalOrderAffirmed?: unknown })
          .externalOrderAffirmed === true;
      // W4-U1.2 FD-1 Option B: affirmative-only; present exactly when this
      // live reservation carries L and not E, so the client asks the existing
      // order question only on backend truth. L itself is never exposed.
      const lapseHold = document as unknown as {
        reservationLapseHold?: unknown;
        externalOrderAffirmed?: unknown;
      };
      const stopAsksOrderQuestion =
        lapseHold.reservationLapseHold === true &&
        lapseHold.externalOrderAffirmed !== true;
      return res.json({
        reservation: {
          request: publicResponse.request,
          claimExpiresAt: reservation.claimExpiresAt,
          claimExtendedAt: reservation.claimExtendedAt ?? null,
          ...(directContactRestricted ? { directContactRestricted: true } : {}),
          ...(stopReturnsHome ? { stopReturnsHome: true } : {}),
          ...(stopAsksOrderQuestion ? { stopAsksOrderQuestion: true } : {}),
        },
        placement: null,
        placements,
        pickupConfirmations,
        serverNow: now,
      });
    }

    // `placement` stays the single newest visible placement for older clients;
    // `placements` is the complete set this build renders.
    return res.json({
      reservation: null,
      placement: placements[0] ?? null,
      placements,
      pickupConfirmations,
      serverNow: now,
    });
  } catch {
    console.error("[route] Active reservation lookup failed");
    return sendDay4Error(
      res,
      503,
      PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
      PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
    );
  }
}
