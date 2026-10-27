import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  CLAIM_MINIMUM_REMAINING_MS,
  buildEffectiveAvailabilityFilter,
  isEffectivelyAvailable,
} from "./requestAvailability.js";
import { buildNotificationGenerationFilter } from "./requestRevision.js";

const alertInstant = new Date("2026-07-30T16:00:00.000Z");

const { models, sendNewRequestAlert } = vi.hoisted(() => {
  const collection = () => ({
    find: vi.fn(),
    findOne: vi.fn(),
    findById: vi.fn(),
    exists: vi.fn(),
    create: vi.fn(),
    updateOne: vi.fn(),
    deleteOne: vi.fn(),
  });

  return {
    models: {
      Subscriber: collection(),
      System: collection(),
      SendLog: collection(),
      Request: collection(),
    },
    sendNewRequestAlert: vi.fn(),
  };
});

vi.mock("../models/db.js", () => models);
vi.mock("./emailHelpers.js", () => ({ sendNewRequestAlert }));

import {
  notifySubscriberAboutRecentRequests,
  notifySubscribersForRequest,
} from "./notifySubscribers.js";

function request(): IRequest {
  return {
    _id: "64b000000000000000000001",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupWindowText: "1:00 PM – 2:00 PM",
  } as unknown as IRequest;
}

function subscriber(): ISubscriber {
  return {
    _id: "64b000000000000000000002",
    email: "helper@example.edu",
    status: "confirmed",
    unsubscribeCredentialVersion: 1,
    dailyCount: 0,
    bounced: false,
  } as unknown as ISubscriber;
}

function everyModelCall() {
  return Object.values(models).flatMap((model) => Object.values(model));
}

beforeEach(() => {
  for (const call of everyModelCall()) call.mockReset();
  sendNewRequestAlert.mockReset();
});

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("notification dispatch while public actions are paused", () => {
  beforeEach(() => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
  });

  it("skips real-time alerts without touching the database or email", async () => {
    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).not.toHaveBeenCalled();
    for (const call of everyModelCall()) {
      expect(call).not.toHaveBeenCalled();
    }
  });

  it("skips recent-request alerts after subscription", async () => {
    await notifySubscriberAboutRecentRequests(subscriber());

    expect(sendNewRequestAlert).not.toHaveBeenCalled();
    for (const call of everyModelCall()) {
      expect(call).not.toHaveBeenCalled();
    }
  });

  it("records no delivery for a skipped alert", async () => {
    await notifySubscribersForRequest(request());
    await notifySubscriberAboutRecentRequests(subscriber());

    expect(models.SendLog.create).not.toHaveBeenCalled();
    expect(models.SendLog.updateOne).not.toHaveBeenCalled();
    expect(models.Subscriber.updateOne).not.toHaveBeenCalled();
  });
});

describe("notification dispatch when public actions are resumed", () => {
  beforeEach(() => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
  });

  it("resumes the real-time path past the pause guard", async () => {
    // Reaching the availability re-check and then the recipient query proves
    // the guard did not short-circuit; an empty eligible set stops the rest.
    models.Request.findOne.mockResolvedValue(request());
    models.Subscriber.find.mockReturnValue({
      sort: vi.fn().mockResolvedValue([]),
    });

    await notifySubscribersForRequest(request());

    expect(models.Request.findOne).toHaveBeenCalledOnce();
    expect(models.Subscriber.find).toHaveBeenCalledOnce();
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });

  it("queries only confirmed, non-bounced subscribers for real-time alerts, with no cooldown or daily-cap restriction", async () => {
    models.Request.findOne.mockResolvedValue(request());
    models.SendLog.exists.mockResolvedValue(null);
    models.Subscriber.find.mockReturnValue({
      sort: vi.fn().mockResolvedValue([]),
    });

    await notifySubscribersForRequest(request());

    expect(models.Subscriber.find).toHaveBeenCalledWith({
      $and: [{ status: "confirmed" }, { bounced: false }],
    });
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });

  function subscriberWithId(id: string, overrides: Partial<ISubscriber> = {}): ISubscriber {
    return { ...subscriber(), _id: id, email: `${id}@example.edu`, ...overrides } as ISubscriber;
  }

  function setUpEligible(subs: ISubscriber[]) {
    models.Request.findOne.mockResolvedValue(request());
    models.SendLog.exists.mockResolvedValue(null);
    models.Subscriber.find.mockReturnValue({
      sort: vi.fn().mockResolvedValue(subs),
    });
    models.SendLog.create.mockResolvedValue({ _id: "claim" });
    models.SendLog.updateOne.mockResolvedValue({});
    models.Subscriber.updateOne.mockResolvedValue({});
  }

  it("notifies every eligible subscriber for a request, not a bounded subset", async () => {
    const subs = [
      subscriberWithId("64b000000000000000000010"),
      subscriberWithId("64b000000000000000000011"),
      subscriberWithId("64b000000000000000000012"),
    ];
    setUpEligible(subs);
    sendNewRequestAlert.mockResolvedValue(undefined);

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledTimes(3);
    for (const sub of subs) {
      expect(sendNewRequestAlert).toHaveBeenCalledWith(sub, request());
    }
  });

  it("still attempts a subscriber with a fresh lastSentAt", async () => {
    const fresh = subscriberWithId("64b000000000000000000013", {
      lastSentAt: new Date(),
    });
    setUpEligible([fresh]);
    sendNewRequestAlert.mockResolvedValue(undefined);

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledWith(fresh, request());
  });

  it("still attempts a subscriber who already reached the old daily cap", async () => {
    const capped = subscriberWithId("64b000000000000000000014", {
      dailyCount: 4,
    });
    setUpEligible([capped]);
    sendNewRequestAlert.mockResolvedValue(undefined);

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledWith(capped, request());
  });

  it("does not let one subscriber's provider failure block the remaining eligible subscribers", async () => {
    const subs = [
      subscriberWithId("64b000000000000000000015"),
      subscriberWithId("64b000000000000000000016"),
    ];
    setUpEligible(subs);
    sendNewRequestAlert
      .mockRejectedValueOnce(new Error("provider outage"))
      .mockResolvedValueOnce(undefined);

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledTimes(2);
    expect(models.SendLog.updateOne).toHaveBeenCalledWith(
      { requestId: request()._id, subscriberId: subs[0]._id },
      expect.objectContaining({ $set: expect.objectContaining({ status: "fail" }) })
    );
    expect(models.SendLog.updateOne).toHaveBeenCalledWith(
      { requestId: request()._id, subscriberId: subs[1]._id },
      expect.objectContaining({ $set: expect.objectContaining({ status: "sent" }) })
    );
  });

  it("still skips a subscriber whose SendLog claim was already taken by another process", async () => {
    const subs = [
      subscriberWithId("64b000000000000000000017"),
      subscriberWithId("64b000000000000000000018"),
    ];
    setUpEligible(subs);
    const duplicateKeyError = Object.assign(new Error("E11000 duplicate key"), {
      code: 11000,
    });
    models.SendLog.create
      .mockRejectedValueOnce(duplicateKeyError)
      .mockResolvedValueOnce({ _id: "claim" });
    sendNewRequestAlert.mockResolvedValue(undefined);

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledTimes(1);
    expect(sendNewRequestAlert).toHaveBeenCalledWith(subs[1], request());
  });

  it("still updates dailyCount and lastSentAt on a successful real-time send, because digest still reads them", async () => {
    const sub = subscriberWithId("64b000000000000000000019");
    setUpEligible([sub]);
    sendNewRequestAlert.mockResolvedValue(undefined);

    await notifySubscribersForRequest(request());

    expect(models.Subscriber.updateOne).toHaveBeenCalledWith(
      { _id: sub._id },
      { $set: { lastSentAt: expect.any(Date) }, $inc: { dailyCount: 1 } }
    );
  });

  it("has no request-wide short-circuit for an already-sent request", async () => {
    // The policy is every confirmed, non-bounced subscriber for every eligible
    // request. One address already having been sent this request says nothing
    // about the others, and asking "has anyone been sent this?" silenced
    // everybody behind the first success.
    const subs = [
      subscriberWithId("64b00000000000000000001c"),
      subscriberWithId("64b00000000000000000001d"),
    ];
    setUpEligible(subs);
    models.SendLog.exists.mockResolvedValue({ _id: "already-sent" });
    sendNewRequestAlert.mockResolvedValue(undefined);

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledTimes(2);
    // The request-level read is gone entirely, not merely ignored.
    expect(models.SendLog.exists).not.toHaveBeenCalled();
  });

  it("skips only the recipient who already has a claim, and processes the rest", async () => {
    // A already has a successful SendLog; B and C do not. The unique
    // per-recipient claim is what decides, one subscriber at a time.
    const [a, b, c] = [
      subscriberWithId("64b00000000000000000001e"),
      subscriberWithId("64b00000000000000000001f"),
      subscriberWithId("64b000000000000000000020"),
    ];
    setUpEligible([a, b, c]);
    const duplicateKeyError = Object.assign(new Error("E11000 duplicate key"), {
      code: 11000,
    });
    models.SendLog.create.mockImplementation(async (claim: any) =>
      String(claim.subscriberId) === String(a._id)
        ? Promise.reject(duplicateKeyError)
        : { _id: "claim" }
    );
    sendNewRequestAlert.mockResolvedValue(undefined);

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledTimes(2);
    expect(sendNewRequestAlert).toHaveBeenCalledWith(b, request());
    expect(sendNewRequestAlert).toHaveBeenCalledWith(c, request());
    expect(sendNewRequestAlert).not.toHaveBeenCalledWith(a, request());
  });

  it("resumes the remaining recipients after an interrupted fan-out", async () => {
    // The first attempt reached A and died. The second must not stop at A.
    const [a, b] = [
      subscriberWithId("64b000000000000000000021"),
      subscriberWithId("64b000000000000000000022"),
    ];
    setUpEligible([a, b]);
    const duplicateKeyError = Object.assign(new Error("E11000 duplicate key"), {
      code: 11000,
    });
    models.SendLog.create.mockImplementation(async (claim: any) =>
      String(claim.subscriberId) === String(a._id)
        ? Promise.reject(duplicateKeyError)
        : { _id: "claim" }
    );
    sendNewRequestAlert.mockResolvedValue(undefined);

    const initiation = await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledOnce();
    expect(sendNewRequestAlert).toHaveBeenCalledWith(b, request());
    expect(initiation).toBe("processed");
  });

  it("keeps the digest's own rows deduplicating a repeat for the same recipient", async () => {
    // The hourly digest writes the same `(requestId, subscriberId)` rows, so a
    // subscriber who received the digest for this request is skipped here by
    // the same claim — without suppressing anybody else.
    const digested = subscriberWithId("64b000000000000000000023");
    setUpEligible([digested]);
    models.SendLog.create.mockRejectedValue(
      Object.assign(new Error("E11000 duplicate key"), { code: 11000 })
    );

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });

  describe("initiation reporting for the eligibility sweep", () => {
    it("reports a request that is no longer available as retryable", async () => {
      models.Request.findOne.mockResolvedValue(null);

      expect(await notifySubscribersForRequest(request())).toBe("retryable");
    });

    it("reports an unwritten claim as retryable", async () => {
      // Neither notified nor recorded, so nothing about this request has been
      // decided and its one initiation must not be consumed.
      const sub = subscriberWithId("64b000000000000000000024");
      setUpEligible([sub]);
      models.SendLog.create.mockRejectedValue(new Error("database unavailable"));

      expect(await notifySubscribersForRequest(request())).toBe("retryable");
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
    });

    it("reports no eligible subscribers as terminally processed", async () => {
      // The accepted lifecycle notifies whoever is eligible when a request
      // becomes eligible; it does not hold the request open for a future
      // subscriber.
      models.Request.findOne.mockResolvedValue(request());
      models.Subscriber.find.mockReturnValue({
        sort: vi.fn().mockResolvedValue([]),
      });

      expect(await notifySubscribersForRequest(request())).toBe("processed");
    });

    it.each([
      ["a delivered alert", undefined],
      ["a provider failure", new Error("provider outage")],
    ])("reports %s as terminally processed", async (_label, failure) => {
      // A failed send keeps its `fail` row, which the unique claim turns into
      // a skip next time. Neither outcome is ever attempted twice.
      const sub = subscriberWithId("64b000000000000000000025");
      setUpEligible([sub]);
      if (failure) {
        sendNewRequestAlert.mockRejectedValue(failure);
      } else {
        sendNewRequestAlert.mockResolvedValue(undefined);
      }

      expect(await notifySubscribersForRequest(request())).toBe("processed");
    });
  });

  it("does not read or write the notify_cursor System document on the real-time path", async () => {
    const subs = [
      subscriberWithId("64b00000000000000000001a"),
      subscriberWithId("64b00000000000000000001b"),
    ];
    setUpEligible(subs);
    sendNewRequestAlert.mockResolvedValue(undefined);

    await notifySubscribersForRequest(request());

    expect(models.System.findOne).not.toHaveBeenCalled();
    expect(models.System.updateOne).not.toHaveBeenCalled();
  });

  it.each(["pending", "unsubscribed"] as const)(
    "keeps a %s subscriber ineligible for recent-request alerts",
    async (status) => {
      await notifySubscriberAboutRecentRequests({
        ...subscriber(),
        status,
      } as ISubscriber);

      expect(models.Request.find).not.toHaveBeenCalled();
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(models.SendLog.create).not.toHaveBeenCalled();
    }
  );

  it("resumes the recent-request path past the pause guard", async () => {
    models.Request.find.mockReturnValue({
      sort: () => ({ limit: () => ({ lean: () => Promise.resolve([]) }) }),
    });

    await notifySubscriberAboutRecentRequests(subscriber());

    expect(models.Request.find).toHaveBeenCalledOnce();
    expect(models.Request.find).toHaveBeenCalledWith(
      expect.objectContaining({
        expiresAt: { $gt: expect.any(Date), $gte: expect.any(Date) },
        $or: [
          { status: "open" },
          {
            status: "claimed",
            claimExpiresAt: { $lte: expect.any(Date) },
          },
        ],
      })
    );
  });

  it("excludes short-lived requests from real-time helper alerts", async () => {
    // Frozen so the captured instant in the module is knowable exactly.
    vi.useFakeTimers();
    vi.setSystemTime(alertInstant);
    models.Request.findOne.mockResolvedValue(null);

    try {
      await notifySubscribersForRequest(request());
    } finally {
      vi.useRealTimers();
    }

    // W4-R5: the re-check is the shared dispatch guard — current availability
    // and the notification generation the dispatch was started for, in `$and`
    // because the availability filter and the generation clause each carry a
    // top-level `$or`.
    expect(models.Request.findOne).toHaveBeenCalledWith(
      {
        $and: [
          { _id: request()._id },
          buildEffectiveAvailabilityFilter(alertInstant),
          buildNotificationGenerationFilter(1),
        ],
      },
      "+notificationGeneration +contentRevision +requesterParticipantId",
      { lean: true }
    );
    // A request expiring inside the next five minutes fails that filter, so no
    // alert is ever sent for it.
    expect(
      isEffectivelyAvailable(
        {
          status: "open",
          expiresAt: new Date(
            alertInstant.getTime() + CLAIM_MINIMUM_REMAINING_MS - 1
          ),
        },
        alertInstant
      )
    ).toBe(false);
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });

  it("excludes short-lived requests from recent-request notification queries", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(alertInstant);
    models.Request.find.mockReturnValue({
      sort: () => ({ limit: () => ({ lean: () => Promise.resolve([]) }) }),
    });

    try {
      await notifySubscriberAboutRecentRequests(subscriber());
    } finally {
      vi.useRealTimers();
    }

    const filter = models.Request.find.mock.calls[0][0];
    expect(filter).toEqual({
      createdAt: {
        $gte: new Date(alertInstant.getTime() - 24 * 60 * 60 * 1000),
      },
      ...buildEffectiveAvailabilityFilter(alertInstant),
    });
    expect(filter.expiresAt.$gte).toEqual(
      new Date(alertInstant.getTime() + CLAIM_MINIMUM_REMAINING_MS)
    );
  });

  it("does not advertise a request that became actively claimed", async () => {
    models.Request.findOne.mockResolvedValue(null);

    await notifySubscribersForRequest(request());

    expect(models.Request.findOne).toHaveBeenCalledWith(
      expect.objectContaining({ $and: expect.any(Array) }),
      "+notificationGeneration +contentRevision +requesterParticipantId",
      { lean: true }
    );
    expect(models.SendLog.exists).not.toHaveBeenCalled();
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });
});

describe("W4-R5 notification-generation fencing", () => {
  beforeEach(() => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
  });

  function subscriberWithId(id: string): ISubscriber {
    return { ...subscriber(), _id: id, email: `${id}@example.edu` } as ISubscriber;
  }

  function setUp(subs: ISubscriber[], ...guard: Array<IRequest | null>) {
    let index = 0;
    models.Request.findOne.mockImplementation(async () => {
      const answer = guard[Math.min(index, guard.length - 1)];
      index += 1;
      return answer;
    });
    models.SendLog.exists.mockResolvedValue(null);
    models.Subscriber.find.mockReturnValue({
      sort: vi.fn().mockResolvedValue(subs),
    });
    models.SendLog.create.mockResolvedValue({ _id: "claim" });
    models.SendLog.updateOne.mockResolvedValue({});
    models.SendLog.deleteOne.mockResolvedValue({});
    models.Subscriber.updateOne.mockResolvedValue({});
  }

  it("runs the guard at the generation the dispatch was started for", async () => {
    const sub = subscriberWithId("64b000000000000000000030");
    setUp([sub], request());

    await notifySubscribersForRequest({
      ...request(),
      notificationGeneration: 4,
    } as unknown as IRequest);

    for (const call of models.Request.findOne.mock.calls) {
      expect(call[0].$and).toContainEqual({ notificationGeneration: 4 });
    }
    // Start, before the claim, after the claim / immediately before handoff.
    expect(models.Request.findOne).toHaveBeenCalledTimes(3);
  });

  it("writes no claim and sends nothing when the guard fails before the claim", async () => {
    const sub = subscriberWithId("64b000000000000000000031");
    setUp([sub], request(), null);

    const result = await notifySubscribersForRequest(request());

    expect(models.SendLog.create).not.toHaveBeenCalled();
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
    expect(result).toBe("retryable");
  });

  it("releases only the unsent placeholder claim when the guard fails after the claim", async () => {
    const sub = subscriberWithId("64b000000000000000000032");
    setUp([sub], request(), request(), null);

    const result = await notifySubscribersForRequest(request());

    expect(models.SendLog.create).toHaveBeenCalledTimes(1);
    expect(models.SendLog.deleteOne).toHaveBeenCalledWith({
      requestId: request()._id,
      subscriberId: sub._id,
      status: "fail",
      error: { $exists: false },
    });
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
    expect(result).toBe("retryable");
  });

  it("sends the current content when an ordinary edit landed since the dispatch began", async () => {
    const sub = subscriberWithId("64b000000000000000000033");
    const edited = {
      ...request(),
      food: "Edited chicken bowl",
    } as unknown as IRequest;
    setUp([sub], request(), request(), edited);

    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledOnce();
    expect(sendNewRequestAlert.mock.calls[0][1]).toMatchObject({
      food: "Edited chicken bowl",
    });
  });

  it("stops the remaining recipients once the request is invalidated and never touches a delivered recipient's record", async () => {
    const first = subscriberWithId("64b000000000000000000034");
    const second = subscriberWithId("64b000000000000000000035");
    // start, first: pre-claim ok, post-claim ok; second: pre-claim fails.
    setUp([first, second], request(), request(), request(), null);

    const result = await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).toHaveBeenCalledOnce();
    expect(models.SendLog.create).toHaveBeenCalledTimes(1);
    expect(models.SendLog.deleteOne).not.toHaveBeenCalled();
    expect(result).toBe("retryable");
  });
});
vi.mock("./requestAlertEmailDelivery.js", () => ({ isRequestAlertEmailDeliveryActive: () => true }));
