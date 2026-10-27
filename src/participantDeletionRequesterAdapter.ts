import type { ClientSession, Types } from "mongoose";
import { Participant, Request as MealRequest } from "../models/db.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import {
  demoteParticipantDeletionReadiness,
  readParticipantDeletionStatus,
  type DeletionOwner,
  type ParticipantDeletionDependencies,
} from "./participantDeletionOperations.js";
import { deriveOwnerPhase, terminalOwnerOutcome } from "./requestOwnerReadRoute.js";

export type DeletionRequesterObservation =
  | "clear"
  | "withdrawalRequired"
  | "helperOrPickup"
  | "unknown";

export type DeletionRequesterReconciliation =
  | { outcome: "notOwned" | "stale" | "inactive" }
  | { outcome: "observed"; requester: DeletionRequesterObservation };

/**
 * The pure requester-side scan, with no readiness-document read or demotion
 * side effect. Shared by the dormant standalone reconciler below (no session,
 * its own two round trips) and by final completion's in-transaction recheck
 * (an explicit session, one consistent snapshot, no second read needed).
 */
export async function classifyDeletionRequesterObservation(
  participantId: string | Types.ObjectId,
  now: Date,
  session?: ClientSession
): Promise<DeletionRequesterObservation> {
  // Do not use R5's bounded ongoing-owner HTTP list: it intentionally omits
  // retained terminal rows and placed work, and caps the list at 25.
  const query = MealRequest.find({ requesterParticipantId: participantId })
    .select("status expiresAt visibleFrom claimExpiresAt " +
      "+externalOrderAffirmed +requesterPickupConfirmedAt")
    .lean();
  if (session) query.session(session);
  const requests = query.cursor();
  let requester: DeletionRequesterObservation = "clear";
  for await (const request of requests) {
    if (request.status === "withdrawn") continue;
    if (request.externalOrderAffirmed === true) {
      requester = "helperOrPickup";
      continue;
    }
    if (request.status === "placed") {
      const confirmedAt: unknown = request.requesterPickupConfirmedAt;
      if (confirmedAt == null) {
        // R3: placed and not yet requester-confirmed. Still a blocker; P2
        // never auto-confirms, withdraws or infers pickup on the owner's
        // behalf.
        requester = "helperOrPickup";
        continue;
      }
      if (confirmedAt instanceof Date && !Number.isNaN(confirmedAt.getTime())) {
        // R3's authoritative terminal fact clears this placed order's
        // contribution. Retention/visibility treatment is unaffected and is
        // not this adapter's concern.
        continue;
      }
      // Malformed R3 truth (wrong type, invalid Date) fails closed: never
      // read as either a clear placed order or a provable blocker shape.
      if (requester !== "helperOrPickup") requester = "unknown";
      continue;
    }
    if (request.status === "claimed") {
      const deadline: unknown = request.claimExpiresAt;
      const claimExpiration = deadline instanceof Date ? deadline.getTime()
        : typeof deadline === "string" ? new Date(deadline).getTime() : Number.NaN;
      // Request expiry alone cannot prove that an incompletely recorded claim lapsed.
      if (!Number.isFinite(claimExpiration)) {
        if (requester !== "helperOrPickup") requester = "unknown";
        continue;
      }
      if (claimExpiration > now.getTime()) {
        requester = "helperOrPickup";
        continue;
      }
    }
    const phase = deriveOwnerPhase(request, now);
    if (phase === "reserved") {
      requester = "helperOrPickup";
    } else if (phase !== null) {
      if (requester === "clear") requester = "withdrawalRequired";
    } else {
      const expiration = request.expiresAt?.getTime();
      // The R5 terminal classifier assumes its caller already checked expiry.
      // Missing/malformed lifecycle truth must not become a clear answer.
      if (expiration === undefined || !Number.isFinite(expiration) ||
          expiration > now.getTime() ||
          terminalOwnerOutcome(request)?.code !== "REQUEST_EXPIRED") {
        if (requester !== "helperOrPickup") requester = "unknown";
      }
    }
  }
  return requester;
}

/**
 * Dormant, internal R5/R3 input to P2, not a complete blocker evaluator or a
 * readiness grant. The caller must supply its authenticated deletion owner,
 * never body/query ownership. Only a blocker can change P2 here (demotion);
 * clearing this input cannot promote, challenge, authorize or delete.
 *
 * R5 withdrawal is an explicit participant action. Reconciliation only reads
 * its committed truth, including after an ambiguous response, and never
 * replays a mutation or derives request identity from editable content.
 *
 * R3's `requesterPickupConfirmedAt` is the only accepted terminal fact for a
 * placed order: it never infers pickup from visibility cutoffs, TTL sweep,
 * missing rows or notification state. A confirmed placed order clears only
 * that request's contribution to the requester observation; it never
 * authorizes retained-data treatment (Request/Fulfillment/PlacementEvidence
 * stay exactly as R3 left them) and never touches the helper adapter's own
 * observation of the same request.
 */
export async function reconcileParticipantDeletionRequesterRequests(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  dependencies: Partial<ParticipantDeletionDependencies>
): Promise<DeletionRequesterReconciliation> {
  if (!Number.isInteger(expectedReadinessGeneration) || expectedReadinessGeneration < 0) {
    throw new Error("participant deletion requires a non-negative readiness generation");
  }
  const participant = await Participant.findOne({
    _id: owner.participantId,
    authorityVersion: owner.authorityVersion,
  }).select("email").lean().exec();
  if (!participant ||
      normalizeParticipantPrincipal(participant.email) !== owner.canonicalEmail) {
    return { outcome: "notOwned" };
  }
  const initial = await readParticipantDeletionStatus(owner, dependencies);
  if (!initial) return { outcome: "notOwned" };
  if (initial.readinessGeneration !== expectedReadinessGeneration) {
    return { outcome: "stale" };
  }
  if (initial.phase === "canceled" || initial.phase === "completed") {
    return { outcome: "inactive" };
  }

  const now = dependencies.now?.() ?? new Date();
  const requester = await classifyDeletionRequesterObservation(
    owner.participantId,
    now
  );
  if (requester !== "clear") {
    await demoteParticipantDeletionReadiness(
      owner, expectedReadinessGeneration, dependencies
    );
  }
  const current = await readParticipantDeletionStatus(owner, dependencies);
  if (!current) return { outcome: "notOwned" };
  if (current.readinessGeneration !== expectedReadinessGeneration) {
    return { outcome: "stale" };
  }
  if (current.phase === "canceled" || current.phase === "completed") {
    return { outcome: "inactive" };
  }
  return { outcome: "observed", requester };
}
