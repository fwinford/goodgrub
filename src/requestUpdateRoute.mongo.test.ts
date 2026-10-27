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
  RequestUpdateOperation,
} from "../models/db.js";
import { OPERATION_IDENTITY_HEADER } from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  getOwnerRequestDetail,
  getOwnerRequestList,
} from "./requestOwnerReadRoute.js";
import { claimRequest } from "./claimRoute.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";
import { getPublicRequestList } from "./requestListRoute.js";
import { editRequest, withdrawRequest } from "./requestUpdateRoute.js";
import { readCurrentForDispatch } from "./requestDispatchGuard.js";
import { latestEditableScheduledStart } from "./requestTiming.js";
import { endOfCampusDay } from "./utils/date.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

// `createRequestRoute.ts` (whose create-time constants these routes reuse)
// constructs the Resend client at import. Edit and Withdraw send no email.
vi.mock("resend", () => ({
  Resend: class {
    emails = { send: vi.fn() };
  },
}));

// Real-MongoDB proof for W4-R5 owner reads, Withdraw and Edit. The mutation
// semantics are one conditional update inside a transaction plus a recovery
// ledger row, so they are proven against a real replica set through the actual
// handlers rather than a mocked model.
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_request_update`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const secretText = "request-update-mongo-secret-32-bytes!!";
const secret = Buffer.from(secretText);
const aId = new mongoose.Types.ObjectId("64f0000000000000000000a1");
const bId = new mongoose.Types.ObjectId("64f0000000000000000000b2");
const authorityFor = (id: mongoose.Types.ObjectId, version = 1) =>
  signParticipantAuthority(id, version, secret);

function call(
  headers: Record<string, string>,
  params: Record<string, string> = {},
  body: unknown = undefined
) {
  const req = { params, headers, body } as unknown as Request;
  const setHeaders: Record<string, string> = {};
  let statusCode = 200;
  let payload: any;
  const res = {} as Response;
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    payload = value;
    return res;
  }) as any;
  res.setHeader = vi.fn((name: string, value: string) => {
    setHeaders[name] = value;
    return res;
  }) as any;
  return {
    req,
    res,
    setHeaders,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return payload;
    },
  };
}

const credential = (as: mongoose.Types.ObjectId) => ({
  [PARTICIPANT_AUTHORITY_HEADER]: authorityFor(as),
});

async function withdraw(
  requestId: unknown,
  as: mongoose.Types.ObjectId | null,
  operationId: string | null
) {
  const headers: Record<string, string> = as ? credential(as) : {};
  if (operationId !== null) headers[OPERATION_IDENTITY_HEADER] = operationId;
  const context = call(headers, { id: String(requestId) }, {});
  await withdrawRequest(context.req, context.res);
  return context;
}

async function edit(
  requestId: unknown,
  as: mongoose.Types.ObjectId | null,
  operationId: string | null,
  body: unknown
) {
  const headers: Record<string, string> = as ? credential(as) : {};
  if (operationId !== null) headers[OPERATION_IDENTITY_HEADER] = operationId;
  const context = call(headers, { id: String(requestId) }, body);
  await editRequest(context.req, context.res);
  return context;
}

async function claim(requestId: unknown, as: mongoose.Types.ObjectId) {
  const context = call(credential(as), { id: String(requestId) }, {});
  await claimRequest(context.req, context.res);
  return context;
}

async function publicDetail(requestId: unknown, as: mongoose.Types.ObjectId) {
  const context = call(credential(as), { id: String(requestId) });
  await getPublicRequestDetail(context.req, context.res, vi.fn());
  return context;
}

async function publicList(as: mongoose.Types.ObjectId) {
  const context = call(credential(as));
  await getPublicRequestList(context.req, context.res, vi.fn());
  return context;
}

async function ownerList(as: mongoose.Types.ObjectId | null) {
  const context = call(as ? credential(as) : {});
  await getOwnerRequestList(context.req, context.res);
  return context;
}

async function ownerDetail(requestId: unknown, as: mongoose.Types.ObjectId | null) {
  const context = call(as ? credential(as) : {}, { id: String(requestId) });
  await getOwnerRequestDetail(context.req, context.res);
  return context;
}

/** Runs `action` with only `Date` pinned, so the horizon is exercised the
 * same way whatever hour this suite happens to run. */
async function atInstant<T>(instant: Date, action: () => Promise<T>): Promise<T> {
  vi.useFakeTimers({ toFake: ["Date"], now: instant });
  try {
    return await action();
  } finally {
    vi.useRealTimers();
  }
}

// 2026-03-10 11:00 AM EDT: a creation day with a known 11:30 PM horizon.
const creationInstant = new Date("2026-03-10T15:00:00.000Z");
const horizonInstant = new Date("2026-03-11T03:30:00.000Z"); // 11:30 PM EDT

async function requestCreatedAt(instant: Date) {
  const request = await createRequest(aId, {
    createdAt: instant,
    visibleFrom: instant,
    expiresAt: new Date(instant.getTime() + 20 * HOUR),
    deleteAt: new Date(instant.getTime() + 20 * HOUR),
  });
  return request;
}


async function seedParticipants() {
  for (const [id, email] of [
    [aId, "update-a@nyu.edu"],
    [bId, "update-b@nyu.edu"],
  ] as const) {
    // A successful claim sets an active-reservation lock on the helper's
    // Participant document; clear it so one case's claim never constrains the next.
    await Participant.updateOne(
      { _id: id },
      {
        $set: { email, verifiedAt: new Date(), authorityVersion: 1 },
        $unset: {
          activeReservationRequestId: 1,
          activeReservationClaimExpiresAt: 1,
          suspended: 1,
        },
      },
      { upsert: true }
    ).exec();
  }
}

const HOUR = 60 * 60 * 1000;

async function createRequest(
  requester: mongoose.Types.ObjectId,
  overrides: Record<string, unknown> = {}
) {
  const now = Date.now();
  const expiresAt = new Date(now + 3 * HOUR);
  return await MealRequest.create({
    vendor: "Crave NYU",
    food: "Rice bowl",
    pickupWindowText: "ASAP",
    menuPath: "meal-exchange",
    mealSwipes: 1,
    mealItems: [{ name: "Rice bowl" }],
    email: "requester@nyu.edu",
    status: "open",
    requesterParticipantId: requester,
    visibleFrom: new Date(now),
    helperNotification: "initiated",
    contentRevision: 1,
    notificationGeneration: 1,
    expiresAt,
    deleteAt: expiresAt,
    ...overrides,
  });
}

async function stored(id: unknown) {
  return (await MealRequest.findById(id)
    .select(
      "+contentRevision +notificationGeneration +withdrawnAt +requesterParticipantId +moderationUnavailable +reservationLapseHold"
    )
    .lean()
    .exec()) as any;
}

const validEdit = (overrides: Record<string, unknown> = {}) => ({
  vendor: "Crave NYU",
  menuPath: "meal-exchange",
  mealSwipes: 2,
  mealItems: [{ name: "Chicken bowl" }, { name: "Side salad", details: "no dressing" }],
  timing: "unchanged",
  expectedContentRevision: 1,
  ...overrides,
});

describeMongo("real MongoDB W4-R5 owner reads, Withdraw and Edit", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, secretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await RequestUpdateOperation.syncIndexes();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
    await RequestUpdateOperation.deleteMany({});
    await seedParticipants();
  });

  afterAll(async () => {
    await Participant.deleteMany({ _id: { $in: [aId, bId] } });
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  // ------------------------------------------------------------- owner reads

  describe("owner reads", () => {
    it("lists exactly the verified participant's ongoing requests with caller-relative DTOs", async () => {
      await seedParticipants();
      const open = await createRequest(aId);
      const later = await createRequest(aId, {
        windowStart: new Date(Date.now() + 2 * HOUR),
        visibleFrom: new Date(Date.now() + 2 * HOUR),
        expiresAt: new Date(Date.now() + 5 * HOUR),
        deleteAt: new Date(Date.now() + 5 * HOUR),
        pickupWindowText: "Later",
      });
      const reserved = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
      });
      const lapsed = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() - 60 * 1000),
      });
      await createRequest(aId, { status: "placed" });
      await createRequest(aId, { status: "withdrawn" });
      await createRequest(aId, { expiresAt: new Date(Date.now() - HOUR) });
      await createRequest(bId);

      const result = await ownerList(aId);

      expect(result.statusCode).toBe(200);
      expect(result.setHeaders["Cache-Control"]).toBe("private, no-store");
      expect(result.setHeaders["Vary"]).toBe(PARTICIPANT_AUTHORITY_HEADER);
      const byId = Object.fromEntries(result.body.requests.map((r: any) => [r.id, r]));
      expect(Object.keys(byId).sort()).toEqual(
        [open, later, reserved, lapsed].map((r) => String(r._id)).sort()
      );
      expect(byId[String(open._id)].phase).toBe("available");
      expect(byId[String(later._id)].phase).toBe("scheduled");
      expect(byId[String(later._id)].timing).toBe("scheduled");
      expect(byId[String(reserved._id)].phase).toBe("reserved");
      expect(byId[String(lapsed._id)].phase).toBe("available");
      // Edit / Withdraw offered only where no helper holds the request.
      expect(byId[String(open._id)]).toMatchObject({ canEdit: true, canWithdraw: true });
      expect(byId[String(reserved._id)]).toMatchObject({ canEdit: false, canWithdraw: false });
      expect(byId[String(lapsed._id)]).toMatchObject({ canEdit: true, canWithdraw: true });
      expect(byId[String(open._id)].contentRevision).toBe(1);
    });

    it("carries no helper identity, claim material or private marker in any DTO", async () => {
      await seedParticipants();
      await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
        helperParticipantId: bId,
        claimTokenDigest: "digest-secret",
        externalOrderAffirmed: true,
      });

      const result = await ownerList(aId);
      const text = JSON.stringify(result.body);

      for (const forbidden of [
        "helperParticipantId",
        "claimTokenDigest",
        "digest-secret",
        "claimExpiresAt",
        "externalOrderAffirmed",
        "requesterParticipantId",
        "notificationGeneration",
        "installationId",
        "email",
        String(bId),
      ]) {
        expect(text).not.toContain(forbidden);
      }
    });

    it("answers a non-owner, a nonexistent id and a malformed id with the same 404", async () => {
      await seedParticipants();
      const mine = await createRequest(aId);
      const placed = await createRequest(aId, { status: "placed" });

      const stranger = await ownerDetail(mine._id, bId);
      const missing = await ownerDetail(new mongoose.Types.ObjectId(), bId);
      const malformed = await ownerDetail("not-an-id", aId);
      // Someone else's request in a terminal state is still indistinguishable.
      const strangerTerminal = await ownerDetail(placed._id, bId);

      for (const context of [stranger, missing, malformed, strangerTerminal]) {
        expect(context.statusCode).toBe(404);
      }
      expect(stranger.body).toEqual(missing.body);
      expect(malformed.body).toEqual(missing.body);
      expect(strangerTerminal.body).toEqual(missing.body);
      expect((await ownerDetail(mine._id, aId)).statusCode).toBe(200);
    });

    it("tells the owner, and only the owner, which terminal state their own request is in", async () => {
      await seedParticipants();
      const withdrawn = await createRequest(aId, { status: "withdrawn" });
      const placed = await createRequest(aId, { status: "placed" });
      const expired = await createRequest(aId, { expiresAt: new Date(Date.now() - HOUR) });

      const results = await Promise.all([
        ownerDetail(withdrawn._id, aId),
        ownerDetail(placed._id, aId),
        ownerDetail(expired._id, aId),
      ]);

      expect(results.map((r) => [r.statusCode, r.body.error.code])).toEqual([
        [410, "REQUEST_WITHDRAWN"],
        [409, "REQUEST_ALREADY_PLACED"],
        [410, "REQUEST_EXPIRED"],
      ]);
      expect(JSON.stringify(results.map((r) => r.body))).not.toContain("Crave NYU");
    });

    it("refuses an unverified caller before any lookup", async () => {
      await seedParticipants();
      const mine = await createRequest(aId);
      for (const context of [await ownerList(null), await ownerDetail(mine._id, null)]) {
        expect(context.statusCode).toBe(401);
        expect(JSON.stringify(context.body)).not.toContain("Crave NYU");
      }
    });

    it("reports removedNotice false unless a live M request exists for the caller", async () => {
      await seedParticipants();
      await createRequest(aId);
      await createRequest(aId, { status: "withdrawn", moderationUnavailable: true });
      await createRequest(aId, { status: "placed", moderationUnavailable: true });
      await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
        reservationLapseHold: true,
      });
      await createRequest(aId, {
        moderationUnavailable: true,
        expiresAt: new Date(Date.now() - 60 * 1000),
      });
      await createRequest(bId, { moderationUnavailable: true });
      const mine = await ownerList(aId);
      expect(mine.body.removedNotice).toBe(false);
      expect(mine.body.requests).toHaveLength(1);
      expect((await ownerList(bId)).body.removedNotice).toBe(true);
      const unauthenticated = await ownerList(null);
      expect(unauthenticated.statusCode).toBe(401);
      expect(JSON.stringify(unauthenticated.body)).not.toContain("removedNotice");
    });

    it("treats a legacy row with no content revision as visible but not editable", async () => {
      await seedParticipants();
      const legacy = await createRequest(aId);
      await MealRequest.updateOne({ _id: legacy._id }, { $unset: { contentRevision: 1 } }).exec();

      const result = await ownerDetail(legacy._id, aId);

      expect(result.statusCode).toBe(200);
      expect(result.body.request).toMatchObject({
        contentRevision: null,
        canEdit: false,
        canWithdraw: true,
      });
    });

    it("omits M/L-held requests from the list, signals only M removal on the owner's detail, and leaves placed-order reads", async () => {
      await seedParticipants();
      const heldM = await createRequest(aId, { moderationUnavailable: true });
      const heldL = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
        reservationLapseHold: true,
      });
      const placed = await createRequest(aId, {
        status: "placed",
        moderationUnavailable: true,
      });

      const list = await ownerList(aId);
      const mDetail = await ownerDetail(heldM._id, aId);
      const lDetail = await ownerDetail(heldL._id, aId);
      const placedDetail = await ownerDetail(placed._id, aId);

      expect(list.body.requests).toEqual([]);
      // Owner-only boolean for Home discovery: M on a live request only, never
      // L, a withdrawn/expired/placed marked request, or another participant's.
      expect(list.body.removedNotice).toBe(true);
      expect((await ownerList(bId)).body).toEqual({ requests: [], removedNotice: false });
      expect(mDetail.statusCode).toBe(410);
      expect(mDetail.body.error.code).toBe("REQUEST_REMOVED");
      expect(lDetail.statusCode).toBe(404);
      expect(lDetail.body.error.code).toBe("REQUEST_NOT_FOUND");
      const strangerOfM = await ownerDetail(heldM._id, bId);
      expect(strangerOfM.statusCode).toBe(404);
      expect(strangerOfM.body).toEqual(lDetail.body);
      expect(placedDetail.statusCode).toBe(409);
      expect(placedDetail.body.error.code).toBe("REQUEST_ALREADY_PLACED");
      expect(JSON.stringify([list.body, mDetail.body, lDetail.body])).not.toMatch(
        /moderationUnavailable|reservationLapseHold/
      );
    });
  });

  // ---------------------------------------------------------------- Withdraw

  describe("Withdraw", () => {
    it("withdraws an open request atomically and records its identity", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const result = await withdraw(request._id, aId, "wd-1");

      expect(result.statusCode).toBe(200);
      expect(result.body).toEqual({ outcome: "withdrawn", requestId: String(request._id) });
      const after = await stored(request._id);
      expect(after.status).toBe("withdrawn");
      expect(after.withdrawnAt).toBeInstanceOf(Date);
      expect(after.notificationGeneration).toBe(2);
      // Retained through the original-creation-day quota boundary, never shortened.
      expect(after.deleteAt.getTime()).toBeGreaterThanOrEqual(
        endOfCampusDay(after.createdAt).getTime()
      );
      expect(after.deleteAt.getTime()).toBeGreaterThanOrEqual(request.expiresAt!.getTime());
      expect(await RequestUpdateOperation.countDocuments({ operationId: "wd-1" })).toBe(1);
      // Gone from ongoing work, but still counted by the daily quota (the row stays).
      expect((await ownerList(aId)).body.requests).toEqual([]);
      expect(await MealRequest.countDocuments({ email: "requester@nyu.edu" })).toBe(1);
    });

    it("an exact replay has no repeated effect", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await withdraw(request._id, aId, "wd-replay");
      const first = await stored(request._id);

      const replay = await withdraw(request._id, aId, "wd-replay");

      expect(replay.statusCode).toBe(200);
      expect(replay.body.outcome).toBe("withdrawn");
      const second = await stored(request._id);
      expect(second.notificationGeneration).toBe(first.notificationGeneration);
      expect(second.withdrawnAt.getTime()).toBe(first.withdrawnAt.getTime());
      expect(await RequestUpdateOperation.countDocuments({})).toBe(1);
    });

    it("a different identity against an already-withdrawn request is a definitive refusal", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await withdraw(request._id, aId, "wd-first");

      const second = await withdraw(request._id, aId, "wd-second");

      expect(second.statusCode).toBe(410);
      expect(second.body.error.code).toBe("REQUEST_WITHDRAWN");
      expect(await RequestUpdateOperation.countDocuments({ operationId: "wd-second" })).toBe(0);
    });

    it("refuses a live reservation, a placed request and an expired request without writing", async () => {
      await seedParticipants();
      const reserved = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
      });
      const affirmed = await createRequest(aId, {
        status: "claimed",
        externalOrderAffirmed: true,
      });
      const placed = await createRequest(aId, { status: "placed" });
      const expired = await createRequest(aId, { expiresAt: new Date(Date.now() - HOUR) });

      const results = await Promise.all([
        withdraw(reserved._id, aId, "wd-reserved"),
        withdraw(affirmed._id, aId, "wd-affirmed"),
        withdraw(placed._id, aId, "wd-placed"),
        withdraw(expired._id, aId, "wd-expired"),
      ]);

      expect(results.map((r) => [r.statusCode, r.body.error.code])).toEqual([
        [409, "REQUEST_RESERVED"],
        [409, "REQUEST_RESERVED"],
        [409, "REQUEST_ALREADY_PLACED"],
        [410, "REQUEST_EXPIRED"],
      ]);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
      expect((await stored(reserved._id)).status).toBe("claimed");
    });

    it("answers non-placed M/L-held requests as unavailable without writing", async () => {
      await seedParticipants();
      const heldM = await createRequest(aId, { moderationUnavailable: true });
      const heldL = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
        reservationLapseHold: true,
      });

      const results = await Promise.all([
        withdraw(heldM._id, aId, "wd-held-m"),
        withdraw(heldL._id, aId, "wd-held-l"),
      ]);

      expect(results.map((result) => [result.statusCode, result.body.error.code])).toEqual([
        [404, "REQUEST_NOT_FOUND"],
        [404, "REQUEST_NOT_FOUND"],
      ]);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
      expect((await stored(heldM._id)).status).toBe("open");
      expect((await stored(heldL._id)).status).toBe("claimed");
    });

    it("refuses Withdraw while the requester is suspended without recording an operation", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await Participant.updateOne({ _id: aId }, { $set: { suspended: true } }).exec();

      const result = await withdraw(request._id, aId, "wd-suspended");

      expect(result.statusCode).toBe(403);
      expect(result.body.error.code).toBe("PARTICIPANT_SUSPENDED");
      expect((await stored(request._id)).status).toBe("open");
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
    });

    it("allows a request whose earlier reservation lapsed", async () => {
      await seedParticipants();
      const lapsed = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() - 60 * 1000),
      });

      expect((await withdraw(lapsed._id, aId, "wd-lapsed")).statusCode).toBe(200);
      expect((await stored(lapsed._id)).status).toBe("withdrawn");
    });

    it("answers a non-owner exactly like a nonexistent request and writes nothing", async () => {
      await seedParticipants();
      const mine = await createRequest(aId);

      const stranger = await withdraw(mine._id, bId, "wd-stranger");
      const missing = await withdraw(new mongoose.Types.ObjectId(), bId, "wd-missing");

      expect(stranger.statusCode).toBe(404);
      expect(stranger.body).toEqual(missing.body);
      expect((await stored(mine._id)).status).toBe("open");
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
    });

    it("requires a participant and a valid operation identity before any lookup", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      expect((await withdraw(request._id, null, "wd-anon")).statusCode).toBe(401);
      expect((await withdraw(request._id, aId, null)).statusCode).toBe(400);
      expect((await withdraw(request._id, aId, "bad id with spaces")).statusCode).toBe(400);
      expect((await stored(request._id)).status).toBe("open");
    });

    it("refuses an identity that belongs to another participant, or another change", async () => {
      await seedParticipants();
      const mine = await createRequest(aId);
      const theirs = await createRequest(bId);
      await withdraw(mine._id, aId, "wd-owned-by-a");

      const foreign = await withdraw(theirs._id, bId, "wd-owned-by-a");
      const otherRequest = await withdraw(
        (await createRequest(aId))._id,
        aId,
        "wd-owned-by-a"
      );

      expect(foreign.statusCode).toBe(403);
      expect(foreign.body.error.code).toBe("OPERATION_UNAUTHORIZED");
      expect(otherRequest.statusCode).toBe(409);
      expect(otherRequest.body.error.code).toBe("OPERATION_CONFLICT");
      expect((await stored(theirs._id)).status).toBe("open");
    });

    it("exactly one of two concurrent withdrawals wins", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const [one, two] = await Promise.all([
        withdraw(request._id, aId, "wd-race-1"),
        withdraw(request._id, aId, "wd-race-2"),
      ]);

      expect([one.statusCode, two.statusCode].sort()).toEqual([200, 410]);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(1);
      expect((await stored(request._id)).notificationGeneration).toBe(2);
    });

    it("concurrent duplicates of one identity produce one effect", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const results = await Promise.all([
        withdraw(request._id, aId, "wd-dupe"),
        withdraw(request._id, aId, "wd-dupe"),
        withdraw(request._id, aId, "wd-dupe"),
      ]);

      expect(results.every((r) => r.statusCode === 200)).toBe(true);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(1);
      expect((await stored(request._id)).notificationGeneration).toBe(2);
    });
  });

  // -------------------------------------------------------------------- Edit

  describe("Edit", () => {
    it("an ordinary edit changes content, advances only the revision and keeps the window and alerts", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      const before = await stored(request._id);

      const result = await edit(request._id, aId, "ed-1", validEdit());

      expect(result.statusCode).toBe(200);
      expect(result.body.outcome).toBe("edited");
      expect(result.body.resultingRevision).toBe(2);
      expect(result.body.request.contentRevision).toBe(2);
      const after = await stored(request._id);
      expect(after.mealSwipes).toBe(2);
      expect(after.mealItems).toEqual([
        { name: "Chicken bowl" },
        { name: "Side salad", details: "no dressing" },
      ]);
      expect(after.food).toBe("Chicken bowl; Side salad (no dressing)");
      expect(after.contentRevision).toBe(2);
      // Not a reschedule: the window, the alert state and the generation are untouched.
      expect(after.notificationGeneration).toBe(1);
      expect(after.helperNotification).toBe("initiated");
      expect(after.visibleFrom.getTime()).toBe(before.visibleFrom.getTime());
      expect(after.expiresAt.getTime()).toBe(before.expiresAt.getTime());
      expect(after.deleteAt.getTime()).toBe(before.deleteAt.getTime());
      expect(after.pickupWindowText).toBe("ASAP");
      // Same identity, never a create: no new row, no new slot.
      expect(await MealRequest.countDocuments({})).toBe(1);
      expect(String(after._id)).toBe(String(request._id));
      expect(String(after.requesterParticipantId)).toBe(String(aId));
    });

    it("stores text beginning with $ literally and can switch to Dining Dollars", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const result = await edit(
        request._id,
        aId,
        "ed-dollar",
        validEdit({
          menuPath: "dining-dollars",
          mealSwipes: 0,
          mealItems: [],
          orderDetails: "$vendor exactly",
          estimatedDiningDollarsCents: 1234,
        })
      );

      expect(result.statusCode).toBe(200);
      const after = await stored(request._id);
      expect(after.orderDetails).toBe("$vendor exactly");
      expect(after.estimatedDiningDollarsCents).toBe(1234);
      expect(after.food).toBe("$vendor exactly ($12.34 Dining Dollars)");
      expect(after.mealItems).toEqual([]);
    });

    it("removes an optional field the edit no longer carries", async () => {
      await seedParticipants();
      const request = await createRequest(aId, { estimatedDiningDollarsCents: 500 });

      await edit(request._id, aId, "ed-unset", validEdit());

      expect((await stored(request._id)).estimatedDiningDollarsCents).toBeUndefined();
    });

    it("an explicit rescheduling recalculates the window and re-arms initiation for a new generation", async () => {
      await seedParticipants();
      const request = await requestCreatedAt(creationInstant);
      const start = new Date(creationInstant.getTime() + 2 * HOUR);

      const result = await atInstant(creationInstant, () =>
        edit(
          request._id,
          aId,
          "ed-later",
          validEdit({ timing: "scheduled", windowStart: start.toISOString() })
        )
      );

      expect(result.statusCode).toBe(200);
      const after = await stored(request._id);
      expect(after.windowStart.getTime()).toBe(start.getTime());
      expect(after.visibleFrom.getTime()).toBe(start.getTime());
      expect(after.expiresAt.getTime()).toBe(start.getTime() + 3 * HOUR);
      expect(after.windowEnd.getTime()).toBe(start.getTime() + 3 * HOUR);
      expect(after.deleteAt.getTime()).toBe(after.expiresAt.getTime());
      expect(after.pickupWindowText).not.toBe("ASAP");
      expect(after.notificationGeneration).toBe(2);
      expect(after.helperNotification).toBe("awaiting-eligibility");
      expect(after.contentRevision).toBe(2);
      const detail = await atInstant(creationInstant, () => ownerDetail(request._id, aId));
      expect(detail.body.request.phase).toBe("scheduled");
    });

    it("Later to ASAP clears the schedule and recalculates a three-hour window from now", async () => {
      await seedParticipants();
      const start = new Date(creationInstant.getTime() + 2 * HOUR);
      const request = await createRequest(aId, {
        createdAt: creationInstant,
        windowStart: start,
        windowEnd: new Date(start.getTime() + 3 * HOUR),
        visibleFrom: start,
        expiresAt: new Date(start.getTime() + 3 * HOUR),
        deleteAt: new Date(start.getTime() + 3 * HOUR),
        helperNotification: "awaiting-eligibility",
      });
      const before = creationInstant.getTime();

      const result = await atInstant(creationInstant, () =>
        edit(request._id, aId, "ed-asap", validEdit({ timing: "asap" }))
      );

      expect(result.statusCode).toBe(200);
      const after = await stored(request._id);
      expect(after.windowStart).toBeUndefined();
      expect(after.windowEnd).toBeUndefined();
      expect(after.pickupWindowText).toBe("ASAP");
      expect(after.visibleFrom.getTime()).toBeGreaterThanOrEqual(before);
      expect(after.expiresAt.getTime() - after.visibleFrom.getTime()).toBe(3 * HOUR);
      expect(after.notificationGeneration).toBe(2);
    });

    it("refuses a start after 11:30 PM on the original creation day, and accepts that exact instant", async () => {
      await seedParticipants();
      const request = await requestCreatedAt(creationInstant);
      expect(latestEditableScheduledStart(creationInstant).toISOString()).toBe(
        horizonInstant.toISOString()
      );

      const tooLate = await atInstant(creationInstant, () =>
        edit(
          request._id,
          aId,
          "ed-late",
          validEdit({
            timing: "scheduled",
            windowStart: new Date(horizonInstant.getTime() + 60_000).toISOString(),
          })
        )
      );
      expect(tooLate.statusCode).toBe(422);
      expect(tooLate.body.error.code).toBe("REQUEST_HORIZON_EXCEEDED");
      expect((await stored(request._id)).contentRevision).toBe(1);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);

      const exact = await atInstant(creationInstant, () =>
        edit(
          request._id,
          aId,
          "ed-exact",
          validEdit({ timing: "scheduled", windowStart: horizonInstant.toISOString() })
        )
      );
      expect(exact.statusCode).toBe(200);
    });

    it("applies the same horizon to an explicit ASAP change, and still accepts ASAP on the creation day", async () => {
      await seedParticipants();
      const request = await requestCreatedAt(creationInstant);

      const nextMorning = new Date("2026-03-11T09:00:00.000Z");
      const late = await atInstant(nextMorning, () =>
        edit(request._id, aId, "ed-asap-late", validEdit({ timing: "asap" }))
      );
      expect(late.statusCode).toBe(422);
      expect(late.body.error.code).toBe("REQUEST_HORIZON_EXCEEDED");
      const untouched = await stored(request._id);
      expect(untouched.contentRevision).toBe(1);
      expect(untouched.pickupWindowText).toBe("ASAP");
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);

      const sameDay = await atInstant(new Date("2026-03-10T20:00:00.000Z"), () =>
        edit(request._id, aId, "ed-asap-ok", validEdit({ timing: "asap" }))
      );
      expect(sameDay.statusCode).toBe(200);
    });

    it("never holds an unchanged-timing edit to the horizon, even after the creation day", async () => {
      await seedParticipants();
      const request = await requestCreatedAt(creationInstant);

      const nextMorning = new Date("2026-03-11T09:00:00.000Z");
      const result = await atInstant(nextMorning, () =>
        edit(request._id, aId, "ed-unchanged-late", validEdit())
      );
      expect(result.statusCode).toBe(200);
    });

    it("uses 11:30 PM local time across the spring-forward and fall-back days", async () => {
      // Spring forward 2026-03-08 (EST->EDT) and fall back 2026-11-01 (EDT->EST).
      expect(
        latestEditableScheduledStart(new Date("2026-03-08T15:00:00.000Z")).toISOString()
      ).toBe("2026-03-09T03:30:00.000Z");
      expect(
        latestEditableScheduledStart(new Date("2026-11-01T14:00:00.000Z")).toISOString()
      ).toBe("2026-11-02T04:30:00.000Z");
      expect(
        latestEditableScheduledStart(new Date("2026-01-15T15:00:00.000Z")).toISOString()
      ).toBe("2026-01-16T04:30:00.000Z");
    });

    it("refuses a start that has already passed", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const result = await edit(
        request._id,
        aId,
        "ed-past",
        validEdit({
          timing: "scheduled",
          windowStart: new Date(Date.now() - 60_000).toISOString(),
        })
      );

      expect(result.statusCode).toBe(400);
      expect(result.body.error.code).toBe("INVALID_REQUEST");
    });

    it("a stale expected revision fails safely and writes nothing", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await edit(request._id, aId, "ed-first", validEdit());

      const stale = await edit(
        request._id,
        aId,
        "ed-stale",
        validEdit({ mealSwipes: 1, mealItems: [{ name: "Other" }], expectedContentRevision: 1 })
      );

      expect(stale.statusCode).toBe(409);
      expect(stale.body.error.code).toBe("REQUEST_REVISION_CONFLICT");
      expect((await stored(request._id)).mealSwipes).toBe(2);
      expect(await RequestUpdateOperation.countDocuments({ operationId: "ed-stale" })).toBe(0);
    });

    it("an exact replay answers the decided revision with no second effect", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await edit(request._id, aId, "ed-replay", validEdit());

      const replay = await edit(request._id, aId, "ed-replay", validEdit());

      expect(replay.statusCode).toBe(200);
      expect(replay.body.resultingRevision).toBe(2);
      expect((await stored(request._id)).contentRevision).toBe(2);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(1);
    });

    it("an identity reused for different content is a conflict, never the old result", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await edit(request._id, aId, "ed-reuse", validEdit());

      const different = await edit(
        request._id,
        aId,
        "ed-reuse",
        validEdit({ mealItems: [{ name: "Something else" }, { name: "Side salad" }] })
      );

      expect(different.statusCode).toBe(409);
      expect(different.body.error.code).toBe("OPERATION_CONFLICT");
      expect((await stored(request._id)).contentRevision).toBe(2);
    });

    it("a replay still answers after the request has since been withdrawn, without reviving it", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await edit(request._id, aId, "ed-then-withdraw", validEdit());
      await withdraw(request._id, aId, "wd-after-edit");

      const replay = await edit(request._id, aId, "ed-then-withdraw", validEdit());

      expect(replay.statusCode).toBe(200);
      expect(replay.body.resultingRevision).toBe(2);
      expect(replay.body.request).toBeNull();
      expect((await stored(request._id)).status).toBe("withdrawn");
    });

    it("refuses a reserved, placed, withdrawn or expired request", async () => {
      await seedParticipants();
      const reserved = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
      });
      const placed = await createRequest(aId, { status: "placed" });
      const withdrawn = await createRequest(aId, { status: "withdrawn" });
      const expired = await createRequest(aId, { expiresAt: new Date(Date.now() - HOUR) });

      const results = await Promise.all([
        edit(reserved._id, aId, "ed-r", validEdit()),
        edit(placed._id, aId, "ed-p", validEdit()),
        edit(withdrawn._id, aId, "ed-w", validEdit()),
        edit(expired._id, aId, "ed-e", validEdit()),
      ]);

      expect(results.map((r) => [r.statusCode, r.body.error.code])).toEqual([
        [409, "REQUEST_RESERVED"],
        [409, "REQUEST_ALREADY_PLACED"],
        [410, "REQUEST_WITHDRAWN"],
        [410, "REQUEST_EXPIRED"],
      ]);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
    });

    it("answers non-placed M/L-held requests as unavailable without writing", async () => {
      await seedParticipants();
      const heldM = await createRequest(aId, { moderationUnavailable: true });
      const heldL = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
        reservationLapseHold: true,
      });

      const results = await Promise.all([
        edit(heldM._id, aId, "ed-held-m", validEdit()),
        edit(heldL._id, aId, "ed-held-l", validEdit()),
      ]);

      expect(results.map((result) => [result.statusCode, result.body.error.code])).toEqual([
        [404, "REQUEST_NOT_FOUND"],
        [404, "REQUEST_NOT_FOUND"],
      ]);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
      expect((await stored(heldM._id)).contentRevision).toBe(1);
      expect((await stored(heldL._id)).contentRevision).toBe(1);
    });

    it("refuses Edit while the requester is suspended without recording an operation", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await Participant.updateOne({ _id: aId }, { $set: { suspended: true } }).exec();

      const result = await edit(request._id, aId, "ed-suspended", validEdit());

      expect(result.statusCode).toBe(403);
      expect(result.body.error.code).toBe("PARTICIPANT_SUSPENDED");
      expect((await stored(request._id)).contentRevision).toBe(1);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
    });

    it("refuses a legacy row that was never given a revision", async () => {
      await seedParticipants();
      const legacy = await createRequest(aId);
      await MealRequest.updateOne({ _id: legacy._id }, { $unset: { contentRevision: 1 } }).exec();

      const result = await edit(legacy._id, aId, "ed-legacy", validEdit());

      expect(result.statusCode).toBe(409);
      expect(result.body.error.code).toBe("REQUEST_NOT_EDITABLE");
    });

    it("applies the participant-text filter and the vendor catalog before writing", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const filtered = await edit(
        request._id,
        aId,
        "ed-filter",
        validEdit({ mealItems: [{ name: "you stupid bitch" }, { name: "Side salad" }] })
      );
      const vendor = await edit(
        request._id,
        aId,
        "ed-vendor",
        validEdit({ vendor: "Not A Real Cafe" })
      );

      expect(filtered.statusCode).toBe(422);
      expect(filtered.body.error.code).toBe("REQUEST_TEXT_NOT_ALLOWED");
      expect(JSON.stringify(filtered.body)).not.toContain("stupid");
      expect(vendor.statusCode).toBe(400);
      expect(vendor.body.error.code).toBe("INVALID_VENDOR");
      expect((await stored(request._id)).contentRevision).toBe(1);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
    });

    it("preserves an unchanged vendor even if it is no longer in the catalog", async () => {
      await seedParticipants();
      const request = await createRequest(aId, { vendor: "Retired Cafe" });

      const result = await edit(
        request._id,
        aId,
        "ed-retired",
        validEdit({ vendor: "Retired Cafe" })
      );

      expect(result.statusCode).toBe(200);
      expect((await stored(request._id)).vendor).toBe("Retired Cafe");
    });

    it("refuses a payload that names the requester, a window end or a flat food", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      for (const extra of [
        { email: "someone@nyu.edu" },
        { windowEnd: new Date(Date.now() + HOUR).toISOString() },
        { food: "Rice" },
        { installationCredential: "x".repeat(40) },
      ]) {
        const result = await edit(
          request._id,
          aId,
          `ed-extra-${Object.keys(extra)[0]}`,
          validEdit(extra)
        );
        expect(result.statusCode).toBe(400);
      }
      expect((await stored(request._id)).contentRevision).toBe(1);
    });

    it("answers a non-owner exactly like a nonexistent request", async () => {
      await seedParticipants();
      const mine = await createRequest(aId);

      const stranger = await edit(mine._id, bId, "ed-stranger", validEdit());
      const missing = await edit(new mongoose.Types.ObjectId(), bId, "ed-missing", validEdit());
      const invalidBodyStranger = await edit(mine._id, bId, "ed-stranger-2", { nonsense: true });

      expect(stranger.statusCode).toBe(404);
      expect(stranger.body).toEqual(missing.body);
      // Payload validity cannot be used to probe ownership.
      expect(invalidBodyStranger.statusCode).toBe(404);
      expect((await stored(mine._id)).contentRevision).toBe(1);
    });

    it("exactly one of two simultaneous edits at the same revision wins", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const [one, two] = await Promise.all([
        edit(request._id, aId, "ed-race-1", validEdit({ mealItems: [{ name: "One" }, { name: "Side" }] })),
        edit(request._id, aId, "ed-race-2", validEdit({ mealItems: [{ name: "Two" }, { name: "Side" }] })),
      ]);

      expect([one.statusCode, two.statusCode].sort()).toEqual([200, 409]);
      expect((await stored(request._id)).contentRevision).toBe(2);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(1);
    });

    it("concurrent duplicates of one edit identity produce one effect", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const results = await Promise.all([
        edit(request._id, aId, "ed-dupe", validEdit()),
        edit(request._id, aId, "ed-dupe", validEdit()),
        edit(request._id, aId, "ed-dupe", validEdit()),
      ]);

      expect(results.every((r) => r.statusCode === 200)).toBe(true);
      expect(results.every((r) => r.body.resultingRevision === 2)).toBe(true);
      expect((await stored(request._id)).contentRevision).toBe(2);
      expect(await RequestUpdateOperation.countDocuments({})).toBe(1);
    });

    it("an edit and a withdrawal racing have one winner", async () => {
      await seedParticipants();
      const request = await createRequest(aId);

      const [edited, withdrawn] = await Promise.all([
        edit(request._id, aId, "ed-vs-wd", validEdit()),
        withdraw(request._id, aId, "wd-vs-ed"),
      ]);

      const final = await stored(request._id);
      if (withdrawn.statusCode === 200) {
        expect(final.status).toBe("withdrawn");
        expect([409, 410, 200]).toContain(edited.statusCode);
      } else {
        expect(edited.statusCode).toBe(200);
        expect(final.status).toBe("open");
      }
      // Never both a committed edit result and a committed withdrawal
      // contradicting each other: an edit that committed before the
      // withdrawal leaves a withdrawn request at revision 2.
      expect(await RequestUpdateOperation.countDocuments({})).toBeGreaterThanOrEqual(1);
    });

    it("does not touch the daily quota or create-operation ledger", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      const before = await MealRequest.countDocuments({ email: "requester@nyu.edu" });

      await edit(request._id, aId, "ed-quota", validEdit());
      await withdraw(request._id, aId, "wd-quota");

      expect(await MealRequest.countDocuments({ email: "requester@nyu.edu" })).toBe(before);
      expect(await mongoose.connection.db!.collection("requestoperations").countDocuments({})).toBe(0);
    });
  });

  // ----------------------------------------- races and helper-facing truth

  describe("claim, public reads and the new lifecycle state", () => {
    it("a withdrawn request is gone from the public list and refuses a claim with its own code", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      expect(
        (await publicList(bId)).body.requests.map((r: any) => r.id)
      ).toContain(String(request._id));
      await withdraw(request._id, aId, "wd-public");

      expect(
        (await publicList(bId)).body.requests.map((r: any) => r.id)
      ).not.toContain(String(request._id));
      const refused = await claim(request._id, bId);
      expect(refused.statusCode).toBe(410);
      expect(refused.body.error.code).toBe("REQUEST_WITHDRAWN");
      expect((await stored(request._id)).status).toBe("withdrawn");
    });

    it("the detail read answers a withdrawn request contentlessly and states the current revision", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await edit(request._id, aId, "ed-public", validEdit());

      const edited = await publicDetail(request._id, bId);
      expect(edited.body.request.contentRevision).toBe(2);
      expect(edited.body.request.status).toBe("open");

      await withdraw(request._id, aId, "wd-public-2");
      const withdrawn = await publicDetail(request._id, bId);
      expect(withdrawn.statusCode).toBe(410);
      expect(withdrawn.body.error.code).toBe("REQUEST_WITHDRAWN");
      // Contentless: nothing of the withdrawn request is in the answer.
      expect(JSON.stringify(withdrawn.body)).not.toContain("Crave NYU");
      expect(withdrawn.body.request).toBeUndefined();
    });

    it("the detail read answers a withdrawn request as withdrawn even when it was rescheduled first", async () => {
      await seedParticipants();
      const request = await requestCreatedAt(creationInstant);
      const start = new Date(creationInstant.getTime() + 2 * HOUR);
      await atInstant(creationInstant, () =>
        edit(
          request._id,
          aId,
          "ed-resched-then-withdraw",
          validEdit({ timing: "scheduled", windowStart: start.toISOString() })
        )
      );
      await atInstant(creationInstant, () => withdraw(request._id, aId, "wd-after-resched"));

      const read = await atInstant(creationInstant, () => publicDetail(request._id, bId));

      expect(read.statusCode).toBe(410);
      expect(read.body.error.code).toBe("REQUEST_WITHDRAWN");
    });

    it("the detail read answers an expired request as expired and a live reservation as itself", async () => {
      await seedParticipants();
      const expired = await createRequest(aId, { expiresAt: new Date(Date.now() - HOUR) });
      const held = await createRequest(aId, {
        status: "claimed",
        claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000),
      });

      const expiredRead = await publicDetail(expired._id, bId);
      const heldRead = await publicDetail(held._id, bId);

      expect(expiredRead.statusCode).toBe(410);
      expect(expiredRead.body.error.code).toBe("REQUEST_EXPIRED");
      expect(heldRead.statusCode).toBe(200);
      expect(heldRead.body.request.status).toBe("claimed");
    });

    it("the public list never carries a revision or generation", async () => {
      await seedParticipants();
      await createRequest(aId);

      const text = JSON.stringify((await publicList(bId)).body);

      expect(text).not.toContain("contentRevision");
      expect(text).not.toContain("notificationGeneration");
    });

    it("a claim and a withdrawal racing have exactly one winner", async () => {
      for (let attempt = 0; attempt < 5; attempt += 1) {
        await seedParticipants();
        const request = await createRequest(aId);

        const [claimed, withdrawn] = await Promise.all([
          claim(request._id, bId),
          withdraw(request._id, aId, `wd-claim-race-${attempt}`),
        ]);

        const final = await stored(request._id);
        if (claimed.statusCode === 200) {
          expect(withdrawn.statusCode).toBe(409);
          expect(withdrawn.body.error.code).toBe("REQUEST_RESERVED");
          expect(final.status).toBe("claimed");
        } else {
          expect(withdrawn.statusCode).toBe(200);
          expect(claimed.statusCode).toBe(410);
          expect(claimed.body.error.code).toBe("REQUEST_WITHDRAWN");
          expect(final.status).toBe("withdrawn");
        }
        await MealRequest.deleteMany({});
        await RequestUpdateOperation.deleteMany({});
      }
    });

    it("a claim and an edit racing have exactly one winner", async () => {
      for (let attempt = 0; attempt < 5; attempt += 1) {
        await seedParticipants();
        const request = await createRequest(aId);

        const [claimed, edited] = await Promise.all([
          claim(request._id, bId),
          edit(request._id, aId, `ed-claim-race-${attempt}`, validEdit()),
        ]);

        // Two legitimate serializations. Edit first: the edit commits and the
        // claim then reserves the edited request (both succeed). Claim first:
        // the reservation makes the edit fail and nothing was written. What
        // can never happen is an edit committing *after* a reservation took
        // the request, which is exactly what the 409 branch proves.
        const final = await stored(request._id);
        expect(claimed.statusCode).toBe(200);
        expect(final.status).toBe("claimed");
        if (edited.statusCode === 200) {
          expect(final.contentRevision).toBe(2);
        } else {
          expect(edited.statusCode).toBe(409);
          expect(edited.body.error.code).toBe("REQUEST_RESERVED");
          expect(final.contentRevision).toBe(1);
          expect(await RequestUpdateOperation.countDocuments({})).toBe(0);
        }
        await MealRequest.deleteMany({});
        await RequestUpdateOperation.deleteMany({});
      }
    });
  });


  describe("dispatcher notification-generation fence (real Mongo)", () => {
    it("serves current content to the dispatch it was started for, and stops it after a withdrawal", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      const startedAt = new Date();

      expect(await readCurrentForDispatch(request._id, 1, startedAt)).not.toBeNull();

      const edited = await edit(
        request._id,
        aId,
        "ed-fence-content",
        validEdit({ mealSwipes: 1, mealItems: [{ name: "Edited" }] })
      );
      expect(edited.statusCode).toBe(200);
      const afterEdit = await readCurrentForDispatch(request._id, 1, new Date());
      expect(afterEdit).not.toBeNull();
      expect((afterEdit as { contentRevision?: number }).contentRevision).toBe(2);
      expect(afterEdit?.mealItems?.[0]?.name).toBe("Edited");

      await withdraw(request._id, aId, "wd-fence");
      expect(await readCurrentForDispatch(request._id, 1, new Date())).toBeNull();
    });

    it("stops a dispatch started for an earlier generation once the time is explicitly changed", async () => {
      await seedParticipants();
      const request = await requestCreatedAt(creationInstant);
      const start = new Date(creationInstant.getTime() + 2 * HOUR);

      const result = await atInstant(creationInstant, () =>
        edit(
          request._id,
          aId,
          "ed-fence-time",
          validEdit({ timing: "scheduled", windowStart: start.toISOString() })
        )
      );
      expect(result.statusCode).toBe(200);

      const later = new Date(start.getTime() + 60_000);
      expect(await readCurrentForDispatch(request._id, 1, later)).toBeNull();
      expect(await readCurrentForDispatch(request._id, 2, later)).not.toBeNull();
    });

    it("reads an absent generation as the first one", async () => {
      await seedParticipants();
      const request = await createRequest(aId);
      await MealRequest.collection.updateOne(
        { _id: request._id as mongoose.Types.ObjectId },
        { $unset: { notificationGeneration: "" } }
      );

      expect(await readCurrentForDispatch(request._id, 1, new Date())).not.toBeNull();
      expect(await readCurrentForDispatch(request._id, 2, new Date())).toBeNull();
    });
  });

});
