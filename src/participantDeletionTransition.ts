import type { ParticipantDeletionPhase } from "../models/db.js";

/** The only legal P2 lifecycle edges. Persistence commands still enforce them
 * with conditional Mongo predicates; this pure table makes the contract
 * reviewable and independently testable. */
const LEGAL_EDGES: Readonly<Record<ParticipantDeletionPhase, readonly ParticipantDeletionPhase[]>> = {
  waiting: ["ready", "canceled"],
  ready: ["challengeIssued", "waiting", "canceled"],
  challengeIssued: ["authorized", "ready", "waiting", "canceled"],
  authorized: ["completed", "ready", "waiting", "canceled"],
  completed: [],
  canceled: [],
};

export function canTransitionParticipantDeletion(
  from: ParticipantDeletionPhase,
  to: ParticipantDeletionPhase
): boolean {
  return LEGAL_EDGES[from].includes(to);
}

export type ParticipantDeletionTransitionReason =
  | "readinessPromoted"
  | "challengeIssued"
  | "challengeRedeemed"
  | "challengeExpiredOrExhausted"
  | "authorizationExpired"
  | "readinessDemoted"
  | "canceled"
  | "completed";

/**
 * The graph alone is not enough: each edge has one accepted cause. Keeping
 * this pure avoids hiding lifecycle policy in individual persistence updates.
 */
export function isParticipantDeletionTransitionAllowed(
  from: ParticipantDeletionPhase,
  to: ParticipantDeletionPhase,
  reason: ParticipantDeletionTransitionReason
): boolean {
  if (!canTransitionParticipantDeletion(from, to)) return false;
  return (
    (from === "waiting" && to === "ready" && reason === "readinessPromoted") ||
    (from === "ready" && to === "challengeIssued" && reason === "challengeIssued") ||
    (from === "challengeIssued" && to === "authorized" && reason === "challengeRedeemed") ||
    (from === "challengeIssued" && to === "ready" && reason === "challengeExpiredOrExhausted") ||
    (from === "authorized" && to === "ready" && reason === "authorizationExpired") ||
    (["ready", "challengeIssued", "authorized"].includes(from) &&
      to === "waiting" &&
      reason === "readinessDemoted") ||
    (["waiting", "ready", "challengeIssued", "authorized"].includes(from) &&
      to === "canceled" &&
      reason === "canceled") ||
    (from === "authorized" && to === "completed" && reason === "completed")
  );
}

export function nextReadinessGeneration(
  phase: ParticipantDeletionPhase,
  generation: number,
  reason: ParticipantDeletionTransitionReason
): number | null {
  if (!Number.isInteger(generation) || generation < 0) return null;
  return phase === "waiting" && reason === "readinessPromoted"
    ? generation + 1
    : generation;
}
