import {
  Fulfillment,
  Installation,
  Participant,
  ParticipantDeletionOperation,
  ParticipantVerification,
  PlacementEvidence,
  Request as MealRequest,
  SendLog,
  Subscriber,
} from "../models/db.js";
import {
  deps,
  demoteParticipantDeletionReadiness,
  ownerFilter,
  readSecureOperation,
  withDeletionOwnerFence,
  type DeletionOwner,
  type ParticipantDeletionDependencies,
} from "./participantDeletionOperations.js";
import { ParticipantAccountFenceUnavailable } from "./participantAccountFence.js";
import { evaluateParticipantDeletionReadiness } from "./participantDeletionReadinessEvaluator.js";
import { classifyDeletionRequesterObservation } from "./participantDeletionRequesterAdapter.js";
import { classifyDeletionHelperObservation } from "./participantDeletionHelperAdapter.js";
import {
  tombstoneCanceledParticipantDeletionOperations,
  tombstoneParticipantOperationLedgers,
  unlinkParticipantFromRequestParticipation,
} from "./participantDeletionLedgers.js";
import { transformParticipantBlocksForDeletion } from "./participantBlockSafety.js";
import {
  participantDeletionCompletionReceiptPipeline,
  verifyDeletionRecoveryCapability,
} from "./participantDeletionRecovery.js";
import { confirmSafetyIdentity } from "./safetyIdentity.js";
import { tryReadSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";
import { isDeletionNamespaceBinding } from "./participantDeletionNamespace.js";

export type CompleteParticipantDeletionOutcome =
  | "completed"
  | "notOwned"
  | "stale"
  | "notAuthorized"
  | "expired"
  | "invalidCapability"
  | "blocked"
  | "safetyIdentityUnavailable";

class CompletionAborted extends Error {
  constructor(readonly outcome: Exclude<CompleteParticipantDeletionOutcome, "completed">) {
    super(`participant deletion completion aborted: ${outcome}`);
  }
}

/**
 * The final, irreversible P2 deletion transaction (Checkpoint 8).
 *
 * Two layers of recheck, matching the accepted design (P2 slice, section G):
 * an outside-the-transaction pre-check through the already-accepted
 * whole-operation evaluator (the same composition Checkpoint 7 proved), and a
 * fresh in-transaction recheck of the same requester/helper predicates using
 * this call's own session, so a blocker that commits in the gap between the
 * pre-check and this transaction's snapshot is still caught before anything
 * irreversible writes. A blocked in-transaction recheck aborts with no
 * partial effect, then demotes the operation through the existing accepted
 * primitive so the newly discovered blocker is reflected in persisted state.
 *
 * Retained-state transformations reuse the already-accepted, already-dormant
 * Checkpoint 5/7 primitives (`transformParticipantBlocksForDeletion`,
 * `unlinkParticipantFromRequestParticipation`,
 * `tombstoneParticipantOperationLedgers`) rather than re-deriving them.
 *
 * Installation association is private recipient metadata, not participant
 * authority. The accepted N1 contract supplies the identity/version fields;
 * P2's narrow shared-schema handoff also establishes them from resolved
 * Participant authority. This transaction unlinks rows bound to the deleting
 * Participant. Request/Fulfillment/PlacementEvidence follow the final P2
 * deletion treatment recorded in the owning slice contract.
 */
export interface CompleteParticipantDeletionTestHooks {
  /**
   * Test-only. Awaited after the pre-check (layer 1) succeeds and before the
   * final transaction opens (layer 2), so a test can deterministically commit
   * a new blocker into the exact gap the two-layer design exists to close,
   * proving layer 2 catches what layer 1's earlier read could not have seen.
   * Never passed by any production caller.
   */
  afterPreCheck?: () => Promise<void>;
  /**
   * Test-only. Awaited inside the final transaction immediately before the
   * Installation unlink so a real competing association write can exercise
   * transaction conflict/retry behavior.
   */
  beforeInstallationUnlink?: () => Promise<void>;
}

export async function completeParticipantDeletionOperation(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  presentedCapability: unknown,
  overrides: Partial<ParticipantDeletionDependencies> = {},
  testHooks: CompleteParticipantDeletionTestHooks = {}
): Promise<CompleteParticipantDeletionOutcome> {
  if (!Number.isInteger(expectedReadinessGeneration) || expectedReadinessGeneration < 0) {
    throw new Error("participant deletion requires a non-negative readiness generation");
  }
  if (!isDeletionNamespaceBinding(owner.namespaceBinding)) {
    return "notOwned";
  }

  // Layer 1: the same accepted evaluator Checkpoint 7 already proved. It
  // demotes internally the moment it observes its own blocker, so a refusal
  // here already left the operation in a correctly reflected state. A
  // concurrent duplicate completion call can win first and delete the
  // Participant between this call's authentication and this read, which
  // surfaces here as the same fence-unavailable condition the transaction
  // below also maps to "notOwned".
  let preCheck;
  try {
    preCheck = await evaluateParticipantDeletionReadiness(
      owner,
      expectedReadinessGeneration,
      overrides
    );
  } catch (error) {
    if (error instanceof ParticipantAccountFenceUnavailable) return "notOwned";
    throw error;
  }
  if (preCheck.outcome === "notOwned") return "notOwned";
  if (preCheck.outcome === "stale") return "stale";
  if (preCheck.outcome === "inactive") return "notAuthorized";
  if (preCheck.outcome === "waiting") return "blocked";

  await testHooks.afterPreCheck?.();

  const d = deps(overrides);

  try {
    await withDeletionOwnerFence(owner, d, async (session, secret) => {
      const now = d.now();
      const filter = ownerFilter(owner, secret);
      const row = await readSecureOperation(filter, session);
      if (row && (!isDeletionNamespaceBinding(row.namespaceBinding) ||
          row.namespaceBinding !== owner.namespaceBinding)) {
        throw new CompletionAborted("notOwned");
      }
      if (!row || row.readinessGeneration !== expectedReadinessGeneration) {
        throw new CompletionAborted("stale");
      }
      if (row.phase !== "authorized") {
        throw new CompletionAborted("notAuthorized");
      }
      if (!row.authorizationExpiresAt || row.authorizationExpiresAt <= now) {
        throw new CompletionAborted("expired");
      }
      if (!verifyDeletionRecoveryCapability(presentedCapability, row.recoveryCapabilityDigest)) {
        throw new CompletionAborted("invalidCapability");
      }

      // Layer 2: the fresh in-transaction recheck. Reads inside this
      // transaction's own snapshot, so no second read-for-change check is
      // needed the way the standalone dormant adapters need one across two
      // unrelated round trips.
      const participantId = owner.participantId;
      const participantRow = await Participant.findOne({
        _id: participantId,
        authorityVersion: owner.authorityVersion,
      })
        .select(
          "+activeReservationRequestId +activeReservationClaimExpiresAt +safetyIdentityRef"
        )
        .session(session)
        .lean<{
          activeReservationRequestId?: unknown;
          activeReservationClaimExpiresAt?: Date | null;
          safetyIdentityRef?: unknown;
        }>()
        .exec();
      if (!participantRow) throw new CompletionAborted("stale");

      const [requesterObservation, helperObservation] = await Promise.all([
        classifyDeletionRequesterObservation(participantId, now, session),
        classifyDeletionHelperObservation(
          participantId,
          owner.canonicalEmail,
          {
            activeReservationRequestId:
              participantRow.activeReservationRequestId as never,
            activeReservationClaimExpiresAt:
              participantRow.activeReservationClaimExpiresAt ?? null,
          },
          now.getTime(),
          session
        ),
      ]);
      if (requesterObservation !== "clear" || helperObservation !== "clear") {
        throw new CompletionAborted("blocked");
      }

      // P2 fixed mechanism item 5 (U1.2's confirm-only seam). Only the
      // ordinary Participant's own reference is read; no other moderation
      // state is consulted and nothing is returned to this transaction's
      // caller beyond ok/not-ok.
      if (participantRow.safetyIdentityRef) {
        const keyring = tryReadSafetyIdentityKeyring();
        const usable = await confirmSafetyIdentity(
          participantRow.safetyIdentityRef as never,
          keyring,
          session
        );
        if (!usable) throw new CompletionAborted("safetyIdentityUnavailable");
      }

      // Retained-state transformations (dormant Checkpoint 5/7 primitives).
      await transformParticipantBlocksForDeletion(
        participantId,
        owner.authorityVersion,
        session
      );
      await unlinkParticipantFromRequestParticipation(participantId, session);
      await tombstoneParticipantOperationLedgers(participantId, session);
      await tombstoneCanceledParticipantDeletionOperations(participantId, session);

      // Invalidate the live challenge, unconditionally, for this exact
      // canonical email (accepted design, section C).
      await ParticipantVerification.deleteOne(
        { email: owner.canonicalEmail },
        { session }
      ).exec();

      await testHooks.beforeInstallationUnlink?.();

      // Remove only this Participant's private Installation association.
      // Push preference, token and installation identity belong to the device
      // and are deliberately preserved; N1 eligibility fails closed without
      // the participant binding.
      await Installation.updateMany(
        { participantId },
        { $unset: { participantId: "", participantAuthorityVersion: "" } },
        { session, timestamps: false }
      ).exec();

      // Account deletion overrides ordinary Request and evidence TTLs.
      // Remove requester-owned Request documents (including all potentially
      // identifying content) and their private evidence immediately, while
      // retaining Fulfillment as the separately authorized permanent
      // operational ledger. Other requesters' rows survive with only the
      // deleting helper's direct bindings removed.
      const ownedRequests = await MealRequest.find({
        requesterParticipantId: participantId,
      })
        .select("_id")
        .session(session)
        .lean<{ _id: typeof participantId }[]>()
        .exec();
      const ownedRequestIds = ownedRequests.map((request) => request._id);
      const deletedSubscriber = await Subscriber.findOneAndDelete({
        email: owner.canonicalEmail,
      })
        .select("_id")
        .session(session)
        .lean<{ _id: typeof participantId } | null>()
        .exec();
      if (deletedSubscriber) {
        await SendLog.deleteMany(
          { subscriberId: deletedSubscriber._id },
          { session }
        ).exec();
      }
      if (ownedRequestIds.length > 0) {
        await SendLog.deleteMany(
          { requestId: { $in: ownedRequestIds } },
          { session }
        ).exec();
        await Fulfillment.updateMany(
          { requestId: { $in: ownedRequestIds } },
          { $unset: { note: "" } },
          { session, timestamps: false }
        ).exec();
        await PlacementEvidence.deleteMany(
          { requestId: { $in: ownedRequestIds } },
          { session }
        ).exec();
        const deletedRequests = await MealRequest.deleteMany(
          {
            _id: { $in: ownedRequestIds },
            requesterParticipantId: participantId,
          },
          { session }
        ).exec();
        if (deletedRequests.deletedCount !== ownedRequestIds.length) {
          throw new Error("Participant-owned Requests changed during deletion");
        }
      }
      await MealRequest.updateMany(
        { helperParticipantId: participantId },
        { $unset: { helperParticipantId: "", fulfillerEmail: "" } },
        { session, timestamps: false }
      ).exec();

      // Transition this exact operation to its completed receipt.
      const completionResult = await ParticipantDeletionOperation.collection.updateOne(
        {
          ...filter,
          phase: "authorized",
          readinessGeneration: expectedReadinessGeneration,
          authorizationExpiresAt: { $gt: now },
          recoveryCapabilityDigest: row.recoveryCapabilityDigest,
        },
        participantDeletionCompletionReceiptPipeline(),
        { session }
      );
      if (completionResult.modifiedCount !== 1) {
        throw new CompletionAborted("stale");
      }

      // Ordinary account identity removal, last, after every required
      // retained-state transformation has succeeded. Credentials signed from
      // {_id, authorityVersion} are invalidated by this row's disappearance
      // with no further state to clear.
      const deletedParticipant = await Participant.deleteOne(
        { _id: participantId, authorityVersion: owner.authorityVersion },
        { session }
      ).exec();
      if (deletedParticipant.deletedCount !== 1) {
        throw new CompletionAborted("stale");
      }
    });
  } catch (error) {
    if (error instanceof CompletionAborted) {
      if (error.outcome === "blocked") {
        // The aborted transaction committed nothing. Reflect the newly
        // discovered blocker in persisted state the same way the dormant
        // adapters already do, rather than leaving a stale "authorized"
        // operation that silently ignored it.
        await demoteParticipantDeletionReadiness(
          owner,
          expectedReadinessGeneration,
          overrides
        ).catch(() => undefined);
      }
      return error.outcome;
    }
    if (error instanceof ParticipantAccountFenceUnavailable) {
      // A concurrent duplicate completion call, or one that lost a race to
      // another winning writer, can find the owning Participant already
      // gone (or its authority version already moved on) the moment it
      // tries to enter the fence. That is exactly "this credential's owner
      // can no longer be established here", the same situation every other
      // caller of this owner binding treats as "notOwned".
      return "notOwned";
    }
    throw error;
  }
  return "completed";
}
