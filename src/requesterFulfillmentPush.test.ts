import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Installation,
  Participant,
  PushDelivery,
  type IRequest,
} from "../models/db.js";
import type { ApnsConfiguration } from "./apnsConfig.js";
import type { ApnsConnection, ApnsOutcome, ApnsSubmission } from "./apnsClient.js";
import {
  REQUESTER_FULFILLMENT_PURPOSE,
  REQUESTER_FULFILLMENT_RETENTION_MS,
  dispatchRequesterFulfillmentPush,
  startRequesterFulfillmentPush,
} from "./requesterFulfillmentPush.js";
import * as moderation from "./moderationEnforcement.js";

/**
 * The dispatcher, exercised against stubbed models and a stubbed provider
 * connection — the same approach `helperNewRequestPush.test.ts` uses. Real
 * persistence behavior lives in `requesterFulfillmentPush.mongo.test.ts`.
 */
const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const installationId = new mongoose.Types.ObjectId("64c000000000000000000001");
const participantId = new mongoose.Types.ObjectId("64d000000000000000000001");
const now = new Date("2026-08-05T12:00:00.000Z");

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: "unused: the provider token is injected",
};

function placedRequestDocument(overrides: Record<string, unknown> = {}): IRequest {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    pickupWindowText: "ASAP (available for the next 3 hours)",
    status: "placed",
    installationId,
    requesterParticipantId: participantId,
    ...overrides,
  } as unknown as IRequest;
}

function installationRow(overrides: Record<string, unknown> = {}) {
  return {
    _id: installationId,
    apnsToken: "a".repeat(64),
    apnsEnvironment: "development",
    participantId,
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

let installationFindOne: ReturnType<typeof vi.spyOn>;
let pushCreate: ReturnType<typeof vi.spyOn>;
let pushUpdate: ReturnType<typeof vi.spyOn>;
let installationUpdate: ReturnType<typeof vi.spyOn>;
let selectionFilter: unknown;
let selectedProjection: unknown;

function stubInstallation(row: Record<string, unknown> | null): void {
  installationFindOne.mockImplementation((filter: unknown) => {
    selectionFilter = filter;
    return {
      select(projection: unknown) {
        selectedProjection = projection;
        return this;
      },
      lean() {
        return this;
      },
      exec: async () => row ? [row] : [],
    };
  });
}

function duplicateKeyError(): Error {
  return Object.assign(new Error("E11000 duplicate key"), { code: 11000 });
}

interface RecordedSubmission {
  origin: string;
  submission: ApnsSubmission;
  timeoutMs: number;
}

function stubConnection(
  respond: (submission: ApnsSubmission) => Promise<ApnsOutcome> | ApnsOutcome
) {
  const submissions: RecordedSubmission[] = [];
  const opened: string[] = [];
  const closed: string[] = [];

  const openConnection = vi.fn((origin: string): ApnsConnection => {
    opened.push(origin);
    return {
      async submit(submission, timeoutMs) {
        submissions.push({ origin, submission, timeoutMs });
        return respond(submission);
      },
      close() {
        closed.push(origin);
      },
    };
  });

  return { openConnection, submissions, opened, closed };
}

function dispatch(
  overrides: Record<string, unknown> = {},
  request: IRequest = placedRequestDocument()
) {
  return dispatchRequesterFulfillmentPush(request, {
    now: () => now,
    isPaused: () => false,
    readConfiguration: () => configuration,
    providerToken: () => "provider-jwt",
    ...overrides,
  });
}

beforeEach(() => {
  vi.spyOn(Participant, "find").mockReturnValue({
    select: () => ({ lean: () => ({ exec: async () => [{ _id: participantId, authorityVersion: 1 }] }) }),
  } as unknown as ReturnType<typeof Participant.find>);
  vi.spyOn(moderation, "isParticipantSuspended").mockResolvedValue(false);
  installationFindOne = vi.spyOn(Installation, "find") as ReturnType<typeof vi.spyOn>;
  stubInstallation(null);
  pushCreate = vi
    .spyOn(PushDelivery, "create")
    .mockImplementation((async () => ({
      _id: new mongoose.Types.ObjectId(),
    })) as never) as ReturnType<typeof vi.spyOn>;
  pushUpdate = vi
    .spyOn(PushDelivery, "updateOne")
    .mockReturnValue({ exec: async () => ({ modifiedCount: 1 }) } as never) as ReturnType<
      typeof vi.spyOn
    >;
  installationUpdate = vi
    .spyOn(Installation, "updateOne")
    .mockReturnValue({ exec: async () => ({ modifiedCount: 1 }) } as never) as ReturnType<
      typeof vi.spyOn
    >;
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  selectionFilter = undefined;
  selectedProjection = undefined;
});

describe("requester fulfillment push guards before any delivery record", () => {
  it("returns through the pause before reading the installation", async () => {
    stubInstallation(installationRow());
    const connections = stubConnection(async () => accepted);

    const summary = await dispatch({
      isPaused: () => true,
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("paused");
    expect(installationFindOne).not.toHaveBeenCalled();
    expect(pushCreate).not.toHaveBeenCalled();
    expect(connections.submissions).toHaveLength(0);
  });

  it("skips with no fallback recipient when the request has no installation association", async () => {
    stubInstallation(installationRow());
    const connections = stubConnection(async () => accepted);

    const summary = await dispatch(
      { openConnection: connections.openConnection },
      placedRequestDocument({ installationId: undefined })
    );

    expect(summary.stop).toBe("no-association");
    expect(installationFindOne).not.toHaveBeenCalled();
    expect(pushCreate).not.toHaveBeenCalled();
  });

  it("stops before any claim when provider configuration is unreadable", async () => {
    stubInstallation(installationRow());
    const connections = stubConnection(async () => accepted);

    const summary = await dispatch({
      readConfiguration: () => {
        throw new Error("APNS_TEAM_ID missing");
      },
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("configuration");
    expect(installationFindOne).not.toHaveBeenCalled();
    expect(pushCreate).not.toHaveBeenCalled();
  });

  it("selects only the request's own associated installation, by id", async () => {
    stubInstallation(installationRow());
    const connections = stubConnection(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(selectionFilter).toEqual({
      _id: installationId,
      pushEnabled: true,
      apnsToken: { $type: "string" },
      invalidatedAt: null,
      participantId: { $ne: null },
    });
  });

  it("asks for the select:false apnsToken explicitly", async () => {
    stubInstallation(installationRow());
    const connections = stubConnection(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(String(selectedProjection)).toContain("+apnsToken");
  });

  it("skips quietly when the associated installation is absent, disabled, or invalidated", async () => {
    // The eligibility filter itself (pushEnabled: true, invalidatedAt: null)
    // is what a disabled/invalidated installation fails to match — Mongo
    // returns null, exactly like an installation that never existed.
    stubInstallation(null);
    const connections = stubConnection(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.stop).toBe("no-eligible-installation");
    expect(pushCreate).not.toHaveBeenCalled();
    expect(connections.submissions).toHaveLength(0);
  });

  it("skips an installation whose stored environment is unusable, never defaulting it", async () => {
    stubInstallation(installationRow({ apnsEnvironment: undefined }));
    const connections = stubConnection(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.stop).toBe("no-eligible-installation");
    expect(pushCreate).not.toHaveBeenCalled();
  });

  it("routes to the host for the installation's own stored environment", async () => {
    stubInstallation(installationRow({ apnsEnvironment: "production" }));
    const connections = stubConnection(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(connections.opened).toEqual(["https://api.push.apple.com:443"]);
  });
});

describe("requester fulfillment push deduplication", () => {
  it("claims the identity triple before submitting", async () => {
    stubInstallation(installationRow());
    const connections = stubConnection(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(pushCreate).toHaveBeenCalledWith(
      expect.objectContaining({
        requestId,
        installationId,
        purpose: REQUESTER_FULFILLMENT_PURPOSE,
        status: "claimed",
      })
    );
    expect(pushCreate.mock.invocationCallOrder[0]).toBeLessThan(
      connections.openConnection.mock.invocationCallOrder[0]
    );
  });

  it("uses a distinct purpose from the helper new-request push", () => {
    expect(REQUESTER_FULFILLMENT_PURPOSE).toBe("requester-fulfillment");
    expect(REQUESTER_FULFILLMENT_PURPOSE).not.toBe("helper-new-request");
  });

  it("sets the TTL a day past dispatch time", async () => {
    stubInstallation(installationRow());

    await dispatch({ openConnection: stubConnection(async () => accepted).openConnection });

    const claim = pushCreate.mock.calls[0][0] as { deleteAt: Date };
    expect(claim.deleteAt).toEqual(
      new Date(now.getTime() + REQUESTER_FULFILLMENT_RETENTION_MS)
    );
  });

  it("skips submission when another dispatch already owns this triple", async () => {
    stubInstallation(installationRow());
    pushCreate.mockRejectedValue(duplicateKeyError());
    const connections = stubConnection(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.duplicate).toBe(1);
    expect(summary.claimed).toBe(0);
    expect(connections.submissions).toHaveLength(0);
  });

  it("records nothing and submits nothing when the claim fails for another reason", async () => {
    stubInstallation(installationRow());
    pushCreate.mockRejectedValue(new Error("database unavailable"));
    const connections = stubConnection(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.failed).toBe(1);
    expect(connections.submissions).toHaveLength(0);
    expect(pushUpdate).not.toHaveBeenCalled();
  });

  it("stores no token, credential, or request content on the claim", async () => {
    stubInstallation(installationRow());

    await dispatch({ openConnection: stubConnection(async () => accepted).openConnection });

    const claim = JSON.stringify(pushCreate.mock.calls[0][0]);
    expect(claim).not.toContain("a".repeat(64));
    expect(claim).not.toContain("Campus Market");
    expect(claim).not.toContain("requester@nyu.edu");
    expect(claim).not.toContain("Requester Private Name");
  });
});

describe("requester fulfillment push submission and provider outcomes", () => {
  it("submits the fixed-copy payload with the bounded submission timeout", async () => {
    stubInstallation(installationRow());
    const connections = stubConnection(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    const [entry] = connections.submissions;
    expect(entry.timeoutMs).toBe(10_000);
    expect(entry.submission.headers["apns-push-type"]).toBe("alert");
    expect(entry.submission.headers["apns-topic"]).toBe(configuration.bundleId);
    expect(entry.submission.headers.authorization).toBe("bearer provider-jwt");
    expect(JSON.parse(entry.submission.payload)).toMatchObject({
      type: "requester-order-placed",
      requestId: requestId.toString(),
    });
  });

  it("records an APNs 200 as an accepted submission with its apns-id", async () => {
    stubInstallation(installationRow());

    const summary = await dispatch({
      openConnection: stubConnection(async () => accepted).openConnection,
    });

    expect(summary.accepted).toBe(1);
    expect(pushUpdate).toHaveBeenCalledWith(
      expect.any(Object),
      expect.objectContaining({
        $set: expect.objectContaining({ status: "accepted", apnsId: "apns-1" }),
      })
    );
    expect(installationUpdate).not.toHaveBeenCalled();
  });

  it.each([
    [410, "Unregistered"],
    [400, "BadDeviceToken"],
  ])("retires the exact token on a terminal %i %s rejection", async (status, reason) => {
    const row = installationRow();
    stubInstallation(row);

    const summary = await dispatch({
      openConnection: stubConnection(async () => ({
        classification: "token-rejected" as const,
        status,
        reason,
      })).openConnection,
    });

    expect(summary.rejected).toBe(1);
    expect(summary.retired).toBe(1);
    expect(installationUpdate).toHaveBeenCalledWith(
      {
        _id: row._id,
        apnsToken: row.apnsToken,
        apnsEnvironment: "development",
        pushEnabled: true,
      },
      {
        $set: {
          pushEnabled: false,
          invalidatedAt: expect.any(Date),
          updatedAt: expect.any(Date),
        },
      }
    );
  });

  it("treats a retirement that matches zero documents as expected, not an error", async () => {
    installationUpdate.mockReturnValue({
      exec: async () => ({ modifiedCount: 0 }),
    } as never);
    stubInstallation(installationRow());

    const summary = await dispatch({
      openConnection: stubConnection(async () => ({
        classification: "token-rejected" as const,
        status: 410,
        reason: "Unregistered",
      })).openConnection,
    });

    expect(summary.rejected).toBe(1);
    expect(summary.retired).toBe(0);
    expect(summary.stop).toBe("completed");
  });

  it.each([
    ["transient", 429, "TooManyRequests"],
    ["transient", 503, "ServiceUnavailable"],
    ["provider-auth", 403, "ExpiredProviderToken"],
    ["configuration", 400, "BadTopic"],
  ] as const)(
    "records a %s %i %s as failed and never retires a token",
    async (classification, status, reason) => {
      stubInstallation(installationRow());

      const summary = await dispatch({
        openConnection: stubConnection(async () => ({
          classification,
          status,
          reason,
        })).openConnection,
      });

      expect(summary.failed).toBe(1);
      expect(summary.stop).toBe("completed");
      expect(installationUpdate).not.toHaveBeenCalled();
      expect(pushUpdate).toHaveBeenCalledWith(
        expect.any(Object),
        expect.objectContaining({ $set: expect.objectContaining({ status: "failed" }) })
      );
    }
  );

  it("contains a connection that throws instead of resolving", async () => {
    stubInstallation(installationRow());
    const openConnection = vi.fn(
      (): ApnsConnection => ({
        async submit() {
          throw new Error("provider exploded");
        },
        close() {},
      })
    );

    const summary = await dispatch({ openConnection });

    expect(summary.failed).toBe(1);
    expect(summary.stop).toBe("completed");
  });

  it("closes the connection it opened", async () => {
    stubInstallation(installationRow());
    const connections = stubConnection(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(connections.closed).toEqual(connections.opened);
  });

  it("logs no token, provider token, or raw provider error", async () => {
    const logged: unknown[] = [];
    (console.log as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (...args: unknown[]) => logged.push(args)
    );
    (console.error as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (...args: unknown[]) => logged.push(args)
    );
    const row = installationRow();
    stubInstallation(row);

    await dispatch({
      openConnection: stubConnection(async () => ({
        classification: "token-rejected" as const,
        status: 410,
        reason: "Unregistered",
      })).openConnection,
    });

    const text = JSON.stringify(logged);
    expect(text).not.toContain(row.apnsToken);
    expect(text).not.toContain("provider-jwt");
    expect(text).not.toContain("bearer");
  });
});

describe("requester fulfillment push persistence failures", () => {
  it("records persistenceFailed without reinterpreting a successful provider outcome", async () => {
    stubInstallation(installationRow());
    pushUpdate.mockReturnValue({
      exec: async () => {
        throw new Error("outcome write failed");
      },
    } as never);

    const summary = await dispatch({
      openConnection: stubConnection(async () => accepted).openConnection,
    });

    expect(summary.accepted).toBe(1);
    expect(summary.persistenceFailed).toBe(1);
  });

  it("does not count a failed retirement write as a retirement", async () => {
    stubInstallation(installationRow());
    installationUpdate.mockReturnValue({
      exec: async () => {
        throw new Error("retirement write failed");
      },
    } as never);

    const summary = await dispatch({
      openConnection: stubConnection(async () => ({
        classification: "token-rejected" as const,
        status: 410,
        reason: "Unregistered",
      })).openConnection,
    });

    expect(summary.rejected).toBe(1);
    expect(summary.retired).toBe(0);
    expect(summary.persistenceFailed).toBe(1);
  });
});

describe("the total start function", () => {
  it("returns void and never throws when dispatch rejects", async () => {
    installationFindOne.mockImplementation(() => {
      throw new Error("selection exploded");
    });
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);

    try {
      expect(startRequesterFulfillmentPush(placedRequestDocument())).toBeUndefined();
      await new Promise((resolve) => setTimeout(resolve, 10));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    expect(rejections).toEqual([]);
  });

  it("contains a synchronous setup failure", () => {
    const broken = { get _id() {
      throw new Error("identity exploded");
    } } as unknown as IRequest;

    expect(() => startRequesterFulfillmentPush(broken)).not.toThrow();
  });
});
