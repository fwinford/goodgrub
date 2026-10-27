import { randomUUID } from "node:crypto";
import type { Request, Response } from "express";
import mongoose from "mongoose";
import { establishRequestOperationLedger } from "./requestOperationAuthority.js";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Fulfillment, Participant, ParticipantBlock, ParticipantDeletionOperation, PlacementEvidence,
  Request as MealRequest, RequestOperation, RequestParticipation,
} from "../models/db.js";
import { claimRequest, extendClaim, releaseClaim } from "./claimRoute.js";
import {
  participationIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";
import { fulfillRequest } from "./fulfillmentRoute.js";
import { confirmPlacedOrderPickup } from "./placedOrderRoutes.js";
import { createParticipantBlock } from "./participantBlockRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import { PARTICIPANT_SIGNING_SECRET_ENV, signParticipantAuthority } from "./participantCredentials.js";
import {
  cancelParticipantDeletionOperation, createOrResolveParticipantDeletionOperation,
  demoteParticipantDeletionReadiness, issueParticipantDeletionChallenge,
  promoteParticipantDeletionReadiness, readParticipantDeletionStatus,
  redeemParticipantDeletionChallenge, type DeletionOwner,
} from "./participantDeletionOperations.js";
import * as deletionOperations from "./participantDeletionOperations.js";
import { reconcileParticipantDeletionHelperRequests } from "./participantDeletionHelperAdapter.js";
import { reconcileParticipantDeletionRequesterRequests } from "./participantDeletionRequesterAdapter.js";

vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail: vi.fn().mockResolvedValue({}) }));

function isolatedDatabaseUri(base: string) {
  const uri = new URL(base);
  uri.pathname = `${uri.pathname}_p2_helper_adapter`;
  return uri.toString();
}
const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI) : undefined;
const describeMongo = mongoUri ? describe : describe.skip;
const secretText = "p2-helper-adapter-test-secret-at-least-32-bytes";
const secret = Buffer.from(secretText);
const dependencies = { readSecret: () => secret, generateCode: () => "424242", sendChallengeEmail: async () => {} };
const helperId = new mongoose.Types.ObjectId();
const requesterId = new mongoose.Types.ObjectId();
let owner: DeletionOwner;

function context(id: unknown, participantId = helperId, body: unknown = {}) {
  const req = {
    params: { id: String(id) }, body,
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

async function start(phase: "waiting" | "ready" = "waiting") {
  const created = await createOrResolveParticipantDeletionOperation({
    participantId: helperId, canonicalEmail: "p2-helper@nyu.edu", authorityVersion: 1,
    initialPhase: phase,
  }, dependencies);
  owner = {
    operationId: created.status.operationId, participantId: helperId,
    canonicalEmail: "p2-helper@nyu.edu", authorityVersion: 1,
  };
}

async function request(overrides: Record<string, unknown> = {}) {
  const now = Date.now();
  return MealRequest.create({
    vendor: "Crave NYU", food: "Rice bowl", pickupWindowText: "ASAP",
    menuPath: "meal-exchange", mealSwipes: 1, mealItems: [{ name: "Rice bowl" }],
    email: "p2-requester@nyu.edu", status: "open", requesterParticipantId: requesterId,
    visibleFrom: new Date(now - 1000), expiresAt: new Date(now + 3 * 60 * 60 * 1000),
    deleteAt: new Date(now + 24 * 60 * 60 * 1000), ...overrides,
  });
}

async function claimed() {
  const row = await request();
  const call = context(row._id);
  await claimRequest(call.req, call.res);
  expect(call.status).toBe(200);
  return row;
}

const reconcile = (generation = 0) =>
  reconcileParticipantDeletionHelperRequests(owner, generation, dependencies);
const placementBody = () => ({
  fulfillment: {
    orderNumber: "001234", eta: "15 minutes",
    placedOrderScreenshot: {
      mimeType: "image/png",
      imageBase64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    },
  },
});
const storedOperation = () => ParticipantDeletionOperation.findOne({ operationId: owner.operationId })
  .select("+challengeDigest +challengeExpiresAt +authorizedAt +authorizationExpiresAt").lean().exec();

describeMongo("P2 accepted H1a helper authority on a real replica set", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, secretText);
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "helper-adapter-claim-token-secret-32");
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    await mongoose.connect(mongoUri!);
    await establishRequestOperationLedger();
    await prepareParticipantIdentityMongoTestState();
    await Promise.all([
      Participant, ParticipantDeletionOperation, MealRequest, RequestOperation,
      RequestParticipation, ParticipantBlock, Fulfillment, PlacementEvidence,
    ].map((model) => model.createIndexes()));
  });
  beforeEach(async () => {
    await Participant.create([
      { _id: helperId, email: "p2-helper@nyu.edu", verifiedAt: new Date(), authorityVersion: 1 },
      { _id: requesterId, email: "p2-requester@nyu.edu", verifiedAt: new Date(), authorityVersion: 1 },
    ]);
  });
  afterEach(async () => {
    vi.restoreAllMocks();
    for (const model of [
      MealRequest, ParticipantDeletionOperation, Participant, RequestOperation,
      RequestParticipation, ParticipantBlock, Fulfillment, PlacementEvidence,
    ]) await model.collection.deleteMany({});
  });
  afterAll(async () => { await mongoose.disconnect(); vi.unstubAllEnvs(); });

  it.each(["ready", "challengeIssued", "authorized"] as const)(
    "demotes %s for a live reservation and invalidates stale security authority", async (phase) => {
      await start("ready");
      if (phase !== "ready") await issueParticipantDeletionChallenge(owner, 1, dependencies);
      if (phase === "authorized") await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies);
      await claimed();
      const requests = await MealRequest.collection.find().toArray();
      expect(await reconcile(1)).toEqual({ outcome: "observed", helper: "helperOrPickup" });
      const operation = await storedOperation();
      expect(operation).toMatchObject({ phase: "waiting", readinessGeneration: 1 });
      for (const field of ["challengeDigest", "challengeExpiresAt", "authorizedAt", "authorizationExpiresAt"]) {
        expect(operation).not.toHaveProperty(field);
      }
      expect(await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies))
        .toMatchObject({ outcome: "notRedeemable" });
      await Promise.all(Array.from({ length: 6 }, () => reconcile(1)));
      expect(await storedOperation()).toEqual(operation);
      expect(await MealRequest.collection.find().toArray()).toEqual(requests);
    }
  );

  it("consumes a committed release despite a lost response, without replay or promotion", async () => {
    await start("ready");
    const row = await claimed();
    await reconcile(1);
    const call = context(row._id);
    vi.spyOn(call.res, "json").mockImplementationOnce(() => { throw new Error("lost response"); });
    vi.spyOn(console, "error").mockImplementation(() => {});
    await releaseClaim(call.req, call.res);
    expect(call.status).toBe(500);
    const requests = await MealRequest.collection.find().toArray();
    const participants = await Participant.collection.find().toArray();
    expect(await reconcile(1)).toEqual({ outcome: "observed", helper: "clear" });
    expect(await reconcile(1)).toEqual({ outcome: "observed", helper: "clear" });
    expect(await MealRequest.collection.find().toArray()).toEqual(requests);
    expect(await Participant.collection.find().toArray()).toEqual(participants);
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("consumes authoritative passive expiry without expiring or changing any H1a row", async () => {
    await start();
    const row = await claimed();
    const before = await MealRequest.collection.findOne({ _id: new mongoose.Types.ObjectId(String(row._id)) });
    const participants = await Participant.collection.find().toArray();
    const expiration = before!.claimExpiresAt as Date;
    expect(await reconcileParticipantDeletionHelperRequests(owner, 0, {
      ...dependencies, now: () => expiration,
    })).toEqual({ outcome: "observed", helper: "clear" });
    expect(await MealRequest.collection.findOne({ _id: before!._id })).toEqual(before);
    expect(await Participant.collection.find().toArray()).toEqual(participants);
  });

  it.each([undefined, null, "", "bad", "2026-01-01T00:00:00.000Z", {}, [], 0])(
    "fails closed for incomplete/malformed persisted expiry %j", async (claimExpiresAt) => {
      await start("ready");
      const row = await request({ status: "claimed", helperParticipantId: helperId, expiresAt: new Date(0) });
      const filter = { _id: new mongoose.Types.ObjectId(String(row._id)) };
      await MealRequest.collection.updateOne(filter, claimExpiresAt === undefined
        ? { $unset: { claimExpiresAt: "" } } : { $set: { claimExpiresAt } });
      expect(await reconcile(1)).toEqual({ outcome: "observed", helper: "unknown" });
      expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
    }
  );

  it("does not use an expired lock or a missing request as proof of release/expiry", async () => {
    await start("ready");
    await Participant.updateOne({ _id: helperId }, {
      $set: { activeReservationRequestId: new mongoose.Types.ObjectId(), activeReservationClaimExpiresAt: new Date(0) },
    });
    expect(await reconcile(1)).toMatchObject({ helper: "unknown" });
  });

  it("keeps accepted post-Yes authority blocking across passive expiry", async () => {
    await start();
    const row = await claimed();
    const block = context(row._id, helperId, { externalOrderPlaced: true });
    await createParticipantBlock(block.req, block.res);
    expect(block.status).toBe(200);
    const persisted = await MealRequest.findById(row._id).select("+externalOrderAffirmed").lean();
    expect(persisted?.externalOrderAffirmed).toBe(true);
    expect(await reconcileParticipantDeletionHelperRequests(owner, 0, {
      ...dependencies, now: () => new Date(persisted!.claimExpiresAt!.getTime() + 1),
    })).toMatchObject({ helper: "helperOrPickup" });
  });

  it("consumes committed placement after response loss without clearing the P2 placed blocker", async () => {
    await start("ready");
    const row = await claimed();
    const call = context(row._id, helperId, placementBody());
    vi.spyOn(call.res, "json").mockImplementationOnce(() => { throw new Error("lost response"); });
    vi.spyOn(console, "error").mockImplementation(() => {});
    await expect(fulfillRequest(call.req, call.res)).rejects.toThrow("lost response");
    expect(await MealRequest.findById(row._id).lean()).toMatchObject({ status: "placed" });
    const evidence = await PlacementEvidence.collection.find().toArray();
    expect(evidence).toHaveLength(1);
    expect(await reconcile(1)).toMatchObject({ helper: "helperOrPickup" });
    expect(await PlacementEvidence.collection.find().toArray()).toEqual(evidence);
    expect(await Fulfillment.countDocuments()).toBe(1);
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("keeps an unconfirmed placed helper blocked after Request TTL", async () => {
    await start("ready");
    const row = await claimed();
    const placement = context(row._id, helperId, placementBody());
    await fulfillRequest(placement.req, placement.res);
    const fulfillment = await Fulfillment.findOne({ requestId: row._id })
      .select("+helperParticipationKeyVersion +helperParticipationHmac")
      .lean()
      .exec();
    const participationIdentity = participationIdentityFields(
      String(row._id),
      "p2-helper@nyu.edu"
    );
    expect(fulfillment).toMatchObject({
      helperParticipationKeyVersion:
        participationIdentity.participationKeyVersion,
      helperParticipationHmac: participationIdentity.participationHmac,
    });
    expect(fulfillment).not.toHaveProperty("helperParticipantId");

    await MealRequest.deleteOne({ _id: row._id });

    expect(await reconcile(1)).toMatchObject({ helper: "helperOrPickup" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({
      phase: "waiting",
    });
  });

  it("uses the per-Request Fulfillment terminal proof after Request TTL", async () => {
    await start("ready");
    const row = await claimed();
    const placement = context(row._id, helperId, placementBody());
    await fulfillRequest(placement.req, placement.res);
    const pickup = context(row._id, requesterId);
    pickup.req.params = { requestId: String(row._id) };
    await confirmPlacedOrderPickup(pickup.req, pickup.res);
    expect(pickup.status).toBe(200);
    const fulfillment = await Fulfillment.findOne({ requestId: row._id })
      .select("+requesterPickupConfirmedAt")
      .lean()
      .exec();
    expect(fulfillment?.requesterPickupConfirmedAt).toBeInstanceOf(Date);

    await MealRequest.deleteOne({ _id: row._id });

    expect(await reconcile(1)).toEqual({ outcome: "observed", helper: "clear" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({
      phase: "ready",
    });
  });

  it("fails closed after Request TTL when the permanent Fulfillment proof is missing", async () => {
    await start("ready");
    const row = await claimed();
    await Participant.updateOne(
      { _id: helperId },
      {
        $set: {
          activeReservationRequestId: null,
          activeReservationClaimExpiresAt: null,
        },
      }
    );
    await MealRequest.deleteOne({ _id: row._id });

    expect(await reconcile(1)).toMatchObject({ helper: "unknown" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({
      phase: "waiting",
    });
  });

  it("does not retry an uncommitted ambiguous placement or clear its active helper blocker", async () => {
    await start();
    const row = await claimed();
    vi.spyOn(PlacementEvidence, "create").mockRejectedValueOnce(new Error("interrupted evidence write"));
    vi.spyOn(console, "error").mockImplementation(() => {});
    const call = context(row._id, helperId, placementBody());
    await fulfillRequest(call.req, call.res);
    expect(call.status).toBe(500);
    expect(await reconcile()).toMatchObject({ helper: "helperOrPickup" });
    expect(await MealRequest.findById(row._id).lean()).toMatchObject({ status: "claimed" });
    expect(await Fulfillment.countDocuments()).toBe(0);
    expect(await PlacementEvidence.countDocuments()).toBe(0);
  });

  it("ignores foreign helper state and refuses foreign deletion bindings", async () => {
    await start();
    await request({ status: "placed", helperParticipantId: requesterId });
    expect(await reconcile()).toMatchObject({ helper: "clear" });
    expect(await reconcileParticipantDeletionHelperRequests({
      ...owner, participantId: requesterId, canonicalEmail: "p2-requester@nyu.edu",
    }, 0, dependencies)).toEqual({ outcome: "notOwned" });
  });

  it.each(["email", "authorityVersion", "missing"] as const)("refuses stale participant %s", async (field) => {
    await start("ready");
    if (field === "missing") await Participant.deleteOne({ _id: helperId });
    else await Participant.updateOne({ _id: helperId }, {
      $set: field === "email" ? { email: "changed@nyu.edu" } : { authorityVersion: 2 },
    });
    expect(await reconcile(1)).toEqual({ outcome: "notOwned" });
  });

  it.each(["helperFirst", "requesterFirst"] as const)(
    "keeps R5/H1a inputs independent: %s", async (order) => {
      await start("ready");
      await request({ requesterParticipantId: helperId });
      const helper = await claimed();
      const release = context(helper._id);
      await releaseClaim(release.req, release.res);
      expect(release.status).toBe(200);
      const h1a = () => reconcile(1);
      const r5 = () => reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies);
      if (order === "helperFirst") {
        expect(await h1a()).toMatchObject({ helper: "clear" });
        expect(await r5()).toMatchObject({ requester: "withdrawalRequired" });
      } else {
        expect(await r5()).toMatchObject({ requester: "withdrawalRequired" });
        expect(await h1a()).toMatchObject({ helper: "clear" });
      }
      expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
    }
  );

  it("an R5 clear cannot erase an H1a blocker", async () => {
    await start("ready");
    await request({ status: "withdrawn", requesterParticipantId: helperId });
    await claimed();
    expect(await reconcile(1)).toMatchObject({ helper: "helperOrPickup" });
    expect(await reconcileParticipantDeletionRequesterRequests(owner, 1, dependencies))
      .toMatchObject({ requester: "clear" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("does not truncate helper inventory or treat retention clocks as pickup", async () => {
    await start();
    for (let i = 0; i < 26; i++) {
      await request({ status: "claimed", helperParticipantId: helperId, claimExpiresAt: new Date(0) });
    }
    await request({ status: "placed", helperParticipantId: helperId, expiresAt: new Date(0) });
    expect(await reconcile()).toMatchObject({ helper: "helperOrPickup" });
  });

  it("refuses generation changes during conditional demotion", async () => {
    await start("ready");
    await claimed();
    const demote = deletionOperations.demoteParticipantDeletionReadiness;
    vi.spyOn(deletionOperations, "demoteParticipantDeletionReadiness").mockImplementationOnce(
      async (binding, generation, deps) => {
        await demote(binding, generation, deps);
        await promoteParticipantDeletionReadiness(binding, generation, deps);
        return demote(binding, generation, deps);
      }
    );
    expect(await reconcile(1)).toEqual({ outcome: "stale" });
    expect(await readParticipantDeletionStatus(owner, dependencies))
      .toMatchObject({ phase: "ready", readinessGeneration: 2 });
    expect(await reconcile(2)).toMatchObject({ helper: "helperOrPickup" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("cannot demote or revive a cancellation that wins the write race", async () => {
    await start("ready");
    await claimed();
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

  it("serializes challenge redemption and new-blocker demotion without stale authorization", async () => {
    await start("ready");
    await issueParticipantDeletionChallenge(owner, 1, dependencies);
    await claimed();
    await Promise.all([reconcile(1), redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies)]);
    expect(await storedOperation()).toMatchObject({ phase: "waiting" });
    expect(await storedOperation()).not.toHaveProperty("authorizationExpiresAt");
    expect(await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies))
      .toMatchObject({ outcome: "notRedeemable" });
  });

  it.each(["release", "fulfillment", "extension"] as const)(
    "races duplicate observations with authoritative %s without readiness promotion", async (kind) => {
      await start("ready");
      const row = await claimed();
      const call = context(row._id, helperId, kind === "fulfillment" ? placementBody() : {});
      const mutate = kind === "release" ? releaseClaim : kind === "fulfillment" ? fulfillRequest : extendClaim;
      await Promise.all([mutate(call.req, call.res), ...Array.from({ length: 6 }, () => reconcile(1))]);
      expect(call.status).toBe(200);
      expect(await reconcile(1)).toMatchObject({ helper: kind === "release" ? "clear" : "helperOrPickup" });
      expect((await readParticipantDeletionStatus(owner, dependencies))?.phase).not.toBe("completed");
      expect(await RequestParticipation.countDocuments()).toBe(1);
      expect(await Fulfillment.countDocuments()).toBe(kind === "fulfillment" ? 1 : 0);
    }
  );

  it("races release against authoritative expiry without P2 lifecycle writes", async () => {
    await start();
    const row = await claimed();
    const stored = await MealRequest.findById(row._id).lean();
    const call = context(row._id);
    const [observation] = await Promise.all([
      reconcileParticipantDeletionHelperRequests(owner, 0, {
        ...dependencies, now: () => stored!.claimExpiresAt!,
      }),
      releaseClaim(call.req, call.res),
    ]);
    expect(call.status).toBe(200);
    expect(observation).toMatchObject({ outcome: "observed" });
    expect(await reconcile()).toMatchObject({ helper: "clear" });
    expect(await readParticipantDeletionStatus(owner, dependencies)).toMatchObject({ phase: "waiting" });
  });

  it("preserves permanent ledgers and their indexes across reconciliation and accepted release", async () => {
    await start();
    const row = await claimed();
    await RequestOperation.create({
      operationId: randomUUID(), participantId: requesterId, requestId: row._id, outcome: "created",
    });
    const operations = await RequestOperation.collection.find().toArray();
    const participation = await RequestParticipation.collection.find().toArray();
    const indexes = await Promise.all([RequestOperation.collection.indexes(), RequestParticipation.collection.indexes()]);
    await reconcile();
    const call = context(row._id);
    await releaseClaim(call.req, call.res);
    expect(call.status).toBe(200);
    await reconcile();
    expect(await RequestOperation.collection.find().toArray()).toEqual(operations);
    expect(await RequestParticipation.collection.find().toArray()).toEqual(participation);
    expect(await Promise.all([RequestOperation.collection.indexes(), RequestParticipation.collection.indexes()]))
      .toEqual(indexes);
    await expect(RequestOperation.create({ ...operations[0], _id: new mongoose.Types.ObjectId() }))
      .rejects.toMatchObject({ code: 11000 });
    await expect(RequestParticipation.create({ requestId: row._id, participantId: helperId }))
      .rejects.toMatchObject({ code: 11000 });
  });

  it("refuses an already stale generation without touching helper truth", async () => {
    await start("ready");
    await demoteParticipantDeletionReadiness(owner, 1, dependencies);
    await promoteParticipantDeletionReadiness(owner, 1, dependencies);
    const row = await claimed();
    expect(await reconcile(1)).toEqual({ outcome: "stale" });
    expect(await MealRequest.findById(row._id).lean()).toMatchObject({ status: "claimed" });
  });
});
