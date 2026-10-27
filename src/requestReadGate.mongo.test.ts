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
import {
  Participant,
  ParticipantBlock,
  Request as MealRequest,
} from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";
import { getPublicRequestList } from "./requestListRoute.js";
import {
  blockSafetyIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";

// Real-MongoDB proof for the W4-R5 verified-only gate: authority is persisted
// (`Participant.authorityVersion`, the stored principal), so independent
// revocation and an ineligible stored principal are proven against real rows through the actual handlers rather
// than a mocked lookup. The cross-participant and pair-fence legs prove that
// A's authority never yields B's ownership or a fenced counterpart's request.
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_request_read_gate`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const secretText = "request-read-gate-mongo-secret-32-bytes!!";
const secret = Buffer.from(secretText);
const aId = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const bId = new mongoose.Types.ObjectId("64e0000000000000000000b2");
const cId = new mongoose.Types.ObjectId("64e0000000000000000000c3");

const authorityFor = (id: mongoose.Types.ObjectId, version = 1) =>
  signParticipantAuthority(id, version, secret);

function call(headers: Record<string, string>, params: Record<string, string> = {}) {
  const req = { params, headers } as unknown as Request;
  const setHeaders: Record<string, string> = {};
  let statusCode = 200;
  let body: any;
  const res = {} as Response;
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    body = value;
    return res;
  }) as any;
  res.setHeader = vi.fn((name: string, value: string) => {
    setHeaders[name] = value;
    return res;
  }) as any;
  const next = vi.fn() as unknown as NextFunction;
  return {
    req,
    res,
    next,
    setHeaders,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return body;
    },
  };
}

async function list(as: mongoose.Types.ObjectId | null, version = 1) {
  const context = call(as ? { [PARTICIPANT_AUTHORITY_HEADER]: authorityFor(as, version) } : {});
  await getPublicRequestList(context.req, context.res, context.next);
  return context;
}

async function detail(
  id: unknown,
  as: mongoose.Types.ObjectId | null,
  version = 1
) {
  const context = call(
    as ? { [PARTICIPANT_AUTHORITY_HEADER]: authorityFor(as, version) } : {},
    { id: String(id) }
  );
  await getPublicRequestDetail(context.req, context.res, context.next);
  return context;
}

async function seedParticipants() {
  for (const [id, email] of [
    [aId, "gate-a@nyu.edu"],
    [bId, "gate-b@nyu.edu"],
    [cId, "gate-c@nyu.edu"],
  ] as const) {
    await Participant.updateOne(
      { _id: id },
      {
        $set: { email, verifiedAt: new Date(), authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
  }
}

async function createRequest(
  requester: mongoose.Types.ObjectId,
  overrides: Record<string, unknown> = {}
) {
  const deadline = new Date(Date.now() + 60 * 60 * 1000);
  return await MealRequest.create({
    vendor: "Gate Cafe",
    food: "Rice bowl",
    pickupWindowText: "ASAP",
    email: "requester@example.edu",
    mealSwipes: 1,
    status: "open",
    requesterParticipantId: requester,
    expiresAt: deadline,
    deleteAt: deadline,
    ...overrides,
  });
}

describeMongo("real MongoDB W4-R5 verified-only request reads", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, secretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await ParticipantBlock.syncIndexes();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
    await ParticipantBlock.deleteMany({});
    await seedParticipants();
  });

  afterAll(async () => {
    await Participant.deleteMany({ _id: { $in: [aId, bId, cId] } });
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("serves a verified participant, with ownership relative to that participant only", async () => {
    await seedParticipants();
    const aRequest = await createRequest(aId);
    const bRequest = await createRequest(bId);

    const aList = await list(aId);
    expect(aList.statusCode).toBe(200);
    const aOwn = Object.fromEntries(
      aList.body.requests.map((r: any) => [r.id, r.isOwnRequest])
    );
    expect(aOwn[String(aRequest._id)]).toBe(true);
    expect(aOwn[String(bRequest._id)]).toBe(false);

    const bList = await list(bId);
    const bOwn = Object.fromEntries(
      bList.body.requests.map((r: any) => [r.id, r.isOwnRequest])
    );
    expect(bOwn[String(aRequest._id)]).toBe(false);
    expect(bOwn[String(bRequest._id)]).toBe(true);

    expect((await detail(aRequest._id, aId)).body.request.isOwnRequest).toBe(true);
    expect((await detail(aRequest._id, bId)).body.request.isOwnRequest).toBe(false);
    for (const context of [aList, bList]) {
      expect(context.setHeaders["Cache-Control"]).toBe("private, no-store");
      expect(context.setHeaders["Vary"]).toBe(PARTICIPANT_AUTHORITY_HEADER);
    }
  });

  it("refuses anonymous list and direct-id reads with no content", async () => {
    await seedParticipants();
    const request = await createRequest(aId);

    const anonymousList = await list(null);
    const anonymousDetail = await detail(request._id, null);
    for (const context of [anonymousList, anonymousDetail]) {
      expect(context.statusCode).toBe(401);
      expect(context.body.error.code).toBe("PARTICIPANT_VERIFICATION_REQUIRED");
      expect(JSON.stringify(context.body)).not.toContain("Gate Cafe");
    }
  });

  it("refuses a revoked authority version identically for an existing and a nonexistent id", async () => {
    await seedParticipants();
    const request = await createRequest(bId);
    // Revocation: the stored authority version moves past the credential's.
    // (Nothing in production bumps `authorityVersion` today — Change Email
    // upserts by address and replaces the credential held by the installation
    // client-side, `R5-IR-2` — so this proves the version-bound lookup of an
    // independently revoked credential, not a Change Email trigger.)
    await Participant.updateOne({ _id: aId }, { $inc: { authorityVersion: 1 } }).exec();

    const revokedList = await list(aId, 1);
    const existing = await detail(request._id, aId, 1);
    const missing = await detail(new mongoose.Types.ObjectId(), aId, 1);

    expect(revokedList.statusCode).toBe(401);
    expect(revokedList.body.error.code).toBe("PARTICIPANT_AUTHORITY_INVALID");
    expect(existing.statusCode).toBe(401);
    expect(missing.statusCode).toBe(401);
    expect(existing.body).toEqual(missing.body);

    // The replacement credential at the new version works.
    expect((await list(aId, 2)).statusCode).toBe(200);
    expect((await detail(request._id, aId, 2)).statusCode).toBe(200);
  });

  it("refuses a credential whose participant row no longer exists", async () => {
    await seedParticipants();
    const request = await createRequest(bId);
    await Participant.deleteOne({ _id: aId }).exec();

    expect((await list(aId)).statusCode).toBe(401);
    expect((await detail(request._id, aId)).statusCode).toBe(401);
  });

  it("does not refuse the original participant's credential merely because another participant was verified (R5-IR-2)", async () => {
    // Change Email verifies the replacement address as its own participant and
    // hands the installation that participant's credential; it never touches
    // the original participant's row. So the original credential, still signed
    // at its stored version for its still-eligible principal, keeps being
    // authorized by the backend.
    await seedParticipants();
    const request = await createRequest(bId);
    const before = await Participant.findById(aId).lean().exec();

    // The replacement participant is verified (its own row, its own version).
    await Participant.updateOne(
      { _id: cId },
      { $set: { email: "gate-replacement@nyu.edu", verifiedAt: new Date() } }
    ).exec();

    const afterReplacement = await Participant.findById(aId).lean().exec();
    expect(afterReplacement?.authorityVersion).toBe(before?.authorityVersion);
    expect((await list(aId)).statusCode).toBe(200);
    expect((await detail(request._id, aId)).statusCode).toBe(200);
    // And the replacement's own credential works too: two valid credentials,
    // two principals, no coupling between them.
    expect((await list(cId)).statusCode).toBe(200);
  });

  it("refuses a credential whose stored principal is no longer eligible", async () => {
    await seedParticipants();
    const request = await createRequest(bId);
    await Participant.updateOne(
      { _id: aId },
      { $set: { email: "someone@gmail.com" } }
    ).exec();

    expect((await list(aId)).statusCode).toBe(401);
    expect((await detail(request._id, aId)).statusCode).toBe(401);
  });

  it("answers a fenced counterpart's request exactly like a missing one for a verified caller, and refuses an unverified one before looking", async () => {
    await seedParticipants();
    const bRequest = await createRequest(bId);
    await ParticipantBlock.create({
      blockerParticipantId: aId,
      blockedParticipantId: bId,
      blockedRole: "requester",
      diningLocation: "Gate Cafe",
      interactionAt: new Date(),
      ...blockSafetyIdentityFields("gate-b@nyu.edu"),
    });

    const fenced = await detail(bRequest._id, aId);
    const missing = await detail(new mongoose.Types.ObjectId(), aId);
    expect(fenced.statusCode).toBe(404);
    expect(fenced.body).toEqual(missing.body);

    // A fenced list never contains the counterpart's request.
    const aList = await list(aId);
    expect(aList.body.requests.map((r: any) => r.id)).not.toContain(
      String(bRequest._id)
    );

    // Unverified: the answer is the same whether or not the id is fenced.
    const anonymousFenced = await detail(bRequest._id, null);
    const anonymousMissing = await detail(new mongoose.Types.ObjectId(), null);
    expect(anonymousFenced.statusCode).toBe(401);
    expect(anonymousFenced.body).toEqual(anonymousMissing.body);
  });

  it("answers an unverified caller identically for a not-yet-visible request", async () => {
    await seedParticipants();
    const later = await createRequest(bId, {
      visibleFrom: new Date(Date.now() + 60 * 60 * 1000),
    });
    const ordinary = await createRequest(bId);

    const anonymousLater = await detail(later._id, null);
    const anonymousOrdinary = await detail(ordinary._id, null);
    expect(anonymousLater.statusCode).toBe(401);
    expect(anonymousLater.body).toEqual(anonymousOrdinary.body);

    // A verified caller keeps the distinct visibility refusal.
    expect((await detail(later._id, cId)).statusCode).toBe(409);
  });
});
