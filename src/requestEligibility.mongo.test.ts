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
import {
  Participant,
  Request as MealRequest,
  RequestOperation,
} from "../models/db.js";
import { readRequestEligibilityState } from "./requestEligibility.js";
import { createRequest, OPERATION_IDENTITY_HEADER } from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

/**
 * Real-Mongo acceptance for the W4-Q1 request-creation eligibility read:
 * that it counts against the real persisted `Request` collection exactly
 * the way `POST /api/request`'s own daily-limit read does (same
 * `src/requestDailyQuota.ts` authority), including the NYU campus-day
 * boundary. Route-level authority-gate and privacy/cache behavior are
 * proved against stubbed persistence in `requestEligibilityRoute.test.ts`.
 */
const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

// Hoisted mocks for the review-fix 3 race proof below, which drives the real
// `createRequest` handler against real Mongo to prove the create-time
// refusal, not merely a second `readRequestEligibilityState` call. Mirrors
// `createRequestRoute.mongo.test.ts`'s own mocking of the same three
// side-effecting dependencies, none of which this proof needs to exercise
// for real.
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

function makeRequest(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Test Vendor",
    food: "Test food",
    email: "eligibility-mongo@nyu.edu",
    menuPath: "meal-exchange",
    mealSwipes: 1,
    mealItems: [{ name: "Test food" }],
    pickupWindowText: "ASAP",
    status: "open",
    visibleFrom: new Date(),
    helperNotification: "initiated",
    expiresAt: new Date(Date.now() + 3 * 60 * 60 * 1000),
    deleteAt: new Date(Date.now() + 3 * 60 * 60 * 1000),
    ...overrides,
  };
}

// Review-fix 3 race-proof participant, real-Mongo-backed like
// `createRequestRoute.mongo.test.ts`'s own fixtures.
const participantSecretText = "eligibility-race-proof-mongo-secret-32byte";
const participantSecret = Buffer.from(participantSecretText);
const raceParticipantId = new mongoose.Types.ObjectId(
  "64f0000000000000000000e1"
);
const raceParticipant = "race-boundary-post@nyu.edu";
const raceParticipantAuthority = signParticipantAuthority(
  raceParticipantId,
  1,
  participantSecret
);

function canonicalAsapPayload() {
  return {
    vendor: "Jasper Kane Cafe",
    timing: "asap",
    menuPath: "meal-exchange",
    mealSwipes: 2,
    mealItems: [{ name: "Vegetable rice bowl" }, { name: "Side salad" }],
  };
}

function routeContext(body: unknown, operationId?: string) {
  const req = {
    body,
    headers: {
      [PARTICIPANT_AUTHORITY_HEADER]: raceParticipantAuthority,
      ...(operationId ? { [OPERATION_IDENTITY_HEADER]: operationId } : {}),
    },
  } as unknown as Request;
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

describeMongo("W4-Q1 request eligibility read against real MongoDB", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_request_eligibility_test",
    });
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await Participant.updateOne(
      { _id: raceParticipantId },
      {
        $set: { email: raceParticipant, verifiedAt: new Date() },
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
    await Participant.deleteMany({ _id: raceParticipantId });
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("reports eligible for a principal with no requests today", async () => {
    await expect(
      readRequestEligibilityState("no-requests@nyu.edu", new Date())
    ).resolves.toEqual({ eligibility: "eligible" });
  });

  it("reports eligible below the three-request threshold and exhausted at it", async () => {
    const principal = "threshold@nyu.edu";
    const now = new Date("2026-07-28T10:00:00.000Z");

    await MealRequest.create(makeRequest({ email: principal, createdAt: now }));
    await MealRequest.create(makeRequest({ email: principal, createdAt: now }));
    await expect(
      readRequestEligibilityState(principal, now)
    ).resolves.toEqual({ eligibility: "eligible" });

    await MealRequest.create(makeRequest({ email: principal, createdAt: now }));
    await expect(
      readRequestEligibilityState(principal, now)
    ).resolves.toEqual({ eligibility: "exhausted" });
  });

  it("excludes a request created before the NYU campus-day boundary from today's count", async () => {
    const principal = "rollover@nyu.edu";
    // 2026-07-28T03:59:59.999Z is still 2026-07-27 in America/New_York.
    const beforeMidnight = new Date("2026-07-28T03:59:59.999Z");
    await MealRequest.create(
      makeRequest({ email: principal, createdAt: beforeMidnight })
    );
    await MealRequest.create(
      makeRequest({ email: principal, createdAt: beforeMidnight })
    );
    await MealRequest.create(
      makeRequest({ email: principal, createdAt: beforeMidnight })
    );

    // A read at 04:00:00.000Z the same day — the first instant of the new
    // NYU campus day — must not see those three as today's requests.
    const atMidnight = new Date("2026-07-28T04:00:00.000Z");
    await expect(
      readRequestEligibilityState(principal, atMidnight)
    ).resolves.toEqual({ eligibility: "eligible" });
  });

  it("isolates counts strictly to the exact principal", async () => {
    const now = new Date("2026-07-28T10:00:00.000Z");
    await MealRequest.create(
      makeRequest({ email: "other-principal@nyu.edu", createdAt: now })
    );
    await MealRequest.create(
      makeRequest({ email: "other-principal@nyu.edu", createdAt: now })
    );
    await MealRequest.create(
      makeRequest({ email: "other-principal@nyu.edu", createdAt: now })
    );

    await expect(
      readRequestEligibilityState("caller@nyu.edu", now)
    ).resolves.toEqual({ eligibility: "eligible" });
  });

  it("shares the exact same count POST /api/request's own daily-limit read would see", async () => {
    const principal = "shared-authority@nyu.edu";
    const now = new Date("2026-07-28T10:00:00.000Z");
    await MealRequest.create(makeRequest({ email: principal, createdAt: now }));

    const eligibilityRead = await readRequestEligibilityState(principal, now);
    const createTimeCount = await MealRequest.countDocuments({
      email: principal,
      createdAt: { $gte: new Date("2026-07-28T04:00:00.000Z") },
    });

    expect(eligibilityRead).toEqual({ eligibility: "eligible" });
    expect(createTimeCount).toBe(1);
  });

  it("proves the current-as-of-read boundary: an eligible Q1 read followed by racing writes still lets the real POST /api/request handler independently refuse with REQUEST_LIMIT_REACHED", async () => {
    // Review-fix 3 (SHOULD FIX): a second `readRequestEligibilityState` call
    // proves the shared authority's *answer* changes, but not that the real
    // create path actually enforces it. This drives the production
    // `createRequest` handler itself against real Mongo, for the same
    // verified participant Q1 read for, so the refusal is the accepted
    // create-time boundary, not a second read of the same function.
    const now = new Date();
    await MealRequest.create(
      makeRequest({ email: raceParticipant, createdAt: now })
    );
    await MealRequest.create(
      makeRequest({ email: raceParticipant, createdAt: now })
    );

    const earlyRead = await readRequestEligibilityState(raceParticipant, now);
    expect(earlyRead).toEqual({ eligibility: "eligible" });

    // Authoritative state changes after the Q1 read returned "eligible" —
    // modeling another concurrent create committing in the window between an
    // iOS eligibility check and its own later POST.
    await MealRequest.create(
      makeRequest({ email: raceParticipant, createdAt: now })
    );

    const createTimeRead = await readRequestEligibilityState(
      raceParticipant,
      now
    );
    expect(createTimeRead).toEqual({ eligibility: "exhausted" });

    // The actual POST attempt: a real, otherwise-valid create request for
    // the same verified participant, carrying a fresh valid D1 operation
    // identity (review-fix 3 — a POST with no operation header at all could
    // never write a ledger row regardless of the quota outcome, which would
    // make the zero-ledger-rows assertion below vacuous). `reconcileOperation`
    // finds no existing ledger row for this fresh identity ("not-found"), so
    // this attempt falls through past the D1 reconciliation gate into
    // ordinary validation and the quota check exactly as an unrecognized
    // identity should (`createRequestRoute.ts`) — meaning this is a genuine
    // proof that a quota-refused D1-tracked attempt writes no ledger row for
    // the identity it presented, not merely that an operation-less request
    // does.
    const operationId = "eligibility-race-boundary-quota-refused-op";
    const context = routeContext(canonicalAsapPayload(), operationId);
    await createRequest(context.req, context.res);

    expect(context.statusCode).toBe(429);
    expect(context.body).toEqual({
      error: {
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      },
    });

    // No additional Request was created by the refused POST — still exactly
    // the three seeded above.
    expect(
      await MealRequest.countDocuments({ email: raceParticipant })
    ).toBe(3);
    // No D1 operation ledger row exists for the exact operation identity this
    // quota-refused attempt presented: the refusal happens ahead of
    // `createRequestWithOperation`, the sole place that writes one.
    expect(
      await RequestOperation.countDocuments({ operationId })
    ).toBe(0);
    // And, more broadly, no ledger row of any kind was written by this
    // attempt at all.
    expect(await RequestOperation.countDocuments({})).toBe(0);
    // No requester/helper notification side effect began from the refused
    // POST — the refusal happens ahead of the confirmation email and both
    // detached notification dispatches.
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    expect(startHelperNewRequestPush).not.toHaveBeenCalled();
  });

  it("performs no mutation on any Request document", async () => {
    const principal = "readonly@nyu.edu";
    const created = await MealRequest.create(
      makeRequest({ email: principal, createdAt: new Date() })
    );

    await readRequestEligibilityState(principal, new Date());

    const stored = await MealRequest.findById(created._id)
      .lean<Record<string, unknown>>()
      .exec();
    expect(stored?.status).toBe("open");
  });
});
