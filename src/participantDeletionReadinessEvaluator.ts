import {
  promoteParticipantDeletionReadiness,
  readParticipantDeletionStatus,
  type DeletionOwner,
  type ParticipantDeletionDependencies,
  type ParticipantDeletionStatus,
} from "./participantDeletionOperations.js";
import {
  reconcileParticipantDeletionRequesterRequests,
  type DeletionRequesterObservation,
} from "./participantDeletionRequesterAdapter.js";
import {
  reconcileParticipantDeletionHelperRequests,
  type DeletionHelperObservation,
} from "./participantDeletionHelperAdapter.js";

export type ParticipantDeletionReadinessBlocker =
  | { source: "requester"; observation: DeletionRequesterObservation }
  | { source: "helper"; observation: DeletionHelperObservation };

export type ParticipantDeletionReadinessEvaluation =
  | { outcome: "notOwned" | "stale" | "inactive" }
  | {
      outcome: "waiting";
      status: ParticipantDeletionStatus;
      blockers: ParticipantDeletionReadinessBlocker[];
    }
  | { outcome: "ready"; status: ParticipantDeletionStatus };

/**
 * Dormant whole-operation readiness evaluator. It composes the accepted R5/R3
 * requester adapter and the accepted H1a helper adapter (each already a
 * fail-closed, generation-fenced, demotion-only input) into the one
 * waiting/ready decision; it never invents a blocker answer itself and
 * imports nothing outside this pair of accepted inputs and the dormant
 * operations primitives below. Promotion is the only mutation this module
 * performs beyond what the two adapters already do: it calls the existing
 * conditional `waiting -> ready` primitive, and only when every required
 * input is observed clear under the exact generation the caller supplied.
 * No route, delivery, challenge, authorization or deletion is reachable
 * from here.
 */
export async function evaluateParticipantDeletionReadiness(
  owner: DeletionOwner,
  expectedReadinessGeneration: number,
  dependencies: Partial<ParticipantDeletionDependencies>
): Promise<ParticipantDeletionReadinessEvaluation> {
  if (!Number.isInteger(expectedReadinessGeneration) || expectedReadinessGeneration < 0) {
    throw new Error("participant deletion requires a non-negative readiness generation");
  }

  // Each adapter independently re-validates ownership and the exact
  // readiness generation before reporting, and already demotes the operation
  // the moment it observes its own blocker. Composing their results does not
  // require a second authority model: a changed generation or a terminal
  // phase surfaces here exactly as "stale"/"inactive", not as an invented
  // clear/blocked guess.
  const requester = await reconcileParticipantDeletionRequesterRequests(
    owner,
    expectedReadinessGeneration,
    dependencies
  );
  if (requester.outcome !== "observed") {
    return { outcome: requester.outcome };
  }

  const helper = await reconcileParticipantDeletionHelperRequests(
    owner,
    expectedReadinessGeneration,
    dependencies
  );
  if (helper.outcome !== "observed") {
    return { outcome: helper.outcome };
  }

  const blockers: ParticipantDeletionReadinessBlocker[] = [];
  if (requester.requester !== "clear") {
    blockers.push({ source: "requester", observation: requester.requester });
  }
  if (helper.helper !== "clear") {
    blockers.push({ source: "helper", observation: helper.helper });
  }

  if (blockers.length > 0) {
    // A non-clear observation already triggered its own adapter's demotion
    // (or found the operation already waiting). One adapter's blocker is
    // never overridden by the other adapter's clear result.
    const status = await readParticipantDeletionStatus(owner, dependencies);
    if (!status) return { outcome: "notOwned" };
    if (status.readinessGeneration !== expectedReadinessGeneration) {
      return { outcome: "stale" };
    }
    return { outcome: "waiting", status, blockers };
  }

  // Both required inputs are clear. Promotion is the only path from waiting
  // to ready, is conditioned on the exact generation the caller observed,
  // and never auto-issues a challenge or authorizes/performs deletion.
  const promoted = await promoteParticipantDeletionReadiness(
    owner,
    expectedReadinessGeneration,
    dependencies
  );
  const status = await readParticipantDeletionStatus(owner, dependencies);
  if (!status) return { outcome: "notOwned" };
  if (promoted) {
    return { outcome: "ready", status };
  }
  if (status.readinessGeneration !== expectedReadinessGeneration) {
    // A concurrent evaluation (or a later caller) already promoted this
    // operation past the generation this run observed; claiming "ready" here
    // would promote a stale observation onto a newer generation.
    return { outcome: "stale" };
  }
  if (status.phase === "canceled" || status.phase === "completed") {
    return { outcome: "inactive" };
  }
  if (status.phase === "ready" || status.phase === "challengeIssued" || status.phase === "authorized") {
    // Idempotent re-evaluation: the exact same generation is already past
    // waiting and both inputs remain clear now, so this is not a new
    // promotion, just a confirmation that clears no blocker.
    return { outcome: "ready", status };
  }
  // Still "waiting" at the same generation: the conditional promote filtered
  // on the exact same predicate we just reconfirmed, so a non-match here can
  // only be a transient write conflict, not a newly discovered blocker. Fail
  // closed rather than guess readiness.
  return { outcome: "waiting", status, blockers: [] };
}
