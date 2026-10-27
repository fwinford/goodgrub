import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Installation,
  Participant,
  PushDelivery,
  Request as MealRequest,
  SendLog,
  Subscriber,
  System,
  type IRequest,
} from "../models/db.js";
import type { ApnsConfiguration } from "./apnsConfig.js";
import type { ApnsConnection, ApnsOutcome, ApnsSubmission } from "./apnsClient.js";
import {
  HELPER_NEW_REQUEST_PURPOSE,
  PUSH_DELIVERY_RETENTION_MS,
  dispatchHelperNewRequestPush,
  helperPushInitiation,
  startHelperNewRequestPush,
  type HelperPushDispatchSummary,
} from "./helperNewRequestPush.js";
import * as moderation from "./moderationEnforcement.js";

/**
 * The dispatcher, exercised against stubbed models and a stubbed provider
 * connection. No case contacts Apple or needs real credentials; the real
 * HTTP/2 behavior is covered in `apnsClient.test.ts` and the real persistence
 * behavior in `helperNewRequestPush.mongo.test.ts`.
 */
const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const now = new Date("2026-07-28T16:00:00.000Z");
/** Three hours after `now`: the W3-R1 ASAP lifetime the window text states. */
const expiresAt = new Date("2026-07-28T19:00:00.000Z");

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: "unused: the provider token is injected",
};

function requestDocument(overrides: Record<string, unknown> = {}): IRequest {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
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
    participantId: new mongoose.Types.ObjectId("64d000000000000000000001"),
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
let requestExists: ReturnType<typeof vi.spyOn>;
let pushCreate: ReturnType<typeof vi.spyOn>;
let pushUpdate: ReturnType<typeof vi.spyOn>;
let pushDelete: ReturnType<typeof vi.spyOn>;
let installationUpdate: ReturnType<typeof vi.spyOn>;
let selectedProjection: unknown;
let selectionFilter: unknown;

function stubInstallations(rows: Record<string, unknown>[]): void {
  installationFind.mockImplementation((filter: unknown) => {
    selectionFilter = filter;
    return {
      select(projection: unknown) {
        selectedProjection = projection;
        return this;
      },
      lean() {
        return this;
      },
      exec: async () => rows,
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

function stubConnections(
  respond: (submission: ApnsSubmission, origin: string) => Promise<ApnsOutcome>
) {
  const submissions: RecordedSubmission[] = [];
  const opened: string[] = [];
  const closed: string[] = [];

  const openConnection = vi.fn((origin: string): ApnsConnection => {
    opened.push(origin);
    return {
      async submit(submission, timeoutMs) {
        submissions.push({ origin, submission, timeoutMs });
        return respond(submission, origin);
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
  request: IRequest = requestDocument()
) {
  return dispatchHelperNewRequestPush(request, {
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
        exec: async () => [{ _id: "64d000000000000000000001", authorityVersion: 1 }],
      }),
    }),
  } as unknown as ReturnType<typeof Participant.find>);
  vi.spyOn(moderation, "isParticipantSuspended").mockResolvedValue(false);
  installationFind = vi.spyOn(Installation, "find") as ReturnType<typeof vi.spyOn>;
  stubInstallations([]);
  // W4-R5: the availability and notification-generation re-check is the shared
  // dispatch guard, which reads the current document.
  requestExists = vi
    .spyOn(MealRequest, "findOne")
    .mockImplementation((async () => requestDocument()) as never) as ReturnType<
      typeof vi.spyOn
    >;
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
  pushDelete = vi
    .spyOn(PushDelivery, "deleteOne")
    .mockReturnValue({ exec: async () => ({ deletedCount: 1 }) } as never) as ReturnType<
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
  selectedProjection = undefined;
  selectionFilter = undefined;
});

describe("helper push eligibility selection", () => {
  it("selects push-enabled, tokened, non-invalidated installations only", async () => {
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    expect(installationFind.mock.calls[0][0]).toEqual({
      pushEnabled: true,
      apnsToken: { $type: "string" },
      invalidatedAt: null,
      participantId: { $ne: null },
    });
  });

  it("asks for the select:false apnsToken explicitly", async () => {
    // A query that forgets this silently selects zero deliverable
    // installations, because the schema hides the token from projections.
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    expect(String(selectedProjection)).toContain("+apnsToken");
  });

  it("submits for every eligible installation, with no cap or round-robin", async () => {
    const rows = Array.from({ length: 25 }, (_, index) =>
      installationRow(index + 1)
    );
    stubInstallations(rows);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.eligible).toBe(25);
    expect(summary.accepted).toBe(25);
    expect(connections.submissions).toHaveLength(25);
    expect(
      new Set(connections.submissions.map((entry) => entry.submission.deviceToken))
        .size
    ).toBe(25);
  });

  it.each([undefined, null, "", "sandbox", "Development"])(
    "skips an installation whose stored environment is %j, never defaulting it",
    async (environment) => {
      stubInstallations([
        installationRow(1, { apnsEnvironment: environment }),
        installationRow(2),
      ]);
      const connections = stubConnections(async () => accepted);

      const summary = await dispatch({ openConnection: connections.openConnection });

      expect(summary.skippedEnvironment).toBe(1);
      expect(summary.eligible).toBe(1);
      expect(connections.submissions).toHaveLength(1);
      expect(pushCreate).toHaveBeenCalledTimes(1);
    }
  );

  it("routes each installation to the host for its own stored environment", async () => {
    stubInstallations([
      installationRow(1, { apnsEnvironment: "development" }),
      installationRow(2, { apnsEnvironment: "production" }),
    ]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(new Set(connections.opened)).toEqual(
      new Set([
        "https://api.sandbox.push.apple.com:443",
        "https://api.push.apple.com:443",
      ])
    );
    expect(connections.closed).toHaveLength(2);
  });

  it("opens one connection per host per dispatch", async () => {
    stubInstallations([
      installationRow(1, { apnsEnvironment: "development" }),
      installationRow(2, { apnsEnvironment: "development" }),
      installationRow(3, { apnsEnvironment: "production" }),
    ]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(connections.openConnection).toHaveBeenCalledTimes(2);
  });

  it("reads and writes nothing belonging to the email channel", async () => {
    const forbidden = [
      vi.spyOn(Subscriber, "find"),
      vi.spyOn(Subscriber, "updateOne"),
      vi.spyOn(SendLog, "create"),
      vi.spyOn(SendLog, "exists"),
      vi.spyOn(SendLog, "updateOne"),
      vi.spyOn(System, "findOne"),
      vi.spyOn(System, "updateOne"),
    ];
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    for (const spy of forbidden) expect(spy).not.toHaveBeenCalled();
  });
});

describe("helper push guards before any delivery record", () => {
  it("returns through the pause before writing a PushDelivery row", async () => {
    // The dispatcher can be called directly, so a suppressed notification must
    // leave no delivery record behind.
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({
      isPaused: () => true,
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("paused");
    expect(requestExists).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
    expect(pushCreate).not.toHaveBeenCalled();
    expect(connections.submissions).toHaveLength(0);
  });

  it("re-checks effective availability and skips a request claimed since creation", async () => {
    requestExists.mockResolvedValue(null);
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.stop).toBe("unavailable");
    expect(requestExists).toHaveBeenCalledWith(
      expect.objectContaining({
        $and: expect.arrayContaining([
          { _id: requestId },
          expect.objectContaining({ expiresAt: expect.any(Object) }),
        ]),
      }),
      "+notificationGeneration +contentRevision +requesterParticipantId",
      { lean: true }
    );
    expect(pushCreate).not.toHaveBeenCalled();
    expect(connections.submissions).toHaveLength(0);
  });

  it("stops before any claim when provider configuration is unreadable", async () => {
    const connections = stubConnections(async () => accepted);
    stubInstallations([installationRow(1)]);

    const summary = await dispatch({
      readConfiguration: () => {
        throw new Error("APNS_TEAM_ID missing");
      },
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("configuration");
    expect(pushCreate).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
  });

  it("stops before any claim when the payload cannot be built", async () => {
    const connections = stubConnections(async () => accepted);
    stubInstallations([installationRow(1)]);

    const summary = await dispatch(
      { openConnection: connections.openConnection },
      requestDocument({ expiresAt: undefined })
    );

    expect(summary.stop).toBe("configuration");
    expect(pushCreate).not.toHaveBeenCalled();
  });
});

describe("helper push deduplication", () => {
  it("claims the identity triple before submitting", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(pushCreate).toHaveBeenCalledWith(
      expect.objectContaining({
        requestId,
        purpose: HELPER_NEW_REQUEST_PURPOSE,
        status: "claimed",
      })
    );
    expect(pushCreate.mock.invocationCallOrder[0]).toBeLessThan(
      connections.openConnection.mock.invocationCallOrder[0]
    );
  });

  it("sets the TTL a day past the request's expiration", async () => {
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    const claim = pushCreate.mock.calls[0][0] as { deleteAt: Date };
    expect(claim.deleteAt).toEqual(
      new Date(expiresAt.getTime() + PUSH_DELIVERY_RETENTION_MS)
    );
  });

  it("skips an installation another dispatch already owns", async () => {
    stubInstallations([installationRow(1), installationRow(2)]);
    pushCreate
      .mockRejectedValueOnce(duplicateKeyError())
      .mockResolvedValueOnce({ _id: new mongoose.Types.ObjectId() });
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.duplicate).toBe(1);
    expect(summary.claimed).toBe(1);
    expect(connections.submissions).toHaveLength(1);
  });

  it("records nothing and submits nothing when the claim fails for another reason", async () => {
    stubInstallations([installationRow(1)]);
    pushCreate.mockRejectedValue(new Error("database unavailable"));
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    // Counted apart from `failed`, which is provider truth. Nothing was
    // submitted and nothing was recorded for this installation, so this is not
    // a delivery failure — it is initiation that did not happen.
    expect(summary.claimFailed).toBe(1);
    expect(summary.failed).toBe(0);
    expect(connections.submissions).toHaveLength(0);
    expect(pushUpdate).not.toHaveBeenCalled();
  });

  it("stores no token, credential, or request content on the claim", async () => {
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    const claim = JSON.stringify(pushCreate.mock.calls[0][0]);
    expect(claim).not.toContain("aaaa");
    expect(claim).not.toContain("Campus Market");
    expect(claim).not.toContain("requester@nyu.edu");
    expect(claim).not.toContain("Requester Private Name");
  });
});

describe("helper push submission and provider outcomes", () => {
  it("submits the alert payload with the bounded per-submission timeout", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    const [entry] = connections.submissions;
    expect(entry.timeoutMs).toBe(10_000);
    expect(entry.submission.headers["apns-push-type"]).toBe("alert");
    expect(entry.submission.headers["apns-topic"]).toBe(configuration.bundleId);
    expect(entry.submission.headers.authorization).toBe("bearer provider-jwt");
    expect(JSON.parse(entry.submission.payload)).toMatchObject({
      type: "new-request",
      requestId: requestId.toString(),
    });
  });

  it("records an APNs 200 as an accepted submission with its apns-id", async () => {
    stubInstallations([installationRow(1)]);

    const summary = await dispatch({
      openConnection: stubConnections(async () => accepted).openConnection,
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
  ])(
    "retires the exact token on a terminal %i %s rejection",
    async (status, reason) => {
      const row = installationRow(1);
      stubInstallations([row]);

      const summary = await dispatch({
        openConnection: stubConnections(async () => ({
          classification: "token-rejected" as const,
          status,
          reason,
        })).openConnection,
      });

      expect(summary.rejected).toBe(1);
      expect(summary.retired).toBe(1);
      expect(pushUpdate).toHaveBeenCalledWith(
        expect.any(Object),
        expect.objectContaining({ $set: expect.objectContaining({ status: "rejected" }) })
      );
      // Exact token and exact environment, matched conditionally in one
      // mutation — never a read-check-save.
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
    }
  );

  it("treats a retirement that matches zero documents as expected, not an error", async () => {
    installationUpdate.mockReturnValue({
      exec: async () => ({ modifiedCount: 0 }),
    } as never);
    stubInstallations([installationRow(1)]);

    const summary = await dispatch({
      openConnection: stubConnections(async () => ({
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
    ["configuration", 400, "BadTopic"],
    ["configuration", 400, "DeviceTokenNotForTopic"],
  ] as const)(
    "records a %s %i %s as failed and never retires a token",
    async (classification, status, reason) => {
      stubInstallations([installationRow(1), installationRow(2)]);

      const summary = await dispatch({
        openConnection: stubConnections(async () => ({
          classification,
          status,
          reason,
        })).openConnection,
      });

      // A topic or environment misconfiguration would otherwise retire every
      // installation's token in one dispatch.
      expect(summary.failed).toBe(2);
      expect(summary.stop).toBe("completed");
      expect(installationUpdate).not.toHaveBeenCalled();
      expect(pushUpdate).toHaveBeenCalledWith(
        expect.any(Object),
        expect.objectContaining({ $set: expect.objectContaining({ status: "failed" }) })
      );
    }
  );

  it.each([401, 403])(
    "abandons the remaining submissions after a %i provider auth failure",
    async (status) => {
      stubInstallations(
        Array.from({ length: 6 }, (_, index) => installationRow(index + 1))
      );
      const connections = stubConnections(async () => ({
        classification: "provider-auth" as const,
        status,
        reason: "ExpiredProviderToken",
      }));

      const summary = await dispatch({
        maximumConcurrentSubmissions: 1,
        openConnection: connections.openConnection,
      });

      expect(summary.stop).toBe("provider-auth");
      expect(connections.submissions).toHaveLength(1);
      expect(summary.failed).toBe(1);
      expect(installationUpdate).not.toHaveBeenCalled();
    }
  );

  it("contains a connection that throws instead of resolving", async () => {
    stubInstallations([installationRow(1)]);
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

  it("logs no token, provider token, or raw provider error", async () => {
    const logged: unknown[] = [];
    (console.log as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (...args: unknown[]) => logged.push(args)
    );
    (console.error as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (...args: unknown[]) => logged.push(args)
    );
    const row = installationRow(1);
    stubInstallations([row]);

    await dispatch({
      openConnection: stubConnections(async () => ({
        classification: "token-rejected" as const,
        status: 410,
        reason: "Unregistered",
      })).openConnection,
    });

    const text = JSON.stringify(logged);
    expect(text).not.toContain(row.apnsToken);
    expect(text).not.toContain("provider-jwt");
    expect(text).not.toContain("bearer");
    expect(text).not.toContain(configuration.authKeyPem);
  });
});

describe("helper push persistence failures stay local to one installation", () => {
  /**
   * The fan-out is the product promise: every eligible installation receives
   * every new eligible request. A database failure while recording one
   * installation's outcome is a bookkeeping loss for that installation, and
   * must never truncate the installations behind it in the queue.
   */
  it("keeps submitting after an outcome write fails", async () => {
    stubInstallations(
      Array.from({ length: 4 }, (_, index) => installationRow(index + 1))
    );
    pushUpdate
      .mockReturnValueOnce({
        exec: async () => {
          throw new Error("outcome write failed");
        },
      } as never)
      .mockReturnValue({ exec: async () => ({ modifiedCount: 1 }) } as never);
    const provider = stubConnections(async () => accepted);

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      openConnection: provider.openConnection,
    });

    expect(provider.submissions).toHaveLength(4);
    expect(summary.claimed).toBe(4);
    // The provider outcome is unchanged by the failed write: APNs accepted
    // all four submissions, and the summary still says so.
    expect(summary.accepted).toBe(4);
    expect(summary.failed).toBe(0);
    expect(summary.persistenceFailed).toBe(1);
    expect(summary.stop).toBe("completed");
  });

  it("keeps submitting after an exact-token retirement write fails", async () => {
    stubInstallations(
      Array.from({ length: 4 }, (_, index) => installationRow(index + 1))
    );
    installationUpdate.mockReturnValueOnce({
      exec: async () => {
        throw new Error("retirement write failed");
      },
    } as never);
    const provider = stubConnections(async (submission) =>
      submission.deviceToken === installationRow(1).apnsToken
        ? { classification: "token-rejected" as const, status: 410, reason: "Unregistered" }
        : accepted
    );

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      openConnection: provider.openConnection,
    });

    expect(provider.submissions).toHaveLength(4);
    expect(summary.rejected).toBe(1);
    expect(summary.accepted).toBe(3);
    // A retirement that could not be written is not a retirement.
    expect(summary.retired).toBe(0);
    expect(summary.persistenceFailed).toBe(1);
    expect(summary.stop).toBe("completed");
  });

  it("still abandons on provider auth when that outcome's write fails", async () => {
    // The abort follows APNs truth, not the success of a bookkeeping write.
    stubInstallations(
      Array.from({ length: 4 }, (_, index) => installationRow(index + 1))
    );
    pushUpdate.mockReturnValue({
      exec: async () => {
        throw new Error("outcome write failed");
      },
    } as never);
    const provider = stubConnections(async () => ({
      classification: "provider-auth" as const,
      status: 403,
      reason: "ExpiredProviderToken",
    }));

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      openConnection: provider.openConnection,
    });

    expect(provider.submissions).toHaveLength(1);
    expect(summary.stop).toBe("provider-auth");
    expect(summary.failed).toBe(1);
    expect(summary.persistenceFailed).toBe(1);
  });

  it("logs no token or provider token when a write fails", async () => {
    const logged: unknown[] = [];
    (console.error as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (...args: unknown[]) => logged.push(args)
    );
    const row = installationRow(1);
    stubInstallations([row]);
    pushUpdate.mockReturnValue({
      exec: async () => {
        throw Object.assign(new Error(`bearer provider-jwt ${row.apnsToken}`), {
          code: "SECRET",
        });
      },
    } as never);

    await dispatch({
      openConnection: stubConnections(async () => accepted).openConnection,
    });

    const text = JSON.stringify(logged);
    expect(text).not.toContain(row.apnsToken);
    expect(text).not.toContain("provider-jwt");
    expect(text).toContain("Error");
  });
});

describe("helper push detached-dispatch bounds", () => {
  it("bounds concurrent submissions", async () => {
    stubInstallations(
      Array.from({ length: 20 }, (_, index) => installationRow(index + 1))
    );
    let inFlight = 0;
    let peak = 0;
    const openConnection = vi.fn(
      (): ApnsConnection => ({
        async submit() {
          inFlight += 1;
          peak = Math.max(peak, inFlight);
          await new Promise((resolve) => setTimeout(resolve, 1));
          inFlight -= 1;
          return accepted;
        },
        close() {},
      })
    );

    const summary = await dispatch({ openConnection });

    expect(summary.accepted).toBe(20);
    expect(peak).toBeLessThanOrEqual(8);
  });

  it("starts no new submission after a provider auth abort observed under concurrency", async () => {
    /**
     * Concurrency greater than one is what production runs. The abort is a
     * gate on *starting* work, not a cancellation of work already in flight:
     * an HTTP/2 request already sent to APNs has no cancellation semantics
     * this contract defines, so it is allowed to finish and be recorded
     * truthfully. What must not happen is a fresh submission beginning after
     * the refusal is known.
     */
    const rows = Array.from({ length: 4 }, (_, index) =>
      installationRow(index + 1)
    );
    stubInstallations(rows);
    const provider = stubConnections(async (submission) => {
      if (submission.deviceToken === rows[0].apnsToken) {
        return {
          classification: "provider-auth" as const,
          status: 403,
          reason: "ExpiredProviderToken",
        };
      }
      // Still in flight when the abort above is observed.
      await new Promise((resolve) => setTimeout(resolve, 30));
      return accepted;
    });
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);

    let summary;
    try {
      summary = await dispatch({
        maximumConcurrentSubmissions: 2,
        openConnection: provider.openConnection,
      });
      await new Promise((resolve) => setTimeout(resolve, 20));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    // Exactly the two the pool had already started; neither of the two behind
    // them began.
    expect(provider.submissions).toHaveLength(2);
    expect(provider.submissions.map((entry) => entry.submission.deviceToken)).toEqual([
      rows[0].apnsToken,
      rows[1].apnsToken,
    ]);
    expect(summary.stop).toBe("provider-auth");
    // The in-flight submission completed and was recorded for what it was.
    expect(summary.accepted).toBe(1);
    expect(summary.failed).toBe(1);
    // Only the started work claimed; the abandoned installations wrote nothing.
    expect(summary.claimed).toBe(2);
    expect(pushCreate).toHaveBeenCalledTimes(2);
    expect(pushUpdate).toHaveBeenCalledTimes(2);
    expect(summary.persistenceFailed).toBe(0);
    expect(installationUpdate).not.toHaveBeenCalled();
    expect(rejections).toEqual([]);
  });

  it("starts no new submission after the deadline is observed under concurrency", async () => {
    // The same gate, proved for the deadline branch at the concurrency
    // production actually uses. Both existing seams — the injected deadline
    // and the injected pool size — are enough; no restructuring was needed.
    const rows = Array.from({ length: 4 }, (_, index) =>
      installationRow(index + 1)
    );
    stubInstallations(rows);
    const provider = stubConnections(async () => {
      await new Promise((resolve) => setTimeout(resolve, 30));
      return accepted;
    });

    const summary = await dispatch({
      maximumConcurrentSubmissions: 2,
      dispatchDeadlineMs: 25,
      openConnection: provider.openConnection,
    });

    expect(provider.submissions).toHaveLength(2);
    expect(summary.stop).toBe("deadline");
    // Both already-started submissions completed and were recorded.
    expect(summary.accepted).toBe(2);
    expect(summary.claimed).toBe(2);
    expect(summary.persistenceFailed).toBe(0);
    // The audience was never capped; the detached work's own lifetime was.
    expect(summary.eligible).toBe(4);
  });

  it("abandons the remaining submissions at the dispatch deadline", async () => {
    stubInstallations(
      Array.from({ length: 5 }, (_, index) => installationRow(index + 1))
    );
    const connections = stubConnections(async () => {
      await new Promise((resolve) => setTimeout(resolve, 30));
      return accepted;
    });

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      dispatchDeadlineMs: 45,
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("deadline");
    expect(connections.submissions.length).toBeLessThan(5);
    // The audience was never capped; the detached work's own lifetime was.
    expect(summary.eligible).toBe(5);
  });
});

describe("the total start function", () => {
  it("returns void and never throws when dispatch rejects", async () => {
    installationFind.mockImplementation(() => {
      throw new Error("selection exploded");
    });
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);

    try {
      expect(startHelperNewRequestPush(requestDocument())).toBeUndefined();
      await new Promise((resolve) => setTimeout(resolve, 10));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    expect(rejections).toEqual([]);
  });

  it("contains a synchronous setup failure", () => {
    // A defect thrown before any promise exists must not escape either.
    const broken = { get _id() {
      throw new Error("identity exploded");
    } } as unknown as IRequest;

    expect(() => startHelperNewRequestPush(broken)).not.toThrow();
  });
});

describe("initiation reporting for the eligibility sweep", () => {
  /**
   * Initiation bookkeeping only. Every provider outcome below keeps exactly the
   * terminal, no-retry meaning it already had; the distinction is whether this
   * dispatch reached one at all.
   */
  function summaryWith(
    overrides: Partial<HelperPushDispatchSummary>
  ): HelperPushDispatchSummary {
    return {
      stop: "completed",
      eligible: 1,
      skippedEnvironment: 0,
      claimed: 1,
      duplicate: 0,
      accepted: 1,
      rejected: 0,
      failed: 0,
      claimFailed: 0,
      invalidated: 0,
      retired: 0,
      persistenceFailed: 0,
      ...overrides,
    };
  }

  it.each(["paused", "unavailable"] as const)(
    "reports %s as retryable, because nothing was initiated",
    (stop) => {
      expect(helperPushInitiation(summaryWith({ stop }))).toBe("retryable");
    }
  );

  it("reports an unwritten claim as retryable", () => {
    expect(
      helperPushInitiation(summaryWith({ claimFailed: 1, claimed: 0 }))
    ).toBe("retryable");
  });

  it.each([
    ["a completed dispatch", summaryWith({})],
    [
      "an accepted submission",
      summaryWith({ accepted: 1 }),
    ],
    [
      "a token rejection",
      summaryWith({ accepted: 0, rejected: 1, retired: 1 }),
    ],
    [
      "a transient provider failure",
      summaryWith({ accepted: 0, failed: 1 }),
    ],
    [
      "an outcome that could not be recorded after submission",
      summaryWith({ persistenceFailed: 1 }),
    ],
    [
      "a duplicate another dispatch already owned",
      summaryWith({ claimed: 0, duplicate: 1, accepted: 0 }),
    ],
    [
      "no eligible installations",
      summaryWith({
        stop: "no-eligible-installations",
        eligible: 0,
        claimed: 0,
        accepted: 0,
      }),
    ],
    [
      "an abandoned provider-auth dispatch",
      summaryWith({ stop: "provider-auth", accepted: 0, failed: 1 }),
    ],
    [
      "an abandoned deadline dispatch",
      summaryWith({ stop: "deadline" }),
    ],
    [
      "an unusable configuration or payload",
      summaryWith({ stop: "configuration", eligible: 0, claimed: 0, accepted: 0 }),
    ],
  ])("reports %s as terminally processed", (_label, summary) => {
    // None of these may be repeated: V1 has no push retry, and re-running them
    // is precisely the duplicate submission the `PushDelivery` claim exists to
    // prevent. Reporting them as processed is what stops the eligibility sweep
    // from looping on the request until it expires.
    expect(helperPushInitiation(summary)).toBe("processed");
  });
});

describe("W4-R5 notification-generation fencing", () => {
  /** A guard that answers per call, in order, then repeats its last answer. */
  function guardAnswers(...answers: Array<Record<string, unknown> | null>) {
    let index = 0;
    requestExists.mockImplementation((async () => {
      const answer = answers[Math.min(index, answers.length - 1)];
      index += 1;
      return answer === null ? null : requestDocument(answer);
    }) as never);
  }

  it("reads the request at the generation the dispatch was started for", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    await dispatch(
      { openConnection: connections.openConnection },
      requestDocument({ notificationGeneration: 3 })
    );

    for (const call of requestExists.mock.calls) {
      const filter = call[0] as { $and: unknown[] };
      expect(filter.$and).toContainEqual({ notificationGeneration: 3 });
    }
    // Three guards for one installation: dispatch start, before the claim,
    // after the claim and immediately before handoff.
    expect(requestExists.mock.calls.length).toBe(3);
  });

  it("stops before writing a claim when the request is no longer the one it was started for", async () => {
    stubInstallations([installationRow(1), installationRow(2)]);
    guardAnswers({}, null);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.stop).toBe("unavailable");
    // The installations run concurrently, so each one that reaches its
    // pre-claim guard before the fan-out is abandoned counts.
    expect(summary.invalidated).toBeGreaterThanOrEqual(1);
    expect(pushCreate).not.toHaveBeenCalled();
    expect(connections.submissions).toHaveLength(0);
    // Nothing was decided, so the sweep must look again.
    expect(helperPushInitiation(summary)).toBe("retryable");
  });

  it("releases the claim and hands nothing to the provider when the generation moves after the claim", async () => {
    stubInstallations([installationRow(1)]);
    guardAnswers({}, {}, null);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(pushCreate).toHaveBeenCalledTimes(1);
    expect(pushDelete).toHaveBeenCalledOnce();
    expect(pushDelete.mock.calls[0][0]).toMatchObject({ status: "claimed" });
    expect(connections.submissions).toHaveLength(0);
    expect(summary.claimed).toBe(0);
    expect(summary.invalidated).toBe(1);
    expect(summary.accepted + summary.rejected + summary.failed).toBe(0);
    expect(helperPushInitiation(summary)).toBe("retryable");
  });

  it("stops the remaining fan-out once one installation finds the request invalidated", async () => {
    stubInstallations([installationRow(1), installationRow(2), installationRow(3)]);
    // start, then installation 1 passes both guards, installation 2 fails its first.
    guardAnswers({}, {}, {}, null);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({
      openConnection: connections.openConnection,
      maximumConcurrentSubmissions: 1,
    });

    expect(connections.submissions).toHaveLength(1);
    expect(summary.accepted).toBe(1);
    expect(summary.invalidated).toBe(1);
  });

  it("never withdraws a submission that was already handed to the provider", async () => {
    stubInstallations([installationRow(1)]);
    // Guards pass for the only installation; the provider answers afterwards.
    guardAnswers({});
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.accepted).toBe(1);
    expect(pushDelete).not.toHaveBeenCalled();
  });

  it("submits the request's current content when an ordinary edit landed mid-dispatch", async () => {
    stubInstallations([installationRow(1)]);
    guardAnswers(
      {},
      {},
      { food: "Edited chicken bowl", mealSwipes: 3, contentRevision: 2 }
    );
    const connections = stubConnections(async () => accepted);

    await dispatch(
      { openConnection: connections.openConnection },
      requestDocument({ contentRevision: 1 })
    );

    const body = JSON.parse(connections.submissions[0].submission.payload);
    expect(body.aps.alert.title).toBe("3 meal swipes");
    expect(body.aps.alert.body).toBe("Campus Market");
    expect(body.contentRevision).toBe(2);
  });

  it("keeps the dispatch's own content when the revision has not moved", async () => {
    stubInstallations([installationRow(1)]);
    guardAnswers({ contentRevision: 1, food: "Different text, same revision" });
    const connections = stubConnections(async () => accepted);

    await dispatch(
      { openConnection: connections.openConnection },
      requestDocument({ contentRevision: 1 })
    );

    const body = JSON.parse(connections.submissions[0].submission.payload);
    expect(body.aps.alert.title).toBe("1 meal swipe");
    expect(body.aps.alert.body).toBe("Campus Market");
    expect(body.contentRevision).toBe(1);
  });

  it("includes the content revision in the payload only when the request carries one", async () => {
    stubInstallations([installationRow(1), installationRow(2)]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });
    expect(
      JSON.parse(connections.submissions[0].submission.payload)
    ).not.toHaveProperty("contentRevision");
  });
});
