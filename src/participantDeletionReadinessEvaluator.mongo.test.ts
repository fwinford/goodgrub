import { randomUUID } from "node:crypto";
import type { Request, Response } from "express";
import mongoose from "mongoose";
import { establishRequestOperationLedger } from "./requestOperationAuthority.js";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Fulfillment,
  Participant,
  ParticipantDeletionOperation,
  PlacementEvidence,
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
import { evaluateParticipantDeletionReadiness } from "./participantDeletionReadinessEvaluator.js";
import { getParticipantDeletionStatus } from "./participantDeletionRoute.js";
import { PARTICIPANT_DELETION_SIGNING_SECRET_ENV } from "./participantIdentityKeys.js";
import { DELETION_NAMESPACE_HEADER } from "./participantDeletionNamespace.js";
import { OPERATION_IDENTITY_HEADER } from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import { PARTICIPANT_SIGNING_SECRET_ENV, signParticipantAuthority } from "./participantCredentials.js";
import { withdrawRequest } from "./requestUpdateRoute.js";
import { claimRequest, releaseClaim } from "./claimRoute.js";
import { fulfillRequest } from "./fulfillmentRoute.js";
import { confirmPlacedOrderPickup } from "./placedOrderRoutes.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

vi.mock("resend", () => ({ Resend: class { emails = { send: vi.fn() }; } }));
vi.mock("./emailHelpers.js", () => ({
  sendFulfillmentEmail: vi.fn().mockResolvedValue({}),
  sendParticipantDeletionChallengeEmail: vi.fn().mockResolvedValue(undefined),
}));

function isolatedDatabaseUri(base: string) {
  const uri = new URL(base);
  uri.pathname = `${uri.pathname}_p2_readiness_evaluator`;
  return uri.toString();
}
const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI) : undefined;
const describeMongo = mongoUri ? describe : describe.skip;
const secretText = "p2-readiness-evaluator-test-secret-32b";
const secret = Buffer.from(secretText);
const authoritySecretText = "p2-readiness-authority-test-secret-32b";
const authoritySecret = Buffer.from(authoritySecretText);
const dependencies = { readSecret: () => secret, generateCode: () => "424242", sendChallengeEmail: async () => {} };
const requesterId = new mongoose.Types.ObjectId();
const helperId = new mongoose.Types.ObjectId();
let owner: DeletionOwner;

async function start(phase: "waiting" | "ready" = "waiting") {
  const created = await createOrResolveParticipantDeletionOperation({
    participantId: requesterId, canonicalEmail: "readiness-requester@nyu.edu",
    authorityVersion: 1, initialPhase: phase,
  }, dependencies);
  owner = {
    operationId: created.status.operationId, participantId: requesterId,
    canonicalEmail: "readiness-requester@nyu.edu", authorityVersion: 1,
  };
  return created.status;
}

async function request(overrides: Record<string, unknown> = {}) {
  const now = Date.now();
  const row = await MealRequest.create({
    vendor: "Crave NYU", food: "Rice bowl", pickupWindowText: "ASAP",
    menuPath: "meal-exchange", mealSwipes: 1, mealItems: [{ name: "Rice bowl" }],
    email: "readiness-requester@nyu.edu", status: "open", requesterParticipantId: requesterId,
    visibleFrom: new Date(now - 1000), contentRevision: 1, notificationGeneration: 1,
    expiresAt: new Date(now + 3 * 60 * 60 * 1000),
    deleteAt: new Date(now + 24 * 60 * 60 * 1000), ...overrides,
  });
  if (row.status === "placed") {
    await Fulfillment.create({ requestId: row._id, orderNumber: "123", placedAt: new Date() });
  }
  return row;
}

function context(id: unknown, participantId = requesterId, operationId = randomUUID(), body: unknown = {}) {
  const req = {
    params: { id: String(id) }, body,
    headers: {
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(participantId, 1, authoritySecret),
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

function pickupContext(requestId: unknown, participantId = requesterId) {
  const req = {
    params: { requestId: String(requestId) },
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(participantId, 1, authoritySecret) },
  } as unknown as Request;
  let status = 200;
  const res = {
    status(value: number) { status = value; return this; },
    json() { return this; },
    setHeader() { return this; },
  } as unknown as Response;
  return { req, res, get status() { return status; } };
}

async function claimedByHelper() {
  const row = await request();
  const claim = context(row._id, helperId);
  await claimRequest(claim.req, claim.res);
  expect(claim.status).toBe(200);
  return row;
}

const evaluate = (generation = 0) => evaluateParticipantDeletionReadiness(owner, generation, dependencies);
const storedOperation = () => ParticipantDeletionOperation.findOne({ operationId: owner.operationId })
  .select("+challengeDigest +challengeExpiresAt +authorizedAt +authorizationExpiresAt").lean().exec();

async function statusRead() {
  const current = await readParticipantDeletionStatus(owner, dependencies);
  const ctx = context(undefined);
  ctx.req.query = { operationId: owner.operationId };
  ctx.req.headers[DELETION_NAMESPACE_HEADER] = current!.namespaceBinding;
  await getParticipantDeletionStatus(ctx.req, ctx.res);
  return ctx;
}

describeMongo("P2 whole-operation readiness evaluator on a real replica set", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, authoritySecretText);
    vi.stubEnv(PARTICIPANT_DELETION_SIGNING_SECRET_ENV, secretText);
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "readiness-evaluator-claim-token-secret-32");
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    await mongoose.connect(mongoUri!);
    await establishRequestOperationLedger();
    await prepareParticipantIdentityMongoTestState();
    await Promise.all([
      Participant, ParticipantDeletionOperation, MealRequest, RequestOperation,
      RequestParticipation, RequestUpdateOperation, Fulfillment, PlacementEvidence,
    ].map((model) => model.createIndexes()));
  });
  beforeEach(async () => {
    await Participant.create([
      { _id: requesterId, email: "readiness-requester@nyu.edu", verifiedAt: new Date(), authorityVersion: 1 },
      { _id: helperId, email: "readiness-helper@nyu.edu", verifiedAt: new Date(), authorityVersion: 1 },
    ]);
  });
  afterEach(async () => {
    vi.restoreAllMocks();
    for (const model of [
      MealRequest, ParticipantDeletionOperation, Participant, RequestOperation,
      RequestParticipation, RequestUpdateOperation, Fulfillment, PlacementEvidence,
    ]) await model.collection.deleteMany({});
  });
  afterAll(async () => { await mongoose.disconnect(); vi.unstubAllEnvs(); });

  it("promotes waiting to ready when both real inputs are genuinely clear", async () => {
    await start("waiting");
    expect(await evaluate(0)).toMatchObject({ outcome: "ready" });
    expect(await storedOperation()).toMatchObject({ phase: "ready", readinessGeneration: 1 });
  });

  it("status reconciles clear inputs and persists ready without issuing a challenge", async () => {
    await start("waiting");
    const ctx = await statusRead();
    expect(ctx.status).toBe(200);
    expect(ctx.payload).toMatchObject({ phase: "ready", readinessGeneration: 1 });
    expect(await storedOperation()).toMatchObject({ phase: "ready", readinessGeneration: 1 });
    const next = await statusRead();
    expect(next.payload).toMatchObject({ phase: "ready", readinessGeneration: 1 });
  });

  it("status stays waiting for an active requester, then promotes after authoritative withdrawal", async () => {
    await start("waiting");
    const row = await request();
    expect((await statusRead()).payload).toMatchObject({ phase: "waiting", readinessGeneration: 0 });
    const withdraw = context(row._id);
    await withdrawRequest(withdraw.req, withdraw.res);
    expect(withdraw.status).toBe(200);
    expect((await statusRead()).payload).toMatchObject({ phase: "ready", readinessGeneration: 1 });
    expect(await storedOperation()).toMatchObject({ phase: "ready", readinessGeneration: 1 });
  });

  it("status remains fail-closed for incomplete helper lock truth", async () => {
    await start("waiting");
    await Participant.updateOne({ _id: requesterId }, {
      $set: { activeReservationRequestId: new mongoose.Types.ObjectId() },
      $unset: { activeReservationClaimExpiresAt: "" },
    });
    const ctx = await statusRead();
    expect(ctx.status).toBe(200);
    expect(ctx.payload).toMatchObject({ phase: "waiting", readinessGeneration: 0 });
    expect(await storedOperation()).toMatchObject({ phase: "waiting", readinessGeneration: 0 });
  });

  it("status remains waiting for an active helper reservation", async () => {
    await claimedByHelper();
    const created = await createOrResolveParticipantDeletionOperation({
      participantId: helperId, canonicalEmail: "readiness-helper@nyu.edu",
      authorityVersion: 1, initialPhase: "waiting",
    }, dependencies);
    const ctx = context(undefined, helperId);
    ctx.req.query = { operationId: created.status.operationId };
    ctx.req.headers[DELETION_NAMESPACE_HEADER] = created.status.namespaceBinding;
    await getParticipantDeletionStatus(ctx.req, ctx.res);
    expect(ctx.status).toBe(200);
    expect(ctx.payload).toMatchObject({ phase: "waiting", readinessGeneration: 0 });
  });

  it("stays waiting on an active requester obligation and never promotes", async () => {
    await start("waiting");
    await request();
    expect(await evaluate(0)).toMatchObject({
      outcome: "waiting",
      blockers: [{ source: "requester", observation: "withdrawalRequired" }],
    });
    expect(await storedOperation()).toMatchObject({ phase: "waiting", readinessGeneration: 0 });
  });

  it("stays waiting on an active helper reservation and never promotes", async () => {
    await start("waiting");
    await claimedByHelper();
    // The requester owns no request here; only the symmetric helper-side
    // owner below exercises the helper blocker through the real H1a route.
    const helperOwner: DeletionOwner = {
      ...owner, participantId: helperId, canonicalEmail: "readiness-helper@nyu.edu",
    };
    await createOrResolveParticipantDeletionOperation({
      participantId: helperId, canonicalEmail: "readiness-helper@nyu.edu",
      authorityVersion: 1, initialPhase: "waiting",
    }, dependencies);
    const stored = await ParticipantDeletionOperation.findOne({ participantId: helperId }).lean();
    const boundOwner: DeletionOwner = { ...helperOwner, operationId: stored!.operationId };
    expect(await evaluateParticipantDeletionReadiness(boundOwner, 0, dependencies)).toMatchObject({
      outcome: "waiting",
      blockers: [{ source: "helper", observation: "helperOrPickup" }],
    });
  });

  it("requires both inputs clear: a requester blocker is never overridden by a clear helper", async () => {
    await start("waiting");
    await request();
    const result = await evaluate(0);
    expect(result).toMatchObject({ outcome: "waiting" });
    expect((result as { blockers: unknown[] }).blockers).toHaveLength(1);
    expect((result as { blockers: { source: string }[] }).blockers[0].source).toBe("requester");
  });

  it("R5 withdrawal race: demotes then clears without ever promoting early", async () => {
    await start("ready");
    const row = await request();
    const withdraw = context(row._id);
    const [, ...evaluations] = await Promise.all([
      withdrawRequest(withdraw.req, withdraw.res),
      ...Array.from({ length: 6 }, () => evaluate(1)),
    ]);
    expect(withdraw.status).toBe(200);
    for (const result of evaluations) {
      expect(["waiting", "ready", "stale"]).toContain(result.outcome);
    }
    // A concurrent evaluation may have already won the promotion the instant
    // it observed the committed withdrawal; re-read current truth rather
    // than assume this run's own generation is still current.
    const current = await readParticipantDeletionStatus(owner, dependencies);
    expect(await evaluateParticipantDeletionReadiness(owner, current!.readinessGeneration, dependencies))
      .toMatchObject({ outcome: "ready" });
    expect(await storedOperation()).toMatchObject({ phase: "ready" });
  });

  it("H1a release race: a lapsing reservation never leaves the operation incorrectly ready", async () => {
    await start("waiting");
    const row = await claimedByHelper();
    const helperOwner: DeletionOwner = {
      operationId: (await createOrResolveParticipantDeletionOperation({
        participantId: helperId, canonicalEmail: "readiness-helper@nyu.edu",
        authorityVersion: 1, initialPhase: "ready",
      }, dependencies)).status.operationId,
      participantId: helperId, canonicalEmail: "readiness-helper@nyu.edu", authorityVersion: 1,
    };
    const release = context(row._id, helperId);
    const [, ...evaluations] = await Promise.all([
      releaseClaim(release.req, release.res),
      ...Array.from({ length: 6 }, () => evaluateParticipantDeletionReadiness(helperOwner, 1, dependencies)),
    ]);
    expect(release.status).toBe(200);
    for (const result of evaluations) {
      expect(["waiting", "ready", "stale"]).toContain(result.outcome);
    }
    const current = await readParticipantDeletionStatus(helperOwner, dependencies);
    expect(await evaluateParticipantDeletionReadiness(helperOwner, current!.readinessGeneration, dependencies))
      .toMatchObject({ outcome: "ready" });
  });

  it("R3 pickup-confirmation race: settles to clear/ready, never resurrects a stale blocker", async () => {
    await start("ready");
    const row = await request({ status: "placed" });
    expect(await evaluate(1)).toMatchObject({ outcome: "waiting" });
    const confirm = pickupContext(row._id);
    const [, ...evaluations] = await Promise.all([
      confirmPlacedOrderPickup(confirm.req, confirm.res),
      ...Array.from({ length: 6 }, () => evaluate(1)),
    ]);
    expect(confirm.status).toBe(200);
    for (const result of evaluations) {
      expect(["waiting", "ready", "stale"]).toContain(result.outcome);
    }
    // One of the six concurrent evaluations may have already won the
    // promotion once it observed R3's clear confirmation, advancing the
    // generation; a caller must re-read current truth before evaluating
    // again rather than assume its own generation is still current.
    const current = await readParticipantDeletionStatus(owner, dependencies);
    expect(await evaluateParticipantDeletionReadiness(owner, current!.readinessGeneration, dependencies))
      .toMatchObject({ outcome: "ready" });
  });

  it("stale readiness generation: an evaluation under an old generation never promotes a newer one", async () => {
    await start("ready");
    await demoteParticipantDeletionReadiness(owner, 1, dependencies);
    await promoteParticipantDeletionReadiness(owner, 1, dependencies);
    expect(await storedOperation()).toMatchObject({ phase: "ready", readinessGeneration: 2 });
    expect(await evaluate(1)).toEqual({ outcome: "stale" });
    expect(await storedOperation()).toMatchObject({ phase: "ready", readinessGeneration: 2 });
  });

  it("concurrent duplicate evaluator runs converge on one winner without double-advancing readiness", async () => {
    await start("waiting");
    const results = await Promise.all(Array.from({ length: 8 }, () => evaluate(0)));
    const ready = results.filter((result) => result.outcome === "ready");
    const stale = results.filter((result) => result.outcome === "stale");
    expect(ready.length + stale.length).toBe(results.length);
    expect(ready.length).toBeGreaterThanOrEqual(1);
    expect(await storedOperation()).toMatchObject({ phase: "ready", readinessGeneration: 1 });
  });

  it("demotes an already-ready operation back to waiting the moment a new blocker lands, idempotently", async () => {
    await start("ready");
    await request();
    expect(await evaluate(1)).toMatchObject({ outcome: "waiting" });
    const demoted = await storedOperation();
    expect(demoted).toMatchObject({ phase: "waiting", readinessGeneration: 1 });
    for (const field of ["challengeDigest", "challengeExpiresAt", "authorizedAt", "authorizationExpiresAt"]) {
      expect(demoted).not.toHaveProperty(field);
    }
    await Promise.all(Array.from({ length: 4 }, () => evaluate(1)));
    expect(await storedOperation()).toEqual(demoted);
  });

  it.each(["challengeIssued", "authorized"] as const)(
    "demotes %s and invalidates live security material when a new blocker is found",
    async (phase) => {
      await start("ready");
      await issueParticipantDeletionChallenge(owner, 1, dependencies);
      if (phase === "authorized") await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies);
      await request();
      expect(await evaluate(1)).toMatchObject({ outcome: "waiting" });
      expect(await storedOperation()).toMatchObject({ phase: "waiting", readinessGeneration: 1 });
      expect(await redeemParticipantDeletionChallenge(owner, 1, "424242", dependencies))
        .toMatchObject({ outcome: "notRedeemable" });
    }
  );

  it("is idempotent: repeated evaluation while clear stays ready at the same generation", async () => {
    await start("waiting");
    expect(await evaluate(0)).toMatchObject({ outcome: "ready" });
    for (let i = 0; i < 4; i++) {
      expect(await evaluate(1)).toMatchObject({ outcome: "ready" });
    }
    expect(await storedOperation()).toMatchObject({ phase: "ready", readinessGeneration: 1 });
  });

  it("does not resurrect a canceled operation as ready", async () => {
    await start("ready");
    await cancelParticipantDeletionOperation(owner, dependencies);
    expect(await evaluate(1)).toEqual({ outcome: "inactive" });
    expect(await storedOperation()).toMatchObject({ phase: "canceled" });
  });

  it("does not resurrect a completed-shaped (foreign-owner) operation and refuses a stale binding", async () => {
    await start("ready");
    await Participant.updateOne({ _id: requesterId }, { $set: { authorityVersion: 2 } });
    expect(await evaluate(1)).toEqual({ outcome: "notOwned" });
  });

  it("refuses a different participant's deletion owner even with a matching operation id", async () => {
    await start("waiting");
    expect(await evaluateParticipantDeletionReadiness({
      ...owner, participantId: helperId, canonicalEmail: "readiness-helper@nyu.edu",
    }, 0, dependencies)).toEqual({ outcome: "notOwned" });
  });

  it("evaluates placed/fulfillment state consistently: a lost fulfillment response still blocks", async () => {
    await start("waiting");
    const row = await claimedByHelper();
    const call = context(row._id, helperId, randomUUID(), {
      fulfillment: {
        orderNumber: "001234", eta: "15 minutes",
        placedOrderScreenshot: {
          mimeType: "image/png",
          imageBase64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
        },
      },
    });
    vi.spyOn(call.res, "json").mockImplementationOnce(() => { throw new Error("lost response"); });
    vi.spyOn(console, "error").mockImplementation(() => {});
    await expect(fulfillRequest(call.req, call.res)).rejects.toThrow("lost response");
    expect(await evaluate(0)).toMatchObject({
      outcome: "waiting",
      blockers: [{ source: "requester", observation: "helperOrPickup" }],
    });
  });

  it("preserves permanent ledgers and real request state across many evaluator runs", async () => {
    await start("waiting");
    const row = await request();
    const before = await MealRequest.collection.find().toArray();
    await Promise.all(Array.from({ length: 10 }, () => evaluate(0)));
    expect(await MealRequest.collection.find().toArray()).toEqual(before);
    expect(await RequestOperation.countDocuments()).toBe(0);
    expect(await RequestParticipation.countDocuments()).toBe(0);
    const withdraw = context(row._id);
    await withdrawRequest(withdraw.req, withdraw.res);
    expect(withdraw.status).toBe(200);
    expect(await evaluate(0)).toMatchObject({ outcome: "ready" });
  });
});
