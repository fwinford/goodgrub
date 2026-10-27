import { type ClientSession, Types } from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import type { MessagingPolicy } from "./messaging.js";

// "pending" covers every non-final account-deletion phase and never denies by
// itself. "final" means deletion completed. The owning P2 slice supplies the
// real mapping; any other value, or an unavailable adapter, denies/throws.
export type DeletionAccess = "none" | "pending" | "final";
export type DeletionAccessPort = (
  participantId: Types.ObjectId,
  session: ClientSession
) => Promise<DeletionAccess>;

// U1.2's isEitherParticipantSuspended(a, b, session) is supplied by the
// composition root: the moderation foundation may only be imported by its
// authorized paths, so this module takes it as a required port.
export type SuspensionPort = (
  requester: Types.ObjectId,
  helper: Types.ObjectId,
  session: ClientSession
) => Promise<boolean>;

interface PolicyRequest {
  status: string;
  expiresAt?: Date | null;
  claimExpiresAt?: Date | null;
  deleteAt?: Date | null;
  requesterParticipantId?: Types.ObjectId | null;
  helperParticipantId?: Types.ObjectId | null;
  requesterPickupConfirmedAt?: Date | null;
  moderationUnavailable?: boolean | null;
}

// Every fact is re-read inside the caller's transaction. The deletion port is
// required: there is deliberately no policy without an explicit P2 decision.
export function createMessagingPolicy(
  deletionAccess: DeletionAccessPort,
  eitherSuspended: SuspensionPort
): MessagingPolicy {
  return {
    async authorize(request, session, now) {
      if (MealRequest.schema.path("requesterPickupConfirmedAt") === undefined) return false;
      const fresh = await MealRequest.findById(request._id)
        .select(
          "status expiresAt claimExpiresAt deleteAt +requesterParticipantId +helperParticipantId " +
          "+requesterPickupConfirmedAt +moderationUnavailable"
        )
        .session(session).lean<PolicyRequest>().exec();
      const requester = fresh?.requesterParticipantId;
      const helper = fresh?.helperParticipantId;
      if (!fresh || !requester || !helper || requester.equals(helper) ||
        !request.requesterParticipantId?.equals(requester) ||
        !request.helperParticipantId?.equals(helper)) return false;
      if (fresh.requesterPickupConfirmedAt || fresh.moderationUnavailable === true) return false;
      const live = fresh.status === "placed"
        ? Boolean(fresh.deleteAt && fresh.deleteAt > now)
        : fresh.status === "claimed" &&
          Boolean(fresh.expiresAt && fresh.expiresAt > now) &&
          Boolean(fresh.claimExpiresAt && fresh.claimExpiresAt > now);
      if (!live) return false;
      if (await eitherSuspended(requester, helper, session)) return false;
      for (const id of [requester, helper]) {
        const state = await deletionAccess(id, session);
        if (state !== "none" && state !== "pending") return false;
      }
      return true;
    },
  };
}
