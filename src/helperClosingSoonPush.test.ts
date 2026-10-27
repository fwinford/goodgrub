import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Installation,
  Participant,
  PushDelivery,
  Request as MealRequest,
  type IRequest,
} from "../models/db.js";
import type { ApnsConfiguration } from "./apnsConfig.js";
import type { ApnsConnection, ApnsOutcome, ApnsSubmission } from "./apnsClient.js";
import {
  HELPER_CLOSING_SOON_PURPOSE,
  dispatchHelperClosingSoonPush,
} from "./helperClosingSoonPush.js";
import { helperPushInitiation } from "./helperNewRequestPush.js";
import * as moderation from "./moderationEnforcement.js";

/**
 * Modeled on `helperNewRequestPush.test.ts`'s stubbing approach: no case
 * contacts Apple or a real database. Real persistence/concurrency behavior
 * belongs in a future `.mongo.test.ts` companion, matching the existing
 * module's split.
 */
const requestId = new mongoose.Types.ObjectId("64b000000000000000000002");
const now = new Date("2026-07-28T16:00:00.000Z");
const expiresAt = new Date("2026-07-28T16:12:00.000Z");

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: "unused: the provider token is injected",
};

function requestDocument(overrides: Record<string, unknown> = {}): IRequest {
  return {
    _id: requestId,
    vendor: "Crave NYU",
    food: "Burrito bowl",
    pickupWindowText: "ASAP (available for the next 3 hours)",
    status: "open",
    mealSwipes: 1,
    expiresAt,
    ...overrides,
  } as unknown as IRequest;
}

function installationRow(
  index: number,
  overrides: Record<string, unknown> = {}
) {
  return {
    _id: new mongoose.Types.ObjectId(
      `64c${index.toString(16).padStart(21, "0")}`
    ),
    apnsToken: index.toString(16).padStart(64, "a"),
    apnsEnvironment: "development",
    participantId: new mongoose.Types.ObjectId("64d000000000000000000002"),
    participantAuthorityVersion: 1,
    ...overrides,
  };
}

const accepted: ApnsOutcome = {
  classification: "accepted",
  status: 200,
  reason: "Accepted",
  apnsId: "apns-1",
};

let installationFind: ReturnType<typeof vi.spyOn>;
let requestFind: ReturnType<typeof vi.spyOn>;
let pushCreate: ReturnType<typeof vi.spyOn>;
let pushDelete: ReturnType<typeof vi.spyOn>;

function stubInstallations(rows: Record<string, unknown>[]): void {
  installationFind.mockImplementation(() => ({
    select() {
      return this;
    },
    lean() {
      return this;
    },
    exec: async () => rows,
  }));
}

function duplicateKeyError(): Error {
  return Object.assign(new Error("E11000 duplicate key"), { code: 11000 });
}

interface RecordedSubmission {
  origin: string;
  submission: ApnsSubmission;
}

function stubConnections(
  respond: (submission: ApnsSubmission, origin: string) => Promise<ApnsOutcome>
) {
  const submissions: RecordedSubmission[] = [];
  const closed: string[] = [];
  const openConnection = vi.fn((origin: string): ApnsConnection => ({
    async submit(submission) {
      submissions.push({ origin, submission });
      return respond(submission, origin);
    },
    close() {
      closed.push(origin);
    },
  }));
  return { openConnection, submissions, closed };
}

function dispatch(
  overrides: Record<string, unknown> = {},
  request: IRequest = requestDocument()
) {
  return dispatchHelperClosingSoonPush(request, {
    now: () => now,
    isPaused: () => false,
    readConfiguration: () => configuration,
    providerToken: () => "provider-jwt",
    ...overrides,
  });
}

beforeEach(() => {
  vi.spyOn(Participant, "find").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: async () => [{ _id: "64d000000000000000000002", authorityVersion: 1 }],
      }),
    }),
  } as unknown as ReturnType<typeof Participant.find>);
  vi.spyOn(moderation, "isParticipantSuspended").mockResolvedValue(false);
  installationFind = vi.spyOn(Installation, "find") as ReturnType<typeof vi.spyOn>;
  stubInstallations([]);
  requestFind = vi.spyOn(MealRequest, "findOne").mockImplementation(
    (async () => requestDocument()) as never
  );
  pushCreate = vi
    .spyOn(PushDelivery, "create")
    .mockImplementation((async () => ({
      _id: new mongoose.Types.ObjectId(),
    })) as never);
  vi.spyOn(PushDelivery, "updateOne").mockReturnValue({
    exec: async () => ({ modifiedCount: 1 }),
  } as never);
  pushDelete = vi.spyOn(PushDelivery, "deleteOne").mockReturnValue({
    exec: async () => ({ deletedCount: 1 }),
  } as never);
  vi.spyOn(Installation, "updateOne").mockReturnValue({
    exec: async () => ({ modifiedCount: 1 }),
  } as never);
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

function mockRetryableClaimLedger(): Set<string> {
  const outstanding = new Set<string>();
  pushCreate.mockImplementation(async (document: Record<string, unknown>) => {
    const key = `${String(document.requestId)}:${String(document.installationId)}:${String(document.purpose)}`;
    if (outstanding.has(key)) throw duplicateKeyError();
    outstanding.add(key);
    return { _id: key };
  });
  pushDelete.mockImplementation((filter: Record<string, unknown>) => ({
    exec: async () => ({
      deletedCount: outstanding.delete(String(filter._id)) ? 1 : 0,
    }),
  }) as never);
  return outstanding;
}

describe("closing-soon push dispatch", () => {
  it("uses the closing-soon purpose for its delivery claim, distinct from the initial push", async () => {
    stubInstallations([installationRow(1)]);
    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    expect(pushCreate).toHaveBeenCalledWith(
      expect.objectContaining({ purpose: HELPER_CLOSING_SOON_PURPOSE })
    );
  });

  it("submits for every eligible installation", async () => {
    stubInstallations([installationRow(1), installationRow(2)]);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.eligible).toBe(2);
    expect(summary.accepted).toBe(2);
    expect(connections.submissions).toHaveLength(2);
  });

  it("reuses the shared N1 eligibility predicate, not a parallel one", async () => {
    stubInstallations([installationRow(1)]);
    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    // The same query shape `selectEligiblePushInstallations` builds —
    // proving this dispatcher selects through the shared predicate rather
    // than re-deriving eligibility.
    expect(installationFind.mock.calls[0][0]).toEqual({
      pushEnabled: true,
      apnsToken: { $type: "string" },
      invalidatedAt: null,
      participantId: { $ne: null },
    });
  });

  it("classifies with the shared helperPushInitiation rule: processed", async () => {
    stubInstallations([installationRow(1)]);
    const summary = await dispatch({
      openConnection: stubConnections(async () => accepted).openConnection,
    });

    expect(helperPushInitiation(summary)).toBe("processed");
  });

  it("classifies as retryable when paused", async () => {
    const summary = await dispatch({ isPaused: () => true });
    expect(summary.stop).toBe("paused");
    expect(helperPushInitiation(summary)).toBe("retryable");
  });

  it("is a no-op with no eligible installations, and still processed", async () => {
    stubInstallations([]);
    const summary = await dispatch();

    expect(summary.stop).toBe("no-eligible-installations");
    expect(helperPushInitiation(summary)).toBe("processed");
  });

  it("stops without claiming when the request became unavailable before dispatch", async () => {
    vi.spyOn(MealRequest, "findOne").mockImplementation((async () => null) as never);
    stubInstallations([installationRow(1)]);

    const summary = await dispatch();

    expect(summary.stop).toBe("unavailable");
    expect(pushCreate).not.toHaveBeenCalled();
    expect(helperPushInitiation(summary)).toBe("retryable");
  });

  it("releases a claim when the post-claim current-request read fails, so a retry can send", async () => {
    stubInstallations([installationRow(1)]);
    const outstanding = mockRetryableClaimLedger();
    requestFind
      .mockImplementationOnce((async () => requestDocument()) as never)
      .mockRejectedValueOnce(new Error("Mongo read failed"))
      .mockImplementation((async () => requestDocument()) as never);
    const connections = stubConnections(async () => accepted);

    await expect(
      dispatch({ openConnection: connections.openConnection })
    ).rejects.toThrow("Mongo read failed");
    expect(outstanding.size).toBe(0);
    expect(connections.submissions).toHaveLength(0);

    const retried = await dispatch({ openConnection: connections.openConnection });
    expect(retried.accepted).toBe(1);
    expect(connections.submissions).toHaveLength(1);
  });

  it("releases a claim when the post-claim eligibility recheck fails, so a retry can send", async () => {
    stubInstallations([installationRow(1)]);
    const outstanding = mockRetryableClaimLedger();
    const selectInstallations = installationFind.getMockImplementation()!;
    installationFind
      .mockImplementationOnce(selectInstallations)
      .mockImplementationOnce(() => {
        throw new Error("eligibility read failed");
      })
      .mockImplementation(selectInstallations);
    const connections = stubConnections(async () => accepted);

    await expect(
      dispatch({ openConnection: connections.openConnection })
    ).rejects.toThrow("eligibility read failed");
    expect(outstanding.size).toBe(0);
    expect(connections.submissions).toHaveLength(0);

    const retried = await dispatch({ openConnection: connections.openConnection });
    expect(retried.accepted).toBe(1);
    expect(connections.submissions).toHaveLength(1);
  });

  it("does not duplicate a claim already owned by another dispatch (replay-safe)", async () => {
    stubInstallations([installationRow(1)]);
    pushCreate.mockImplementation(async () => {
      throw duplicateKeyError();
    });

    const summary = await dispatch({
      openConnection: stubConnections(async () => accepted).openConnection,
    });

    expect(summary.duplicate).toBe(1);
    expect(summary.accepted).toBe(0);
  });

  it("retires the installation's token on a token-rejected outcome", async () => {
    stubInstallations([installationRow(1)]);
    const installationUpdate = vi.spyOn(Installation, "updateOne");

    const summary = await dispatch({
      openConnection: stubConnections(async () => ({
        classification: "token-rejected",
        status: 410,
        reason: "Unregistered",
      })).openConnection,
    });

    expect(summary.rejected).toBe(1);
    expect(summary.retired).toBe(1);
    expect(installationUpdate).toHaveBeenCalled();
  });

  it("abandons the remaining fan-out on a provider-auth refusal", async () => {
    stubInstallations([installationRow(1), installationRow(2)]);
    let calls = 0;
    const connections = stubConnections(async () => {
      calls += 1;
      return { classification: "provider-auth", status: 403, reason: "InvalidProviderToken" };
    });

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("provider-auth");
    expect(calls).toBe(1);
  });

  it("closes every opened connection", async () => {
    stubInstallations([
      installationRow(1, { apnsEnvironment: "development" }),
      installationRow(2, { apnsEnvironment: "production" }),
    ]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(connections.closed).toHaveLength(2);
  });

  it("carries the closing-soon title/body, not the initial discovery copy", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection }, requestDocument({ mealSwipes: 1 }));

    const payload = JSON.parse(connections.submissions[0].submission.payload);
    expect(payload.aps.alert.title).toBe("1 meal swipe");
    expect(payload.aps.alert.subtitle).toBe("Closing in 15 min");
    expect(payload.aps.alert.body).toBe("Crave NYU");
  });
});
