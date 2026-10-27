import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { evaluateParticipantDeletionReadiness } from "./participantDeletionReadinessEvaluator.js";

const mocks = vi.hoisted(() => ({
  requester: vi.fn(),
  helper: vi.fn(),
  promote: vi.fn(),
  status: vi.fn(),
}));
vi.mock("./participantDeletionRequesterAdapter.js", () => ({
  reconcileParticipantDeletionRequesterRequests: mocks.requester,
}));
vi.mock("./participantDeletionHelperAdapter.js", () => ({
  reconcileParticipantDeletionHelperRequests: mocks.helper,
}));
vi.mock("./participantDeletionOperations.js", () => ({
  promoteParticipantDeletionReadiness: mocks.promote,
  readParticipantDeletionStatus: mocks.status,
}));

const source = readFileSync(
  new URL("./participantDeletionReadinessEvaluator.ts", import.meta.url),
  "utf8"
);
const app = readFileSync(new URL("../app.ts", import.meta.url), "utf8");

const owner = {
  operationId: "owned-operation",
  participantId: "owned-participant",
  canonicalEmail: "owner@nyu.edu",
  authorityVersion: 1,
};
const dependencies = { now: () => new Date("2026-10-23T12:00:00.000Z") };
const readyStatus = { operationId: owner.operationId, phase: "ready" as const, readinessGeneration: 1 };
const waitingStatus = { operationId: owner.operationId, phase: "waiting" as const, readinessGeneration: 1 };

describe("P2 whole-operation readiness evaluator: validation", () => {
  it.each([-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY])(
    "rejects an invalid expected generation (%s)",
    async (generation) => {
      await expect(evaluateParticipantDeletionReadiness(owner, generation, dependencies))
        .rejects.toThrow("non-negative readiness generation");
      expect(mocks.requester).not.toHaveBeenCalled();
    }
  );
});

describe("P2 whole-operation readiness evaluator: all-clear matrix", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("promotes to ready only when both required inputs are clear", async () => {
    mocks.requester.mockResolvedValue({ outcome: "observed", requester: "clear" });
    mocks.helper.mockResolvedValue({ outcome: "observed", helper: "clear" });
    mocks.promote.mockResolvedValue(true);
    mocks.status.mockResolvedValue(readyStatus);
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies))
      .toEqual({ outcome: "ready", status: readyStatus });
    expect(mocks.promote).toHaveBeenCalledWith(owner, 1, dependencies);
  });

  it("stays waiting on a requester blocker and never promotes", async () => {
    mocks.requester.mockResolvedValue({ outcome: "observed", requester: "withdrawalRequired" });
    mocks.helper.mockResolvedValue({ outcome: "observed", helper: "clear" });
    mocks.status.mockResolvedValue(waitingStatus);
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({
      outcome: "waiting",
      status: waitingStatus,
      blockers: [{ source: "requester", observation: "withdrawalRequired" }],
    });
    expect(mocks.promote).not.toHaveBeenCalled();
  });

  it("stays waiting on a helper blocker and never promotes", async () => {
    mocks.requester.mockResolvedValue({ outcome: "observed", requester: "clear" });
    mocks.helper.mockResolvedValue({ outcome: "observed", helper: "helperOrPickup" });
    mocks.status.mockResolvedValue(waitingStatus);
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({
      outcome: "waiting",
      status: waitingStatus,
      blockers: [{ source: "helper", observation: "helperOrPickup" }],
    });
    expect(mocks.promote).not.toHaveBeenCalled();
  });

  it("reports both blockers together when both inputs are blocked", async () => {
    mocks.requester.mockResolvedValue({ outcome: "observed", requester: "helperOrPickup" });
    mocks.helper.mockResolvedValue({ outcome: "observed", helper: "helperOrPickup" });
    mocks.status.mockResolvedValue(waitingStatus);
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({
      outcome: "waiting",
      status: waitingStatus,
      blockers: [
        { source: "requester", observation: "helperOrPickup" },
        { source: "helper", observation: "helperOrPickup" },
      ],
    });
    expect(mocks.promote).not.toHaveBeenCalled();
  });

  it.each(["requester", "helper"] as const)(
    "treats an unknown %s observation as a fail-closed blocker, never clear",
    async (which) => {
      mocks.requester.mockResolvedValue({
        outcome: "observed",
        requester: which === "requester" ? "unknown" : "clear",
      });
      mocks.helper.mockResolvedValue({
        outcome: "observed",
        helper: which === "helper" ? "unknown" : "clear",
      });
      mocks.status.mockResolvedValue(waitingStatus);
      const result = await evaluateParticipantDeletionReadiness(owner, 1, dependencies);
      expect(result).toMatchObject({ outcome: "waiting" });
      expect((result as { blockers: unknown[] }).blockers).toEqual([
        { source: which, observation: "unknown" },
      ]);
      expect(mocks.promote).not.toHaveBeenCalled();
    }
  );
});

describe("P2 whole-operation readiness evaluator: fail-closed propagation", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it.each(["notOwned", "stale", "inactive"] as const)(
    "propagates a requester %s outcome without consulting the helper adapter",
    async (outcome) => {
      mocks.requester.mockResolvedValue({ outcome });
      expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({ outcome });
      expect(mocks.helper).not.toHaveBeenCalled();
      expect(mocks.promote).not.toHaveBeenCalled();
    }
  );

  it.each(["notOwned", "stale", "inactive"] as const)(
    "propagates a helper %s outcome after a clear requester observation, without promoting",
    async (outcome) => {
      mocks.requester.mockResolvedValue({ outcome: "observed", requester: "clear" });
      mocks.helper.mockResolvedValue({ outcome });
      expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({ outcome });
      expect(mocks.promote).not.toHaveBeenCalled();
    }
  );

  it("one adapter's clear result never overrides the other adapter's blocker", async () => {
    mocks.requester.mockResolvedValue({ outcome: "observed", requester: "clear" });
    mocks.helper.mockResolvedValue({ outcome: "observed", helper: "helperOrPickup" });
    mocks.status.mockResolvedValue(waitingStatus);
    const result = await evaluateParticipantDeletionReadiness(owner, 1, dependencies);
    expect(result).toMatchObject({
      outcome: "waiting",
      blockers: [{ source: "helper", observation: "helperOrPickup" }],
    });
  });

  it("fails closed as stale when the generation advanced while both inputs read clear", async () => {
    mocks.requester.mockResolvedValue({ outcome: "observed", requester: "withdrawalRequired" });
    mocks.helper.mockResolvedValue({ outcome: "observed", helper: "clear" });
    mocks.status.mockResolvedValue({ ...waitingStatus, readinessGeneration: 2 });
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({ outcome: "stale" });
  });

  it("returns notOwned if the operation disappears before the post-blocker status read", async () => {
    mocks.requester.mockResolvedValue({ outcome: "observed", requester: "withdrawalRequired" });
    mocks.helper.mockResolvedValue({ outcome: "observed", helper: "clear" });
    mocks.status.mockResolvedValue(null);
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({ outcome: "notOwned" });
  });
});

describe("P2 whole-operation readiness evaluator: promotion races and idempotency", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.requester.mockResolvedValue({ outcome: "observed", requester: "clear" });
    mocks.helper.mockResolvedValue({ outcome: "observed", helper: "clear" });
  });

  it("is idempotent: ready remains ready when both inputs remain clear on a repeat run", async () => {
    mocks.promote.mockResolvedValue(false);
    mocks.status.mockResolvedValue(readyStatus);
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies))
      .toEqual({ outcome: "ready", status: readyStatus });
  });

  it.each(["challengeIssued", "authorized"] as const)(
    "treats an already-%s phase at the same generation as ready, not a re-promotion",
    async (phase) => {
      mocks.promote.mockResolvedValue(false);
      mocks.status.mockResolvedValue({ ...readyStatus, phase });
      expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies))
        .toEqual({ outcome: "ready", status: { ...readyStatus, phase } });
    }
  );

  it("never promotes a newer generation onto a stale observation", async () => {
    mocks.promote.mockResolvedValue(false);
    mocks.status.mockResolvedValue({ ...readyStatus, readinessGeneration: 2 });
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({ outcome: "stale" });
  });

  it("does not resurrect a canceled operation as ready", async () => {
    mocks.promote.mockResolvedValue(false);
    mocks.status.mockResolvedValue({ ...waitingStatus, phase: "canceled" });
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({ outcome: "inactive" });
  });

  it("does not resurrect a completed operation as ready", async () => {
    mocks.promote.mockResolvedValue(false);
    mocks.status.mockResolvedValue({ ...waitingStatus, phase: "completed" });
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({ outcome: "inactive" });
  });

  it("fails closed to waiting rather than guessing readiness on an unexplained non-match", async () => {
    mocks.promote.mockResolvedValue(false);
    mocks.status.mockResolvedValue(waitingStatus);
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies))
      .toEqual({ outcome: "waiting", status: waitingStatus, blockers: [] });
  });

  it("returns notOwned if the operation disappears between a successful promote and its status read", async () => {
    mocks.promote.mockResolvedValue(true);
    mocks.status.mockResolvedValue(null);
    expect(await evaluateParticipantDeletionReadiness(owner, 1, dependencies)).toEqual({ outcome: "notOwned" });
  });

  it("duplicate concurrent runs converge: only one reports ready, the loser reports stale", async () => {
    mocks.promote.mockResolvedValueOnce(true).mockResolvedValueOnce(false);
    mocks.status
      .mockResolvedValueOnce(readyStatus)
      .mockResolvedValueOnce({ ...readyStatus, readinessGeneration: 2 });
    const [first, second] = await Promise.all([
      evaluateParticipantDeletionReadiness(owner, 1, dependencies),
      evaluateParticipantDeletionReadiness(owner, 1, dependencies),
    ]);
    expect([first, second]).toEqual(
      expect.arrayContaining([
        { outcome: "ready", status: readyStatus },
        { outcome: "stale" },
      ])
    );
  });
});

describe("P2 whole-operation readiness evaluator: Checkpoint-7/8 boundary proof", () => {
  it("never reads U1.2 moderation or N1/MSG1 state", () => {
    const specifiers = [...source.matchAll(/from "([^"]+)";/g)].map(([, specifier]) => specifier);
    expect(specifiers.length).toBeGreaterThan(0);
    expect(specifiers.every((specifier) =>
      specifier === "./participantDeletionOperations.js" ||
      specifier === "./participantDeletionRequesterAdapter.js" ||
      specifier === "./participantDeletionHelperAdapter.js"
    )).toBe(true);
  });

  it("never issues, redeems, authorizes or completes deletion", () => {
    expect(source).not.toMatch(
      /issueParticipantDeletionChallenge|redeemParticipantDeletionChallenge|confirmSafetyIdentity|cancelParticipantDeletionOperation/
    );
  });

  it("only promotes through the existing conditional primitive, never demotes directly", () => {
    expect(source).toContain("promoteParticipantDeletionReadiness");
    expect(source).not.toContain("demoteParticipantDeletionReadiness");
    expect(source).not.toMatch(/ParticipantDeletionOperation\.(update|findOneAnd|create|bulkWrite)/);
  });

  it("is dormant: no production caller registers it", () => {
    expect(app).not.toContain("participantDeletionReadinessEvaluator");
  });
});
