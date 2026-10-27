import mongoose, { Types } from "mongoose";
import type { Express, Request, Response } from "express";
import { Participant, Request as MealRequest } from "../models/db.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { isParticipantPairFenced } from "./participantBlocks.js";
import {
  contactIsDisabledByModeration,
  placedOrderCacheIsolation,
  placedOrderReadRateLimiter,
} from "./placedOrderRoutes.js";

export const HELPER_RESERVATION_CONTACT_ROUTE_PATH =
  "/api/participant/active-reservation/:requestId/contact";
export const RESERVATION_CONTACT_NOT_FOUND_CODE = "RESERVATION_CONTACT_NOT_FOUND";
export const RESERVATION_CONTACT_NOT_FOUND_MESSAGE =
  "Contact isn't available for this request.";

function sendContactNotFound(res: Response): Response {
  return sendDay4Error(
    res,
    404,
    RESERVATION_CONTACT_NOT_FOUND_CODE,
    RESERVATION_CONTACT_NOT_FOUND_MESSAGE
  );
}

/**
 * `GET /api/participant/active-reservation/:requestId/contact` — the
 * requester's address, to the helper holding the live reservation only, so
 * they can ask a question before placing the order (Faith, W4-N1 walkthrough).
 * Every refusal is the same 404 so it reveals nothing about the request, the
 * pair, or either participant.
 */
export async function getHelperReservationContact(
  req: Request,
  res: Response
): Promise<Response> {
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const requestId = String(req.params.requestId ?? "");
  if (!mongoose.isValidObjectId(requestId)) {
    return sendContactNotFound(res);
  }

  try {
    const helperId = new Types.ObjectId(authority.participant.participantId);
    const document = (await MealRequest.findOne({
      _id: requestId,
      helperParticipantId: helperId,
      status: "claimed",
      claimExpiresAt: { $gt: new Date() },
      moderationUnavailable: { $ne: true },
    })
      .select("+requesterParticipantId")
      .lean()
      .exec()) as unknown as {
      requesterParticipantId?: Types.ObjectId | null;
    } | null;
    const requesterId = document?.requesterParticipantId;
    if (!requesterId || requesterId.equals(helperId)) {
      return sendContactNotFound(res);
    }

    const [pairFenced, suspended, requester] = await Promise.all([
      isParticipantPairFenced(requesterId, helperId),
      contactIsDisabledByModeration(requesterId, helperId),
      Participant.findById(requesterId).select("email").lean().exec(),
    ]);
    const email = (requester as { email?: string } | null)?.email;
    if (pairFenced || suspended || !email) {
      return sendContactNotFound(res);
    }
    return res.json({ contactRequesterEmail: email });
  } catch {
    console.error("[route] Helper reservation contact lookup failed");
    return sendContactNotFound(res);
  }
}

export function registerHelperReservationContactRoute(app: Express): void {
  app.get(
    HELPER_RESERVATION_CONTACT_ROUTE_PATH,
    placedOrderCacheIsolation,
    placedOrderReadRateLimiter,
    getHelperReservationContact
  );
}
