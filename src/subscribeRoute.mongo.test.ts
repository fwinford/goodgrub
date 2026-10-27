import type { Request, Response } from "express";
import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { Subscriber } from "../models/db.js";
vi.mock("./requestAlertEmailDelivery.js", () => ({ isRequestAlertEmailDeliveryActive: () => true }));

vi.mock("./emailHelpers.js", () => ({
  sendSubscriptionConfirmationEmail: vi.fn(),
}));

import {
  CONFIRMATION_LIFETIME_MS,
  CONFIRMATION_SEND_LEASE_MS,
  SUBSCRIBE_ACCEPTED_RESPONSE,
  createSubscribeHandler,
  digestConfirmationToken,
} from "./subscribeRoute.js";

/**
 * Mirrors the name thrown by the real `sendSubscriptionConfirmationEmail`
 * deadline. `emailHelpers.test.ts` proves a genuine abort produces that error;
 * these suites prove such a rejection takes the compensation while preserving
 * the generic accepted public response.
 */
class ProviderTimeout extends Error {
  constructor() {
    super("Email provider did not answer within 30000ms");
    this.name = "EmailProviderTimeoutError";
  }
}

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;
const backendNow = new Date("2026-08-03T18:30:00.000Z");

function routeContext(email: string) {
  const req = {
    body: { email },
    protocol: "https",
    get: () => "commonplate.test",
  } as unknown as Request;
  const res = {} as Response;
  let statusCode = 200;
  let bodyValue: any;
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    bodyValue = value;
    return res;
  }) as any;
  return {
    req,
    res,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return bodyValue;
    },
  };
}

function rawToken(byte: number): string {
  return Buffer.alloc(32, byte).toString("base64url");
}

function expectAccepted(context: ReturnType<typeof routeContext>) {
  expect(context.statusCode).toBe(202);
  expect(JSON.stringify(context.body)).toBe(
    JSON.stringify(SUBSCRIBE_ACCEPTED_RESPONSE)
  );
}

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

describeMongo("pending subscription lifecycle against real MongoDB", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
    await Subscriber.syncIndexes();
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    await Subscriber.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("creates one pending record with only a digest and an exact 24-hour expiry", async () => {
    const token = rawToken(1);
    const sendConfirmationEmail = vi.fn().mockResolvedValue(undefined);
    const context = routeContext("  New.Helper@NYU.EDU  ");

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => token,
      generateAttemptId: () => "new-attempt",
      sendConfirmationEmail,
    })(context.req, context.res);

    expectAccepted(context);
    expect(sendConfirmationEmail).toHaveBeenCalledWith(
      "new.helper@nyu.edu",
      token
    );
    const stored = await Subscriber.collection.findOne({
      email: "new.helper@nyu.edu",
    });
    expect(stored?.status).toBe("pending");
    expect(stored?.confirmationTokenDigest).toBe(
      digestConfirmationToken(token)
    );
    expect(stored?.confirmationExpiresAt).toEqual(
      new Date(backendNow.getTime() + CONFIRMATION_LIFETIME_MS)
    );
    expect(stored).not.toHaveProperty("confirmationSendAttemptId");
    expect(stored).not.toHaveProperty("confirmationSendAttemptAt");
    expect(stored).not.toHaveProperty("confirmToken");
    expect(JSON.stringify(stored)).not.toContain(token);
    expect(JSON.stringify(context.body)).not.toContain(token);
    expect(stored?.dailyCount).toBe(0);
    expect(stored?.bounced).toBe(false);
  });

  it("rotates an unexpired pending lifecycle on the same document", async () => {
    const id = new mongoose.Types.ObjectId();
    const previousDigest = "a".repeat(64);
    const previousExpiry = new Date(backendNow.getTime() + 60_000);
    const lastSentAt = new Date("2026-08-01T16:00:00.000Z");
    await Subscriber.collection.insertOne({
      _id: id,
      email: "pending@nyu.edu",
      status: "pending",
      confirmationTokenDigest: previousDigest,
      confirmationExpiresAt: previousExpiry,
      bounced: true,
      dailyCount: 3,
      lastSentAt,
    });
    const token = rawToken(2);
    const context = routeContext("pending@nyu.edu");

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => token,
      generateAttemptId: () => "pending-attempt",
      sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
    })(context.req, context.res);

    expectAccepted(context);
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?._id).toEqual(id);
    expect(stored?.confirmationTokenDigest).toBe(
      digestConfirmationToken(token)
    );
    expect(stored?.confirmationTokenDigest).not.toBe(previousDigest);
    expect(stored?.confirmationExpiresAt).toEqual(
      new Date(backendNow.getTime() + CONFIRMATION_LIFETIME_MS)
    );
    expect(stored?.bounced).toBe(true);
    expect(stored?.dailyCount).toBe(3);
    expect(stored?.lastSentAt).toEqual(lastSentAt);
    expect(stored).not.toHaveProperty("unsubToken");
  });

  it("rotates an expired pending lifecycle on the same document", async () => {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "expired@nyu.edu",
      status: "pending",
      confirmationTokenDigest: "b".repeat(64),
      confirmationExpiresAt: new Date(backendNow.getTime() - 1),
      bounced: false,
      dailyCount: 0,
      lastSentAt: null,
    });
    const token = rawToken(3);
    const context = routeContext("expired@nyu.edu");

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => token,
      generateAttemptId: () => "expired-attempt",
      sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
    })(context.req, context.res);

    expectAccepted(context);
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?._id).toEqual(id);
    expect(stored?.status).toBe("pending");
    expect(stored?.confirmationTokenDigest).toBe(
      digestConfirmationToken(token)
    );
  });

  it("rotates an unsubscribed lifecycle while preserving all history", async () => {
    const id = new mongoose.Types.ObjectId();
    const lastSentAt = new Date("2026-07-31T12:00:00.000Z");
    const unsubscribedAt = new Date("2026-08-01T12:00:00.000Z");
    await Subscriber.collection.insertOne({
      _id: id,
      email: "unsubscribed@nyu.edu",
      status: "unsubscribed",
      bounced: true,
      dailyCount: 4,
      lastSentAt,
      unsubToken: "existing-unsubscribe-token",
      unsubscribedAt,
      unsubscribeCredentialVersion: 3,
      deliveryHistoryMarker: { provider: "preserved" },
    });
    const token = rawToken(4);
    const context = routeContext("unsubscribed@nyu.edu");

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => token,
      generateAttemptId: () => "unsubscribed-attempt",
      sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
    })(context.req, context.res);

    expectAccepted(context);
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?._id).toEqual(id);
    expect(stored?.status).toBe("pending");
    expect(stored?.confirmationTokenDigest).toBe(
      digestConfirmationToken(token)
    );
    expect(stored?.bounced).toBe(true);
    expect(stored?.dailyCount).toBe(4);
    expect(stored?.lastSentAt).toEqual(lastSentAt);
    expect(stored?.unsubToken).toBe("existing-unsubscribe-token");
    expect(stored?.unsubscribedAt).toEqual(unsubscribedAt);
    expect(stored?.deliveryHistoryMarker).toEqual({ provider: "preserved" });
    // The revocation counter is what every emailed unsubscribe link is signed
    // against. Re-signup preserving it is what keeps an old link working.
    expect(stored?.unsubscribeCredentialVersion).toBe(3);
  });

  it("gives a brand-new subscriber the initial credential version", async () => {
    const token = rawToken(40);
    const context = routeContext("brand-new-version@nyu.edu");

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => token,
      generateAttemptId: () => "brand-new-version-attempt",
      sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
    })(context.req, context.res);

    expectAccepted(context);
    const stored = await Subscriber.collection.findOne({
      email: "brand-new-version@nyu.edu",
    });
    // Nothing in the route names this field: the schema default supplies it.
    expect(stored?.unsubscribeCredentialVersion).toBe(1);
    expect(stored).not.toHaveProperty("unsubscribeTokenDigest");
  });

  it("leaves a legacy document with no credential version untouched", async () => {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "legacy-version@nyu.edu",
      status: "unsubscribed",
      bounced: false,
      dailyCount: 2,
      lastSentAt: new Date("2026-07-30T12:00:00.000Z"),
    });
    const token = rawToken(41);
    const context = routeContext("legacy-version@nyu.edu");

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => token,
      generateAttemptId: () => "legacy-version-attempt",
      sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
    })(context.req, context.res);

    expectAccepted(context);
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?.status).toBe("pending");
    // Re-signup writes no version onto an older document either; such a
    // document is treated as the initial version when a link is signed.
    expect(stored).not.toHaveProperty("unsubscribeCredentialVersion");
    expect(stored?.dailyCount).toBe(2);
  });

  it("returns the same accepted response for confirmed without a write or email", async () => {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "confirmed@nyu.edu",
      status: "confirmed",
      bounced: false,
      dailyCount: 1,
      unsubToken: "unsubscribe-token",
    });
    const before = await Subscriber.collection.findOne({ _id: id });
    const sendConfirmationEmail = vi.fn();
    const update = vi.spyOn(Subscriber, "findOneAndUpdate");
    const context = routeContext("confirmed@nyu.edu");

    await createSubscribeHandler({ sendConfirmationEmail })(
      context.req,
      context.res
    );

    expectAccepted(context);
    expect(sendConfirmationEmail).not.toHaveBeenCalled();
    expect(update).not.toHaveBeenCalled();
    expect(await Subscriber.collection.findOne({ _id: id })).toEqual(before);
  });

  it("conditionally deletes a new record when the provider throws", async () => {
    const context = routeContext("new-failure@nyu.edu");

    await createSubscribeHandler({
      generateRawToken: () => rawToken(5),
      generateAttemptId: () => "new-failure-attempt",
      sendConfirmationEmail: vi.fn().mockRejectedValue(new Error("offline")),
    })(context.req, context.res);

    expectAccepted(context);
    expect(
      await Subscriber.countDocuments({ email: "new-failure@nyu.edu" })
    ).toBe(0);
  });

  it("restores exact absent, null, and valued fields when the provider returns an error", async () => {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "rollback@nyu.edu",
      status: "unsubscribed",
      confirmationExpiresAt: null,
      confirmToken: "legacy-raw-token",
      bounced: true,
      dailyCount: 2,
      lastSentAt: null,
      unsubToken: "preserved-unsubscribe-token",
      unsubscribedAt: new Date("2026-08-01T00:00:00.000Z"),
    });
    const before = await Subscriber.collection.findOne({ _id: id });
    const context = routeContext("rollback@nyu.edu");

    await createSubscribeHandler({
      generateRawToken: () => rawToken(6),
      generateAttemptId: () => "rollback-attempt",
      sendConfirmationEmail: vi
        .fn()
        .mockResolvedValue({ error: { message: "rejected" } }),
    })(context.req, context.res);

    expectAccepted(context);
    expect(await Subscriber.collection.findOne({ _id: id })).toEqual(before);
  });

  it("restores a pending lifecycle after provider failure while returning generic acceptance", async () => {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "pending-failure@nyu.edu",
      status: "pending",
      confirmationTokenDigest: "a".repeat(64),
      confirmationExpiresAt: new Date(backendNow.getTime() + 60_000),
      bounced: false,
      dailyCount: 0,
    });
    const before = await Subscriber.collection.findOne({ _id: id });
    const context = routeContext("pending-failure@nyu.edu");

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => rawToken(30),
      generateAttemptId: () => "pending-failure-attempt",
      sendConfirmationEmail: vi.fn().mockRejectedValue(new Error("offline")),
    })(context.req, context.res);

    expectAccepted(context);
    expect(await Subscriber.collection.findOne({ _id: id })).toEqual(before);
  });

  it("cannot delete a newer lifecycle during stale new-record cleanup", async () => {
    const enteredProvider = deferred();
    const releaseProvider = deferred();
    const context = routeContext("stale-delete@nyu.edu");
    const attempt = createSubscribeHandler({
      generateRawToken: () => rawToken(7),
      generateAttemptId: () => "stale-delete-attempt",
      sendConfirmationEmail: vi.fn(async () => {
        enteredProvider.resolve();
        await releaseProvider.promise;
        throw new Error("provider failed");
      }),
    })(context.req, context.res);

    await enteredProvider.promise;
    const newerDigest = "c".repeat(64);
    await Subscriber.updateOne(
      { email: "stale-delete@nyu.edu" },
      {
        $set: {
          confirmationTokenDigest: newerDigest,
          confirmationSendAttemptId: "newer-attempt",
        },
      }
    );
    releaseProvider.resolve();
    await attempt;

    expectAccepted(context);
    const stored = await Subscriber.collection.findOne({
      email: "stale-delete@nyu.edu",
    });
    expect(stored?.confirmationTokenDigest).toBe(newerDigest);
    expect(stored?.confirmationSendAttemptId).toBe("newer-attempt");
  });

  it("cannot overwrite a newer lifecycle during stale existing-state rollback", async () => {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "stale-rollback@nyu.edu",
      status: "pending",
      confirmationTokenDigest: "d".repeat(64),
      confirmationExpiresAt: new Date(backendNow.getTime() + 60_000),
      bounced: false,
      dailyCount: 0,
    });
    const enteredProvider = deferred();
    const releaseProvider = deferred();
    const context = routeContext("stale-rollback@nyu.edu");
    const attempt = createSubscribeHandler({
      generateRawToken: () => rawToken(8),
      generateAttemptId: () => "stale-rollback-attempt",
      sendConfirmationEmail: vi.fn(async () => {
        enteredProvider.resolve();
        await releaseProvider.promise;
        throw new Error("provider failed");
      }),
    })(context.req, context.res);

    await enteredProvider.promise;
    const newerDigest = "e".repeat(64);
    await Subscriber.updateOne(
      { _id: id },
      {
        $set: {
          confirmationTokenDigest: newerDigest,
          confirmationSendAttemptId: "newer-attempt",
        },
      }
    );
    releaseProvider.resolve();
    await attempt;

    expectAccepted(context);
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?.confirmationTokenDigest).toBe(newerDigest);
    expect(stored?.confirmationSendAttemptId).toBe("newer-attempt");
  });

  it("serializes simultaneous first signup so only the current token is submitted", async () => {
    const bothAtCreate = deferred();
    const enteredProvider = deferred();
    const releaseProvider = deferred();
    const originalCreate = (Subscriber.create as any).bind(Subscriber);
    let createArrivals = 0;
    vi.spyOn(Subscriber, "create").mockImplementation((async (...args: any[]) => {
      createArrivals += 1;
      if (createArrivals === 2) bothAtCreate.resolve();
      await bothAtCreate.promise;
      return originalCreate(...args);
    }) as any);
    const find = vi.spyOn(Subscriber, "findOne");
    let tokenByte = 9;
    let attemptNumber = 0;
    const generatedTokens: string[] = [];
    const generateRawToken = vi.fn(() => {
      const token = rawToken(tokenByte++);
      generatedTokens.push(token);
      return token;
    });
    const sendConfirmationEmail = vi.fn(async () => {
      enteredProvider.resolve();
      await releaseProvider.promise;
    });
    const handler = createSubscribeHandler({
      generateRawToken,
      generateAttemptId: () => `first-owner-${++attemptNumber}`,
      sendConfirmationEmail,
    });
    const first = routeContext("concurrent-new@nyu.edu");
    const second = routeContext("concurrent-new@nyu.edu");
    const firstAttempt = handler(first.req, first.res);
    const secondAttempt = handler(second.req, second.res);

    await enteredProvider.promise;
    const losingAttempt = await Promise.race([
      firstAttempt.then(() => first),
      secondAttempt.then(() => second),
    ]);
    expectAccepted(losingAttempt);
    releaseProvider.resolve();
    await Promise.all([firstAttempt, secondAttempt]);

    expectAccepted(first);
    expectAccepted(second);
    expect(generateRawToken).toHaveBeenCalledTimes(2);
    expect(sendConfirmationEmail).toHaveBeenCalledOnce();
    expect(
      find.mock.calls.filter(
        ([filter]) =>
          (filter as { email?: string }).email === "concurrent-new@nyu.edu"
      )
    ).toHaveLength(3);
    expect(await Subscriber.countDocuments({ email: "concurrent-new@nyu.edu" })).toBe(1);
    const stored = await Subscriber.collection.findOne({
      email: "concurrent-new@nyu.edu",
    });
    const submittedToken = (
      sendConfirmationEmail.mock.calls as unknown as [string, string, string][]
    )[0][1];
    const discardedToken = generatedTokens.find(
      (candidate) => candidate !== submittedToken
    );
    expect(stored?.confirmationTokenDigest).toBe(
      digestConfirmationToken(submittedToken)
    );
    expect(stored?.confirmationTokenDigest).not.toBe(
      digestConfirmationToken(discardedToken!)
    );
    expect(stored).not.toHaveProperty("confirmationSendAttemptId");
    expect(stored).not.toHaveProperty("confirmationSendAttemptAt");
  });

  it("makes a simultaneous pending loser re-read and submit no discarded token", async () => {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "concurrent-pending@nyu.edu",
      status: "pending",
      confirmationTokenDigest: "f".repeat(64),
      confirmationExpiresAt: new Date(backendNow.getTime() + 60_000),
      bounced: false,
      dailyCount: 0,
    });
    const bothAtRotation = deferred();
    const enteredProvider = deferred();
    const releaseProvider = deferred();
    const originalFindOneAndUpdate = (Subscriber.findOneAndUpdate as any).bind(
      Subscriber
    );
    let rotationArrivals = 0;
    vi.spyOn(Subscriber, "findOneAndUpdate").mockImplementation(((...args: any[]) => {
      const query = originalFindOneAndUpdate(...args);
      const originalExec = query.exec.bind(query);
      query.exec = async () => {
        rotationArrivals += 1;
        if (rotationArrivals === 2) bothAtRotation.resolve();
        await bothAtRotation.promise;
        return originalExec();
      };
      return query;
    }) as any);
    let tokenByte = 11;
    let attemptNumber = 0;
    const generatedTokens: string[] = [];
    const generateRawToken = vi.fn(() => {
      const token = rawToken(tokenByte++);
      generatedTokens.push(token);
      return token;
    });
    const sendConfirmationEmail = vi.fn(async () => {
      enteredProvider.resolve();
      await releaseProvider.promise;
    });
    const handler = createSubscribeHandler({
      generateRawToken,
      generateAttemptId: () => `pending-owner-${++attemptNumber}`,
      sendConfirmationEmail,
    });
    const first = routeContext("concurrent-pending@nyu.edu");
    const second = routeContext("concurrent-pending@nyu.edu");
    const find = vi.spyOn(Subscriber, "findOne");
    const firstAttempt = handler(first.req, first.res);
    const secondAttempt = handler(second.req, second.res);

    await enteredProvider.promise;
    const losingAttempt = await Promise.race([
      firstAttempt.then(() => first),
      secondAttempt.then(() => second),
    ]);
    expectAccepted(losingAttempt);
    releaseProvider.resolve();
    await Promise.all([firstAttempt, secondAttempt]);

    expectAccepted(first);
    expectAccepted(second);
    expect(generateRawToken).toHaveBeenCalledTimes(2);
    expect(sendConfirmationEmail).toHaveBeenCalledOnce();
    expect(
      find.mock.calls.filter(
        ([filter]) =>
          (filter as { email?: string }).email ===
          "concurrent-pending@nyu.edu"
      )
    ).toHaveLength(3);
    const submittedToken = (
      sendConfirmationEmail.mock.calls as unknown as [string, string, string][]
    )[0][1];
    const discardedToken = generatedTokens.find(
      (candidate) => candidate !== submittedToken
    );
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?.confirmationTokenDigest).toBe(
      digestConfirmationToken(submittedToken)
    );
    expect(stored?.confirmationTokenDigest).not.toBe(
      digestConfirmationToken(discardedToken!)
    );
    expect(stored).not.toHaveProperty("confirmationSendAttemptId");
    expect(stored).not.toHaveProperty("confirmationSendAttemptAt");
  });

  describe("bounded send-ownership lease", () => {
    const email = "leased@nyu.edu";
    const heldDigest = "1".repeat(64);

    async function insertOwned(attemptAt: Date | undefined) {
      const id = new mongoose.Types.ObjectId();
      await Subscriber.collection.insertOne({
        _id: id,
        email,
        status: "pending",
        confirmationTokenDigest: heldDigest,
        confirmationExpiresAt: new Date(backendNow.getTime() + 60_000),
        confirmationSendAttemptId: "dead-owner",
        ...(attemptAt ? { confirmationSendAttemptAt: attemptAt } : {}),
        bounced: false,
        dailyCount: 0,
      });
      return id;
    }

    it("blocks a second sender while the owner's lease is still live", async () => {
      const id = await insertOwned(
        new Date(backendNow.getTime() - CONFIRMATION_SEND_LEASE_MS + 1_000)
      );
      const sendConfirmationEmail = vi.fn();
      const context = routeContext(email);

      await createSubscribeHandler({
        now: () => backendNow,
        generateRawToken: () => rawToken(20),
        generateAttemptId: () => "intruder",
        sendConfirmationEmail,
      })(context.req, context.res);

      expectAccepted(context);
      expect(sendConfirmationEmail).not.toHaveBeenCalled();
      const stored = await Subscriber.collection.findOne({ _id: id });
      expect(stored?.confirmationTokenDigest).toBe(heldDigest);
      expect(stored?.confirmationSendAttemptId).toBe("dead-owner");
    });

    it.each([
      [
        "an owner exactly at the lease boundary",
        new Date(backendNow.getTime() - CONFIRMATION_SEND_LEASE_MS),
      ],
      [
        "an owner past the lease boundary",
        new Date(backendNow.getTime() - CONFIRMATION_SEND_LEASE_MS - 1),
      ],
      ["an owner recorded with no lease timestamp", undefined],
    ])(
      "recovers a lifecycle abandoned by %s",
      async (_label, attemptAt) => {
        const id = await insertOwned(attemptAt);
        const token = rawToken(21);
        const sendConfirmationEmail = vi.fn().mockResolvedValue(undefined);
        const context = routeContext(email);

        await createSubscribeHandler({
          now: () => backendNow,
          generateRawToken: () => token,
          generateAttemptId: () => "recovering-attempt",
          sendConfirmationEmail,
        })(context.req, context.res);

        expectAccepted(context);
        expect(sendConfirmationEmail).toHaveBeenCalledOnce();
        expect(sendConfirmationEmail).toHaveBeenCalledWith(email, token);
        const stored = await Subscriber.collection.findOne({ _id: id });
        expect(stored?._id).toEqual(id);
        expect(stored?.confirmationTokenDigest).toBe(
          digestConfirmationToken(token)
        );
        expect(stored?.confirmationTokenDigest).not.toBe(heldDigest);
        expect(stored?.confirmationExpiresAt).toEqual(
          new Date(backendNow.getTime() + CONFIRMATION_LIFETIME_MS)
        );
        expect(stored).not.toHaveProperty("confirmationSendAttemptId");
        expect(stored).not.toHaveProperty("confirmationSendAttemptAt");
      }
    );

    it("restores the exact stale owner when a takeover's submission fails", async () => {
      const staleAt = new Date(
        backendNow.getTime() - CONFIRMATION_SEND_LEASE_MS - 30_000
      );
      const id = await insertOwned(staleAt);
      const before = await Subscriber.collection.findOne({ _id: id });
      const context = routeContext(email);

      await createSubscribeHandler({
        now: () => backendNow,
        generateRawToken: () => rawToken(22),
        generateAttemptId: () => "failing-takeover",
        sendConfirmationEmail: vi.fn().mockRejectedValue(new ProviderTimeout()),
      })(context.req, context.res);

      expectAccepted(context);
      // Including the expired lease itself: an already-stale owner is harmless
      // because the next signup may take it over again immediately.
      expect(await Subscriber.collection.findOne({ _id: id })).toEqual(before);
      expect(
        (await Subscriber.collection.findOne({ _id: id }))
          ?.confirmationSendAttemptAt
      ).toEqual(staleAt);
    });

    it("still answers 202 when the owner clear fails, and recovers after the lease", async () => {
      const errors = vi.spyOn(console, "error").mockImplementation(() => {});
      const firstToken = rawToken(23);
      const clear = vi
        .spyOn(Subscriber, "updateOne")
        .mockRejectedValueOnce(new Error("clear unavailable") as never);
      const firstSend = vi.fn().mockResolvedValue(undefined);
      const first = routeContext(email);

      await createSubscribeHandler({
        now: () => backendNow,
        generateRawToken: () => firstToken,
        generateAttemptId: () => "stranded-owner",
        sendConfirmationEmail: firstSend,
      })(first.req, first.res);

      expectAccepted(first);
      expect(firstSend).toHaveBeenCalledOnce();
      expect(errors).toHaveBeenCalledWith(
        expect.stringContaining(
          "Confirmation send-owner clear outcome is unknown"
        ),
        expect.objectContaining({
          subscriberId: expect.any(String),
          attemptId: "stranded-owner",
        })
      );
      expect(JSON.stringify(errors.mock.calls)).not.toContain(firstToken);
      expect(JSON.stringify(errors.mock.calls)).not.toContain(
        "/api/subscribe/confirm"
      );
      const stranded = await Subscriber.collection.findOne({ email });
      expect(stranded?.confirmationSendAttemptId).toBe("stranded-owner");

      clear.mockRestore();
      const laterToken = rawToken(24);
      const laterSend = vi.fn().mockResolvedValue(undefined);
      const later = routeContext(email);

      await createSubscribeHandler({
        now: () => new Date(backendNow.getTime() + CONFIRMATION_SEND_LEASE_MS + 1),
        generateRawToken: () => laterToken,
        generateAttemptId: () => "recovered-owner",
        sendConfirmationEmail: laterSend,
      })(later.req, later.res);

      expectAccepted(later);
      expect(laterSend).toHaveBeenCalledWith(email, laterToken);
      const recovered = await Subscriber.collection.findOne({ email });
      expect(recovered?._id).toEqual(stranded?._id);
      expect(recovered?.confirmationTokenDigest).toBe(
        digestConfirmationToken(laterToken)
      );
      expect(recovered).not.toHaveProperty("confirmationSendAttemptId");
    });
  });

  describe("provider timeout and compensation containment", () => {
    it("routes a provider timeout through deletion and generic acceptance", async () => {
      const context = routeContext("timeout-new@nyu.edu");

      await createSubscribeHandler({
        generateRawToken: () => rawToken(25),
        generateAttemptId: () => "timeout-attempt",
        sendConfirmationEmail: vi.fn().mockRejectedValue(new ProviderTimeout()),
      })(context.req, context.res);

      expectAccepted(context);
      expect(
        await Subscriber.countDocuments({ email: "timeout-new@nyu.edu" })
      ).toBe(0);
    });

    it("returns generic acceptance when new-record deletion itself rejects", async () => {
      const errors = vi.spyOn(console, "error").mockImplementation(() => {});
      vi.spyOn(Subscriber, "deleteOne").mockRejectedValue(
        new Error("delete unavailable") as never
      );
      const token = rawToken(26);
      const context = routeContext("delete-fails@nyu.edu");

      await createSubscribeHandler({
        generateRawToken: () => token,
        generateAttemptId: () => "delete-fails-attempt",
        sendConfirmationEmail: vi.fn().mockRejectedValue(new Error("offline")),
      })(context.req, context.res);

      expectAccepted(context);
      expect(errors).toHaveBeenCalledWith(
        expect.stringContaining(
          "Confirmation cleanup outcome is unknown; new-record deletion could not be verified"
        ),
        expect.objectContaining({
          subscriberId: expect.any(String),
          attemptId: "delete-fails-attempt",
        })
      );
      expect(JSON.stringify(errors.mock.calls)).not.toContain(token);
      expect(JSON.stringify(errors.mock.calls)).not.toContain(
        "/api/subscribe/confirm"
      );
    });

    it("returns generic acceptance when existing-record rollback itself rejects", async () => {
      const id = new mongoose.Types.ObjectId();
      await Subscriber.collection.insertOne({
        _id: id,
        email: "rollback-fails@nyu.edu",
        status: "unsubscribed",
        bounced: false,
        dailyCount: 0,
        unsubToken: "kept-unsubscribe-token",
      });
      const errors = vi.spyOn(console, "error").mockImplementation(() => {});
      vi.spyOn(Subscriber, "updateOne").mockRejectedValue(
        new Error("rollback unavailable") as never
      );
      const token = rawToken(27);
      const context = routeContext("rollback-fails@nyu.edu");

      await createSubscribeHandler({
        generateRawToken: () => token,
        generateAttemptId: () => "rollback-fails-attempt",
        sendConfirmationEmail: vi.fn().mockRejectedValue(new Error("offline")),
      })(context.req, context.res);

      expectAccepted(context);
      expect(errors).toHaveBeenCalledWith(
        expect.stringContaining(
          "Confirmation rollback outcome is unknown; restoration of the previous lifecycle could not be verified"
        ),
        expect.objectContaining({
          subscriberId: expect.any(String),
          attemptId: "rollback-fails-attempt",
        })
      );
      expect(JSON.stringify(errors.mock.calls)).not.toContain(token);
      expect(JSON.stringify(errors.mock.calls)).not.toContain(
        "/api/subscribe/confirm"
      );
    });
  });

  describe("compensation matches both the digest and the attempt", () => {
    async function runInterruptedAttempt(
      email: string,
      interrupt: () => Promise<unknown>,
      attemptId: string
    ) {
      const enteredProvider = deferred();
      const releaseProvider = deferred();
      const context = routeContext(email);
      const attempt = createSubscribeHandler({
        now: () => backendNow,
        generateRawToken: () => rawToken(28),
        generateAttemptId: () => attemptId,
        sendConfirmationEmail: vi.fn(async () => {
          enteredProvider.resolve();
          await releaseProvider.promise;
          throw new Error("provider failed");
        }),
      })(context.req, context.res);

      await enteredProvider.promise;
      await interrupt();
      releaseProvider.resolve();
      await attempt;
      return context;
    }

    it("blocks new-record deletion when only the digest moved on", async () => {
      const email = "digest-only-delete@nyu.edu";
      const newerDigest = "2".repeat(64);
      const context = await runInterruptedAttempt(
        email,
        // The attempt ID is deliberately left untouched, so only the digest
        // clause can reject this stale delete.
        () =>
          Subscriber.updateOne(
            { email },
            { $set: { confirmationTokenDigest: newerDigest } }
          ),
        "digest-only-attempt"
      );

      expectAccepted(context);
      const stored = await Subscriber.collection.findOne({ email });
      expect(stored).not.toBeNull();
      expect(stored?.confirmationTokenDigest).toBe(newerDigest);
      expect(stored?.confirmationSendAttemptId).toBe("digest-only-attempt");
    });

    it("blocks new-record deletion when only the attempt moved on", async () => {
      const email = "attempt-only-delete@nyu.edu";
      const context = await runInterruptedAttempt(
        email,
        // The digest is deliberately left untouched, so only the attempt-ID
        // clause can reject this stale delete.
        () =>
          Subscriber.updateOne(
            { email },
            { $set: { confirmationSendAttemptId: "newer-owner" } }
          ),
        "attempt-only-attempt"
      );

      expectAccepted(context);
      const stored = await Subscriber.collection.findOne({ email });
      expect(stored).not.toBeNull();
      expect(stored?.confirmationTokenDigest).toBe(
        digestConfirmationToken(rawToken(28))
      );
      expect(stored?.confirmationSendAttemptId).toBe("newer-owner");
    });

    it.each([
      [
        "only the digest moved on",
        { confirmationTokenDigest: "3".repeat(64) },
        "digest-only-rollback",
      ],
      [
        "only the attempt moved on",
        { confirmationSendAttemptId: "newer-owner" },
        "attempt-only-rollback",
      ],
    ])(
      "blocks existing-record rollback when %s",
      async (_label, newerState, attemptId) => {
        const email = `${attemptId}@nyu.edu`;
        const id = new mongoose.Types.ObjectId();
        await Subscriber.collection.insertOne({
          _id: id,
          email,
          status: "unsubscribed",
          bounced: true,
          dailyCount: 2,
          unsubToken: "kept-unsubscribe-token",
        });

        const context = await runInterruptedAttempt(
          email,
          () => Subscriber.updateOne({ _id: id }, { $set: newerState }),
          attemptId
        );

        expectAccepted(context);
        const stored = await Subscriber.collection.findOne({ _id: id });
        // The rotation stayed: a stale rollback must not resurrect the
        // pre-rotation `unsubscribed` lifecycle over the newer one.
        expect(stored?.status).toBe("pending");
        for (const [field, value] of Object.entries(newerState)) {
          expect(stored?.[field]).toBe(value);
        }
      }
    );

    it("removes a legacy raw token when rotation succeeds", async () => {
      const id = new mongoose.Types.ObjectId();
      await Subscriber.collection.insertOne({
        _id: id,
        email: "legacy@nyu.edu",
        status: "pending",
        confirmToken: "legacy-raw-token",
        bounced: false,
        dailyCount: 0,
      });
      const token = rawToken(29);
      const context = routeContext("legacy@nyu.edu");

      await createSubscribeHandler({
        now: () => backendNow,
        generateRawToken: () => token,
        generateAttemptId: () => "legacy-attempt",
        sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
      })(context.req, context.res);

      expectAccepted(context);
      const stored = await Subscriber.collection.findOne({ _id: id });
      expect(stored?._id).toEqual(id);
      expect(stored).not.toHaveProperty("confirmToken");
      expect(stored?.confirmationTokenDigest).toBe(
        digestConfirmationToken(token)
      );
      expect(JSON.stringify(stored)).not.toContain("legacy-raw-token");
    });
  });
});
