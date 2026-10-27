import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { reconcileParticipantDeletionRequesterRequests } from "./participantDeletionRequesterAdapter.js";

const mocks = vi.hoisted(() => ({
  requests: vi.fn<() => Record<string, unknown>[]>(),
  status: vi.fn(),
  demote: vi.fn(),
}));
vi.mock("../models/db.js", () => ({
  Participant: {
    findOne: () => ({
      select: () => ({ lean: () => ({ exec: async () => ({ email: "owner@nyu.edu" }) }) }),
    }),
  },
  Request: {
    find: () => ({
      select: () => ({
        lean: () => ({
          cursor: async function* () { yield* mocks.requests(); },
        }),
      }),
    }),
  },
}));
vi.mock("./participantDeletionOperations.js", () => ({
  readParticipantDeletionStatus: mocks.status,
  demoteParticipantDeletionReadiness: mocks.demote,
}));

const source = readFileSync(new URL("./participantDeletionRequesterAdapter.ts", import.meta.url), "utf8");
const app = readFileSync(new URL("../app.ts", import.meta.url), "utf8");

describe("P2 claimed-request deadline classification", () => {
  const now = new Date("2026-10-19T20:00:00.000Z");
  const owner = {
    operationId: "owned-operation", participantId: "owned-participant",
    canonicalEmail: "owner@nyu.edu", authorityVersion: 1,
  };
  const dependencies = { now: () => now };

  beforeEach(() => {
    vi.clearAllMocks();
    mocks.status.mockResolvedValue({ phase: "waiting", readinessGeneration: 1 });
    mocks.demote.mockResolvedValue(false);
  });

  it.each([
    ["missing", undefined],
    ["null", null],
    ["invalid Date", new Date(Number.NaN)],
    ["invalid string", "not-a-deadline"],
    ["empty string", ""],
    ["non-finite number", Number.POSITIVE_INFINITY],
    ["NaN", Number.NaN],
    ["object", {}],
    ["array", []],
    ["boolean", false],
  ])("keeps expired claimed work with a %s deadline blocking", async (_label, claimExpiresAt) => {
    mocks.requests.mockReturnValue([{
      status: "claimed", expiresAt: new Date(now.getTime() - 1000), claimExpiresAt,
    }]);
    for (let i = 0; i < 2; i++) {
      expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
        .toEqual({ outcome: "observed", requester: "unknown" });
    }
    expect(mocks.demote).toHaveBeenCalledWith(owner, 1, dependencies);
  });

  it.each([
    ["future Date", new Date(now.getTime() + 1000), "helperOrPickup"],
    ["future string", new Date(now.getTime() + 1000).toISOString(), "helperOrPickup"],
    ["expired Date", new Date(now.getTime() - 1000), "clear"],
    ["expired string", new Date(now.getTime() - 1000).toISOString(), "clear"],
    ["exact deadline", now, "clear"],
  ])("preserves R5 classification for a valid %s", async (_label, claimExpiresAt, requester) => {
    mocks.requests.mockReturnValue([{
      status: "claimed", expiresAt: new Date(now.getTime() - 1000), claimExpiresAt,
    }]);
    expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
      .toEqual({ outcome: "observed", requester });
    expect(mocks.demote).toHaveBeenCalledTimes(requester === "clear" ? 0 : 1);
  });
});

describe("P2 R3 placed-order pickup-confirmation classification", () => {
  const now = new Date("2026-10-22T20:00:00.000Z");
  const owner = {
    operationId: "owned-operation", participantId: "owned-participant",
    canonicalEmail: "owner@nyu.edu", authorityVersion: 1,
  };
  const dependencies = { now: () => now };

  beforeEach(() => {
    vi.clearAllMocks();
    mocks.status.mockResolvedValue({ phase: "waiting", readinessGeneration: 1 });
    mocks.demote.mockResolvedValue(false);
  });

  it("blocks a placed order with no pickup confirmation yet", async () => {
    mocks.requests.mockReturnValue([{ status: "placed" }]);
    expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
      .toEqual({ outcome: "observed", requester: "helperOrPickup" });
    expect(mocks.demote).toHaveBeenCalledWith(owner, 1, dependencies);
  });

  it("blocks a placed order with an explicit null pickup confirmation", async () => {
    mocks.requests.mockReturnValue([{ status: "placed", requesterPickupConfirmedAt: null }]);
    expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
      .toEqual({ outcome: "observed", requester: "helperOrPickup" });
  });

  it("clears a placed order once R3's authoritative pickup confirmation is set", async () => {
    mocks.requests.mockReturnValue([{
      status: "placed", requesterPickupConfirmedAt: new Date(now.getTime() - 1000),
    }]);
    expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
      .toEqual({ outcome: "observed", requester: "clear" });
    expect(mocks.demote).not.toHaveBeenCalled();
  });

  it.each([
    ["invalid Date", new Date(Number.NaN)],
    ["invalid string", "not-a-timestamp"],
    ["number", 12345],
    ["object", {}],
    ["boolean", true],
  ])("fails closed on malformed pickup confirmation (%s)", async (_label, requesterPickupConfirmedAt) => {
    mocks.requests.mockReturnValue([{ status: "placed", requesterPickupConfirmedAt }]);
    expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
      .toEqual({ outcome: "observed", requester: "unknown" });
    expect(mocks.demote).toHaveBeenCalledWith(owner, 1, dependencies);
  });

  it("does not let one confirmed placed order clear a separate active obligation", async () => {
    mocks.requests.mockReturnValue([
      { status: "placed", requesterPickupConfirmedAt: new Date(now.getTime() - 1000) },
      { status: "claimed", claimExpiresAt: new Date(now.getTime() + 1000) },
    ]);
    expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
      .toEqual({ outcome: "observed", requester: "helperOrPickup" });
  });

  it("an externally affirmed order still blocks regardless of placed/pickup state", async () => {
    mocks.requests.mockReturnValue([{
      status: "placed",
      requesterPickupConfirmedAt: new Date(now.getTime() - 1000),
      externalOrderAffirmed: true,
    }]);
    expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
      .toEqual({ outcome: "observed", requester: "helperOrPickup" });
  });
});

describe("P2 requester adapter dormant boundaries", () => {
  it("consumes accepted R5 lifecycle helpers", () => {
    expect(source).toContain('from "./requestOwnerReadRoute.js"');
    expect(source).toContain("deriveOwnerPhase(request, now)");
    expect(source).toContain("terminalOwnerOutcome(request)");
  });

  it("never performs or retries a request mutation or writes permanent ledgers", () => {
    expect(source).not.toMatch(/withdrawRequest|editRequest|RequestOperation|RequestParticipation|RequestUpdateOperation/);
    expect(source).not.toMatch(/MealRequest\.(update|delete|findOneAnd|create|bulkWrite)/);
  });

  it("can only demote P2, never grant readiness or completion", () => {
    expect(source).toContain("demoteParticipantDeletionReadiness");
    expect(source).not.toMatch(/promoteParticipantDeletionReadiness|issueParticipantDeletionChallenge|redeemParticipantDeletionChallenge|ParticipantDeletionOperation/);
    expect(app).not.toContain("participantDeletionRequesterAdapter");
  });

  it("does not accept a caller-selected request or a truncated owner list", () => {
    expect(source).toContain("requesterParticipantId: participantId");
    expect(source).toContain("owner.participantId");
    expect(source).not.toMatch(/requestId:|\.limit\(|getOwnerRequestList/);
  });
});
