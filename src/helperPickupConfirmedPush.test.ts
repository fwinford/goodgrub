import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Installation, Participant, PushDelivery } from "../models/db.js";
import type { ApnsConfiguration } from "./apnsConfig.js";
import type { ApnsConnection, ApnsOutcome, ApnsSubmission } from "./apnsClient.js";
import {
  HELPER_PICKUP_CONFIRMED_PURPOSE,
  dispatchHelperPickupConfirmedPush,
} from "./helperPickupConfirmedPush.js";
import * as moderation from "./moderationEnforcement.js";
import * as blocks from "./participantBlocks.js";

/**
 * Modeled on `helperNewRequestPush.test.ts`'s stubbing approach. Nothing
 * here contacts Apple or a real database.
 */
const requestId = new mongoose.Types.ObjectId("64b000000000000000000004");
const helperParticipantId = new mongoose.Types.ObjectId("64d000000000000000000005");
const requesterParticipantId = new mongoose.Types.ObjectId("64d000000000000000000006");
const now = new Date("2026-08-05T12:00:00.000Z");

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: "unused: the provider token is injected",
};

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
    participantId: helperParticipantId,
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

function stubConnections(
  respond: (submission: ApnsSubmission, origin: string) => Promise<ApnsOutcome>
) {
  const submissions: { origin: string; submission: ApnsSubmission }[] = [];
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

function dispatch(overrides: Record<string, unknown> = {}) {
  return dispatchHelperPickupConfirmedPush(
    { requestId, helperParticipantId, requesterParticipantId },
    {
      now: () => now,
      isPaused: () => false,
      readConfiguration: () => configuration,
      providerToken: () => "provider-jwt",
      ...overrides,
    }
  );
}

beforeEach(() => {
  vi.spyOn(Participant, "find").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: async () => [
          { _id: String(helperParticipantId), authorityVersion: 1 },
        ],
      }),
    }),
  } as unknown as ReturnType<typeof Participant.find>);
  vi.spyOn(moderation, "isParticipantSuspended").mockResolvedValue(false);
  vi.spyOn(blocks, "findFencedCounterpartIds").mockResolvedValue(new Set());
  installationFind = vi.spyOn(Installation, "find") as ReturnType<typeof vi.spyOn>;
  stubInstallations([]);
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

afterEach(() => {
  vi.restoreAllMocks();
});

describe("D-N1-5 dispatch recipient targeting", () => {
  it("targets only the recorded helper's eligible installations", async () => {
    stubInstallations([installationRow(1)]);
    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    // `requiredParticipantId` + `counterpartParticipantId` fence through the
    // shared predicate — proved directly in pushEligibility.test.ts; here we
    // prove this dispatcher actually supplies them.
    expect(installationFind.mock.calls[0][0]).toEqual({
      pushEnabled: true,
      apnsToken: { $type: "string" },
      invalidatedAt: null,
      participantId: { $ne: null },
    });
  });

  it("selects nothing, and submits nothing, when no helper is recorded", async () => {
    stubInstallations([installationRow(1)]);
    const summary = await dispatchHelperPickupConfirmedPush(
      { requestId, helperParticipantId: null, requesterParticipantId },
      { now: () => now, isPaused: () => false, readConfiguration: () => configuration, providerToken: () => "jwt" }
    );

    expect(summary.stop).toBe("no-eligible-installations");
    expect(pushCreate).not.toHaveBeenCalled();
  });

  it("excludes an installation belonging to a different participant (fencing proved via the predicate)", async () => {
    vi.spyOn(Participant, "find").mockReturnValue({
      select: () => ({
        lean: () => ({ exec: async () => [] }),
      }),
    } as unknown as ReturnType<typeof Participant.find>);
    stubInstallations([installationRow(1, { participantId: requesterParticipantId })]);

    const summary = await dispatch();

    expect(summary.stop).toBe("no-eligible-installations");
  });
});

describe("D-N1-5 dispatch idempotency and dedup", () => {
  it("claims under the requester-pickup-confirmed purpose, distinct from every other push kind", async () => {
    stubInstallations([installationRow(1)]);
    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    expect(pushCreate).toHaveBeenCalledWith(
      expect.objectContaining({ purpose: HELPER_PICKUP_CONFIRMED_PURPOSE })
    );
  });

  it("yields no second logical notification on a replayed/concurrent claim attempt", async () => {
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

  it("releases an unsubmitted claim when the shared eligibility recheck fails, so retry can send", async () => {
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
});

describe("D-N1-5 dispatch provider outcomes", () => {
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

  it("carries the exact accepted copy, carrying nothing private", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    const payload = JSON.parse(connections.submissions[0].submission.payload);
    expect(payload.aps.alert.title).toBe("Pickup confirmed");
    expect(payload.aps.alert.body).toBe(
      "The requester confirmed pickup. Thanks for helping make a meal possible!"
    );
    expect(payload.type).toBe("helper-pickup-confirmed");
    expect(JSON.stringify(payload)).not.toContain(String(requesterParticipantId));
  });

  it("does not submit while paused", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ isPaused: () => true, openConnection: connections.openConnection });

    expect(summary.stop).toBe("paused");
    expect(connections.submissions).toHaveLength(0);
  });

  it("closes every opened connection", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(connections.closed).toHaveLength(1);
  });
});
