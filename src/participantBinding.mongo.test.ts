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

vi.mock("./notifySubscribers.js", () => ({ notifySubscribersForRequest }));
vi.mock("./helperNewRequestPush.js", () => ({ startHelperNewRequestPush }));

import { Participant, Request as MealRequest } from "../models/db.js";
import { claimRequest } from "./claimRoute.js";
import { createRequest } from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";
import {
  buildPublicRequestDetailResponse,
  mapPublicRequestFields,
  type PublicRequestDocument,
} from "./requestListResponse.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  uri.pathname = `${uri.pathname}_participant_binding`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const signingSecretText = "participant-binding-mongo-secret-32-bytes";
const signingSecret = Buffer.from(signingSecretText);
const requesterId = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const firstHelperId = new mongoose.Types.ObjectId("64e0000000000000000000b1");
const secondHelperId = new mongoose.Types.ObjectId("64e0000000000000000000b2");

function authorityFor(participantId: mongoose.Types.ObjectId): string {
  return signParticipantAuthority(participantId, 1, signingSecret);
}

function routeContext(
  authority: string,
  options: { body?: unknown; id?: string } = {}
) {
  const req = {
    body: options.body,
    params: options.id ? { id: options.id } : {},
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: authority },
  } as unknown as Request;
  const res = {} as Response;
  let statusCode = 200;
  let responseBody: any;
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    responseBody = value;
    return res;
  }) as any;
  return {
    req,
    res,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return responseBody;
    },
  };
}

describeMongo("durable participant bindings", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, signingSecretText);
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "participant-binding-claim-secret-32-bytes"
    );
    resendSend.mockResolvedValue({ data: { id: "request-email" }, error: null });
    notifySubscribersForRequest.mockResolvedValue(undefined);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await Participant.syncIndexes();
    await MealRequest.syncIndexes();
  });

  afterEach(async () => {
    await Promise.all([
      Participant.deleteMany({}),
      MealRequest.deleteMany({}),
    ]);
    vi.clearAllMocks();
    resendSend.mockResolvedValue({ data: { id: "request-email" }, error: null });
    notifySubscribersForRequest.mockResolvedValue(undefined);
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("persists exact requester/helper principals, replaces an expired claim binding, and omits both from public projection", async () => {
    await Participant.insertMany([
      {
        _id: requesterId,
        email: "binding-requester@nyu.edu",
        authorityVersion: 1,
        verifiedAt: new Date(),
      },
      {
        _id: firstHelperId,
        email: "binding-helper-one@nyu.edu",
        authorityVersion: 1,
        verifiedAt: new Date(),
      },
      {
        _id: secondHelperId,
        email: "binding-helper-two@stern.nyu.edu",
        authorityVersion: 1,
        verifiedAt: new Date(),
      },
    ]);

    const creation = routeContext(authorityFor(requesterId), {
      body: {
        vendor: "Jasper Kane Cafe",
        timing: "asap",
        menuPath: "meal-exchange",
        mealSwipes: 2,
        mealItems: [{ name: "Rice bowl" }, { name: "Side salad" }],
      },
    });
    await createRequest(creation.req, creation.res);

    expect(creation.statusCode).toBe(201);
    expect(JSON.stringify(creation.body)).not.toMatch(
      /requesterParticipantId|helperParticipantId/
    );
    const requestId = creation.body.request.id as string;
    let stored = await MealRequest.collection.findOne({
      _id: new mongoose.Types.ObjectId(requestId),
    });
    expect(stored?.requesterParticipantId).toEqual(requesterId);
    expect(stored).not.toHaveProperty("helperParticipantId");

    const firstClaim = routeContext(authorityFor(firstHelperId), { id: requestId });
    await claimRequest(firstClaim.req, firstClaim.res);
    expect(firstClaim.statusCode).toBe(200);
    expect(JSON.stringify(firstClaim.body.request)).not.toMatch(
      /requesterParticipantId|helperParticipantId/
    );
    stored = await MealRequest.collection.findOne({
      _id: new mongoose.Types.ObjectId(requestId),
    });
    expect(stored?.helperParticipantId).toEqual(firstHelperId);

    await MealRequest.collection.updateOne(
      { _id: new mongoose.Types.ObjectId(requestId) },
      { $set: { claimExpiresAt: new Date(Date.now() - 1) } }
    );

    const replacementClaim = routeContext(authorityFor(secondHelperId), {
      id: requestId,
    });
    await claimRequest(replacementClaim.req, replacementClaim.res);
    expect(replacementClaim.statusCode).toBe(200);
    stored = await MealRequest.collection.findOne({
      _id: new mongoose.Types.ObjectId(requestId),
    });
    expect(stored?.requesterParticipantId).toEqual(requesterId);
    expect(stored?.helperParticipantId).toEqual(secondHelperId);

    const publicDetail = buildPublicRequestDetailResponse(
      stored as unknown as PublicRequestDocument,
      new Date()
    );
    const publicFields = mapPublicRequestFields(
      stored as unknown as PublicRequestDocument & { status: string }
    );
    for (const projection of [publicDetail, publicFields]) {
      expect(JSON.stringify(projection)).not.toMatch(
        /requesterParticipantId|helperParticipantId|binding-requester|binding-helper/
      );
    }
  });
});
