import type { Request, Response } from "express";
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
import { Installation, Subscriber, Participant, ParticipantBlock } from "../models/db.js";
import { digestInstallationCredential } from "./installationCredential.js";
import { createInstallationPushHandler } from "./installationPushRoute.js";
import { signParticipantAuthority } from "./participantCredentials.js";
import { selectEligiblePushInstallations } from "./pushEligibility.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;
const backendNow = new Date("2026-08-04T12:00:00.000Z");
const participantId = new mongoose.Types.ObjectId();
const participantB = new mongoose.Types.ObjectId();
const secret = "installation-push-mongo-test-signing-secret";
const authority = signParticipantAuthority(participantId, 1, Buffer.from(secret));

function routeContext(body: unknown) {
  const normalized = typeof body === "object" && body !== null && "association" in body
    ? { mutationVersion: 1, ...body } : body;
  const req = { body: normalized, headers: { "x-commonplate-participant": authority } } as unknown as Request;
  const res = {} as Response;
  let statusCode = 200;
  let bodyValue: unknown;
  res.status = ((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = ((value: unknown) => {
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

function credential(byte: number): string {
  return Buffer.alloc(32, byte).toString("base64url");
}

function apnsToken(byte: number): string {
  return Buffer.alloc(32, byte).toString("hex");
}

describeMongo("installation push-state synchronization against real MongoDB", () => {
  async function enabledInstallation(byte = 40) {
    const context = routeContext({
      installationCredential: credential(byte), enabled: true,
      apnsToken: apnsToken(byte), environment: "development",
    });
    await createInstallationPushHandler()(context.req, context.res);
    expect(context.body).toEqual({ push: { enabled: true } });
    return Installation.findOne({ installationCredentialDigest: digestInstallationCredential(credential(byte)) })
      .select("+participantId +participantAuthorityVersion").lean().exec();
  }

  it("hands off only this Installation from A to B, including an Off association", async () => {
    const first = await enabledInstallation(40);
    await enabledInstallation(41);
    await Installation.updateOne({ _id: first!._id }, { $set: { pushEnabled: false } });
    const c = routeContext({ installationCredential: credential(40), association: "replace" });
    c.req.headers = { "x-commonplate-participant": signParticipantAuthority(participantB, 2, Buffer.from(secret)) };
    await createInstallationPushHandler()(c.req, c.res);
    expect(c.body).toEqual({ association: { confirmed: true }, push: { enabled: false } });
    const changed = await Installation.collection.findOne({ _id: first!._id });
    expect(changed?.participantId).toEqual(participantB);
    expect(changed?.participantAuthorityVersion).toBe(2);
    expect(changed?.apnsToken).toBe(apnsToken(40));
    expect(await Installation.countDocuments({ participantId })).toBe(1);
    expect((await Participant.findById(participantId))?.authorityVersion).toBe(1);
    // Reassertion uses already-verified B authority, not a second code redemption.
    await createInstallationPushHandler()(c.req, c.res);
    expect(c.body).toEqual({ association: { confirmed: true }, push: { enabled: false } });
  });

  it("refuses stale B authority without touching A and confirms credential-only clear", async () => {
    const installation = await enabledInstallation();
    const c = routeContext({ installationCredential: credential(40), association: "replace" });
    c.req.headers = { "x-commonplate-participant": signParticipantAuthority(participantB, 1, Buffer.from(secret)) };
    await createInstallationPushHandler()(c.req, c.res);
    expect(c.statusCode).toBe(401);
    expect((await Installation.collection.findOne({ _id: installation!._id }))?.participantId).toEqual(participantId);
    const clear = routeContext({ installationCredential: credential(40), association: "clear" });
    clear.req.headers = {};
    await createInstallationPushHandler()(clear.req, clear.res);
    expect(clear.body).toEqual({ association: { confirmed: true }, push: { enabled: false } });
    const stored = await Installation.collection.findOne({ _id: installation!._id });
    expect(stored).not.toHaveProperty("participantId");
    expect(stored).not.toHaveProperty("participantAuthorityVersion");
    expect(await selectEligiblePushInstallations()).toHaveLength(0);
    await createInstallationPushHandler()(clear.req, clear.res);
    expect(clear.body).toEqual({ association: { confirmed: true }, push: { enabled: false } });
    expect((await Participant.findById(participantId))?.authorityVersion).toBe(1);
  });

  it.each([
    ["disabled", { pushEnabled: false }],
    ["no token", { apnsToken: null }],
    ["invalidated", { invalidatedAt: backendNow }],
    ["unbound", { participantId: null }],
    ["no participant", { participantId: new mongoose.Types.ObjectId() }],
    ["stale version", { participantAuthorityVersion: 2 }],
  ])("excludes %s installations against real Mongo", async (_, fields) => {
    const installation = await enabledInstallation();
    await Installation.updateOne({ _id: installation!._id }, { $set: fields });
    expect(await selectEligiblePushInstallations()).toHaveLength(0);
  });

  it("filters suspension, requester self-exclusion and pair blocks in either direction", async () => {
    await enabledInstallation();
    expect(await selectEligiblePushInstallations()).toHaveLength(1);
    expect(await selectEligiblePushInstallations({ excludeParticipantId: participantId })).toHaveLength(0);
    expect(await selectEligiblePushInstallations({ excludeParticipantId: participantB })).toHaveLength(1);
    await Participant.updateOne({ _id: participantId }, { $set: { suspended: true } });
    expect(await selectEligiblePushInstallations()).toHaveLength(0);
    await Participant.updateOne({ _id: participantId }, { $set: { suspended: false } });
    for (const [blockerParticipantId, blockedParticipantId] of [
      [participantId, participantB], [participantB, participantId],
    ]) {
      await ParticipantBlock.collection.insertOne({ blockerParticipantId, blockedParticipantId });
      expect(await selectEligiblePushInstallations({ excludeParticipantId: participantB })).toHaveLength(0);
      await ParticipantBlock.deleteMany({});
    }
  });

  it("reads recipient authority inside the caller's Mongo session", async () => {
    await enabledInstallation();
    const session = await mongoose.startSession();
    try {
      await session.withTransaction(async () => {
        await Participant.updateOne({ _id: participantId }, { $set: { suspended: true } }, { session });
        expect(await selectEligiblePushInstallations({ session })).toHaveLength(0);
        expect(await selectEligiblePushInstallations()).toHaveLength(1);
      });
    } finally {
      await session.endSession();
    }
    expect(await selectEligiblePushInstallations()).toHaveLength(0);
  });

  it.each(["clear", "replace", "disable"] as const)(
    "a delayed older enable cannot undo a newer %s, including the no-row case",
    async (action) => {
      for (const initiallyExists of [false, true]) {
        await Installation.deleteMany({});
        if (initiallyExists) await enabledInstallation(80);
        const original = Installation.findOneAndUpdate.bind(Installation);
        let resume!: () => void;
        let started!: () => void;
        const waiting = new Promise<void>((resolve) => { resume = resolve; });
        const reached = new Promise<void>((resolve) => { started = resolve; });
        const spy = vi.spyOn(Installation, "findOneAndUpdate").mockImplementationOnce(
          ((...args: Parameters<typeof Installation.findOneAndUpdate>) => ({
            select: () => ({
              lean: () => ({
                exec: async () => {
                  started();
                  await waiting;
                  return original(...args).select("pushEnabled").lean().exec();
                },
              }),
            }),
          })) as never
        );
        const old = routeContext({
          installationCredential: credential(80), enabled: true, mutationVersion: 2,
          apnsToken: apnsToken(80), environment: "development",
        });
        const oldOperation = createInstallationPushHandler()(old.req, old.res);
        await reached;
        const newer = routeContext({
          installationCredential: credential(80), mutationVersion: 3,
          ...(action === "disable" ? { enabled: false } : { association: action }),
        });
        if (action === "replace") newer.req.headers = {
          "x-commonplate-participant": signParticipantAuthority(participantB, 2, Buffer.from(secret)),
        };
        await createInstallationPushHandler()(newer.req, newer.res);
        expect(newer.statusCode).toBe(200);
        resume();
        await oldOperation;
        spy.mockRestore();
        expect(old.statusCode).toBe(409);
        const stored = await Installation.collection.findOne({
          installationCredentialDigest: digestInstallationCredential(credential(80)),
        });
        expect(stored?.pushMutationVersion).toBe(3);
        expect(stored?.pushEnabled).toBe(action === "replace" && initiallyExists);
        if (action === "clear") expect(stored).not.toHaveProperty("participantId");
        if (action === "replace") expect(stored?.participantId).toEqual(participantB);
        // An old client without ordering metadata cannot bypass the newer fence either.
        const legacy = routeContext({
          installationCredential: credential(80), enabled: true,
          apnsToken: apnsToken(80), environment: "development",
        });
        await createInstallationPushHandler()(legacy.req, legacy.res);
        expect(legacy.statusCode).toBe(409);
      }
    }
  );
  beforeAll(async () => {
    // Its own database: Mongo test files run concurrently and several
    // suites clear their collections between cases, so a shared database
    // would let one suite delete another's fixtures mid-test.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_installation_push_test",
    });
    await Installation.syncIndexes();
    await Subscriber.syncIndexes();
    await Participant.syncIndexes();
    await ParticipantBlock.syncIndexes();
  });

  beforeEach(async () => {
    vi.stubEnv("PARTICIPANT_SIGNING_SECRET", secret);
    await Participant.create([
      { _id: participantId, email: "a@nyu.edu", authorityVersion: 1, verifiedAt: backendNow },
      { _id: participantB, email: "b@nyu.edu", authorityVersion: 2, verifiedAt: backendNow },
    ]);
  });

  afterEach(async () => {
    await Installation.deleteMany({});
    await Subscriber.deleteMany({});
    await Participant.deleteMany({});
    await ParticipantBlock.deleteMany({});
    vi.unstubAllEnvs();
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("creates one installation on first enabled synchronization, storing only the credential digest", async () => {
    const raw = credential(1);
    const token = apnsToken(1);
    const digest = digestInstallationCredential(raw);
    const context = routeContext({
      installationCredential: raw,
      enabled: true,
      apnsToken: token,
      environment: "development",
    });

    await createInstallationPushHandler({ now: () => backendNow })(
      context.req,
      context.res
    );

    expect(context.body).toEqual({ push: { enabled: true } });
    expect(Object.keys((context.body as any).push)).toEqual(["enabled"]);
    expect(await Installation.countDocuments({})).toBe(1);
    const stored = await Installation.collection.findOne({
      installationCredentialDigest: digest,
    });
    expect(stored).not.toBeNull();
    expect(stored?.pushEnabled).toBe(true);
    expect(stored?.participantId).toEqual(participantId);
    expect(stored?.participantAuthorityVersion).toBe(1);
    expect(stored?.apnsToken).toBe(token);
    expect(stored?.apnsEnvironment).toBe("development");
    expect(stored?.tokenUpdatedAt).toEqual(backendNow);
    expect(JSON.stringify(stored)).not.toContain(raw);
    const serializedResponse = JSON.stringify(context.body);
    expect(serializedResponse).not.toContain(raw);
    expect(serializedResponse).not.toContain(token);
    expect(serializedResponse).not.toContain(digest);
  });

  it("does not create a duplicate installation when the same enabled state repeats", async () => {
    const raw = credential(2);
    const token = apnsToken(2);
    const handler = createInstallationPushHandler({ now: () => backendNow });
    const body = {
      installationCredential: raw,
      enabled: true as const,
      apnsToken: token,
      environment: "development" as const,
    };

    const first = routeContext(body);
    await handler(first.req, first.res);
    const second = routeContext(body);
    await handler(second.req, second.res);

    expect(await Installation.countDocuments({})).toBe(1);
    expect(second.body).toEqual({ push: { enabled: true } });
  });

  it("replaces the previous token when the same installation registers a new one", async () => {
    const raw = credential(3);
    const digest = digestInstallationCredential(raw);
    const firstToken = apnsToken(3);
    const secondToken = apnsToken(4);
    const handler = createInstallationPushHandler({ now: () => backendNow });

    const first = routeContext({
      installationCredential: raw,
      enabled: true,
      apnsToken: firstToken,
      environment: "development",
    });
    await handler(first.req, first.res);

    const later = new Date(backendNow.getTime() + 60_000);
    const second = routeContext({
      installationCredential: raw,
      enabled: true,
      apnsToken: secondToken,
      environment: "development",
    });
    await createInstallationPushHandler({ now: () => later })(
      second.req,
      second.res
    );

    expect(await Installation.countDocuments({})).toBe(1);
    const stored = await Installation.collection.findOne({
      installationCredentialDigest: digest,
    });
    expect(stored?.apnsToken).toBe(secondToken);
    expect(stored?.tokenUpdatedAt).toEqual(later);
    expect(
      await Installation.countDocuments({
        apnsToken: firstToken,
        pushEnabled: true,
      })
    ).toBe(0);
  });

  it("disabling preserves the installation record, keeps the token, and makes it ineligible", async () => {
    const raw = credential(5);
    const digest = digestInstallationCredential(raw);
    const token = apnsToken(5);
    const handler = createInstallationPushHandler({ now: () => backendNow });

    const enableContext = routeContext({
      installationCredential: raw,
      enabled: true,
      apnsToken: token,
      environment: "development",
    });
    await handler(enableContext.req, enableContext.res);

    const disableContext = routeContext({
      installationCredential: raw,
      enabled: false,
    });
    await handler(disableContext.req, disableContext.res);

    expect(disableContext.body).toEqual({ push: { enabled: false } });
    expect(await Installation.countDocuments({})).toBe(1);
    const stored = await Installation.collection.findOne({
      installationCredentialDigest: digest,
    });
    expect(stored).not.toBeNull();
    expect(stored?.pushEnabled).toBe(false);
    // Retained so a later provider-invalidation notice for this exact token
    // can still recognize it as this installation's last-known current token.
    expect(stored?.apnsToken).toBe(token);
  });

  it("treats a repeated disable of a never-registered installation as harmless", async () => {
    const raw = credential(6);
    const handler = createInstallationPushHandler({ now: () => backendNow });
    const body = { installationCredential: raw, enabled: false as const };

    const first = routeContext(body);
    await handler(first.req, first.res);
    const second = routeContext(body);
    await handler(second.req, second.res);

    expect(first.body).toEqual({ push: { enabled: false } });
    expect(second.body).toEqual({ push: { enabled: false } });
    expect(await Installation.countDocuments({ pushEnabled: false })).toBe(1);
  });

  it("reactivates an installation after it was disabled", async () => {
    const raw = credential(7);
    const digest = digestInstallationCredential(raw);
    const token = apnsToken(7);
    const handler = createInstallationPushHandler({ now: () => backendNow });

    const enableContext = routeContext({
      installationCredential: raw,
      enabled: true,
      apnsToken: token,
      environment: "production",
    });
    await handler(enableContext.req, enableContext.res);

    const disableContext = routeContext({
      installationCredential: raw,
      enabled: false,
    });
    await handler(disableContext.req, disableContext.res);

    const reenableContext = routeContext({
      installationCredential: raw,
      enabled: true,
      apnsToken: token,
      environment: "production",
    });
    await handler(reenableContext.req, reenableContext.res);

    expect(reenableContext.body).toEqual({ push: { enabled: true } });
    expect(await Installation.countDocuments({})).toBe(1);
    const stored = await Installation.collection.findOne({
      installationCredentialDigest: digest,
    });
    expect(stored?.pushEnabled).toBe(true);
  });

  it("never touches Subscriber records", async () => {
    await Subscriber.create({ email: "unaffected@nyu.edu", status: "confirmed" });
    const before = await Subscriber.collection.findOne({
      email: "unaffected@nyu.edu",
    });

    const context = routeContext({
      installationCredential: credential(8),
      enabled: true,
      apnsToken: apnsToken(8),
      environment: "development",
    });
    await createInstallationPushHandler({ now: () => backendNow })(
      context.req,
      context.res
    );

    const after = await Subscriber.collection.findOne({
      email: "unaffected@nyu.edu",
    });
    expect(after).toEqual(before);
  });

  it("transfers eligibility to a newer installation that registers the same token", async () => {
    const oldRaw = credential(9);
    const newRaw = credential(10);
    const oldDigest = digestInstallationCredential(oldRaw);
    const newDigest = digestInstallationCredential(newRaw);
    const token = apnsToken(9);
    const handler = createInstallationPushHandler({ now: () => backendNow });

    const oldContext = routeContext({
      installationCredential: oldRaw,
      enabled: true,
      apnsToken: token,
      environment: "production",
    });
    await handler(oldContext.req, oldContext.res);
    expect(oldContext.body).toEqual({ push: { enabled: true } });

    const newContext = routeContext({
      installationCredential: newRaw,
      enabled: true,
      apnsToken: token,
      environment: "production",
    });
    await handler(newContext.req, newContext.res);
    expect(newContext.body).toEqual({ push: { enabled: true } });

    expect(await Installation.countDocuments({})).toBe(2);
    const oldStored = await Installation.collection.findOne({
      installationCredentialDigest: oldDigest,
    });
    const newStored = await Installation.collection.findOne({
      installationCredentialDigest: newDigest,
    });
    expect(oldStored?.pushEnabled).toBe(false);
    expect(newStored?.pushEnabled).toBe(true);
    expect(newStored?.apnsToken).toBe(token);
    expect(
      await Installation.countDocuments({
        apnsToken: token,
        apnsEnvironment: "production",
        pushEnabled: true,
      })
    ).toBe(1);
  });

  it("keeps exactly one eligible owner when two installations race for the same token", async () => {
    const credA = credential(11);
    const credB = credential(12);
    const digestA = digestInstallationCredential(credA);
    const digestB = digestInstallationCredential(credB);
    const token = apnsToken(11);
    const handler = createInstallationPushHandler({ now: () => backendNow });

    const contextA = routeContext({
      installationCredential: credA,
      enabled: true,
      apnsToken: token,
      environment: "development",
    });
    const contextB = routeContext({
      installationCredential: credB,
      enabled: true,
      apnsToken: token,
      environment: "development",
    });

    await Promise.all([
      handler(contextA.req, contextA.res),
      handler(contextB.req, contextB.res),
    ]);

    expect(contextA.body).toEqual({ push: { enabled: true } });
    expect(contextB.body).toEqual({ push: { enabled: true } });
    const eligible = await Installation.collection
      .find({
        apnsToken: token,
        apnsEnvironment: "development",
        pushEnabled: true,
      })
      .toArray();
    expect(eligible).toHaveLength(1);
    expect([digestA, digestB]).toContain(
      eligible[0].installationCredentialDigest
    );
    expect(await Installation.countDocuments({})).toBe(2);
  });

  it("never exposes the credential, its digest, or the token in the response", async () => {
    const raw = credential(13);
    const digest = digestInstallationCredential(raw);
    const token = apnsToken(13);
    const context = routeContext({
      installationCredential: raw,
      enabled: true,
      apnsToken: token,
      environment: "production",
    });

    await createInstallationPushHandler({ now: () => backendNow })(
      context.req,
      context.res
    );

    expect(context.body).toEqual({ push: { enabled: true } });
    const serialized = JSON.stringify(context.body);
    expect(serialized).not.toContain(raw);
    expect(serialized).not.toContain(token);
    expect(serialized).not.toContain(digest);
  });
});
