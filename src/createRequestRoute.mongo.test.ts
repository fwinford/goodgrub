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

const { resendSend, notifySubscribersForRequest, startHelperNewRequestPush } =
  vi.hoisted(() => ({
    resendSend: vi.fn(),
    notifySubscribersForRequest: vi.fn(),
    startHelperNewRequestPush: vi.fn(),
  }));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

vi.mock("./notifySubscribers.js", () => ({
  notifySubscribersForRequest,
}));

vi.mock("./helperNewRequestPush.js", () => ({
  startHelperNewRequestPush,
}));

import {
  Participant,
  Request as MealRequest,
  RequestOperation,
} from "../models/db.js";
import {
  createRequest,
  OPERATION_EXPIRED_CODE,
  OPERATION_IDENTITY_HEADER,
  OPERATION_NOT_CREATED_CODE,
  OPERATION_UNAUTHORIZED_CODE,
  OPERATION_UNAUTHORIZED_MESSAGE,
  REQUEST_TEXT_NOT_ALLOWED_CODE,
  REQUEST_TEXT_NOT_ALLOWED_MESSAGE,
  terminalizeOperation,
} from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

/**
 * W3-D1 real-Mongo proof: the backend exact-operation identity, bounded
 * recovery, and idempotency/reconciliation primitive for request creation.
 * This is the first Mongo-gated suite to drive `POST /api/request` — every
 * other create-route suite is fully mocked — because the properties under
 * test here are database-level guarantees a mocked model cannot exercise:
 * "at most one Request per logical operation, even under real concurrency"
 * (`request_operation_ledger_identity_unique`), and "an expired operation's
 * identity survives its Request's own TTL cleanup" (the separate
 * `RequestOperation` ledger, never reclaimed by that TTL).
 */
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_create_request_operation`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const participantSecretText = "create-request-mongo-participant-secret-32b";
const participantSecret = Buffer.from(participantSecretText);

const requesterAId = new mongoose.Types.ObjectId("64f0000000000000000000a1");
const requesterAPrincipal = "d1-mongo-requester-a@nyu.edu";
const requesterAAuthority = signParticipantAuthority(
  requesterAId,
  1,
  participantSecret
);

const requesterBId = new mongoose.Types.ObjectId("64f0000000000000000000b2");
const requesterBPrincipal = "d1-mongo-requester-b@nyu.edu";
const requesterBAuthority = signParticipantAuthority(
  requesterBId,
  1,
  participantSecret
);

function canonicalAsapPayload(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Jasper Kane Cafe",
    timing: "asap",
    // W4-R4 structured representation: `food` is derived by the backend and
    // `pickupName` no longer exists, so neither is sent.
    menuPath: "meal-exchange",
    mealSwipes: 2,
    mealItems: [{ name: "Vegetable rice bowl" }, { name: "Side salad" }],
    ...overrides,
  };
}

function routeContext(
  body: unknown,
  headers: Record<string, string> = {
    [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
  }
) {
  const req = { body, headers } as unknown as Request;
  const res = {} as Response;
  let statusCode = 0;
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

describeMongo("real MongoDB durable create-operation identity (W3-D1)", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
    await RequestOperation.syncIndexes();
    await Participant.updateOne(
      { _id: requesterAId },
      {
        $set: { email: requesterAPrincipal, verifiedAt: new Date() },
        $setOnInsert: { authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
    await Participant.updateOne(
      { _id: requesterBId },
      {
        $set: { email: requesterBPrincipal, verifiedAt: new Date() },
        $setOnInsert: { authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
    await RequestOperation.deleteMany({});
    resendSend.mockReset().mockResolvedValue({ data: { id: "x" }, error: null });
    notifySubscribersForRequest.mockReset().mockResolvedValue(undefined);
    startHelperNewRequestPush.mockReset();
  });

  afterAll(async () => {
    await Participant.deleteMany({ _id: { $in: [requesterAId, requesterBId] } });
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("creates exactly one Request for a first, genuinely new operation", async () => {
    const context = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-first",
    });

    await createRequest(context.req, context.res);

    expect(context.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("answers an owner-deleted operation with generic unauthorized before Request lookup", async () => {
    const operationId = "mongo-owner-deleted-operation";
    await RequestOperation.create({
      operationId,
      outcome: "created",
      ownerDeleted: true,
    });
    const requestLookup = vi.spyOn(MealRequest, "findOne");
    const context = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterBAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });

    await createRequest(context.req, context.res);

    expect(context.statusCode).toBe(403);
    expect(context.body).toEqual({
      error: {
        code: OPERATION_UNAUTHORIZED_CODE,
        message: OPERATION_UNAUTHORIZED_MESSAGE,
      },
    });
    expect(requestLookup).not.toHaveBeenCalled();
    expect(await MealRequest.countDocuments({})).toBe(0);
    expect(JSON.stringify(context.body)).not.toContain(operationId);
    expect(await RequestOperation.countDocuments({ operationId })).toBe(1);
  });

  it("reconciles a sequential replay to the same Request and creates no second one", async () => {
    const first = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-sequential-replay",
    });
    await createRequest(first.req, first.res);
    expect(first.statusCode).toBe(201);
    const createdId = first.body.request.id;

    const replay = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-sequential-replay",
    });
    await createRequest(replay.req, replay.res);

    expect(replay.statusCode).toBe(200);
    expect(replay.body.request.id).toBe(createdId);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("creates at most one Request when two attempts race the same operation identity concurrently", async () => {
    const operationId = "mongo-op-concurrent-race";
    const first = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    const second = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });

    await Promise.all([
      createRequest(first.req, first.res),
      createRequest(second.req, second.res),
    ]);

    const statuses = [first.statusCode, second.statusCode].sort();
    // Exactly one attempt is the authoritative creator (201); the other
    // reconciles to it (200). Neither may fail, and neither may silently win
    // a second Request into existence.
    expect(statuses).toEqual([200, 201]);
    expect(first.body.request.id).toBe(second.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("creates distinct Requests for distinct operation identities with an identical payload", async () => {
    const first = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-distinct-1",
    });
    const second = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-distinct-2",
    });

    await createRequest(first.req, first.res);
    await createRequest(second.req, second.res);

    expect(first.statusCode).toBe(201);
    expect(second.statusCode).toBe(201);
    expect(first.body.request.id).not.toBe(second.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(2);
  });

  it("refuses cross-participant replay/reconciliation without exposing the existing Request", async () => {
    const created = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-cross-participant",
    });
    await createRequest(created.req, created.res);
    expect(created.statusCode).toBe(201);

    const intruder = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterBAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-cross-participant",
    });
    await createRequest(intruder.req, intruder.res);

    expect(intruder.statusCode).toBe(403);
    expect(intruder.body).toEqual({
      error: expect.objectContaining({ code: OPERATION_UNAUTHORIZED_CODE }),
    });
    // Nothing about the existing request leaked, and nothing new was created.
    expect(JSON.stringify(intruder.body)).not.toContain("Jasper Kane Cafe");
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("refuses the same cross-participant collision when it surfaces as a create-time race", async () => {
    const operationId = "mongo-op-cross-participant-race";
    const owner = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    const intruder = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterBAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });

    await Promise.all([
      createRequest(owner.req, owner.res),
      createRequest(intruder.req, intruder.res),
    ]);

    // Whichever request actually won the insert must be requester A's; the
    // other must be a definitive refusal, never a reconciliation to A's data.
    const results = [owner, intruder];
    const winner = results.find((entry) => entry.statusCode === 201);
    const loser = results.find((entry) => entry !== winner);
    expect(winner).toBeDefined();
    expect(loser?.statusCode).toBe(403);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("does not consume quota on replay, and still enforces quota for a genuinely distinct operation", async () => {
    const now = new Date();
    for (let index = 0; index < 3; index += 1) {
      await MealRequest.create({
        vendor: "Jasper Kane Cafe",
        food: "Prior request",
        pickupWindowText: "ASAP",
        menuPath: "meal-exchange",
        mealSwipes: 1,
        mealItems: [{ name: "Prior request" }],
        email: requesterAPrincipal,
        requesterParticipantId: requesterAId,
        status: "open",
        visibleFrom: now,
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
        helperNotification: "initiated",
      });
    }
    expect(await MealRequest.countDocuments({})).toBe(3);

    // The requester is already at the daily limit. A genuinely distinct
    // operation is refused by the unchanged quota rule.
    const distinct = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-quota-distinct",
    });
    await createRequest(distinct.req, distinct.res);
    expect(distinct.statusCode).toBe(429);
    expect(await MealRequest.countDocuments({})).toBe(3);
  });

  it("reconciles an already-created operation even when the requester is now over quota", async () => {
    const first = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-quota-replay",
    });
    await createRequest(first.req, first.res);
    expect(first.statusCode).toBe(201);

    const now = new Date();
    for (let index = 0; index < 2; index += 1) {
      await MealRequest.create({
        vendor: "Jasper Kane Cafe",
        food: "Additional request",
        pickupWindowText: "ASAP",
        menuPath: "meal-exchange",
        mealSwipes: 1,
        mealItems: [{ name: "Additional request" }],
        email: requesterAPrincipal,
        requesterParticipantId: requesterAId,
        status: "open",
        visibleFrom: now,
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
        helperNotification: "initiated",
      });
    }
    expect(await MealRequest.countDocuments({})).toBe(3);

    const replay = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-quota-replay",
    });
    await createRequest(replay.req, replay.res);

    expect(replay.statusCode).toBe(200);
    expect(replay.body.request.id).toBe(first.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(3);
  });

  it("creates no Request for a malformed operation identity and does not poison a later valid one", async () => {
    const malformed = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "not a valid identity",
    });
    await createRequest(malformed.req, malformed.res);
    expect(malformed.statusCode).toBe(400);
    expect(await MealRequest.countDocuments({})).toBe(0);

    const valid = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-after-malformed",
    });
    await createRequest(valid.req, valid.res);
    expect(valid.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("keeps the operation identity out of the public response", async () => {
    const context = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-not-public",
    });
    await createRequest(context.req, context.res);

    expect(context.statusCode).toBe(201);
    expect(JSON.stringify(context.body)).not.toContain("mongo-op-not-public");
  });

  it("still creates a Request normally when no operation identity is presented (legacy/opt-in compatibility)", async () => {
    const context = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
    });
    await createRequest(context.req, context.res);

    expect(context.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("survives the Request's own deletion: the ledger, not the Request, is what a bounded-recovery-horizon check reads", async () => {
    const operationId = "mongo-op-ledger-survives-request-deletion";
    const created = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(created.req, created.res);
    expect(created.statusCode).toBe(201);

    // Simulates MongoDB's TTL reclaiming the Request once it is no longer
    // active/actionable (the accepted recovery-horizon boundary), while the
    // durable operation ledger row is deliberately left in place — exactly
    // what the real `deleteAt` TTL index does to the Request collection.
    await MealRequest.deleteMany({});
    expect(await RequestOperation.countDocuments({ operationId })).toBe(1);

    const afterCleanup = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(afterCleanup.req, afterCleanup.res);

    // Terminal expired/unrecoverable, never a fresh create: cleanup of the
    // original Request must not make this exact identity look new again.
    expect(afterCleanup.statusCode).toBe(410);
    expect(afterCleanup.body).toEqual({
      error: expect.objectContaining({ code: OPERATION_EXPIRED_CODE }),
    });
    expect(await MealRequest.countDocuments({})).toBe(0);
  });

  it("keeps repeating the terminal expired outcome for the same exact identity, creating zero Requests every time", async () => {
    const operationId = "mongo-op-expired-repeat-presentation";
    const created = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(created.req, created.res);
    await MealRequest.deleteMany({});

    for (let attempt = 0; attempt < 3; attempt += 1) {
      const replay = routeContext(canonicalAsapPayload(), {
        [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
        [OPERATION_IDENTITY_HEADER]: operationId,
      });
      await createRequest(replay.req, replay.res);
      expect(replay.statusCode).toBe(410);
    }
    expect(await MealRequest.countDocuments({})).toBe(0);
  });

  it("permits a fresh intentional operation to create normally after the prior exact identity has expired", async () => {
    const expiredOperationId = "mongo-op-expired-then-fresh-y";
    const expiredAttempt = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: expiredOperationId,
    });
    await createRequest(expiredAttempt.req, expiredAttempt.res);
    await MealRequest.deleteMany({});

    const expiredReplay = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: expiredOperationId,
    });
    await createRequest(expiredReplay.req, expiredReplay.res);
    expect(expiredReplay.statusCode).toBe(410);
    expect(await MealRequest.countDocuments({})).toBe(0);

    // A genuinely new operation identity (Y) is unaffected by X's expiry and
    // creates normally under existing validation/quota rules.
    const fresh = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-expired-then-fresh-y-actual",
    });
    await createRequest(fresh.req, fresh.res);
    expect(fresh.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("refuses cross-participant reconciliation of an expired identity the same generic way, without revealing that it ever existed", async () => {
    const operationId = "mongo-op-expired-cross-participant";
    const created = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(created.req, created.res);
    await MealRequest.deleteMany({});

    const intruder = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterBAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(intruder.req, intruder.res);

    // Unauthorized takes precedence over expired: Participant B never learns
    // whether this identity created a Request at all, let alone that it has
    // since expired.
    expect(intruder.statusCode).toBe(403);
    expect(intruder.body).toEqual({
      error: expect.objectContaining({ code: OPERATION_UNAUTHORIZED_CODE }),
    });
    expect(await MealRequest.countDocuments({})).toBe(0);
  });

  // MARK: - W4-R4 structured payload identity through D1 recovery

  /** A deliberately distinctive structured payload: five swipes with five
   * distinct meal entries plus an exact optional estimate, so a field that
   * silently dropped, reordered, or rounded during replay is visible. */
  function structuredMealExchangePayload() {
    return {
      vendor: "Jasper Kane Cafe",
      timing: "asap",
      menuPath: "meal-exchange",
      mealSwipes: 5,
      mealItems: [
        { name: "Chicken over rice, no onions" },
        { name: "Falafel wrap with extra tahini" },
        { name: "Large iced coffee" },
        { name: "Side of plantains" },
        { name: "Bottled water" },
      ],
      estimatedDiningDollarsCents: 1_337,
    };
  }

  function diningDollarsOnlyPayload() {
    return {
      vendor: "Jasper Kane Cafe",
      timing: "asap",
      menuPath: "dining-dollars",
      mealSwipes: 0,
      orderDetails: "Grain bowl with extra avocado",
      estimatedDiningDollarsCents: 4_999,
    };
  }

  it("replays a structured Meal Exchange operation to the same Request with every field intact", async () => {
    const operationId = "mongo-op-structured-replay";
    const first = routeContext(structuredMealExchangePayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(first.req, first.res);
    expect(first.statusCode).toBe(201);

    const replay = routeContext(structuredMealExchangePayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(replay.req, replay.res);

    expect(replay.statusCode).toBe(200);
    expect(replay.body.request.id).toBe(first.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(1);

    // The reconciled response describes the same authoritative Request, with
    // the structured representation byte-for-byte as submitted — not a
    // regenerated or re-derived one.
    expect(replay.body.request.menuPath).toBe("meal-exchange");
    expect(replay.body.request.mealSwipes).toBe(5);
    expect(replay.body.request.mealItems).toEqual(
      structuredMealExchangePayload().mealItems
    );
    expect(replay.body.request.estimatedDiningDollarsCents).toBe(1_337);
    expect(replay.body.request).toEqual(first.body.request);

    const stored = await MealRequest.findById(first.body.request.id).lean();
    expect(stored?.mealItems).toEqual(structuredMealExchangePayload().mealItems);
    expect(stored?.estimatedDiningDollarsCents).toBe(1_337);
  });

  it("replays a Dining-Dollars-only operation with its exact cents preserved", async () => {
    const operationId = "mongo-op-dining-dollars-replay";
    const first = routeContext(diningDollarsOnlyPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(first.req, first.res);
    expect(first.statusCode).toBe(201);

    const replay = routeContext(diningDollarsOnlyPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(replay.req, replay.res);

    expect(replay.statusCode).toBe(200);
    expect(await MealRequest.countDocuments({})).toBe(1);
    expect(replay.body.request.mealSwipes).toBe(0);
    expect(replay.body.request.orderDetails).toBe(
      "Grain bowl with extra avocado"
    );
    // Exactly 4999 cents, with no rounding introduced anywhere between
    // submission, persistence, and reconciliation.
    expect(replay.body.request.estimatedDiningDollarsCents).toBe(4_999);
  });

  it("creates at most one Request when a structured payload races its own identity", async () => {
    const operationId = "mongo-op-structured-race";
    const first = routeContext(structuredMealExchangePayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    const second = routeContext(structuredMealExchangePayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });

    await Promise.all([
      createRequest(first.req, first.res),
      createRequest(second.req, second.res),
    ]);

    expect([first.statusCode, second.statusCode].sort()).toEqual([200, 201]);
    expect(first.body.request.id).toBe(second.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(1);
    expect(first.body.request.mealItems).toEqual(
      structuredMealExchangePayload().mealItems
    );
  });

  it("reconciles by identity alone, never by structured payload similarity", async () => {
    const first = routeContext(structuredMealExchangePayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-structured-identity-a",
    });
    await createRequest(first.req, first.res);
    expect(first.statusCode).toBe(201);

    // The exact same structured content under a new identity is a genuinely
    // new intentional submission, not a replay.
    const second = routeContext(structuredMealExchangePayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-structured-identity-b",
    });
    await createRequest(second.req, second.res);

    expect(second.statusCode).toBe(201);
    expect(second.body.request.id).not.toBe(first.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(2);
  });

  // W4-U1.1: a refusal is a definitive pre-mutation non-create. These are the
  // database-level properties a mocked model cannot prove: nothing at all is
  // committed (no Request, and no operation ledger row of any kind), and an
  // exact-operation replay is still answered by reconciliation, never by the
  // filter.
  describe("W4-U1.1 requester text filtering is a definitive pre-mutation refusal", () => {
    const BLOCKED = "you stupid bitch";
    const refusedPayload = () =>
      canonicalAsapPayload({
        mealItems: [{ name: "Vegetable rice bowl" }, { name: BLOCKED }],
      });
    const headersFor = (operationId?: string) => ({
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      ...(operationId ? { [OPERATION_IDENTITY_HEADER]: operationId } : {}),
    });

    it("commits zero Requests and zero operation rows, and starts no confirmation, email, or push", async () => {
      const context = routeContext(refusedPayload(), headersFor());

      await createRequest(context.req, context.res);

      expect(context.statusCode).toBe(422);
      expect(context.body.error).toEqual({
        code: REQUEST_TEXT_NOT_ALLOWED_CODE,
        message: REQUEST_TEXT_NOT_ALLOWED_MESSAGE,
        fields: null,
      });
      expect(JSON.stringify(context.body)).not.toMatch(/stupid|bitch/i);
      expect(await MealRequest.countDocuments({})).toBe(0);
      expect(await RequestOperation.countDocuments({})).toBe(0);
      expect(resendSend).not.toHaveBeenCalled();
      expect(notifySubscribersForRequest).not.toHaveBeenCalled();
      expect(startHelperNewRequestPush).not.toHaveBeenCalled();
    });

    it("with an operation identity, commits no Request and no ledger row (not CREATED, not NO-CREATE)", async () => {
      const context = routeContext(refusedPayload(), headersFor("mongo-op-u11-fresh-refused"));

      await createRequest(context.req, context.res);

      expect(context.statusCode).toBe(422);
      expect(await MealRequest.countDocuments({})).toBe(0);
      expect(await RequestOperation.countDocuments({})).toBe(0);
      expect(
        await RequestOperation.collection.countDocuments({ operationId: "mongo-op-u11-fresh-refused" })
      ).toBe(0);
    });

    it("leaves the refused identity genuinely unused: a corrected submission under it creates normally", async () => {
      const refused = routeContext(refusedPayload(), headersFor("mongo-op-u11-corrected"));
      await createRequest(refused.req, refused.res);
      expect(refused.statusCode).toBe(422);

      const corrected = routeContext(canonicalAsapPayload(), headersFor("mongo-op-u11-corrected"));
      await createRequest(corrected.req, corrected.res);

      expect(corrected.statusCode).toBe(201);
      expect(await MealRequest.countDocuments({})).toBe(1);
      expect(await RequestOperation.countDocuments({ operationId: "mongo-op-u11-corrected" })).toBe(1);
    });

    it("the existing D2 mechanism still retires a refused identity: terminalization writes NO-CREATE and replay answers OPERATION_NOT_CREATED", async () => {
      const refused = routeContext(refusedPayload(), headersFor("mongo-op-u11-d2"));
      await createRequest(refused.req, refused.res);
      expect(refused.statusCode).toBe(422);

      // What D2 recovery does for a refusal that follows an empty lookup.
      const outcome = await terminalizeOperation("mongo-op-u11-d2", String(requesterAId));
      expect(outcome).toEqual({ outcome: "not-created" });

      const replay = routeContext(refusedPayload(), headersFor("mongo-op-u11-d2"));
      await createRequest(replay.req, replay.res);
      expect(replay.statusCode).toBe(409);
      expect(replay.body.error.code).toBe(OPERATION_NOT_CREATED_CODE);
      expect(await MealRequest.countDocuments({})).toBe(0);
    });

    it("recovery is not conflated with a fresh refusal: replaying an operation that CREATED answers CREATED even for text the filter would now refuse", async () => {
      const first = routeContext(canonicalAsapPayload(), headersFor("mongo-op-u11-created"));
      await createRequest(first.req, first.res);
      expect(first.statusCode).toBe(201);
      const createdId = first.body.request.id;
      resendSend.mockClear();
      startHelperNewRequestPush.mockClear();

      const replay = routeContext(refusedPayload(), headersFor("mongo-op-u11-created"));
      await createRequest(replay.req, replay.res);

      expect(replay.statusCode).toBe(200);
      expect(replay.body.request.id).toBe(createdId);
      expect(await MealRequest.countDocuments({})).toBe(1);
      expect(await RequestOperation.countDocuments({})).toBe(1);
      // A reconciliation re-sends nothing.
      expect(resendSend).not.toHaveBeenCalled();
      expect(startHelperNewRequestPush).not.toHaveBeenCalled();
    });

    it("consumes no quota: repeated refusals leave the full daily allowance available", async () => {
      for (let attempt = 0; attempt < 4; attempt += 1) {
        const refused = routeContext(refusedPayload(), headersFor(`mongo-op-u11-quota-refused-${attempt}`));
        await createRequest(refused.req, refused.res);
        expect(refused.statusCode).toBe(422);
      }
      for (let created = 0; created < 3; created += 1) {
        const ok = routeContext(canonicalAsapPayload(), headersFor(`mongo-op-u11-quota-ok-${created}`));
        await createRequest(ok.req, ok.res);
        expect(ok.statusCode).toBe(201);
      }
      expect(await MealRequest.countDocuments({})).toBe(3);
    });

    it("filters before the quota read: a refused attempt at the daily limit is the filtering refusal, not REQUEST_LIMIT_REACHED", async () => {
      for (let created = 0; created < 3; created += 1) {
        const ok = routeContext(canonicalAsapPayload(), headersFor(`mongo-op-u11-limit-${created}`));
        await createRequest(ok.req, ok.res);
        expect(ok.statusCode).toBe(201);
      }
      const refused = routeContext(refusedPayload(), headersFor("mongo-op-u11-limit-refused"));
      await createRequest(refused.req, refused.res);

      expect(refused.statusCode).toBe(422);
      expect(refused.body.error.code).toBe(REQUEST_TEXT_NOT_ALLOWED_CODE);
      expect(await MealRequest.countDocuments({})).toBe(3);
    });

    it("never persists refused text anywhere in the database", async () => {
      const refused = routeContext(refusedPayload(), headersFor("mongo-op-u11-nowhere"));
      await createRequest(refused.req, refused.res);

      const db = mongoose.connection.db!;
      for (const { name } of await db.listCollections().toArray()) {
        const documents = await db.collection(name).find({}).toArray();
        expect(JSON.stringify(documents)).not.toMatch(/stupid|bitch/i);
      }
    });
  });
});
