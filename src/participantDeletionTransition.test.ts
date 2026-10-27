import { describe, expect, it } from "vitest";
import type { ParticipantDeletionPhase } from "../models/db.js";
import {
  canTransitionParticipantDeletion,
  isParticipantDeletionTransitionAllowed,
  nextReadinessGeneration,
  type ParticipantDeletionTransitionReason,
} from "./participantDeletionTransition.js";

const phases: ParticipantDeletionPhase[] = [
  "waiting", "ready", "challengeIssued", "authorized", "completed", "canceled",
];

const legal: Array<[ParticipantDeletionPhase, ParticipantDeletionPhase, ParticipantDeletionTransitionReason]> = [
  ["waiting", "ready", "readinessPromoted"],
  ["ready", "challengeIssued", "challengeIssued"],
  ["challengeIssued", "authorized", "challengeRedeemed"],
  ["challengeIssued", "ready", "challengeExpiredOrExhausted"],
  ["authorized", "ready", "authorizationExpired"],
  ["ready", "waiting", "readinessDemoted"],
  ["challengeIssued", "waiting", "readinessDemoted"],
  ["authorized", "waiting", "readinessDemoted"],
  ["waiting", "canceled", "canceled"],
  ["ready", "canceled", "canceled"],
  ["challengeIssued", "canceled", "canceled"],
  ["authorized", "canceled", "canceled"],
  ["authorized", "completed", "completed"],
];

describe("W4-P2 participant deletion pure transition table", () => {
  it.each(legal)("allows %s -> %s only for %s", (from, to, reason) => {
    expect(canTransitionParticipantDeletion(from, to)).toBe(true);
    expect(isParticipantDeletionTransitionAllowed(from, to, reason)).toBe(true);
  });

  it("rejects every non-contract edge, including direct waiting authorization/completion", () => {
    const allowedPairs = new Set(legal.map(([from, to]) => `${from}:${to}`));
    for (const from of phases) {
      for (const to of phases) {
        if (allowedPairs.has(`${from}:${to}`)) continue;
        expect(canTransitionParticipantDeletion(from, to)).toBe(false);
      }
    }
    expect(canTransitionParticipantDeletion("waiting", "authorized")).toBe(false);
    expect(canTransitionParticipantDeletion("waiting", "completed")).toBe(false);
  });

  it("keeps terminal phases terminal and rejects a correct edge with the wrong cause", () => {
    for (const terminal of ["completed", "canceled"] as const) {
      for (const to of phases) expect(canTransitionParticipantDeletion(terminal, to)).toBe(false);
    }
    expect(isParticipantDeletionTransitionAllowed("authorized", "ready", "readinessDemoted")).toBe(false);
    expect(isParticipantDeletionTransitionAllowed("ready", "waiting", "authorizationExpired")).toBe(false);
  });

  it("advances readiness only on a waiting promotion", () => {
    expect(nextReadinessGeneration("waiting", 0, "readinessPromoted")).toBe(1);
    expect(nextReadinessGeneration("waiting", 8, "readinessPromoted")).toBe(9);
    expect(nextReadinessGeneration("authorized", 8, "authorizationExpired")).toBe(8);
    expect(nextReadinessGeneration("waiting", -1, "readinessPromoted")).toBeNull();
  });
});
