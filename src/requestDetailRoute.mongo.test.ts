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
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  participationIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";

// Real-Mongo production-boundary proof for W3-H2 stale detail Reserve truth
// (`getPublicRequestDetail`'s participant-aware `alreadyParticipated` field):
// a real persisted `RequestParticipation` row, read through the actual route
// handler, must be disclosed only to the exact participant it belongs to.
// `requestDetailRoute.test.ts` already covers this with mocked models; this
// file proves the same behavior against a real durable row rather than a
// mocked lookup.
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_request_detail`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const participantSecretText = "request-detail-mongo-participant-secret-32";
const participantSecret = Buffer.from(participantSecretText);
const pParticipantId = new mongoose.Types.ObjectId(
  "64e0000000000000000000f1"
);
const pPrincipal = "request-detail-mongo-p@nyu.edu";
const pAuthority = signParticipantAuthority(pParticipantId, 1, participantSecret);
const qParticipantId = new mongoose.Types.ObjectId(
  "64e0000000000000000000f2"
);
const qPrincipal = "request-detail-mongo-q@nyu.edu";
const qAuthority = signParticipantAuthority(qParticipantId, 1, participantSecret);

async function ensureVerifiedParticipants() {
  await Participant.updateOne(
    { _id: pParticipantId },
    {
      $set: { email: pPrincipal, verifiedAt: new Date() },
      $setOnInsert: { authorityVersion: 1 },
    },
    { upsert: true }
  ).exec();
  await Participant.updateOne(
    { _id: qParticipantId },
    {
      $set: { email: qPrincipal, verifiedAt: new Date() },
      $setOnInsert: { authorityVersion: 1 },
    },
    { upsert: true }
  ).exec();
}

function routeContext(id: string, headers: Record<string, string> = {}) {
  const req = { params: { id }, headers } as unknown as Request;
  const res = {} as Response;
  let statusCode = 200;
  let bodyValue: any;
  const setHeaders: Record<string, string> = {};
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    bodyValue = value;
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
    get statusCode() {
      return statusCode;
    },
    get body() {
      return bodyValue;
    },
    setHeaders,
  };
}

describeMongo("real MongoDB W3-H2 stale detail Reserve truth (participant-aware GET /api/request/:id)", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await RequestParticipation.syncIndexes();
    await ensureVerifiedParticipants();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
    await RequestParticipation.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  async function createDetailRequest() {
    const now = new Date();
    const deadline = new Date(now.getTime() + 60 * 60 * 1000);
    return await MealRequest.create({
      vendor: "Detail Isolation Cafe",
      food: "Rice bowl",
      pickupName: "Only Winner Sees This",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      mealSwipes: 3,
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
    });
  }

  it("tells P their own real durable participation truth", async () => {
    const request = await createDetailRequest();
    await RequestParticipation.create([
      {
        requestId: request._id,
        participantId: pParticipantId,
        ...participationIdentityFields(String(request._id), pPrincipal),
      },
    ]);

    const context = routeContext(String(request._id), {
      [PARTICIPANT_AUTHORITY_HEADER]: pAuthority,
    });
    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.statusCode).toBe(200);
    expect(context.body.alreadyParticipated).toBe(true);
    expect(context.body.request.id).toBe(String(request._id));
  });

  it("never discloses P's participation truth to Q", async () => {
    const request = await createDetailRequest();
    await RequestParticipation.create([
      {
        requestId: request._id,
        participantId: pParticipantId,
        ...participationIdentityFields(String(request._id), pPrincipal),
      },
    ]);

    const context = routeContext(String(request._id), {
      [PARTICIPANT_AUTHORITY_HEADER]: qAuthority,
    });
    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.statusCode).toBe(200);
    expect(context.body).not.toHaveProperty("alreadyParticipated");
  });

  it("refuses an anonymous caller with no request and no participation disclosure", async () => {
    const request = await createDetailRequest();
    await RequestParticipation.create([
      {
        requestId: request._id,
        participantId: pParticipantId,
        ...participationIdentityFields(String(request._id), pPrincipal),
      },
    ]);

    const context = routeContext(String(request._id), {});
    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.statusCode).toBe(401);
    expect(context.body.error.code).toBe("PARTICIPANT_VERIFICATION_REQUIRED");
    expect(context.body).not.toHaveProperty("request");
    expect(context.body).not.toHaveProperty("alreadyParticipated");
  });

  it("refuses an unusable participant authority with no request and no disclosure", async () => {
    const request = await createDetailRequest();
    await RequestParticipation.create([
      {
        requestId: request._id,
        participantId: pParticipantId,
        ...participationIdentityFields(String(request._id), pPrincipal),
      },
    ]);

    const context = routeContext(String(request._id), {
      [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential",
    });
    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.statusCode).toBe(401);
    expect(context.body.error.code).toBe("PARTICIPANT_AUTHORITY_INVALID");
    expect(context.body).not.toHaveProperty("request");
    expect(context.body).not.toHaveProperty("alreadyParticipated");
  });

  it("carries the caller-specific cache/privacy headers on every one of the above responses", async () => {
    const request = await createDetailRequest();
    await RequestParticipation.create([
      {
        requestId: request._id,
        participantId: pParticipantId,
        ...participationIdentityFields(String(request._id), pPrincipal),
      },
    ]);

    const headerSets: Record<string, string>[] = [
      { [PARTICIPANT_AUTHORITY_HEADER]: pAuthority },
      { [PARTICIPANT_AUTHORITY_HEADER]: qAuthority },
      {},
      { [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential" },
    ];
    for (const headers of headerSets) {
      const context = routeContext(String(request._id), headers);
      await getPublicRequestDetail(context.req, context.res, context.next);
      expect(context.setHeaders["Cache-Control"]).toBe("private, no-store");
      expect(context.setHeaders["Vary"]).toBe(PARTICIPANT_AUTHORITY_HEADER);
    }
  });

  it("exposes only the ordinary public projection plus P's own scoped boolean — no participant id, email, RequestParticipation data, claim token/authority, or private request fields, for any caller", async () => {
    const request = await createDetailRequest();
    await RequestParticipation.create([
      {
        requestId: request._id,
        participantId: pParticipantId,
        ...participationIdentityFields(String(request._id), pPrincipal),
      },
    ]);

    const responses = [];
    const headerSets: Record<string, string>[] = [
      { [PARTICIPANT_AUTHORITY_HEADER]: pAuthority },
      { [PARTICIPANT_AUTHORITY_HEADER]: qAuthority },
      {},
      { [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential" },
    ];
    for (const headers of headerSets) {
      const context = routeContext(String(request._id), headers);
      await getPublicRequestDetail(context.req, context.res, context.next);
      responses.push(context.body);
    }

    const [pBody, qBody, anonymousBody, unusableBody] = responses;
    expect(Object.keys(pBody).sort()).toEqual(["alreadyParticipated", "request"]);
    expect(Object.keys(qBody)).toEqual(["request"]);
    for (const body of [anonymousBody, unusableBody]) {
      expect(Object.keys(body)).toEqual(["error"]);
    }
    expect(Object.keys(pBody.request).sort()).toEqual(
      Object.keys(qBody.request).sort()
    );

    for (const body of [pBody, qBody]) {
      const serialized = JSON.stringify(body);
      expect(serialized).not.toMatch(
        /participantId|email|claimToken|claimTokenDigest|pickupName|authorityVersion/
      );
    }
    for (const body of [anonymousBody, unusableBody]) {
      expect(JSON.stringify(body)).not.toMatch(
        /participantId|claimToken|claimTokenDigest|pickupName|authorityVersion|Detail Isolation Cafe/
      );
    }
  });
});
