import type { NextFunction, Request, Response } from "express";
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
vi.mock("./notifySubscribers.js", () => ({ notifySubscribersForRequest }));
vi.mock("./helperNewRequestPush.js", () => ({ startHelperNewRequestPush }));

import {
  Participant,
  Request as MealRequest,
  RequestOperation,
} from "../models/db.js";
import { createRequest, OPERATION_IDENTITY_HEADER, terminalizeOperation } from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

/**
 * W4-U1.2 CP2 (boundary contract EO): a request carrying M or L is answered
 * by the direct detail read as the generic not-found, and an operation
 * replay resolves it as the existing terminal expired outcome. It is never
 * projected as open or claimed, and no private marker reaches a response.
 */
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_moderation_projection`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const secretText = "moderation-projection-mongo-participant-secret-32";
const secret = Buffer.from(secretText);
const requesterId = new mongoose.Types.ObjectId("64e0000000000000000000d1");
const helperId = new mongoose.Types.ObjectId("64e0000000000000000000d2");
const requesterAuthority = signParticipantAuthority(requesterId, 1, secret);

function context(
  options: { params?: Record<string, string>; body?: unknown; headers?: Record<string, string> }
) {
  const req = {
    params: options.params ?? {},
    body: options.body,
    headers: options.headers ?? {},
  } as unknown as Request;
  const res = {} as Response;
  const call = { statusCode: 200, body: undefined as any };
  res.status = vi.fn((code: number) => {
    call.statusCode = code;
    return res;
  }) as never;
  res.json = vi.fn((value: unknown) => {
    call.body = value;
    return res;
  }) as never;
  res.setHeader = vi.fn(() => res) as never;
  return { req, res, call };
}

async function detail(id: unknown) {
  const { req, res, call } = context({
    params: { id: String(id) },
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: requesterAuthority },
  });
  await getPublicRequestDetail(req, res, vi.fn() as unknown as NextFunction);
  return call;
}

async function create(operationId: string) {
  const { req, res, call } = context({
    body: {
      vendor: "Jasper Kane Cafe",
      timing: "asap",
      menuPath: "meal-exchange",
      mealSwipes: 2,
      mealItems: [{ name: "Vegetable rice bowl" }, { name: "Side salad" }],
    },
    headers: {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    },
  });
  await createRequest(req, res);
  return call;
}

const PRIVATE_MARKER = /moderationUnavailable|reservationLapseHold|externalOrderAffirmed/;

describeMongo("real MongoDB M/L projection (W4-U1.2 EO)", { timeout: 30_000 }, () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, secretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await RequestOperation.syncIndexes();
    for (const [id, email] of [
      [requesterId, "projection-requester@nyu.edu"],
      [helperId, "projection-helper@nyu.edu"],
    ] as const) {
      await Participant.updateOne(
        { _id: id },
        {
          $set: { email, verifiedAt: new Date() },
          $setOnInsert: { authorityVersion: 1 },
        },
        { upsert: true }
      ).exec();
    }
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
    await RequestOperation.deleteMany({});
    resendSend.mockReset().mockResolvedValue({ data: { id: "x" }, error: null });
    notifySubscribersForRequest.mockReset().mockResolvedValue(undefined);
    startHelperNewRequestPush.mockReset();
  });

  afterAll(async () => {
    await Participant.deleteMany({ _id: { $in: [requesterId, helperId] } });
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  async function seed(overrides: Record<string, unknown> = {}) {
    const deadline = new Date(Date.now() + 60 * 60 * 1000);
    return await MealRequest.create({
      vendor: "Jasper Kane Cafe",
      food: "Rice bowl",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
      requesterParticipantId: requesterId,
      ...overrides,
    });
  }

  describe("direct detail", () => {
    const NOT_FOUND = { error: "Request not found" };

    it("projects an unrestricted open request as open", async () => {
      const request = await seed();
      const call = await detail(request._id);
      expect(call.statusCode).toBe(200);
      expect(call.body.request.status).toBe("open");
    });

    it("answers M on a persistently open request as the generic not-found, never open or claimed", async () => {
      const request = await seed({ moderationUnavailable: true });
      expect((await MealRequest.findById(request._id).lean())!.status).toBe("open");

      const call = await detail(request._id);
      expect(call.statusCode).toBe(404);
      expect(call.body).toEqual(NOT_FOUND);
    });

    it("answers L after the reservation lapsed as the generic not-found", async () => {
      const request = await seed({
        status: "claimed",
        helperParticipantId: helperId,
        claimExpiresAt: new Date(Date.now() - 60_000),
        reservationLapseHold: true,
      });
      const call = await detail(request._id);
      expect(call.statusCode).toBe(404);
      expect(call.body).toEqual(NOT_FOUND);
    });

    it("gives the owner a generic not-found for held requests and refuses anonymous detail reads", async () => {
      const held = await seed({ moderationUnavailable: true });
      const missing = await detail(new mongoose.Types.ObjectId());
      const asRequester = await detail(held._id);
      expect(asRequester.statusCode).toBe(missing.statusCode);
      expect(asRequester.body).toEqual(missing.body);

      const { req, res, call } = context({ params: { id: String(held._id) } });
      await getPublicRequestDetail(req, res, vi.fn() as unknown as NextFunction);
      expect(call.statusCode).toBe(401);
      expect(call.body).not.toHaveProperty("request");
    });

    it("still projects a lapsed unmarked claim as open and a placed M request as placed", async () => {
      const lapsed = await seed({
        status: "claimed",
        helperParticipantId: helperId,
        claimExpiresAt: new Date(Date.now() - 60_000),
      });
      expect((await detail(lapsed._id)).body.request.status).toBe("open");

      const placed = await seed({
        status: "placed",
        placedAt: new Date(),
        moderationUnavailable: true,
      });
      const call = await detail(placed._id);
      expect(call.statusCode).toBe(200);
      expect(call.body.request.status).toBe("placed");
      expect(JSON.stringify(call.body)).not.toMatch(PRIVATE_MARKER);
    });
  });

  describe("operation replay", () => {
    async function heldReplay(operationId: string, set: Record<string, unknown>) {
      const first = await create(operationId);
      expect(first.statusCode).toBe(201);
      await MealRequest.updateOne({ _id: first.body.request.id }, { $set: set }).exec();
      return first;
    }

    it("replays an unrestricted created request as open", async () => {
      const first = await create("projection-op-plain");
      expect(first.statusCode).toBe(201);
      const replay = await create("projection-op-plain");
      expect(replay.statusCode).toBe(200);
      expect(replay.body.request.status).toBe("open");
    });

    const CREATED_UNAVAILABLE = {
      error: {
        code: "REQUEST_CREATED_UNAVAILABLE",
        message: "Your request was posted, but it's no longer available.",
      },
    };

    it("resolves an M-held operation as created-then-unavailable, without a second request, an open projection or a leak", async () => {
      const first = await heldReplay("projection-op-m", { moderationUnavailable: true });
      expect(await MealRequest.countDocuments({})).toBe(1);

      const replay = await create("projection-op-m");
      expect(replay.statusCode).toBe(410);
      expect(replay.body).toEqual(CREATED_UNAVAILABLE);
      expect(JSON.stringify(replay.body)).not.toMatch(PRIVATE_MARKER);
      expect(JSON.stringify(replay.body)).not.toContain(first.body.request.id);
      // Idempotent: the same answer again, still exactly one Request and row.
      const again = await create("projection-op-m");
      expect(again.statusCode).toBe(410);
      expect(again.body).toEqual(CREATED_UNAVAILABLE);
      expect((await MealRequest.findById(first.body.request.id).lean())!.status).toBe("open");
      expect(await MealRequest.countDocuments({})).toBe(1);
      expect(await RequestOperation.countDocuments({ operationId: "projection-op-m" })).toBe(1);
    });

    it("resolves an L-held operation as created-then-unavailable", async () => {
      await heldReplay("projection-op-l", {
        status: "claimed",
        helperParticipantId: helperId,
        claimExpiresAt: new Date(Date.now() - 60_000),
        reservationLapseHold: true,
      });
      const replay = await create("projection-op-l");
      expect(replay.statusCode).toBe(410);
      expect(replay.body).toEqual(CREATED_UNAVAILABLE);
      expect(await MealRequest.countDocuments({})).toBe(1);
    });

    it("resolves exact-operation terminal reconciliation of a held request as created-unavailable, never created, expired or not-created", async () => {
      await heldReplay("projection-op-term", { moderationUnavailable: true });
      const outcome = await terminalizeOperation("projection-op-term", String(requesterId));
      expect(outcome.outcome).toBe("created-unavailable");
      expect(await MealRequest.countDocuments({})).toBe(1);
    });

    it("keeps authorization: another participant still gets unauthorized for a held operation", async () => {
      await heldReplay("projection-op-auth", { moderationUnavailable: true });
      const outcome = await terminalizeOperation("projection-op-auth", String(helperId));
      expect(outcome.outcome).toBe("unauthorized");
    });

    it("keeps genuine expiry distinct: a missing request behind a ledger row is still 410 OPERATION_EXPIRED", async () => {
      const first = await create("projection-op-gone");
      await MealRequest.deleteOne({ _id: first.body.request.id }).exec();
      const replay = await create("projection-op-gone");
      expect(replay.statusCode).toBe(410);
      expect(replay.body.error.code).toBe("OPERATION_EXPIRED");
    });

    it("still reconciles a placed request carrying M as created", async () => {
      await heldReplay("projection-op-placed", {
        status: "placed",
        placedAt: new Date(),
        moderationUnavailable: true,
      });
      const replay = await create("projection-op-placed");
      expect(replay.statusCode).toBe(200);
      expect(replay.body.request.status).toBe("placed");
      expect(JSON.stringify(replay.body)).not.toMatch(PRIVATE_MARKER);
    });
  });
});
