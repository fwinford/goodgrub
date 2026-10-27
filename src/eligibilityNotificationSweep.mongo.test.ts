import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const { sendNewRequestAlert } = vi.hoisted(() => ({
  sendNewRequestAlert: vi.fn(),
}));

// The only replaced boundary. Everything else in this file — availability,
// recipient selection, both delivery ledgers, the state transition, and the
// indexes behind them — is the real production code against real MongoDB.
vi.mock("./emailHelpers.js", () => ({ sendNewRequestAlert }));

import {
  Installation,
  Participant,
  PushDelivery,
  Request as MealRequest,
  SendLog,
  Subscriber,
  type IRequest,
} from "../models/db.js";
import type { ApnsConfiguration } from "./apnsConfig.js";
import type { ApnsConnection, ApnsOutcome, ApnsSubmission } from "./apnsClient.js";
import {
  HELPER_NEW_REQUEST_PURPOSE,
  dispatchHelperNewRequestPush,
  helperPushInitiation,
} from "./helperNewRequestPush.js";
import { runEligibilityNotificationSweep } from "./eligibilityNotificationSweep.js";
import { notifySubscribersForRequest } from "./notifySubscribers.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { digestInstallationCredential } from "./installationCredential.js";
import { REQUEST_VISIBLE_DURATION_MS } from "./requestTiming.js";

/**
 * Integration files run in parallel against the same mongod, and this suite
 * clears its collections between cases. It gets its own database so cleanup
 * cannot delete another file's fixtures mid-run.
 */
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  uri.pathname = `${uri.pathname}_eligibility`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: "unused: the provider token is injected",
};

const accepted: ApnsOutcome = {
  classification: "accepted",
  status: 200,
  reason: "Accepted",
  apnsId: "apns-accepted",
};

const HOUR_MS = 60 * 60 * 1000;
const helperId = new mongoose.Types.ObjectId();

function credential(byte: number): string {
  return Buffer.alloc(32, byte).toString("base64url");
}

function apnsToken(byte: number): string {
  return Buffer.alloc(32, byte).toString("hex");
}

/**
 * A Later request exactly as `POST /api/request` persists one: `visibleFrom` at
 * the accepted scheduled start, `expiresAt` three hours after it, and the
 * eligibility sweep named as the owner of its helper notification.
 */
async function createLaterRequest(
  visibleFromOffsetMs: number,
  overrides: Record<string, unknown> = {}
): Promise<IRequest> {
  const visibleFrom = new Date(Date.now() + visibleFromOffsetMs);
  const expiresAt = new Date(visibleFrom.getTime() + REQUEST_VISIBLE_DURATION_MS);
  return MealRequest.create({
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    pickupWindowText: "Aug 9, 2:00 PM – 5:00 PM",
    status: "open",
    mealSwipes: 1,
    windowStart: visibleFrom,
    windowEnd: expiresAt,
    visibleFrom,
    helperNotification: "awaiting-eligibility",
    expiresAt,
    deleteAt: expiresAt,
    ...overrides,
  });
}

/** An ASAP request as the create route persists one: already initiated. */
async function createAsapRequest(
  overrides: Record<string, unknown> = {}
): Promise<IRequest> {
  const visibleFrom = new Date();
  const expiresAt = new Date(visibleFrom.getTime() + REQUEST_VISIBLE_DURATION_MS);
  return MealRequest.create({
    vendor: "Jasper Kane Cafe",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    pickupWindowText: "ASAP",
    status: "open",
    mealSwipes: 1,
    visibleFrom,
    helperNotification: "initiated",
    expiresAt,
    deleteAt: expiresAt,
    ...overrides,
  });
}

/**
 * Backdates `createdAt` through the driver: Mongoose timestamps would
 * otherwise overwrite it, and an old creation instant is the exact condition
 * this slice exists for.
 */
async function backdateCreation(request: IRequest, ageMs: number): Promise<void> {
  await MealRequest.collection.updateOne(
    { _id: request._id as never },
    { $set: { createdAt: new Date(Date.now() - ageMs) } }
  );
}

async function createConfirmedSubscriber(index: number) {
  return Subscriber.create({
    email: `helper${index}@nyu.edu`,
    status: "confirmed",
    bounced: false,
    dailyCount: 0,
  });
}

async function createPushInstallation(
  byte: number,
  overrides: Record<string, unknown> = {}
) {
  await Participant.updateOne({ _id: helperId }, { $setOnInsert: {
    email: "helper@nyu.edu", authorityVersion: 1, verifiedAt: new Date(),
  } }, { upsert: true });
  return Installation.create({
    installationCredentialDigest: digestInstallationCredential(credential(byte)),
    pushEnabled: true,
    apnsToken: apnsToken(byte),
    apnsEnvironment: "development",
    tokenUpdatedAt: new Date(),
    participantId: helperId,
    participantAuthorityVersion: 1,
    ...overrides,
  });
}

interface RecordingProvider {
  openConnection: (origin: string) => ApnsConnection;
  submissions: ApnsSubmission[];
}

function provider(
  respond: () => ApnsOutcome | Promise<ApnsOutcome> = () => accepted
): RecordingProvider {
  const submissions: ApnsSubmission[] = [];
  return {
    submissions,
    openConnection: () => ({
      async submit(submission) {
        submissions.push(submission);
        return respond();
      },
      close() {},
    }),
  };
}

function pushWith(recording: RecordingProvider) {
  return (request: IRequest) =>
    dispatchHelperNewRequestPush(request, {
      isPaused: () => false,
      readConfiguration: () => configuration,
      providerToken: () => "provider-jwt",
      openConnection: recording.openConnection,
    });
}

/**
 * The sweep with only its provider boundary injected. Selection, the
 * availability rule, the pause reading, the recipient queries, both ledgers,
 * and the state transition all run for real.
 */
/**
 * The push channel as the sweep consumes it: the real dispatcher, with the
 * real production mapping from its summary to an initiation outcome.
 */
function pushChannel(recording: RecordingProvider) {
  return async (request: IRequest) =>
    helperPushInitiation(await pushWith(recording)(request));
}

function sweep(recording: RecordingProvider, overrides = {}) {
  return runEligibilityNotificationSweep({
    dispatchPush: pushChannel(recording),
    ...overrides,
  });
}

async function storedState(request: IRequest): Promise<unknown> {
  const stored = await MealRequest.findById(request._id).lean();
  return (stored as unknown as { helperNotification?: string })
    ?.helperNotification;
}

describeMongo("eligibility-time notification dispatch against real MongoDB", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!, { dbName: "commonplate_eligibility_test" });
    await MealRequest.syncIndexes();
    await Installation.syncIndexes();
    await PushDelivery.syncIndexes();
    await SendLog.syncIndexes();
    await Subscriber.syncIndexes();
  });

  beforeEach(() => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    sendNewRequestAlert.mockReset();
    sendNewRequestAlert.mockResolvedValue(undefined);
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(async () => {
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
    await Promise.all([
      MealRequest.deleteMany({}),
      Installation.deleteMany({}),
      PushDelivery.deleteMany({}),
      SendLog.deleteMany({}),
      Subscriber.deleteMany({}),
    ]);
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  describe("nothing before visibleFrom", () => {
    it("sends no helper email and no helper push for a future Later request", async () => {
      const request = await createLaterRequest(2 * HOUR_MS);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      // Both real dispatchers, called directly exactly as the create route
      // calls them at creation. Both must find the request unavailable.
      const pushSummary = await pushWith(recording)(request);
      await notifySubscribersForRequest(request);

      expect(pushSummary.stop).toBe("unavailable");
      expect(recording.submissions).toHaveLength(0);
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(await PushDelivery.countDocuments({})).toBe(0);
      expect(await SendLog.countDocuments({})).toBe(0);
    });

    it("is not selected by the sweep before its eligibility begins", async () => {
      const request = await createLaterRequest(2 * HOUR_MS);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.candidates).toBe(0);
      expect(recording.submissions).toHaveLength(0);
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      // The state survives: the request has not lost its one initiation.
      expect(await storedState(request)).toBe("awaiting-eligibility");
    });
  });

  describe("initiation once eligibility begins", () => {
    it("starts both channel lifecycles and records the transition", async () => {
      const request = await createLaterRequest(-1);
      const subscriber = await createConfirmedSubscriber(1);
      const installation = await createPushInstallation(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary).toMatchObject({
        stop: "completed",
        candidates: 1,
        initiated: 1,
        deferred: 0,
      });
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(recording.submissions).toHaveLength(1);
      expect(recording.submissions[0].deviceToken).toBe(apnsToken(1));
      expect(
        await SendLog.countDocuments({
          requestId: request._id,
          subscriberId: subscriber._id,
          status: "sent",
        })
      ).toBe(1);
      expect(
        await PushDelivery.countDocuments({
          requestId: request._id,
          installationId: installation._id,
          purpose: HELPER_NEW_REQUEST_PURPOSE,
          status: "accepted",
        })
      ).toBe(1);
      expect(await storedState(request)).toBe("initiated");
    });

    it("finds a request whose createdAt is far outside the former lookback", async () => {
      const request = await createLaterRequest(-1);
      await backdateCreation(request, 9 * HOUR_MS);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      // The mechanism this slice replaces: the hourly digest's creation-age
      // window cannot see this request at all.
      const byCreationAge = await MealRequest.countDocuments({
        createdAt: { $gte: new Date(Date.now() - HOUR_MS) },
      });
      expect(byCreationAge).toBe(0);

      const summary = await sweep(recording);

      expect(summary.initiated).toBe(1);
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(recording.submissions).toHaveLength(1);
    });

    it("catches up on a request that became eligible before this run", async () => {
      // The worker did not run at `visibleFrom`; the request is two hours past
      // it and still has an hour of availability left.
      const request = await createLaterRequest(-2 * HOUR_MS);
      await backdateCreation(request, 12 * HOUR_MS);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.initiated).toBe(1);
      expect(await storedState(request)).toBe("initiated");
      expect(await SendLog.countDocuments({ status: "sent" })).toBe(1);
      expect(await PushDelivery.countDocuments({ status: "accepted" })).toBe(1);
    });

    it("takes the longest-eligible request first", async () => {
      const older = await createLaterRequest(-2 * HOUR_MS);
      const newer = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      const recording = provider();

      await sweep(recording);

      const ledger = await SendLog.find({}).sort({ _id: 1 }).lean();
      expect(ledger).toHaveLength(2);
      expect(String(ledger[0].requestId)).toBe(String(older._id));
      expect(String(ledger[1].requestId)).toBe(String(newer._id));
    });
  });

  describe("no stale notification once the request is no longer eligible", () => {
    it.each([
      [
        "expired while it waited",
        () => ({
          expiresAt: new Date(Date.now() - 1),
          deleteAt: new Date(Date.now() + HOUR_MS),
        }),
      ],
      ["placed", () => ({ status: "placed", placedAt: new Date() })],
      [
        "held under a live claim",
        () => ({
          status: "claimed",
          claimedAt: new Date(),
          claimExpiresAt: new Date(Date.now() + 15 * 60 * 1000),
        }),
      ],
      [
        "inside the five-minute claim floor",
        () => ({ expiresAt: new Date(Date.now() + 60 * 1000) }),
      ],
    ])("sends nothing for a request %s", async (_label, overrides) => {
      const request = await createLaterRequest(-HOUR_MS, overrides());
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.candidates).toBe(0);
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(recording.submissions).toHaveLength(0);
      expect(await SendLog.countDocuments({})).toBe(0);
      expect(await PushDelivery.countDocuments({})).toBe(0);
      // It leaves the awaiting state by TTL deletion, never by a stale alert.
      expect(await storedState(request)).toBe("awaiting-eligibility");
    });
  });

  describe("repeated, overlapping, and concurrent processing", () => {
    it("notifies each recipient exactly once across repeated runs", async () => {
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createConfirmedSubscriber(2);
      await createPushInstallation(1);
      const recording = provider();

      const first = await sweep(recording);
      const second = await sweep(recording);

      expect(first.initiated).toBe(1);
      expect(second.candidates).toBe(0);
      expect(sendNewRequestAlert).toHaveBeenCalledTimes(2);
      expect(recording.submissions).toHaveLength(1);
      expect(await SendLog.countDocuments({ requestId: request._id })).toBe(2);
      expect(await PushDelivery.countDocuments({ requestId: request._id })).toBe(
        1
      );
    });

    it("submits once per recipient under a concurrent second processor", async () => {
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      // A second process running the same initiation at the same time: the
      // in-process guard cannot see it, so only the existing `SendLog` and
      // `PushDelivery` unique claims stand between them and a duplicate.
      await Promise.all([
        sweep(recording),
        (async () => {
          await pushWith(recording)(request);
          await notifySubscribersForRequest(request);
        })(),
      ]);

      expect(await SendLog.countDocuments({ requestId: request._id })).toBe(1);
      expect(await PushDelivery.countDocuments({ requestId: request._id })).toBe(
        1
      );
      expect(await storedState(request)).toBe("initiated");
    });

    it("retries an interrupted initiation without duplicating a delivered one", async () => {
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      // A run whose push dispatch dies after the email already went out.
      const interrupted = await runEligibilityNotificationSweep({
        dispatchPush: async () => {
          throw new Error("process interrupted");
        },
      });

      expect(interrupted.deferred).toBe(1);
      expect(await storedState(request)).toBe("awaiting-eligibility");
      expect(await SendLog.countDocuments({ status: "sent" })).toBe(1);

      const recovered = await sweep(recording);

      expect(recovered.initiated).toBe(1);
      // The email is not sent twice: the existing per-pair claim already owns
      // it. The push that never happened does happen now.
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(recording.submissions).toHaveLength(1);
      expect(await SendLog.countDocuments({ requestId: request._id })).toBe(1);
      expect(await PushDelivery.countDocuments({ requestId: request._id })).toBe(
        1
      );
      expect(await storedState(request)).toBe("initiated");
    });
  });

  describe("per-recipient deduplication is the only email boundary", () => {
    it("skips the recipient who already has a send and still processes the rest", async () => {
      const request = await createLaterRequest(-1);
      const [a, b, c] = [
        await createConfirmedSubscriber(1),
        await createConfirmedSubscriber(2),
        await createConfirmedSubscriber(3),
      ];
      // A has already successfully received this request — the situation that
      // used to abandon the whole fan-out.
      await SendLog.create({
        requestId: request._id,
        subscriberId: a._id,
        sentAt: new Date(),
        status: "sent",
      });
      const recording = provider();

      await sweep(recording);

      const notified = sendNewRequestAlert.mock.calls.map(
        (call) => call[0].email
      );
      expect(notified.sort()).toEqual([b.email, c.email].sort());
      expect(notified).not.toContain(a.email);
      expect(await SendLog.countDocuments({ requestId: request._id })).toBe(3);
    });

    it("resumes an interrupted fan-out that had reached one recipient", async () => {
      const request = await createLaterRequest(-1);
      const [a, b] = [
        await createConfirmedSubscriber(1),
        await createConfirmedSubscriber(2),
      ];
      const recording = provider();

      // First attempt: the process dies after A, leaving A's row behind.
      await SendLog.create({
        requestId: request._id,
        subscriberId: a._id,
        sentAt: new Date(),
        status: "sent",
      });

      await sweep(recording);

      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(sendNewRequestAlert.mock.calls[0][0].email).toBe(b.email);
      expect(
        await SendLog.countDocuments({
          requestId: request._id,
          subscriberId: a._id,
        })
      ).toBe(1);
    });

    it("still prevents a duplicate to a recipient across repeated runs", async () => {
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createConfirmedSubscriber(2);
      const recording = provider();

      await sweep(recording);
      // A second, direct fan-out for the same request — the shape a concurrent
      // or catch-up processor produces.
      await notifySubscribersForRequest(request);

      expect(sendNewRequestAlert).toHaveBeenCalledTimes(2);
      expect(await SendLog.countDocuments({ requestId: request._id })).toBe(2);
    });

    it("skips a recipient the hourly digest already covered for this request", async () => {
      const request = await createLaterRequest(-1);
      const digested = await createConfirmedSubscriber(1);
      const fresh = await createConfirmedSubscriber(2);
      // Exactly the row the digest cron writes.
      await SendLog.create({
        requestId: request._id,
        subscriberId: digested._id,
        sentAt: new Date(),
        status: "sent",
        error: "digest",
      });
      const recording = provider();

      await sweep(recording);

      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(sendNewRequestAlert.mock.calls[0][0].email).toBe(fresh.email);
    });
  });

  describe("initiation is only consumed by a terminally processed channel", () => {
    it("keeps the request awaiting when it is unavailable at the moment a channel looks", async () => {
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      // A claim lands after selection, before either dispatcher's own
      // availability re-check.
      const claimExpiresAt = new Date(Date.now() + 15 * 60 * 1000);
      const summary = await runEligibilityNotificationSweep({
        dispatchPush: async (selected) => {
          await MealRequest.updateOne(
            { _id: selected._id },
            {
              $set: {
                status: "claimed",
                claimedAt: new Date(),
                claimExpiresAt,
              },
            }
          );
          return pushChannel(recording)(selected);
        },
      });

      expect(summary.deferred).toBe(1);
      expect(summary.initiated).toBe(0);
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(recording.submissions).toHaveLength(0);
      expect(await SendLog.countDocuments({})).toBe(0);
      expect(await PushDelivery.countDocuments({})).toBe(0);
      // The state survived: this request is still discoverable.
      expect(await storedState(request)).toBe("awaiting-eligibility");

      // The claim expires while the request is still within its window.
      await MealRequest.updateOne(
        { _id: request._id },
        { $set: { claimExpiresAt: new Date(Date.now() - 1000) } }
      );

      const recovered = await sweep(recording);

      expect(recovered.initiated).toBe(1);
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(recording.submissions).toHaveLength(1);
      expect(await storedState(request)).toBe("initiated");
    });

    it("recovers from a retryable SendLog claim-write failure without duplicating push", async () => {
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const create = vi
        .spyOn(SendLog, "create")
        .mockRejectedValueOnce(new Error("database unavailable") as never);

      const blocked = await sweep(recording);

      expect(blocked.deferred).toBe(1);
      expect(await storedState(request)).toBe("awaiting-eligibility");
      expect(await SendLog.countDocuments({})).toBe(0);
      // Push did reach its terminal outcome and is not repeated below.
      expect(recording.submissions).toHaveLength(1);

      create.mockRestore();
      const recovered = await sweep(recording);

      expect(recovered.initiated).toBe(1);
      expect(await SendLog.countDocuments({ status: "sent" })).toBe(1);
      expect(recording.submissions).toHaveLength(1);
      expect(await PushDelivery.countDocuments({})).toBe(1);
      expect(await storedState(request)).toBe("initiated");
    });

    it("recovers from a retryable PushDelivery claim-write failure without duplicating email", async () => {
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const create = vi
        .spyOn(PushDelivery, "create")
        .mockRejectedValueOnce(new Error("database unavailable") as never);

      const blocked = await sweep(recording);

      expect(blocked.deferred).toBe(1);
      expect(await storedState(request)).toBe("awaiting-eligibility");
      expect(await PushDelivery.countDocuments({})).toBe(0);
      expect(recording.submissions).toHaveLength(0);
      // Email did reach its terminal outcome and is not repeated below.
      expect(await SendLog.countDocuments({ status: "sent" })).toBe(1);

      create.mockRestore();
      const recovered = await sweep(recording);

      expect(recovered.initiated).toBe(1);
      expect(recording.submissions).toHaveLength(1);
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(await SendLog.countDocuments({ requestId: request._id })).toBe(1);
      expect(await storedState(request)).toBe("initiated");
    });

    it.each([
      [
        "a token rejection",
        {
          classification: "token-rejected",
          status: 410,
          reason: "Unregistered",
        } as ApnsOutcome,
      ],
      [
        "a transient submission failure",
        {
          classification: "transient",
          status: 503,
          reason: "ServiceUnavailable",
        } as ApnsOutcome,
      ],
    ])(
      "consumes initiation on %s, so the request does not loop until it expires",
      async (_label, outcome) => {
        const request = await createLaterRequest(-1);
        await createConfirmedSubscriber(1);
        await createPushInstallation(1);
        const recording = provider(() => outcome);

        const first = await sweep(recording);

        expect(first.initiated).toBe(1);
        expect(await storedState(request)).toBe("initiated");

        const second = await sweep(recording);

        // Terminal stays terminal: V1 has no push retry, and the sweep must
        // not become one.
        expect(second.candidates).toBe(0);
        expect(recording.submissions).toHaveLength(1);
      }
    );

    it("consumes initiation when no recipients exist at all", async () => {
      const request = await createLaterRequest(-1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.initiated).toBe(1);
      expect(await storedState(request)).toBe("initiated");
      expect(await SendLog.countDocuments({})).toBe(0);
      expect(await PushDelivery.countDocuments({})).toBe(0);
    });
  });

  describe("pre-N3 W3-R1 Later rows", () => {
    /**
     * Exactly what W3-R1 persisted before this slice existed: correct
     * `visibleFrom`/`expiresAt`, a scheduled `windowStart`, an old
     * `createdAt`, and no `helperNotification` field at all.
     */
    async function createPreN3LaterRequest(
      visibleFromOffsetMs: number,
      ageMs = 9 * HOUR_MS
    ): Promise<IRequest> {
      const request = await createLaterRequest(visibleFromOffsetMs);
      await backdateCreation(request, ageMs);
      await MealRequest.collection.updateOne(
        { _id: request._id as never },
        { $unset: { helperNotification: "" } }
      );
      return request;
    }

    it("is not notified before its visibleFrom", async () => {
      await createPreN3LaterRequest(2 * HOUR_MS);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.candidates).toBe(0);
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(recording.submissions).toHaveLength(0);
      expect(await SendLog.countDocuments({})).toBe(0);
      expect(await PushDelivery.countDocuments({})).toBe(0);
    });

    it("is discovered once eligible, however old its createdAt is", async () => {
      const request = await createPreN3LaterRequest(-1, 30 * HOUR_MS);
      const subscriber = await createConfirmedSubscriber(1);
      const installation = await createPushInstallation(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.initiated).toBe(1);
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(recording.submissions).toHaveLength(1);
      expect(
        await SendLog.countDocuments({
          requestId: request._id,
          subscriberId: subscriber._id,
          status: "sent",
        })
      ).toBe(1);
      expect(
        await PushDelivery.countDocuments({
          requestId: request._id,
          installationId: installation._id,
          status: "accepted",
        })
      ).toBe(1);
      // The transition row can leave the unset state, not only the awaiting one.
      expect(await storedState(request)).toBe("initiated");
    });

    it.each([
      [
        "a row with no visibleFrom at all",
        async (request: IRequest) => {
          await MealRequest.collection.updateOne(
            { _id: request._id as never },
            { $unset: { visibleFrom: "" } }
          );
        },
      ],
      [
        "a row with no scheduled windowStart",
        async (request: IRequest) => {
          await MealRequest.collection.updateOne(
            { _id: request._id as never },
            { $unset: { windowStart: "" } }
          );
        },
      ],
      [
        "a row whose visibility began at or before creation",
        async (request: IRequest) => {
          await MealRequest.collection.updateOne(
            { _id: request._id as never },
            { $set: { createdAt: new Date() } }
          );
        },
      ],
    ])("leaves %s untouched", async (_label, degrade) => {
      // Not a legacy migration: a row that cannot prove it is a future Later
      // request stays out of the transition population entirely.
      const legacy = await createPreN3LaterRequest(-1);
      await degrade(legacy);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.candidates).toBe(0);
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(recording.submissions).toHaveLength(0);
      expect(await storedState(legacy)).toBeUndefined();
    });

    it("stays deduplicated under repeated processing", async () => {
      const request = await createPreN3LaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      await sweep(recording);
      const second = await sweep(recording);

      expect(second.candidates).toBe(0);
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(recording.submissions).toHaveLength(1);
      expect(await SendLog.countDocuments({ requestId: request._id })).toBe(1);
      expect(await PushDelivery.countDocuments({ requestId: request._id })).toBe(
        1
      );
    });

    it("is protected by existing dedupe if a channel had somehow already run", async () => {
      const request = await createPreN3LaterRequest(-1);
      const subscriber = await createConfirmedSubscriber(1);
      await SendLog.create({
        requestId: request._id,
        subscriberId: subscriber._id,
        sentAt: new Date(),
        status: "sent",
      });
      const recording = provider();

      await sweep(recording);

      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(await SendLog.countDocuments({ requestId: request._id })).toBe(1);
    });
  });

  describe("requests the sweep must never own", () => {
    it("adds no second notification to an ASAP request", async () => {
      const request = await createAsapRequest();
      const subscriber = await createConfirmedSubscriber(1);
      const installation = await createPushInstallation(1);
      const recording = provider();

      // Creation-time dispatch, exactly as `POST /api/request` performs it.
      await pushWith(recording)(request);
      await notifySubscribersForRequest(request);
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(recording.submissions).toHaveLength(1);

      const summary = await sweep(recording);

      expect(summary.candidates).toBe(0);
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(recording.submissions).toHaveLength(1);
      expect(
        await SendLog.countDocuments({
          requestId: request._id,
          subscriberId: subscriber._id,
        })
      ).toBe(1);
      expect(
        await PushDelivery.countDocuments({
          requestId: request._id,
          installationId: installation._id,
        })
      ).toBe(1);
    });

    it("never selects a pre-W3-R1 row that cannot prove it is a future Later request", async () => {
      // Neither `helperNotification` nor `visibleFrom` — a row from before
      // either field existed. It is left alone for the same reason nothing
      // migrates `visibleFrom`, and the transition branch cannot reach it.
      const legacy = await createLaterRequest(-1);
      await backdateCreation(legacy, 9 * HOUR_MS);
      await MealRequest.collection.updateOne(
        { _id: legacy._id as never },
        { $unset: { helperNotification: "", visibleFrom: "" } }
      );
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.candidates).toBe(0);
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(recording.submissions).toHaveLength(0);
    });
  });

  describe("preserved gates", () => {
    it("consumes no awaiting state while public actions are paused", async () => {
      vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      const summary = await runEligibilityNotificationSweep({
        dispatchPush: pushChannel(recording),
      });

      expect(summary.stop).toBe("paused");
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(recording.submissions).toHaveLength(0);
      expect(await SendLog.countDocuments({})).toBe(0);
      expect(await PushDelivery.countDocuments({})).toBe(0);
      // The whole point of failing closed: unpausing must still notify.
      expect(await storedState(request)).toBe("awaiting-eligibility");
    });

    it("keeps the existing recipient eligibility rules", async () => {
      await createLaterRequest(-1);
      const confirmed = await createConfirmedSubscriber(1);
      await Subscriber.create({
        email: "pending@nyu.edu",
        status: "pending",
        confirmationTokenDigest: "a".repeat(64),
        confirmationExpiresAt: new Date(Date.now() + HOUR_MS),
        bounced: false,
        dailyCount: 0,
      });
      await Subscriber.create({
        email: "gone@nyu.edu",
        status: "unsubscribed",
        bounced: false,
        dailyCount: 0,
      });
      await Subscriber.create({
        email: "bounced@nyu.edu",
        status: "confirmed",
        bounced: true,
        dailyCount: 0,
      });
      const eligibleInstallation = await createPushInstallation(1);
      await createPushInstallation(2, { pushEnabled: false });
      await createPushInstallation(3, {
        invalidatedAt: new Date(),
        pushEnabled: false,
      });
      const recording = provider();

      await sweep(recording);

      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(sendNewRequestAlert.mock.calls[0][0].email).toBe(confirmed.email);
      expect(recording.submissions).toHaveLength(1);
      expect(
        await PushDelivery.countDocuments({
          installationId: eligibleInstallation._id,
        })
      ).toBe(1);
    });

    it("leaves each channel unaffected by the other's absence", async () => {
      const emailOnly = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      const recording = provider();

      const summary = await sweep(recording);

      expect(summary.initiated).toBe(1);
      expect(sendNewRequestAlert).toHaveBeenCalledOnce();
      expect(await PushDelivery.countDocuments({})).toBe(0);
      expect(await storedState(emailOnly)).toBe("initiated");
    });

    it("carries the awaiting-eligibility selection index", async () => {
      const indexes = await MealRequest.collection.indexes();
      const awaiting = indexes.find(
        (index) => index.name === "request_helper_notification_awaiting"
      );

      expect(awaiting).toBeDefined();
      expect(awaiting?.key).toEqual({ visibleFrom: 1 });
      expect(awaiting?.partialFilterExpression).toEqual({
        helperNotification: "awaiting-eligibility",
      });
      expect(awaiting?.unique).toBeUndefined();
    });

    it("stores no requester-private content in either delivery ledger", async () => {
      const request = await createLaterRequest(-1);
      await createConfirmedSubscriber(1);
      await createPushInstallation(1);
      const recording = provider();

      await sweep(recording);

      const written = JSON.stringify([
        await SendLog.find({}).lean(),
        await PushDelivery.find({}).lean(),
      ]);

      for (const secret of [
        "Requester Private Name",
        "requester@nyu.edu",
        apnsToken(1),
        credential(1),
      ]) {
        expect(written).not.toContain(secret);
      }
      expect(written).toContain(String(request._id));
    });
  });
  describe("W4-R5 email dispatcher notification-generation fence", () => {
    it("sends nothing and leaves no SendLog for a request withdrawn before dispatch", async () => {
      const request = await createAsapRequest();
      await createConfirmedSubscriber(1);
      await MealRequest.updateOne(
        { _id: request._id },
        { $set: { status: "withdrawn", withdrawnAt: new Date() } }
      );

      await notifySubscribersForRequest(request);

      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(await SendLog.countDocuments({})).toBe(0);
    });

    it("stops the remaining recipients once the request is withdrawn mid-dispatch", async () => {
      const request = await createAsapRequest();
      for (const index of [1, 2, 3]) await createConfirmedSubscriber(index);
      sendNewRequestAlert.mockImplementationOnce(async () => {
        await MealRequest.updateOne(
          { _id: request._id },
          { $set: { status: "withdrawn", withdrawnAt: new Date() } }
        );
      });

      await notifySubscribersForRequest(request);

      expect(sendNewRequestAlert).toHaveBeenCalledTimes(1);
      expect(await SendLog.countDocuments({})).toBe(1);
    });
  });
});
vi.mock("./requestAlertEmailDelivery.js", () => ({ isRequestAlertEmailDeliveryActive: () => true }));
