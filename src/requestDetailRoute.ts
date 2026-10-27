import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
} from "./participantAuthorityGate.js";
import { isParticipantPairFenced } from "./participantBlocks.js";
import { ParticipantIdentityConfigurationError } from "./participantIdentityKeys.js";
import {
  findParticipatedRequestIds,
  requireVerifiedCallerForRead,
} from "./requestParticipation.js";
import {
  carriesModerationHold,
  isVisibleNow,
  REQUEST_NOT_YET_AVAILABLE_CODE,
  REQUEST_NOT_YET_AVAILABLE_MESSAGE,
} from "./requestAvailability.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";

export async function getPublicRequestDetail(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<Response | void> {
  try {
    // W4-R5 verified-only gate, ahead of id validation, every database lookup,
    // the pair fence, and the visibility check, so an unauthorized caller's
    // answer is identical whether or not the id exists, is fenced, or is not
    // yet visible. The gate also sets `Cache-Control: private, no-store` and
    // `Vary` on the participant-authority header before any response (W3-H2:
    // this response is caller-specific — `alreadyParticipated`, `isOwnRequest`
    // — so no cache may reuse one caller's answer for another), which covers
    // the 400/404/409 refusals and the error-delegated 500 below as well.
    //
    // The same resolution decides the participant fence, the W4-H2
    // caller-relative ownership signal, and the W3-H2 `alreadyParticipated`
    // signal, so they can never describe different callers for one read.
    const caller = await requireVerifiedCallerForRead(req, res);
    if (!caller) return;
    const { participant, ownershipContext } = caller;

    const { id } = req.params;
    if (!mongoose.Types.ObjectId.isValid(String(id))) {
      return res.status(400).json({ error: "Invalid request id" });
    }

    // One instant decides both the visibility gate below and the effective
    // status of the response, so the two cannot disagree about the same read.
    const now = new Date();

    // `+requesterParticipantId` (W4-H2): `select: false` on the schema like
    // every other private field, so deriving the caller-relative ownership
    // signal below requires selecting it explicitly — exactly as
    // `GET /api/requests` already does. It is read only through
    // `callerOwnershipFor` and never copied onto the response.
    // `+externalOrderAffirmed` (W4-U1.3) is read only so the effective status
    // below is truthful for a request that must never read as available; like
    // the two participant ids it is never copied onto the response. M and L
    // (W4-U1.2) are read to answer a held request as unavailable and are never projected.
    const document = await MealRequest.findById(id)
      .select(
        "+requesterParticipantId +helperParticipantId +externalOrderAffirmed +contentRevision +moderationUnavailable +reservationLapseHold"
      )
      .lean()
      .exec();
    if (!document) {
      return res.status(404).json({ error: "Request not found" });
    }
    // W4-U1.2: a request held by M or L is answered exactly as a request that
    // does not exist, the same generic answer as the pair fence below. It is
    // never projected as open or claimed. A placed request is exempt: a
    // moderation hold never undoes a placement.
    if (
      (document as { status?: string }).status !== "placed" &&
      carriesModerationHold(document)
    ) {
      return res.status(404).json({ error: "Request not found" });
    }

    // W4-U1.3 participant-pair fence. Possession of a request id does not
    // bypass a block: a fenced counterpart's request is answered exactly as a
    // request that does not exist, and before the not-yet-available refusal
    // below, so the two answers cannot be compared to learn anything.
    //
    // Exempt, because it is not a new interaction: the request's own
    // requester (their request, whoever their helper is) and the participant
    // holding it as helper right now — its placement, or its live unexpired
    // reservation — which a block must not strand. Expiry never clears
    // `helperParticipantId`, so a bare match is a stale last helper, not
    // continuity, and is fenced like any other counterpart.
    const requesterId = (document as { requesterParticipantId?: unknown })
      .requesterParticipantId;
    const helperId = (document as { helperParticipantId?: unknown })
      .helperParticipantId;
    const isRequester =
      Boolean(requesterId) && String(requesterId) === participant.participantId;
    const { status, claimExpiresAt } = document as {
      status?: string;
      claimExpiresAt?: Date | null;
    };
    const holdsRequestNow =
      status === "placed" ||
      (status === "claimed" &&
        Boolean(claimExpiresAt) &&
        new Date(claimExpiresAt as Date).getTime() > now.getTime());
    const isBoundHelper =
      Boolean(helperId) &&
      String(helperId) === participant.participantId &&
      holdsRequestNow;
    if (
      requesterId &&
      !isRequester &&
      !isBoundHelper &&
      (await isParticipantPairFenced(
        participant.participantId,
        String(requesterId)
      ))
    ) {
      return res.status(404).json({ error: "Request not found" });
    }

    // W4-R5: a withdrawn request is gone from ongoing work for good. Ordered
    // ahead of the not-yet-available gate, as the claim route orders them, so a
    // withdrawn request that was rescheduled first is never told to "come back
    // later". Answered contentlessly with the same code and sentence the claim
    // route uses, never with the request's content.
    if (status === "withdrawn") {
      return sendDay4Error(
        res,
        410,
        "REQUEST_WITHDRAWN",
        "This request is no longer available."
      );
    }

    // A scheduled request withheld from the list must also be withheld here.
    // Otherwise this route is the hole in the W3-R1 visibility rule: knowing
    // an id — from a shared link, an enumeration attempt, or a notification
    // that should not have been sent yet — would return the vendor, the food,
    // the pickup window, and a status of `open`, hours before helpers are
    // meant to see any of it.
    //
    // The refusal carries no request content of any kind: only the shared
    // not-yet-available code and sentence, which are the same ones the claim
    // route answers with. It is deliberately distinct from the 404 below,
    // which keeps meaning exactly one thing — no such request — so a client
    // can tell "come back later" apart from "this is gone" without either
    // answer describing the request itself.
    //
    // Legacy rows carry no `visibleFrom`, and `isVisibleNow` reads that
    // absence as "visible from creation", so nothing persisted before this
    // field existed becomes unreachable.
    if (!isVisibleNow((document as { visibleFrom?: Date }).visibleFrom, now)) {
      return sendDay4Error(
        res,
        409,
        REQUEST_NOT_YET_AVAILABLE_CODE,
        REQUEST_NOT_YET_AVAILABLE_MESSAGE
      );
    }

    // W4-R5 notification-tap currency: a request that is still stored open (or
    // whose reservation lapsed) but whose availability window has ended is
    // *expired*, and the one read a tap relies on must say so rather than read
    // back as `open` and send the helper to a screen whose claim can only fail.
    // Answered with the same code and sentence the claim route uses, so one
    // situation has one answer. A live reservation, a placement and a
    // withdrawal keep the answers they already had.
    const expiresAtValue = (document as { expiresAt?: Date | null }).expiresAt;
    const holdsLiveReservation =
      status === "claimed" &&
      Boolean(claimExpiresAt) &&
      new Date(claimExpiresAt as Date).getTime() > now.getTime();
    if (
      (status === "open" || status === "claimed") &&
      !holdsLiveReservation &&
      expiresAtValue != null &&
      new Date(expiresAtValue).getTime() <= now.getTime()
    ) {
      return sendDay4Error(
        res,
        410,
        "REQUEST_EXPIRED",
        "This request is no longer available."
      );
    }

    const response = buildPublicRequestDetailResponse(
      document as unknown as PublicRequestDocument,
      now,
      ownershipContext,
      // W4-R5: the detail read alone states the current content revision, so a
      // tapped notification can say truthfully that the request changed since.
      { includeContentRevision: true }
    );

    // W3-H2 stale detail Reserve truth: this is the same durable participation
    // truth `/api/requests` already filters its own list by
    // (`findParticipatedRequestIds`) — a stale detail screen reached through
    // direct navigation, a deep link, or a not-yet-refreshed list can be told
    // this participant already successfully held this exact request, so it can
    // withdraw the Reserve affordance instead of only discovering the refusal
    // after a tap. `claimRequest`'s own conditional grant remains the
    // authoritative backstop regardless of this flag.
    const participatedIds = await findParticipatedRequestIds(
      participant.participantId,
      participant.principal,
      [document._id]
    );
    if (participatedIds.has(String(document._id))) {
      return res.json({ ...response, alreadyParticipated: true });
    }

    return res.json(response);
  } catch (err) {
    if (err instanceof ParticipantIdentityConfigurationError) {
      return sendDay4Error(
        res,
        503,
        PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
        PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
      );
    }
    next(err);
  }
}
