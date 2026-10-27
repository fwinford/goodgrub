import { randomUUID } from "node:crypto";
import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  Fulfillment,
  Participant,
  ParticipantDeletionOperation,
  Request as MealRequest,
  RequestOperation,
  RequestParticipation,
  RequestUpdateOperation,
} from "../models/db.js";
import {
  cancelParticipantDeletionOperation,
  createOrResolveParticipantDeletionOperation,
  demoteParticipantDeletionReadiness,
  issueParticipantDeletionChallenge,
  promoteParticipantDeletionReadiness,
  readParticipantDeletionStatus,
  redeemParticipantDeletionChallenge,
  type DeletionOwner,
} from "./participantDeletionOperations.js";
import { reconcileParticipantDeletionRequesterRequests } from "./participantDeletionRequesterAdapter.js";
import * as deletionOperations from "./participantDeletionOperations.js";
import { OPERATION_IDENTITY_HEADER } from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import { PARTICIPANT_SIGNING_SECRET_ENV, signParticipantAuthority } from "./participantCredentials.js";
import { editRequest, withdrawRequest } from "./requestUpdateRoute.js";
import { claimRequest } from "./claimRoute.js";
import { confirmPlacedOrderPickup } from "./placedOrderRoutes.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";
import { establishRequestOperationLedger } from "./requestOperationAuthority.js";

vi.mock("resend", () => ({ Resend: class { emails = { send: vi.fn() }; } }));

function isolatedDatabaseUri(base: string) {
  const uri = new URL(base);
  uri.pathname = `${uri.pathname}_p2_requester_adapter`;
  return uri.toString();
}
const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI) : undefined;
const describeMongo = mongoUri ? describe : describe.skip;
const secretText = "p2-adapter-test-secret-at-least-32-bytes";
const secret = Buffer.from(secretText);
const dependencies = { readSecret: () => secret, generateCode: () => "424242", sendChallengeEmail: async () => {} };
const aId = new mongoose.Types.ObjectId();
const bId = new mongoose.Types.ObjectId();
let owner: DeletionOwner;

async function start(phase: "waiting" | "ready" = "waiting") {
  const created = await createOrResolveParticipantDeletionOperation({
    participantId: aId, canonicalEmail: "adapter-a@nyu.edu",
    authorityVersion: 1, initialPhase: phase,
  }, dependencies);
  owner = {
    operationId: created.status.operationId, participantId: aId,
    canonicalEmail: "adapter-a@nyu.edu", authorityVersion: 1,
  };
  return created.status;
}

async function request(overrides: Record<string, unknown> = {}) {
  const now = Date.now();
  const row = await MealRequest.create({
    vendor: "Crave NYU", food: "Rice bowl", pickupWindowText: "ASAP",
    menuPath: "meal-exchange", mealSwipes: 1, mealItems: [{ name: "Rice bowl" }],
    email: "adapter-a@nyu.edu", status: "open", requesterParticipantId: aId,
    visibleFrom: new Date(now - 1000), contentRevision: 1, notificationGeneration: 1,
    expiresAt: new Date(now + 3 * 60 * 60 * 1000),
    deleteAt: new Date(now + 24 * 60 * 60 * 1000), ...overrides,
  });
  if (row.status === "placed") {
    await Fulfillment.create({ requestId: row._id, orderNumber: "123", placedAt: new Date() });
  }
  return row;
}

function context(id: unknown, participantId = aId, operationId = randomUUID(), body: unknown = {}) {
  const req = {
    params: { id: String(id) }, body,
    headers: {
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(participantId, 1, secret),
      [OPERATION_IDENTITY_HEADER]: operationId,
    },
  } as unknown as Request;
  let status = 200;
  let payload: unknown;
  const res = {
    status(value: number) { status = value; return this; },
    json(value: unknown) { payload = value; return this; },
    setHeader() { return this; },
  } as unknown as Response;
  return { req, res, get status() { return status; }, get payload() { return payload; } };
}

const reconcile = (generation = 0) =>
  reconcileParticipantDeletionRequesterRequests(owner, generation, dependencies);

function pickupContext(requestId: unknown, participantId = aId) {
  const req = {
    params: { requestId: String(requestId) },
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(participantId, 1, secret) },
  } as unknown as Request;
  let status = 200;
  let payload: unknown;
  const res = {
    status(value: number) { status = value; return this; },
    json(value: unknown) { payload = value; return this; },
    setHeader() { return this; },
  } as unknown as Response;
  return { req, res, get status() { return status; }, get payload() { return payload; } };
}

async function storedRequests() {
  return MealRequest.find().select("+requesterParticipantId +contentRevision +notificationGeneration +withdrawnAt +externalOrderAffirmed").lean().exec();
}

describeMongo("P2 accepted R5 authority consumption on a real replica set", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, secretText);
    await mongoose.connect(mongoUri!);
    await establishRequestOperationLedger();
    await prepareParticipantIdentityMongoTestState();
    await Promise.all([
      Participant.createIndexes(), ParticipantDeletionOperation.createIndexes(),
      MealRequest.createIndexes(), RequestUpdateOperation.createIndexes(),
      RequestOperation.createIndexes(), RequestParticipation.createIndexes(),
      Fulfillment.createIndexes(),
    ]);
  });
  afterEach(async () => {
    vi.restoreAllMocks();
    for (const model of [MealRequest, Fulfillment, ParticipantDeletionOperation, Participant,
      RequestOperation, RequestParticipation, RequestUpdateOperation]) {
      await model.collection.deleteMany({});
    }
  });
  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  async function seed() {
    await Participant.create([
      { _id: aId, email: "adapter-a@nyu.edu", verifiedAt: new Date(), authorityVersion: 1 },
      { _id: bId, email: "adapter-b@nyu.edu", verifiedAt: new Date(), authorityVersion: 1 },
    ]);
  }

  it("requires explicit R5 withdrawal for active and scheduled requests without touching them", async () => {
    await seed();
    await start("ready");
    await request();
    await request({ visibleFrom: new Date(Date.now() + 60_000) });
    const before = await storedRequests();
    expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "withdrawalRequired" });
    expect(await storedRequests()).toEqual(before);
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({
      phase: "waiting", readinessGeneration: 1,
    });
    expect(await RequestUpdateOperation.countDocuments()).toBe(0);
  });

  it("consumes already-withdrawn truth repeatedly without duplicate mutations or promotion", async () => {
    await seed();
    await start();
    const row = await request();
    const call = context(row._id);
    await withdrawRequest(call.req, call.res);
    expect(call.status).toBe(200);
    const before = await storedRequests();
    const ledgers = await RequestUpdateOperation.find().select("+participantId +requestId +kind").lean();
    const results = await Promise.all(Array.from({ length: 8 }, () => reconcile()));
    expect(results.every((result) => result.outcome === "observed" && result.requester === "clear")).toBe(true);
    expect(await storedRequests()).toEqual(before);
    expect(await RequestUpdateOperation.find().select("+participantId +requestId +kind").lean()).toEqual(ledgers);
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting", readinessGeneration: 0 });
  });

  it("keeps edited request identity and consumes withdrawal using that same retained identity", async () => {
    await seed();
    await start();
    const row = await request();
    const change = context(row._id, aId, randomUUID(), {
      vendor: "Crave NYU", menuPath: "meal-exchange", mealSwipes: 2,
      mealItems: [{ name: "Changed bowl" }, { name: "Side" }], timing: "unchanged", expectedContentRevision: 1,
    });
    await editRequest(change.req, change.res);
    expect(change.status).toBe(200);
    expect(await reconcile()).toMatchObject({ requester: "withdrawalRequired" });
    const remove = context(row._id);
    await withdrawRequest(remove.req, remove.res);
    expect(remove.status).toBe(200);
    expect(await reconcile()).toMatchObject({ requester: "clear" });
    expect(await MealRequest.countDocuments()).toBe(1);
    expect(await RequestUpdateOperation.countDocuments({ requestId: row._id })).toBe(2);
  });

  it("consumes expired retained ordinary and lapsed-claim truth without deleting history", async () => {
    await seed();
    await start();
    await request({ expiresAt: new Date(Date.now() - 1000) });
    await request({ status: "claimed", claimExpiresAt: new Date(Date.now() - 2000), expiresAt: new Date(Date.now() - 1000) });
    const before = await storedRequests();
    expect(await reconcile()).toMatchObject({ requester: "clear" });
    expect(await storedRequests()).toEqual(before);
  });

  describe.each([
    ["missing", undefined],
    ["null", null],
  ] as const)("incomplete persisted claim deadline: %s", (_label, claimExpiresAt) => {
    it.each(["ready", "challengeIssued", "authorized"] as const)(
      "demotes %s and invalidates security material idempotently",
      async (phase) => {
        await seed();
        await start("ready");
        if (phase !== "ready") await issueParticipantDeletionChallenge(owner, 1, dependencies);
        if (phase === "authorized") {
          await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies);
        }
        const row = await request({
          status: "claimed", expiresAt: new Date(Date.now() - 1000), claimExpiresAt,
        });
        const persisted = await MealRequest.collection.findOne({
          _id: new mongoose.Types.ObjectId(String(row._id)),
        });
        if (claimExpiresAt === undefined) expect(persisted).not.toHaveProperty("claimExpiresAt");
        else expect(persisted?.claimExpiresAt).toBeNull();
        const before = await storedRequests();
        expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "unknown" });
        const demoted = await ParticipantDeletionOperation.findOne({ operationId: owner.operationId })
          .select("+challengeDigest +challengeExpiresAt +authorizedAt +authorizationExpiresAt").lean();
        expect(demoted).toMatchObject({ phase: "waiting", readinessGeneration: 1 });
        for (const field of ["challengeDigest", "challengeExpiresAt", "authorizedAt", "authorizationExpiresAt"]) {
          expect(demoted).not.toHaveProperty(field);
        }
        await Promise.all(Array.from({ length: 4 }, async () => {
          expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "unknown" });
        }));
        expect(await ParticipantDeletionOperation.findOne({ operationId: owner.operationId })
          .select("+challengeDigest +challengeExpiresAt +authorizedAt +authorizationExpiresAt").lean())
          .toEqual(demoted);
        expect(await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies))
          .toMatchObject({ outcome: "notRedeemable" });
        expect(await storedRequests()).toEqual(before);
      }
    );
  });

  it.each(["not-a-deadline", "", Number.POSITIVE_INFINITY, {}, []])(
    "fails closed for a malformed legacy/raw Mongo claim deadline: %j",
    async (claimExpiresAt) => {
      await seed();
      await start("ready");
      const row = await request({ status: "claimed", expiresAt: new Date(Date.now() - 1000) });
      // Raw/legacy rows bypass Mongoose's Date casting; lean reads preserve them.
      await mongoose.connection.db!.collection("requests").updateOne(
        { _id: new mongoose.Types.ObjectId(String(row._id)) }, { $set: { claimExpiresAt } }
      );
      expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "unknown" });
      expect(await readParticipantDeletionStatus(owner, dependencies))
        .toMatchObject({ phase: "waiting", readinessGeneration: 1 });
    }
  );

  it.each([
    { claimExpiresAt: new Date(Date.now() + 60_000), requester: "helperOrPickup" },
    { claimExpiresAt: new Date(Date.now() - 60_000), requester: "clear" },
  ])("classifies a finite persisted claim deadline independently of expired request timing: $requester", async ({ claimExpiresAt, requester }) => {
    await seed();
    await start("ready");
    await request({ status: "claimed", expiresAt: new Date(Date.now() - 1000), claimExpiresAt });
    expect(await reconcile(1)).toEqual({ outcome: "observed", requester });
    expect(await readParticipantDeletionStatus(owner, dependencies))
      .toMatchObject({ phase: requester === "clear" ? "ready" : "waiting" });
  });

  it.each([
    { status: "claimed", claimExpiresAt: new Date(Date.now() + 60_000) },
    { status: "claimed", externalOrderAffirmed: true, claimExpiresAt: new Date(0) },
    { status: "claimed", externalOrderAffirmed: true, expiresAt: new Date(0) },
    { status: "placed" },
    { status: "placed", expiresAt: new Date(0) },
  ])("leaves unsafe helper/placed work to H1/R3 ($status)", async (fields) => {
    await seed();
    await start("ready");
    await request(fields);
    const before = await storedRequests();
    expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "helperOrPickup" });
    expect(await storedRequests()).toEqual(before);
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("clears a placed order through R3's real pickup-confirmation route, never by inference", async () => {
    await seed();
    await start("ready");
    const row = await request({ status: "placed" });
    expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "helperOrPickup" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });

    const confirm = pickupContext(row._id);
    await confirmPlacedOrderPickup(confirm.req, confirm.res);
    expect(confirm.status).toBe(200);

    const before = await storedRequests();
    expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "clear" });
    // The Request/retention truth R3 owns is untouched by P2's reconciliation.
    expect(await storedRequests()).toEqual(before);
    expect((await MealRequest.findById(row._id).select("+requesterPickupConfirmedAt").lean())?.status)
      .toBe("placed");
  });

  it("races real R3 pickup confirmation against deletion-readiness reconciliation without corrupting readiness", async () => {
    await seed();
    await start("ready");
    const row = await request({ status: "placed" });
    const confirm = pickupContext(row._id);
    const [, ...reconciles] = await Promise.all([
      confirmPlacedOrderPickup(confirm.req, confirm.res),
      ...Array.from({ length: 6 }, () => reconcile(1)),
    ]);
    expect(confirm.status).toBe(200);
    expect(reconciles.every((result) =>
      result.outcome === "observed" &&
      (result.requester === "clear" || result.requester === "helperOrPickup")
    )).toBe(true);
    // Whatever interleaving occurred, re-reading settles to the authoritative
    // post-confirmation truth. Whether any concurrent reconcile actually
    // observed the pre-confirmation row is a real race outcome (depends on
    // interleaving with the real route's own atomic write), so the phase may
    // settle as "ready" (never demoted) or "waiting" (demoted once, and
    // never self-promoted back — only a blocker can change P2 here).
    expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "clear" });
    expect(["ready", "waiting"]).toContain(
      (await readParticipantDeletionStatus(owner, dependencies))?.phase
    );
  });

  it("does not let a confirmed placed order clear a concurrently active claim obligation", async () => {
    await seed();
    await start("ready");
    await request({ status: "placed", requesterPickupConfirmedAt: new Date() });
    await request({ status: "claimed", claimExpiresAt: new Date(Date.now() + 60_000) });
    expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "helperOrPickup" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("fails closed on a raw malformed persisted pickup-confirmation value", async () => {
    await seed();
    await start("ready");
    const row = await request({ status: "placed" });
    // Raw/legacy rows bypass Mongoose's Date casting; lean reads preserve them.
    await mongoose.connection.db!.collection("requests").updateOne(
      { _id: new mongoose.Types.ObjectId(String(row._id)) },
      { $set: { requesterPickupConfirmedAt: "not-a-timestamp" } }
    );
    expect(await reconcile(1)).toEqual({ outcome: "observed", requester: "unknown" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("does not use another participant's requests as blocker truth", async () => {
    await seed();
    await start();
    await request({ requesterParticipantId: bId });
    expect(await reconcile()).toMatchObject({ requester: "clear" });
    expect(await reconcileParticipantDeletionRequesterRequests({
      ...owner, participantId: bId, canonicalEmail: "adapter-b@nyu.edu",
    }, 0, dependencies)).toEqual({ outcome: "notOwned" });
  });

  it.each(["email", "version", "missing"] as const)("refuses stale participant binding: %s", async (field) => {
    await seed();
    await start("ready");
    await request();
    if (field === "missing") await Participant.deleteOne({ _id: aId });
    else await Participant.updateOne({ _id: aId }, { $set: field === "email"
      ? { email: "changed@nyu.edu" } : { authorityVersion: 2 } });
    expect(await reconcile(1)).toEqual({ outcome: "notOwned" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "ready" });
  });

  it("does not confuse an owner-list limit or edit revision with complete inventory", async () => {
    await seed();
    await start();
    for (let i = 0; i < 26; i++) await request({ status: "withdrawn" });
    await request({ contentRevision: 42 });
    expect(await reconcile()).toMatchObject({ requester: "withdrawalRequired" });
  });

  it("fails closed for missing lifecycle truth", async () => {
    await seed();
    await start("ready");
    const row = await request();
    await MealRequest.collection.updateOne(
      { _id: new mongoose.Types.ObjectId(String(row._id)) },
      { $unset: { expiresAt: "" } }
    );
    expect(await reconcile(1)).toMatchObject({ requester: "unknown" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("fences a stale deletion generation and preserves a canceled operation", async () => {
    await seed();
    await start("ready");
    await request();
    await demoteParticipantDeletionReadiness(owner, 1, dependencies);
    await promoteParticipantDeletionReadiness(owner, 1, dependencies);
    expect(await reconcile(1)).toEqual({ outcome: "stale" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "ready", readinessGeneration: 2 });
    await cancelParticipantDeletionOperation(owner, dependencies);
    expect(await reconcile(2)).toEqual({ outcome: "inactive" });
  });

  it.each(["challengeIssued", "authorized"] as const)("invalidates live %s material when a requester blocker is found", async (phase) => {
    await seed();
    await start("ready");
    await issueParticipantDeletionChallenge(owner, 1, dependencies);
    if (phase === "authorized") await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies);
    await request();
    expect(await reconcile(1)).toMatchObject({ requester: "withdrawalRequired" });
    const row = await ParticipantDeletionOperation.findOne({ operationId: owner.operationId })
      .select("+challengeDigest +authorizationExpiresAt").lean();
    expect(row).toMatchObject({ phase: "waiting", readinessGeneration: 1 });
    expect(row).not.toHaveProperty("challengeDigest");
    expect(row).not.toHaveProperty("authorizationExpiresAt");
    expect(await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies)).toMatchObject({ outcome: "notRedeemable" });
  });

  it("converges after R5 commits but its response is lost; P2 never replays it", async () => {
    await seed();
    await start();
    const row = await request();
    const operationId = randomUUID();
    const lost = context(row._id, aId, operationId);
    vi.spyOn(lost.res, "json").mockImplementationOnce(() => { throw new Error("lost response"); });
    vi.spyOn(console, "error").mockImplementation(() => {});
    await withdrawRequest(lost.req, lost.res);
    expect(lost.status).toBe(500);
    expect(await reconcile()).toMatchObject({ requester: "clear" });
    expect(await RequestUpdateOperation.countDocuments({ operationId })).toBe(1);
    const exact = context(row._id, aId, operationId);
    await withdrawRequest(exact.req, exact.res);
    expect(exact.status).toBe(200);
    expect(await RequestUpdateOperation.countDocuments()).toBe(1);
    expect(await reconcile()).toMatchObject({ requester: "clear" });
  });

  it("handles duplicate reconciles racing competing R5 withdrawals without readiness progress", async () => {
    await seed();
    await start("ready");
    const row = await request();
    const one = context(row._id);
    const two = context(row._id);
    await Promise.all([
      ...Array.from({ length: 6 }, () => reconcile(1)),
      withdrawRequest(one.req, one.res), withdrawRequest(two.req, two.res),
    ]);
    expect([one.status, two.status].every((code) => code === 200 || code === 410)).toBe(true);
    expect(await reconcile(1)).toMatchObject({ requester: "clear" });
    expect((await readParticipantDeletionStatus(owner, dependencies))?.phase).not.toBe("completed");
    expect(await RequestUpdateOperation.countDocuments()).toBe(1);
  });

  it("does not retry an uncommitted ambiguous R5 outcome or clear its requester blocker", async () => {
    await seed();
    await start();
    const row = await request();
    vi.spyOn(RequestUpdateOperation, "create").mockRejectedValueOnce(new Error("write interrupted"));
    vi.spyOn(console, "error").mockImplementation(() => {});
    const failed = context(row._id);
    await withdrawRequest(failed.req, failed.res);
    expect(failed.status).toBe(500);
    expect(await RequestUpdateOperation.countDocuments()).toBe(0);
    expect(await reconcile()).toMatchObject({ requester: "withdrawalRequired" });
    expect((await storedRequests())[0].status).toBe("open");
  });

  it("preserves a newer readiness generation when it wins before the adapter demotion", async () => {
    await seed();
    await start("ready");
    await request();
    const demote = deletionOperations.demoteParticipantDeletionReadiness;
    vi.spyOn(deletionOperations, "demoteParticipantDeletionReadiness").mockImplementationOnce(
      async (binding, generation, deps) => {
        await demote(binding, generation, deps);
        await promoteParticipantDeletionReadiness(binding, generation, deps);
        return demote(binding, generation, deps);
      }
    );
    expect(await reconcile(1)).toEqual({ outcome: "stale" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({
      phase: "ready", readinessGeneration: 2,
    });
  });

  it("cannot demote or revive a cancellation that wins before its conditional write", async () => {
    await seed();
    await start("ready");
    await request();
    const demote = deletionOperations.demoteParticipantDeletionReadiness;
    vi.spyOn(deletionOperations, "demoteParticipantDeletionReadiness").mockImplementationOnce(
      async (binding, generation, deps) => {
        await cancelParticipantDeletionOperation(binding, deps);
        return demote(binding, generation, deps);
      }
    );
    expect(await reconcile(1)).toEqual({ outcome: "inactive" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "canceled" });
  });

  it("preserves both permanent ledgers and their unique indexes across R5 and P2 reconciliation", async () => {
    await seed();
    await start();
    const row = await request();
    await RequestOperation.create({ operationId: randomUUID(), participantId: aId, requestId: row._id, outcome: "created" });
    await RequestParticipation.create({ requestId: row._id, participantId: bId });
    const operations = await RequestOperation.collection.find().toArray();
    const participation = await RequestParticipation.collection.find().toArray();
    const beforeIndexes = await Promise.all([RequestOperation.collection.indexes(), RequestParticipation.collection.indexes()]);
    const call = context(row._id);
    await withdrawRequest(call.req, call.res);
    expect(call.status).toBe(200);
    await reconcile();
    await reconcile();
    expect(await RequestOperation.collection.find().toArray()).toEqual(operations);
    expect(await RequestParticipation.collection.find().toArray()).toEqual(participation);
    expect(await Promise.all([RequestOperation.collection.indexes(), RequestParticipation.collection.indexes()])).toEqual(beforeIndexes);
    await expect(RequestOperation.create({ ...operations[0], _id: new mongoose.Types.ObjectId() })).rejects.toMatchObject({ code: 11000 });
    await expect(RequestParticipation.create({ requestId: row._id, participantId: bId })).rejects.toMatchObject({ code: 11000 });
  });

  it("races R5 Edit and a helper acquisition safely without changing request authority", async () => {
    await seed();
    await start();
    const row = await request();
    const change = context(row._id, aId, randomUUID(), {
      vendor: "Crave NYU", menuPath: "meal-exchange", mealSwipes: 2,
      mealItems: [{ name: "Edited" }, { name: "Side" }], timing: "unchanged", expectedContentRevision: 1,
    });
    const helper = context(row._id, bId);
    await Promise.all([editRequest(change.req, change.res), claimRequest(helper.req, helper.res), reconcile()]);
    expect(helper.status).toBe(200);
    expect(await reconcile()).toMatchObject({ requester: "helperOrPickup" });
    expect(await RequestParticipation.countDocuments({ requestId: row._id, participantId: bId })).toBe(1);
  });
});
