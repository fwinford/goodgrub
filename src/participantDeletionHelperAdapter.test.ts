import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { reconcileParticipantDeletionHelperRequests } from "./participantDeletionHelperAdapter.js";

const mocks = vi.hoisted(() => ({
  participant: vi.fn(),
  requests: vi.fn<() => Record<string, unknown>[]>(),
  participations: vi.fn<() => Record<string, unknown>[]>(),
  fulfillments: vi.fn<() => Record<string, unknown>[]>(),
  existingRequests: vi.fn<() => Record<string, unknown>[]>(),
  status: vi.fn(),
  demote: vi.fn(),
  find: vi.fn(),
  participationFind: vi.fn(),
  fulfillmentFind: vi.fn(),
  read: vi.fn(),
}));
vi.mock("../models/db.js", () => ({
  Participant: {
    findOne: () => ({
      select: () => ({
        read: mocks.read.mockImplementation(() => ({
          lean: () => ({ exec: mocks.participant }),
        })),
      }),
    }),
  },
  Request: {
    find: mocks.find.mockImplementation((filter: Record<string, unknown>) => {
      if ("_id" in filter) {
        const chain = {
          select: () => chain,
          read: () => chain,
          lean: () => chain,
          session: () => chain,
          exec: () => Promise.resolve(mocks.existingRequests()),
        };
        return chain;
      }
      return {
        select: () => ({
          read: () => ({
            lean: () => ({ cursor: async function* () { yield* mocks.requests(); } }),
          }),
        }),
      };
    }),
  },
  RequestParticipation: {
    find: mocks.participationFind.mockImplementation(() => {
      const chain = {
        select: () => chain,
        read: () => chain,
        lean: () => chain,
        session: () => chain,
        exec: () => Promise.resolve(mocks.participations()),
      };
      return chain;
    }),
  },
  Fulfillment: {
    find: mocks.fulfillmentFind.mockImplementation(() => {
      const chain = {
        select: () => chain,
        read: () => chain,
        lean: () => chain,
        session: () => chain,
        exec: () => Promise.resolve(mocks.fulfillments()),
      };
      return chain;
    }),
  },
}));
vi.mock("./participantIdentityKeys.js", () => ({
  loadParticipantIdentityManifest: vi.fn().mockResolvedValue({
    ring: { keys: new Map([[1, Buffer.alloc(32, 1)]]) },
    entries: [{ version: 1 }],
  }),
  deriveParticipantIdentityAliases: vi.fn(
    (_purpose: string, _ring: unknown, _entries: unknown, requestId: string) => [
      { version: 1, digest: requestId === "64e000000000000000000001" ? "a".repeat(64) : "b".repeat(64) },
    ]
  ),
}));
vi.mock("./participantDeletionOperations.js", () => ({
  readParticipantDeletionStatus: mocks.status,
  demoteParticipantDeletionReadiness: mocks.demote,
}));

const owner = {
  operationId: "operation", participantId: "helper",
  canonicalEmail: "helper@nyu.edu", authorityVersion: 1,
};
const now = new Date("2026-10-20T04:00:00.000Z");
const dependencies = { now: () => now };
const reconcile = (generation = 1) =>
  reconcileParticipantDeletionHelperRequests(owner, generation, dependencies);
const source = readFileSync(new URL("./participantDeletionHelperAdapter.ts", import.meta.url), "utf8");

describe("dormant P2 H1a helper input", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.participant.mockResolvedValue({ email: owner.canonicalEmail });
    mocks.requests.mockReturnValue([]);
    mocks.participations.mockReturnValue([]);
    mocks.fulfillments.mockReturnValue([]);
    mocks.existingRequests.mockReturnValue([]);
    mocks.status.mockResolvedValue({ phase: "waiting", readinessGeneration: 1 });
    mocks.demote.mockResolvedValue(false);
  });

  it.each([
    ["absent", undefined], ["null", null], ["invalid Date", new Date(Number.NaN)],
    ["string", now.toISOString()], ["bad string", "bad"], ["number", now.getTime()],
    ["infinity", Number.POSITIVE_INFINITY], ["object", {}], ["array", []], ["boolean", false],
  ])("fails closed for %s expiry authority", async (_label, claimExpiresAt) => {
    mocks.requests.mockReturnValue([{ status: "claimed", claimExpiresAt }]);
    expect(await reconcile()).toEqual({ outcome: "observed", helper: "unknown" });
    expect(mocks.demote).toHaveBeenCalledWith(owner, 1, dependencies);
  });

  it.each([
    ["active", new Date(now.getTime() + 1), "helperOrPickup"],
    ["expired", new Date(now.getTime() - 1), "clear"],
    ["exact boundary", now, "clear"],
  ])("consumes %s persisted reservation truth", async (_label, claimExpiresAt, helper) => {
    mocks.requests.mockReturnValue([{ status: "claimed", claimExpiresAt }]);
    expect(await reconcile()).toEqual({ outcome: "observed", helper });
    expect(mocks.demote).toHaveBeenCalledTimes(helper === "clear" ? 0 : 1);
  });

  it.each([
    { status: "placed", deleteAt: new Date(0) },
    { status: "claimed", externalOrderAffirmed: true, claimExpiresAt: new Date(0) },
    { status: "claimed", externalOrderAffirmed: true },
  ])("does not clear placement or post-Yes authority: %j", async (row) => {
    mocks.requests.mockReturnValue([row]);
    expect(await reconcile()).toMatchObject({ helper: "helperOrPickup" });
  });

  it("clears a placed helper obligation only on a valid R3 pickup confirmation", async () => {
    mocks.requests.mockReturnValue([
      {
        status: "placed",
        requesterPickupConfirmedAt: new Date("2026-10-19T17:00:00.000Z"),
      },
    ]);
    expect(await reconcile()).toEqual({ outcome: "observed", helper: "clear" });
    expect(mocks.demote).not.toHaveBeenCalled();
  });

  it("fails closed when a claimed Request expired without a durable terminal record", async () => {
    mocks.participations.mockReturnValue([
      { requestId: "64e000000000000000000001" },
    ]);
    expect(await reconcile()).toEqual({
      outcome: "observed",
      helper: "unknown",
    });
    expect(mocks.demote).toHaveBeenCalledOnce();
  });

  it("uses matching durable Fulfillment pickup proof after Request TTL", async () => {
    mocks.participations.mockReturnValue([
      { requestId: "64e000000000000000000001" },
    ]);
    mocks.fulfillments.mockReturnValue([
      {
        requestId: "64e000000000000000000001",
        helperParticipationKeyVersion: 1,
        helperParticipationHmac: "a".repeat(64),
        requesterPickupConfirmedAt: new Date("2026-10-19T17:00:00.000Z"),
      },
    ]);
    expect(await reconcile()).toEqual({
      outcome: "observed",
      helper: "clear",
    });
    expect(mocks.demote).not.toHaveBeenCalled();
  });

  it.each([
    [{ requesterPickupConfirmedAt: undefined }, "helperOrPickup"],
    [{ requesterPickupConfirmedAt: "not-a-date" }, "unknown"],
  ] as const)("does not clear missing or malformed retained pickup proof after Request TTL: %j", async (proof, helper) => {
    mocks.participations.mockReturnValue([
      { requestId: "64e000000000000000000001" },
    ]);
    mocks.fulfillments.mockReturnValue([
      {
        requestId: "64e000000000000000000001",
        helperParticipationKeyVersion: 1,
        helperParticipationHmac: "a".repeat(64),
        ...proof,
      },
    ]);
    expect(await reconcile()).toMatchObject({ helper });
  });

  it("fails closed when retained terminal proof belongs to another helper", async () => {
    mocks.participations.mockReturnValue([
      { requestId: "64e000000000000000000001" },
    ]);
    mocks.fulfillments.mockReturnValue([
      {
        requestId: "64e000000000000000000001",
        helperParticipationKeyVersion: 1,
        helperParticipationHmac: "b".repeat(64),
        requesterPickupConfirmedAt: new Date("2026-10-19T17:00:00.000Z"),
      },
    ]);
    expect(await reconcile()).toEqual({ outcome: "observed", helper: "unknown" });
    expect(mocks.demote).toHaveBeenCalledOnce();
  });

  it.each([now.toISOString(), "invalid", Number.NaN])(
    "fails closed for malformed R3 pickup truth %j",
    async (requesterPickupConfirmedAt) => {
      mocks.requests.mockReturnValue([
        { status: "placed", requesterPickupConfirmedAt },
      ]);
      expect(await reconcile()).toEqual({
        outcome: "observed",
        helper: "unknown",
      });
      expect(mocks.demote).toHaveBeenCalledWith(owner, 1, dependencies);
    }
  );

  it.each([
    { status: "open" }, { status: "withdrawn" }, { status: "unexpected" },
    { status: "claimed", externalOrderAffirmed: "true", claimExpiresAt: new Date(0) },
  ])("does not invent a terminal state from inconsistent helper binding: %j", async (row) => {
    mocks.requests.mockReturnValue([row]);
    expect(await reconcile()).toMatchObject({ helper: "unknown" });
  });

  it("does not let a clear row erase unknown or active input", async () => {
    for (const rows of [
      [{ status: "claimed" }, { status: "claimed", claimExpiresAt: new Date(0) }],
      [{ status: "placed" }, { status: "claimed" }],
    ]) {
      mocks.requests.mockReturnValue(rows);
      expect(await reconcile()).toMatchObject({
        helper: rows[0].status === "placed" ? "helperOrPickup" : "unknown",
      });
    }
  });

  it.each([
    { activeReservationRequestId: "missing", activeReservationClaimExpiresAt: new Date(0) },
    { activeReservationRequestId: "missing" },
    { activeReservationClaimExpiresAt: now },
  ])("fails closed for incomplete lock/request authority: %j", async (lock) => {
    mocks.participant.mockResolvedValue({ email: owner.canonicalEmail, ...lock });
    expect(await reconcile()).toMatchObject({ helper: "unknown" });
  });

  it.each([
    { activeReservationRequestId: "new", activeReservationClaimExpiresAt: now },
    { blockFenceEpoch: 1 },
  ])("refuses a clear observation changed during inventory: %j", async (change) => {
    mocks.participant.mockResolvedValueOnce({ email: owner.canonicalEmail })
      .mockResolvedValueOnce({ email: owner.canonicalEmail, ...change });
    expect(await reconcile()).toMatchObject({ helper: "unknown" });
    expect(mocks.demote).toHaveBeenCalledOnce();
  });

  it("refuses a participant revoked during inventory", async () => {
    mocks.participant.mockResolvedValueOnce({ email: owner.canonicalEmail }).mockResolvedValueOnce(null);
    expect(await reconcile()).toEqual({ outcome: "notOwned" });
    expect(mocks.demote).not.toHaveBeenCalled();
  });

  it("refuses stale generations, terminal operations and foreign owners", async () => {
    mocks.status.mockResolvedValueOnce({ phase: "ready", readinessGeneration: 2 });
    expect(await reconcile()).toEqual({ outcome: "stale" });
    mocks.status.mockResolvedValueOnce({ phase: "canceled", readinessGeneration: 1 });
    expect(await reconcile()).toEqual({ outcome: "inactive" });
    mocks.participant.mockResolvedValueOnce({ email: "foreign@nyu.edu" });
    expect(await reconcile()).toEqual({ outcome: "notOwned" });
    expect(mocks.find).not.toHaveBeenCalled();
  });

  it("propagates unavailable authoritative reads instead of returning clear", async () => {
    mocks.requests.mockImplementationOnce(() => { throw new Error("read unavailable"); });
    await expect(reconcile()).rejects.toThrow("read unavailable");
  });

  it.each([-1, 0.5, Number.NaN])("refuses invalid generation %s", async (generation) => {
    await expect(reconcile(generation)).rejects.toThrow("non-negative readiness generation");
  });

  it("is unbounded, participant-scoped and primary-only", async () => {
    expect(await reconcile()).toEqual({ outcome: "observed", helper: "clear" });
    expect(mocks.find).toHaveBeenCalledWith({ helperParticipantId: owner.participantId });
    expect(mocks.participationFind).toHaveBeenCalledWith({
      participantId: owner.participantId,
    });
    expect(mocks.read).toHaveBeenCalledWith("primary");
    expect(source).not.toMatch(/\.limit\(|getActiveReservation/);
  });

  it("has no lifecycle, evidence, ledger, challenge, promotion or public-route write", () => {
    expect(source).not.toMatch(/releaseClaim|fulfillRequest|PlacementEvidence|RequestOperation/);
    expect(source).not.toMatch(/(?:RequestParticipation|Fulfillment)\.(?:update|delete|create|bulkWrite)/);
    expect(source).not.toMatch(/promoteParticipantDeletionReadiness|issueParticipantDeletionChallenge|redeemParticipantDeletionChallenge/);
    expect(source).not.toMatch(/(?:Participant|MealRequest)\.(?:update|delete|findOneAnd|create|bulkWrite)/);
    expect(readFileSync(new URL("../app.ts", import.meta.url), "utf8"))
      .not.toContain("participantDeletionHelperAdapter");
  });
});
