import mongoose, { type ClientSession, type Types } from "mongoose";
import {
  Fulfillment,
  Participant,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import {
  deriveParticipantIdentityAliases,
  loadParticipantIdentityManifest,
} from "./participantIdentityKeys.js";
import {
  demoteParticipantDeletionReadiness,
  readParticipantDeletionStatus,
  type DeletionOwner,
  type ParticipantDeletionDependencies,
} from "./participantDeletionOperations.js";

export type DeletionHelperObservation = "clear" | "helperOrPickup" | "unknown";

export type DeletionHelperReconciliation =
  | { outcome: "notOwned" | "stale" | "inactive" }
  | { outcome: "observed"; helper: DeletionHelperObservation };

function deadline(value: unknown): number {
  return value instanceof Date ? value.getTime() : Number.NaN;
}

function readParticipant(owner: DeletionOwner) {
  return Participant.findOne({
    _id: owner.participantId,
    authorityVersion: owner.authorityVersion,
  }).select("email +activeReservationRequestId +activeReservationClaimExpiresAt +blockFenceEpoch")
    .read("primary").lean().exec();
}

export interface HelperLockSnapshot {
  activeReservationRequestId?: Types.ObjectId | string | null;
  activeReservationClaimExpiresAt?: Date | null;
}

/**
 * The pure helper-side scan against one already-read lock snapshot, with no
 * readiness-document read, no re-read-for-change check and no demotion side
 * effect. Shared by the dormant standalone reconciler below (no session, its
 * own extra re-read to detect a race across two round trips) and by final
 * completion's in-transaction recheck (an explicit session, one consistent
 * snapshot, so the re-read-for-change check is unnecessary and is the
 * caller's concern, not this function's).
 */
export async function classifyDeletionHelperObservation(
  participantId: string | Types.ObjectId,
  principal: string,
  lock: HelperLockSnapshot,
  now: number,
  session?: ClientSession
): Promise<DeletionHelperObservation> {
  if (!Number.isFinite(now)) throw new Error("participant deletion requires a valid backend time");
  let helper: DeletionHelperObservation = "clear";
  const lockId = lock.activeReservationRequestId;
  const lockDeadline = lock.activeReservationClaimExpiresAt;
  let lockRequestSeen = lockId == null;
  const liveRequestIds = new Set<string>();
  if (lockId != null) {
    const expiration = deadline(lockDeadline);
    helper = !Number.isFinite(expiration) ? "unknown"
      : expiration > now ? "helperOrPickup" : "clear";
  } else if (lockDeadline != null) {
    helper = "unknown";
  }

  const query = MealRequest.find({ helperParticipantId: participantId })
    .select("status claimExpiresAt +requesterPickupConfirmedAt +externalOrderAffirmed")
    .read("primary")
    .lean();
  if (session) query.session(session);
  const requests = query.cursor();
  for await (const request of requests) {
    liveRequestIds.add(String(request._id));
    if (String(request._id) === String(lockId)) lockRequestSeen = true;
    if (request.externalOrderAffirmed === true) {
      helper = "helperOrPickup";
    } else if (request.status === "placed") {
      const confirmedAt: unknown = request.requesterPickupConfirmedAt;
      if (confirmedAt instanceof Date && !Number.isNaN(confirmedAt.getTime())) {
        continue;
      }
      if (confirmedAt != null && helper !== "helperOrPickup") {
        helper = "unknown";
      } else {
        helper = "helperOrPickup";
      }
    } else if (request.externalOrderAffirmed != null &&
        request.externalOrderAffirmed !== false) {
      if (helper !== "helperOrPickup") helper = "unknown";
    } else if (request.status === "claimed") {
      const expiration = deadline(request.claimExpiresAt);
      if (!Number.isFinite(expiration)) {
        if (helper !== "helperOrPickup") helper = "unknown";
      } else if (expiration > now) {
        helper = "helperOrPickup";
      }
    } else if (helper !== "helperOrPickup") {
      // Ordinary release removes helperParticipantId, not just the status.
      helper = "unknown";
    }
  }

  const participationQuery = RequestParticipation.find({ participantId })
    .select("+requestId")
    .read("primary")
    .lean();
  if (session) participationQuery.session(session);
  const participationRows = await participationQuery.exec();
  const priorRequestIds = [
    ...new Set(
      participationRows
        .map((row) => String(row.requestId))
        .filter((requestId) => !liveRequestIds.has(requestId))
    ),
  ];
  let missingRequestIds = priorRequestIds;
  if (priorRequestIds.length > 0) {
    const existingRequestsQuery = MealRequest.find({
      _id: {
        $in: priorRequestIds.map(
          (requestId) => new mongoose.Types.ObjectId(requestId)
        ),
      },
    })
      .select("_id")
      .read("primary")
      .lean();
    if (session) existingRequestsQuery.session(session);
    const existingRequests = await existingRequestsQuery.exec();
    const existingRequestIds = new Set(
      existingRequests.map((request) => String(request._id))
    );
    missingRequestIds = priorRequestIds.filter(
      (requestId) => !existingRequestIds.has(requestId)
    );
  }
  if (missingRequestIds.length > 0) {
    const identity = await loadParticipantIdentityManifest(
      "participation",
      session
    );
    const fulfillmentQuery = Fulfillment.find({
      requestId: {
        $in: missingRequestIds.map(
          (requestId) => new mongoose.Types.ObjectId(requestId)
        ),
      },
    })
      .select(
        "+helperParticipationKeyVersion +helperParticipationHmac +requesterPickupConfirmedAt"
      )
      .read("primary")
      .lean();
    if (session) fulfillmentQuery.session(session);
    const fulfillmentRows = await fulfillmentQuery.exec();
    const fulfillmentsByRequestId = new Map(
      fulfillmentRows.map((row) => [String(row.requestId), row])
    );
    for (const requestId of missingRequestIds) {
      const fulfillment = fulfillmentsByRequestId.get(requestId);
      if (!fulfillment) {
        if (helper !== "helperOrPickup") helper = "unknown";
        continue;
      }
      const version = fulfillment.helperParticipationKeyVersion;
      const digest = fulfillment.helperParticipationHmac;
      if (
        !Number.isSafeInteger(version) ||
        !identity.entries.some((entry) => entry.version === version) ||
        typeof digest !== "string" ||
        !/^[0-9a-f]{64}$/.test(digest)
      ) {
        if (helper !== "helperOrPickup") helper = "unknown";
        continue;
      }
      const aliases = deriveParticipantIdentityAliases(
        "participation",
        identity.ring,
        identity.entries,
        requestId,
        principal
      );
      const belongsToParticipant = aliases.some(
        (alias) => alias.version === version && alias.digest === digest
      );
      if (!belongsToParticipant) {
        if (helper !== "helperOrPickup") helper = "unknown";
        continue;
      }
      const confirmedAt: unknown = fulfillment.requesterPickupConfirmedAt;
      if (confirmedAt instanceof Date && !Number.isNaN(confirmedAt.getTime())) {
        continue;
      }
      if (confirmedAt == null) {
        helper = "helperOrPickup";
      } else if (helper !== "helperOrPickup") {
        helper = "unknown";
      }
    }
  }
  if (!lockRequestSeen && helper !== "helperOrPickup") helper = "unknown";
  return helper;
}

/**
 * Dormant H1a blocker input, never a readiness grant. Reads current helper
 * binding, not the bounded continuation HTTP response or client recovery/UI.
 * Release removes that binding; passive expiry requires its persisted BSON
 * deadline. Placement and post-Yes risk stay blocked pending other P2 gates.
 * No H1a mutation, recovery resend, evidence or ledger write is performed.
 */
export async function reconcileParticipantDeletionHelperRequests(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  dependencies: Partial<ParticipantDeletionDependencies>
): Promise<DeletionHelperReconciliation> {
  if (!Number.isInteger(expectedReadinessGeneration) || expectedReadinessGeneration < 0) {
    throw new Error("participant deletion requires a non-negative readiness generation");
  }
  const participant = await readParticipant(owner);
  if (!participant ||
      normalizeParticipantPrincipal(participant.email) !== owner.canonicalEmail) {
    return { outcome: "notOwned" };
  }
  const initial = await readParticipantDeletionStatus(owner, dependencies);
  if (!initial) return { outcome: "notOwned" };
  if (initial.readinessGeneration !== expectedReadinessGeneration) return { outcome: "stale" };
  if (initial.phase === "canceled" || initial.phase === "completed") return { outcome: "inactive" };

  const now = (dependencies.now?.() ?? new Date()).getTime();
  const lockId = participant.activeReservationRequestId;
  const lockDeadline = participant.activeReservationClaimExpiresAt;
  let helper = await classifyDeletionHelperObservation(
    owner.participantId,
    owner.canonicalEmail,
    { activeReservationRequestId: lockId, activeReservationClaimExpiresAt: lockDeadline },
    now
  );

  // Claim, release, extension and placement change the lock; a post-Yes Block
  // changes the pair-fence epoch. A changed observation is not terminal proof.
  const observed = await readParticipant(owner);
  if (!observed ||
      normalizeParticipantPrincipal(observed.email) !== owner.canonicalEmail) {
    return { outcome: "notOwned" };
  }
  if (String(observed.activeReservationRequestId) !== String(lockId) ||
      !Object.is(deadline(observed.activeReservationClaimExpiresAt), deadline(lockDeadline)) ||
      observed.blockFenceEpoch !== participant.blockFenceEpoch) {
    if (helper !== "helperOrPickup") helper = "unknown";
  }
  if (helper !== "clear") {
    await demoteParticipantDeletionReadiness(owner, expectedReadinessGeneration, dependencies);
  }
  const current = await readParticipantDeletionStatus(owner, dependencies);
  if (!current) return { outcome: "notOwned" };
  if (current.readinessGeneration !== expectedReadinessGeneration) return { outcome: "stale" };
  if (current.phase === "canceled" || current.phase === "completed") return { outcome: "inactive" };
  return { outcome: "observed", helper };
}
