import type { Request, Response } from "express";
import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import {
  Fulfillment,
  Participant,
  ParticipantIdentityKeyVersion,
  PlacementEvidence,
  Request as MealRequest,
} from "../models/db.js";
import {
  digestClaimToken,
  generateClaimToken,
  readClaimTokenHmacSecret,
} from "./claimToken.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  BLOCK_SAFETY_HMAC_KEYRING_ENV,
  PARTICIPATION_HMAC_KEYRING_ENV,
} from "./participantIdentityKeys.js";

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import { releaseClaim } from "./claimRoute.js";
import {
  fulfillRequest,
  PLACED_RETENTION_MS,
} from "./fulfillmentRoute.js";
import { getActiveReservation } from "./reservationRoute.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import { buildPublicRequestDetailResponse } from "./requestListResponse.js";
import { getStats } from "./statsRoute.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_fulfillment`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

function routeContext(
  id: string,
  body: unknown,
  headers: Record<string, string> = {}
) {
  const req = { params: { id }, body, headers } as unknown as Request;
  const res = {} as Response;
  let statusCode = 200;
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

/**
 * The verified helper every reservation below is bound to (W3-I1). Fulfillment
 * derives the helper address from this binding, so it is the only place the
 * placed request's `fulfillerEmail` and the requester email's Reply-To can come
 * from — nothing in the payload supplies one.
 */
const helperParticipantId = new mongoose.Types.ObjectId(
  "64d0000000000000000000c3"
);
const boundHelperEmail = "fulfillment-mongo-helper@nyu.edu";
const participantSecret = Buffer.from(
  "real-mongo-test-participant-secret-material"
);
const participationKey = Buffer.alloc(32, 0x31);
const blockSafetyKey = Buffer.alloc(32, 0x52);
/**
 * A real signed credential for the bound helper (W3-H1 continuation), used in
 * place of the raw claim token once a relaunch has discarded it.
 */
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);
const continuationHeaders = {
  [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
};

// Smallest well-formed 1x1 PNG: passes the same structural validation a real
// screenshot does without shipping a real fixture (W4-H1a).
const ONE_PIXEL_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
const validScreenshot = () => ({
  mimeType: "image/png",
  imageBase64: ONE_PIXEL_PNG_BASE64,
});

function fulfillmentBody(rawToken: string) {
  return {
    claimToken: rawToken,
    fulfillment: {
      orderNumber: "70154321",
      eta: "15 minutes",
      contactMessage: "Your meal is ready",
      placedOrderScreenshot: validScreenshot(),
    },
  };
}

/** The W3-H1 continuation wire shape: no raw token, participant header instead. */
function continuationFulfillmentBody() {
  return {
    fulfillment: {
      orderNumber: "70154321",
      eta: "15 minutes",
      contactMessage: "Your meal is ready",
      placedOrderScreenshot: validScreenshot(),
    },
  };
}

async function createClaimedRequest(
  overrides: Record<string, unknown> = {}
) {
  const rawToken = generateClaimToken();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + 60 * 60 * 1000);
  const request = await MealRequest.create({
    vendor: "Transaction Cafe",
    food: "Rice bowl",
    pickupName: "Requester Pickup",
    pickupWindowText: "ASAP",
    email: "requester@example.edu",
    status: "claimed",
    expiresAt,
    deleteAt: expiresAt,
    claimedAt: now,
    claimExpiresAt: new Date(now.getTime() + 15 * 60 * 1000),
    claimExtendedAt: null,
    claimTokenDigest: digestClaimToken(
      rawToken,
      readClaimTokenHmacSecret()
    ),
    helperParticipantId,
    ...overrides,
  });
  return { request, rawToken };
}

describeMongo("transactional fulfillment against a real replica set", () => {
  beforeAll(async () => {
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "real-mongo-test-secret-material-32-bytes"
    );
    vi.stubEnv(
      PARTICIPANT_SIGNING_SECRET_ENV,
      participantSecret.toString("utf8")
    );
    vi.stubEnv(
      PARTICIPATION_HMAC_KEYRING_ENV,
      JSON.stringify({
        currentVersion: 1,
        keys: { "1": participationKey.toString("base64") },
      })
    );
    vi.stubEnv(
      BLOCK_SAFETY_HMAC_KEYRING_ENV,
      JSON.stringify({
        currentVersion: 1,
        keys: { "1": blockSafetyKey.toString("base64") },
      })
    );
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
    await Fulfillment.syncIndexes();
    await PlacementEvidence.syncIndexes();
    await Participant.createIndexes();
    await ParticipantIdentityKeyVersion.syncIndexes();
    await ParticipantIdentityKeyVersion.updateOne(
      { purpose: "participation", version: 1 },
      { $set: { normalizationVersion: 1 } },
      { upsert: true }
    ).exec();
    await Participant.updateOne(
      { _id: helperParticipantId },
      {
        $set: { email: boundHelperEmail, verifiedAt: new Date() },
        $setOnInsert: { authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
  });

  beforeEach(() => {
    sendFulfillmentEmail.mockReset();
    sendFulfillmentEmail.mockResolvedValue(undefined);
  });

  afterEach(async () => {
    await Promise.all([
      MealRequest.deleteMany({}),
      Fulfillment.deleteMany({}),
      PlacementEvidence.deleteMany({}),
    ]);
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("runs against a transaction-capable replica set", async () => {
    const hello = await mongoose.connection.db!.admin().command({ hello: 1 });
    expect(hello.setName).toBe("commonplateTestReplica");
    expect(hello.isWritablePrimary).toBe(true);
  });

  it("lets the valid claimant place once with authoritative timestamps and private fields", async () => {
    const originalExpiresAt = new Date(Date.now() - 60 * 1000);
    const { request, rawToken } = await createClaimedRequest({
      // Fulfillment authorization deliberately ignores request.expiresAt once
      // a still-active claim exists.
      expiresAt: originalExpiresAt,
      deleteAt: new Date(Date.now() + 60 * 60 * 1000),
    });
    const before = new Date();
    const context = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );

    await fulfillRequest(context.req, context.res);
    const after = new Date();

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    expect(context.body.notification).toEqual({ status: "sent" });

    const stored = await MealRequest.findById(request._id)
      .select("+claimTokenDigest")
      .lean();
    expect(stored?.status).toBe("placed");
    // `placedAt` and `deleteAt` are optional on the schema but always written
    // by the placement transaction this test just committed.
    expect(stored?.placedAt!.getTime()).toBeGreaterThanOrEqual(before.getTime());
    expect(stored?.placedAt!.getTime()).toBeLessThanOrEqual(after.getTime());
    expect(stored!.deleteAt!.getTime() - stored!.placedAt!.getTime()).toBe(
      PLACED_RETENTION_MS
    );
    expect(stored?.expiresAt).toEqual(originalExpiresAt);
    expect(stored?.orderNumber).toBe("70154321");
    expect(stored?.etaText).toBe("15 minutes");
    expect(stored?.fulfillerEmail).toBe(boundHelperEmail);
    // W4-U1.1: the allowed Message is transient (email only) and is not
    // retained on the Request; no marker is written either, since nothing was
    // suppressed.
    expect(stored).not.toHaveProperty("contactMessage");
    expect(stored).not.toHaveProperty("contactMessageSuppressed");
    expect(stored?.notificationStatus).toBe("sent");
    expect(stored?.notificationAttemptedAt).toBeInstanceOf(Date);
    expect(stored).not.toHaveProperty("claimedAt");
    expect(stored).not.toHaveProperty("claimExpiresAt");
    expect(stored).not.toHaveProperty("claimExtendedAt");
    expect(stored).not.toHaveProperty("claimTokenDigest");

    const ledger = await Fulfillment.findOne({ requestId: request._id }).lean();
    expect(ledger).toMatchObject({
      orderNumber: "70154321",
      etaText: "15 minutes",
    });
    expect(ledger?.placedAt).toEqual(stored?.placedAt);
    expect(await Fulfillment.countDocuments()).toBe(1);

    // W4-H1a: the private evidence row committed with the placement, bound to
    // this exact Request, holding the exact bytes and the Request's own horizon.
    const evidence = await PlacementEvidence.findOne({ requestId: request._id })
      .select("+image")
      .lean();
    expect(evidence).not.toBeNull();
    expect(Buffer.isBuffer((evidence!.image as any).buffer ?? evidence!.image)).toBe(true);
    expect(Buffer.from((evidence!.image as any).buffer ?? evidence!.image).equals(
      Buffer.from(ONE_PIXEL_PNG_BASE64, "base64")
    )).toBe(true);
    expect(evidence?.mimeType).toBe("image/png");
    expect(evidence?.byteLength).toBe(Buffer.from(ONE_PIXEL_PNG_BASE64, "base64").length);
    expect(evidence?.deleteAt).toEqual(stored?.deleteAt);
    expect(await PlacementEvidence.countDocuments()).toBe(1);

    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.objectContaining({ _id: request._id, status: "placed" }),
      "70154321",
      "15 minutes",
      "Your meal is ready",
      boundHelperEmail
    );

    const active = await MealRequest.find(
      buildEffectiveAvailabilityFilter(new Date())
    ).lean();
    expect(active).toHaveLength(0);

    const publicDetail = buildPublicRequestDetailResponse(
      stored as any,
      new Date()
    );
    expect(publicDetail.request.status).toBe("placed");
    expect(JSON.stringify(publicDetail)).not.toMatch(
      /pickupName|email|orderNumber|etaText|placedAt|contactMessage|notification|claim/i
    );
  });

  // W3-I1 pre-I1 active-claim compatibility: a claim granted before
  // `helperParticipantId` existed carries no binding at all, and the accepted
  // fulfillment-safety contract requires it to remain recordable on the
  // existing valid-token authorization alone rather than becoming refusable.
  it("records placement for a claim with no helperParticipantId binding (pre-I1 compatibility)", async () => {
    const { request, rawToken } = await createClaimedRequest({
      helperParticipantId: undefined,
    });
    const preexisting = await MealRequest.findById(request._id)
      .select("+helperParticipantId")
      .lean();
    expect(preexisting).not.toHaveProperty("helperParticipantId");

    const context = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    expect(context.body.notification).toEqual({ status: "sent" });

    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe("placed");
    expect(stored?.orderNumber).toBe("70154321");
    // No verified helper to derive an address from, and the payload carries
    // none either, so the field is left unset rather than fabricated.
    expect(stored?.fulfillerEmail).toBeUndefined();

    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(
      1
    );
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.objectContaining({ _id: request._id }),
      "70154321",
      "15 minutes",
      "Your meal is ready",
      undefined
    );
  });

  // The order number is a digits-only *string*, and stays one through the
  // transaction, the ledger, the response, and the student's email. A leading
  // zero is the value that proves it: any numeric conversion anywhere along
  // that path would drop it and leave the student a number that no longer
  // matches the helper's Grubhub confirmation.
  it("preserves a leading-zero order number as a string end to end", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(String(request._id), {
      claimToken: rawToken,
      fulfillment: {
        orderNumber: "00070154321",
        eta: "ASAP",
        placedOrderScreenshot: validScreenshot(),
      },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);

    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.orderNumber).toBe("00070154321");
    expect(typeof stored?.orderNumber).toBe("string");

    const ledger = await Fulfillment.findOne({ requestId: request._id }).lean();
    expect(ledger?.orderNumber).toBe("00070154321");
    expect(typeof ledger?.orderNumber).toBe("string");

    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.objectContaining({ _id: request._id }),
      "00070154321",
      "ASAP",
      undefined,
      boundHelperEmail
    );

    // The response is still the same two-key shape; the order number is private
    // and does not appear in the public projection at all.
    expect(Object.keys(context.body).sort()).toEqual([
      "notification",
      "request",
    ]);
    expect(JSON.stringify(context.body)).not.toContain("00070154321");
  });

  it("refuses a non-numeric order number without touching the request", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(String(request._id), {
      claimToken: rawToken,
      fulfillment: {
        orderNumber: "7015-4321",
        eta: "ASAP",
      },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(400);
    expect(context.body.error.code).toBe("INVALID_FULFILLMENT_PAYLOAD");

    // Placement semantics are untouched: the claim survives and can still be
    // used for a corrected submission.
    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe("claimed");
    expect(stored?.orderNumber).toBeUndefined();
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(0);
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("leaves no contact message anywhere when the helper omits one", async () => {
    // W4-U1.1: the Message is never persisted at all (the Request schema has no
    // such field), so there is nothing stale to seed or clear; the stronger
    // "never stored anywhere, allowed or blocked" proofs live in the W4-U1.1
    // block below.
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(String(request._id), {
      claimToken: rawToken,
      fulfillment: {
        orderNumber: "70154321",
        eta: "15 minutes",
        placedOrderScreenshot: validScreenshot(),
      },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    expect(context.body.notification).toEqual({ status: "sent" });

    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe("placed");
    expect(stored?.orderNumber).toBe("70154321");
    expect(stored).not.toHaveProperty("contactMessage");

    const ledger = await Fulfillment.findOne({ requestId: request._id }).lean();
    expect(ledger).not.toBeNull();
    expect(ledger).not.toHaveProperty("contactMessage");
    expect(ledger).not.toHaveProperty("note");

    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.objectContaining({ _id: request._id }),
      "70154321",
      "15 minutes",
      undefined,
      boundHelperEmail
    );
  });

  it("classifies wrong token, expired claim, already placed, and not found", async () => {
    const wrong = await createClaimedRequest();
    const expired = await createClaimedRequest({
      claimExpiresAt: new Date(Date.now() - 1),
    });
    const placed = await createClaimedRequest({ status: "placed" });
    const scenarios = [
      {
        context: routeContext(
          String(wrong.request._id),
          fulfillmentBody(generateClaimToken())
        ),
        status: 403,
        code: "INVALID_CLAIM_TOKEN",
      },
      {
        context: routeContext(
          String(expired.request._id),
          fulfillmentBody(expired.rawToken)
        ),
        status: 409,
        code: "CLAIM_EXPIRED",
      },
      {
        context: routeContext(
          String(placed.request._id),
          fulfillmentBody(placed.rawToken)
        ),
        status: 409,
        code: "REQUEST_ALREADY_PLACED",
      },
      {
        context: routeContext(
          String(new mongoose.Types.ObjectId()),
          fulfillmentBody(generateClaimToken())
        ),
        status: 404,
        code: "REQUEST_NOT_FOUND",
      },
    ];

    for (const scenario of scenarios) {
      await fulfillRequest(scenario.context.req, scenario.context.res);
      expect(scenario.context.statusCode).toBe(scenario.status);
      expect(scenario.context.body.error.code).toBe(scenario.code);
    }
    expect(await Fulfillment.countDocuments()).toBe(0);
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("allows one core result from two concurrent fulfillment attempts", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const attempts = [
      routeContext(String(request._id), fulfillmentBody(rawToken)),
      routeContext(String(request._id), fulfillmentBody(rawToken)),
    ];

    await Promise.all(
      attempts.map((attempt) => fulfillRequest(attempt.req, attempt.res))
    );

    const winners = attempts.filter(
      (attempt) =>
        attempt.statusCode === 200 && attempt.body?.request?.status === "placed"
    );
    const losers = attempts.filter(
      (attempt) =>
        attempt.statusCode === 409 &&
        attempt.body?.error?.code === "REQUEST_ALREADY_PLACED"
    );
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(await MealRequest.countDocuments({ status: "placed" })).toBe(1);
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
  });

  it("rolls back the Request transition when the ledger insert fails", async () => {
    const forcedFailureIndex = "test_force_core_failure";
    const existingRequestId = new mongoose.Types.ObjectId();
    await Fulfillment.collection.createIndex(
      { orderNumber: 1 },
      { unique: true, name: forcedFailureIndex }
    );
    try {
      await Fulfillment.create({
        requestId: existingRequestId,
        orderNumber: "70154321",
        etaText: "10 minutes",
      });
      const { request, rawToken } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        fulfillmentBody(rawToken)
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(500);
      expect(context.body.error.code).toBe("INTERNAL_FAILURE");
      const stored = await MealRequest.findById(request._id)
        .select("+claimTokenDigest")
        .lean();
      expect(stored?.status).toBe("claimed");
      expect(stored?.claimTokenDigest).toBeDefined();
      expect(stored).not.toHaveProperty("placedAt");
      expect(
        await Fulfillment.countDocuments({ requestId: request._id })
      ).toBe(0);
      // W4-H1a: nothing of the placement survives a ledger failure — no
      // evidence row either.
      expect(
        await PlacementEvidence.countDocuments({ requestId: request._id })
      ).toBe(0);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    } finally {
      await Fulfillment.collection.dropIndex(forcedFailureIndex);
    }
  });

  it("enforces Fulfillment request uniqueness at the database", async () => {
    const requestId = new mongoose.Types.ObjectId();
    await Fulfillment.create({ requestId, orderNumber: "70150001" });

    await expect(
      Fulfillment.create({ requestId, orderNumber: "70150002" })
    ).rejects.toMatchObject({ code: 11000 });
    expect(await Fulfillment.countDocuments({ requestId })).toBe(1);
  });

  it("keeps the all-time stats count after the private Request expires or is removed", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const placement = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );
    await fulfillRequest(placement.req, placement.res);
    expect(placement.statusCode).toBe(200);

    await MealRequest.deleteOne({ _id: request._id });
    const json = vi.fn();
    const next = vi.fn();
    await getStats({} as Request, { json } as unknown as Response, next);

    expect(json).toHaveBeenCalledWith({ totalShared: 1 });
    expect(next).not.toHaveBeenCalled();
  });

  // The post-commit notification is handed the *placed* document, which is what
  // carries the student address the request was created with. The helper's
  // address arrives only as the last argument — the Reply-To — so entering it on
  // the fulfillment form can never redirect the notification to them.
  it("notifies from the placed request and passes the helper address only as reply-to", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(sendFulfillmentEmail).toHaveBeenCalledTimes(1);
    const [notified, orderNumber, eta, contactMessage, replyTo] =
      sendFulfillmentEmail.mock.calls[0];

    expect(String(notified._id)).toBe(String(request._id));
    expect(notified.status).toBe("placed");
    expect(notified.email).toBe("requester@example.edu");
    // W4-R4: the Request the fulfillment email is composed from carries no
    // pickup name, because the schema no longer has the field at all.
    expect(notified.pickupName).toBeUndefined();
    expect(orderNumber).toBe("70154321");
    expect(eta).toBe("15 minutes");
    expect(contactMessage).toBe("Your meal is ready");
    // The claim-bound verified helper, and never the recipient. No payload
    // supplied it, so the Reply-To the requester sees is an address CommonPlate
    // has actually proved control of.
    expect(replyTo).toBe(boundHelperEmail);
    expect(notified.email).not.toBe(replyTo);
    expect(context.body.notification).toEqual({ status: "sent" });
  });

  it("attempts email after commit and keeps placement when provider submission fails", async () => {
    const { request, rawToken } = await createClaimedRequest();
    sendFulfillmentEmail.mockImplementationOnce(async () => {
      const committedRequest = await MealRequest.findById(request._id).lean();
      const committedLedger = await Fulfillment.findOne({
        requestId: request._id,
      }).lean();
      expect(committedRequest?.status).toBe("placed");
      expect(committedRequest?.notificationStatus).toBe("pending");
      expect(committedLedger).not.toBeNull();
      throw new Error("provider unavailable");
    });
    const context = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    expect(context.body.notification).toEqual({ status: "failed" });
    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe("placed");
    expect(stored?.notificationStatus).toBe("failed");
    expect(stored?.notificationAttemptedAt).toBeInstanceOf(Date);
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
    // Email failure is a post-commit outcome: the evidence stays.
    expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(1);
  });

  // Week 3 Day 6 Slice 6E: the requester-fulfillment push dispatcher reads
  // `installationId` off the placed document the transaction returns.
  // `installationId` is `select: false`, so this proves the placement query
  // actually requests it rather than silently carrying `undefined` through.
  it("carries the request's installationId through the placement transaction", async () => {
    const installationId = new mongoose.Types.ObjectId();
    const { request, rawToken } = await createClaimedRequest({ installationId });
    const context = routeContext(String(request._id), fulfillmentBody(rawToken));

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    const stored = await MealRequest.findById(request._id)
      .select("+installationId")
      .lean();
    expect(String(stored?.installationId)).toBe(String(installationId));
    // Never exposed through the public response.
    expect(JSON.stringify(context.body)).not.toContain(String(installationId));
  });

  it("places normally for a request with no installation association", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(String(request._id), fulfillmentBody(rawToken));

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    const stored = await MealRequest.findById(request._id)
      .select("+installationId")
      .lean();
    expect(stored?.installationId).toBeUndefined();
  });

  it("clears the verified helper's one-active-reservation lock on successful placement (W3-H1)", async () => {
    const { request, rawToken } = await createClaimedRequest();
    await Participant.updateOne(
      { _id: helperParticipantId },
      {
        $set: {
          activeReservationRequestId: request._id,
          activeReservationClaimExpiresAt: new Date(
            Date.now() + 60 * 60 * 1000
          ),
        },
      }
    ).exec();
    const context = routeContext(String(request._id), fulfillmentBody(rawToken));

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    const lock = await Participant.findById(helperParticipantId)
      .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
      .lean();
    expect(lock?.activeReservationRequestId).toBeNull();
    expect(lock?.activeReservationClaimExpiresAt).toBeNull();
  });

  it("release-vs-fulfillment race cannot reopen a successful placement (W3-H1)", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const release = routeContext(String(request._id), { claimToken: rawToken });
    const fulfill = routeContext(String(request._id), fulfillmentBody(rawToken));

    await Promise.all([
      releaseClaim(release.req, release.res),
      fulfillRequest(fulfill.req, fulfill.res),
    ]);

    // Both mutations pivot on the same `status: "claimed"` conditional
    // filter, so exactly one of them can have matched; the other lost the
    // race and was refused. Whichever won, the persisted status settles on a
    // terminal outcome the loser cannot undo.
    const releaseWon = release.statusCode === 200;
    const fulfillWon = fulfill.statusCode === 200;
    expect(releaseWon !== fulfillWon).toBe(true);
    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe(releaseWon ? "open" : "placed");
  });

  describe("participant-authority continuation (W3-H1 MUST FIX 1)", () => {
    it("fulfills a restored reservation without the lost raw claim token", async () => {
      const { request } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      expect(context.body.request.status).toBe("placed");
      const stored = await MealRequest.findById(request._id)
        .select("+claimTokenDigest")
        .lean();
      expect(stored?.status).toBe("placed");
      expect(stored?.orderNumber).toBe("70154321");
      expect(stored?.fulfillerEmail).toBe(boundHelperEmail);
      expect(stored).not.toHaveProperty("claimTokenDigest");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      expect(sendFulfillmentEmail).toHaveBeenCalledWith(
        expect.objectContaining({ _id: request._id }),
        "70154321",
        "15 minutes",
        "Your meal is ready",
        boundHelperEmail
      );
    });

    it("still authorizes fine with the raw token unchanged (regression)", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        fulfillmentBody(rawToken)
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe("placed");
      expect(stored?.fulfillerEmail).toBe(boundHelperEmail);
    });

    it("refuses without any participant credential or raw token", async () => {
      const { request } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody()
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(401);
      expect(context.body.error.code).toBe("PARTICIPANT_VERIFICATION_REQUIRED");
      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe("claimed");
    });

    it("refuses fulfillment of a differently owned reservation", async () => {
      const otherParticipantId = new mongoose.Types.ObjectId();
      const { request } = await createClaimedRequest({
        helperParticipantId: otherParticipantId,
      });
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(403);
      expect(context.body.error.code).toBe("INVALID_CLAIM_TOKEN");
      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe("claimed");
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("refuses fulfillment of a released reservation", async () => {
      const released = await MealRequest.create({
        vendor: "Transaction Cafe",
        food: "Rice bowl",
        pickupName: "Requester Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "open",
        expiresAt: new Date(Date.now() + 60 * 60 * 1000),
        deleteAt: new Date(Date.now() + 60 * 60 * 1000),
      });
      const context = routeContext(
        String(released._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(409);
      expect(context.body.error.code).toBe("REQUEST_NOT_CLAIMED");
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("refuses fulfillment of an expired reservation", async () => {
      const { request } = await createClaimedRequest({
        claimExpiresAt: new Date(Date.now() - 1),
      });
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(409);
      expect(context.body.error.code).toBe("CLAIM_EXPIRED");
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("refuses fulfillment of an already-placed reservation and cannot double-record it", async () => {
      const { request } = await createClaimedRequest({ status: "placed" });
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(409);
      expect(context.body.error.code).toBe("REQUEST_ALREADY_PLACED");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(0);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("participant-authorized fulfillment racing release remains one-winner and cannot reopen placement", async () => {
      const { request } = await createClaimedRequest();
      const release = routeContext(String(request._id), {}, continuationHeaders);
      const fulfill = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await Promise.all([
        releaseClaim(release.req, release.res),
        fulfillRequest(fulfill.req, fulfill.res),
      ]);

      const releaseWon = release.statusCode === 200;
      const fulfillWon = fulfill.statusCode === 200;
      expect(releaseWon !== fulfillWon).toBe(true);
      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe(releaseWon ? "open" : "placed");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(
        fulfillWon ? 1 : 0
      );
    });

    // The transactional rollback and one-active-reservation-lock-clearing
    // safeguards already proved above for the raw-token path are the same
    // production code path for participant-authority continuation — both
    // modes converge on the identical `persistCorePlacement` transaction —
    // so this proves the convergence itself rather than re-proving rollback
    // and lock-clearing from scratch.
    it("clears the verified helper's one-active-reservation lock via participant-authority continuation", async () => {
      const { request } = await createClaimedRequest();
      await Participant.updateOne(
        { _id: helperParticipantId },
        {
          $set: {
            activeReservationRequestId: request._id,
            activeReservationClaimExpiresAt: new Date(
              Date.now() + 60 * 60 * 1000
            ),
          },
        }
      ).exec();
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      const lock = await Participant.findById(helperParticipantId)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
        .lean();
      expect(lock?.activeReservationRequestId).toBeNull();
      expect(lock?.activeReservationClaimExpiresAt).toBeNull();
    });
  });

  // W4-U1.1: the helper's optional Message is filtered after authority/payload
  // validation and before the durable placement mutation. A match commits the
  // real placement exactly once as if no Message existed, stores nothing but a
  // content-free marker (atomically, in the placement update), and never emails
  // the Message. An allowed Message is transient email-only context.
  describe("W4-U1.1 helper Message filtering and content-free suppression", () => {
    const BLOCKED = "thanks you stupid bitch";
    const ALLOWED = "I'll shoot you a text when I'm at the front door";

    function bodyWith(rawToken: string, contactMessage?: string) {
      return {
        claimToken: rawToken,
        fulfillment: {
          orderNumber: "70154321",
          eta: "15 minutes",
          placedOrderScreenshot: validScreenshot(),
          ...(contactMessage === undefined ? {} : { contactMessage }),
        },
      };
    }

    /** The raw stored document, bypassing every Mongoose projection default. */
    function rawRequest(id: unknown) {
      return MealRequest.collection.findOne({ _id: id as mongoose.Types.ObjectId });
    }

    /** Whether any document in any collection of this database contains `text`. */
    async function databaseContains(text: string): Promise<boolean> {
      const db = mongoose.connection.db!;
      for (const { name } of await db.listCollections().toArray()) {
        const documents = await db.collection(name).find({}).toArray();
        if (JSON.stringify(documents).includes(text)) return true;
      }
      return false;
    }

    it("allowed Message: emailed, never persisted anywhere, no marker", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const context = routeContext(String(request._id), bodyWith(rawToken, ALLOWED));

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      expect(context.body).not.toHaveProperty("messageSuppressed");
      expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
      expect(sendFulfillmentEmail.mock.calls[0][3]).toBe(ALLOWED);

      const raw = await rawRequest(request._id);
      expect(raw).not.toHaveProperty("contactMessage");
      expect(raw).not.toHaveProperty("contactMessageSuppressed");
      expect(await databaseContains(ALLOWED)).toBe(false);
    });

    it("blocked Message: placement commits once, Message neither stored nor emailed, marker written atomically", async () => {
      const { request, rawToken } = await createClaimedRequest();
      await Participant.updateOne(
        { _id: helperParticipantId },
        {
          $set: {
            activeReservationRequestId: request._id,
            activeReservationClaimExpiresAt: new Date(Date.now() + 60 * 60 * 1000),
          },
        }
      ).exec();
      const context = routeContext(String(request._id), bodyWith(rawToken, BLOCKED));

      await fulfillRequest(context.req, context.res);

      // A successful placement, not a refusal.
      expect(context.statusCode).toBe(200);
      expect(context.body.request.status).toBe("placed");
      expect(context.body.notification).toEqual({ status: "sent" });
      expect(context.body.messageSuppressed).toBe(true);

      // The placement transaction's other effects are exactly as without a Message.
      const stored = await MealRequest.findById(request._id)
        .select("+contactMessageSuppressed")
        .lean();
      expect(stored?.status).toBe("placed");
      expect(stored?.orderNumber).toBe("70154321");
      expect(stored?.contactMessageSuppressed).toBe(true);
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      const lock = await Participant.findById(helperParticipantId)
        .select("+activeReservationRequestId")
        .lean();
      expect(lock?.activeReservationRequestId).toBeNull();

      // Content-free: the marker is a boolean; the blocked text exists nowhere.
      const raw = await rawRequest(request._id);
      expect(raw).not.toHaveProperty("contactMessage");
      expect(raw?.contactMessageSuppressed).toBe(true);
      expect(await databaseContains(BLOCKED)).toBe(false);
      expect(await databaseContains("stupid")).toBe(false);
      expect(await databaseContains("bitch")).toBe(false);

      // The requester email goes out normally, without the Message.
      expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
      expect(sendFulfillmentEmail.mock.calls[0][3]).toBeUndefined();
      expect(sendFulfillmentEmail.mock.calls[0][4]).toBe(boundHelperEmail);
    });

    it("a retry after a suppressed placement is REQUEST_ALREADY_PLACED: no second placement, ledger row, or email", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const first = routeContext(String(request._id), bodyWith(rawToken, BLOCKED));
      await fulfillRequest(first.req, first.res);
      expect(first.statusCode).toBe(200);

      const retry = routeContext(String(request._id), bodyWith(rawToken, BLOCKED));
      await fulfillRequest(retry.req, retry.res);

      expect(retry.statusCode).toBe(409);
      expect(retry.body.error.code).toBe("REQUEST_ALREADY_PLACED");
      expect(JSON.stringify(retry.body)).not.toMatch(/suppress|stupid|bitch/i);
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
    });

    it("requester-email failure cannot undo a suppressed placement or its marker", async () => {
      const { request, rawToken } = await createClaimedRequest();
      sendFulfillmentEmail.mockRejectedValueOnce(new Error("provider unavailable"));
      const context = routeContext(String(request._id), bodyWith(rawToken, BLOCKED));

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      expect(context.body.notification).toEqual({ status: "failed" });
      expect(context.body.messageSuppressed).toBe(true);
      const raw = await rawRequest(request._id);
      expect(raw?.status).toBe("placed");
      expect(raw?.notificationStatus).toBe("failed");
      expect(raw?.contactMessageSuppressed).toBe(true);
    });

    it("writes no marker when placement itself is refused (wrong token, expired claim)", async () => {
      const wrong = await createClaimedRequest();
      const expired = await createClaimedRequest({ claimExpiresAt: new Date(Date.now() - 1) });
      const wrongContext = routeContext(
        String(wrong.request._id),
        bodyWith(generateClaimToken(), BLOCKED)
      );
      const expiredContext = routeContext(
        String(expired.request._id),
        bodyWith(expired.rawToken, BLOCKED)
      );

      await fulfillRequest(wrongContext.req, wrongContext.res);
      await fulfillRequest(expiredContext.req, expiredContext.res);

      expect(wrongContext.statusCode).toBe(403);
      expect(expiredContext.statusCode).toBe(409);
      for (const id of [wrong.request._id, expired.request._id]) {
        const raw = await rawRequest(id);
        expect(raw?.status).toBe("claimed");
        expect(raw).not.toHaveProperty("contactMessageSuppressed");
      }
      expect(await Fulfillment.countDocuments()).toBe(0);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("same-flow placed-result recovery reports suppression only when the durable marker proves it", async () => {
      const suppressed = await createClaimedRequest();
      const suppressedContext = routeContext(
        String(suppressed.request._id),
        bodyWith(suppressed.rawToken, BLOCKED)
      );
      await fulfillRequest(suppressedContext.req, suppressedContext.res);
      expect(suppressedContext.statusCode).toBe(200);

      // The participant-scoped placed read the helper client uses for recovery.
      const recovery = routeContext("unused", undefined, continuationHeaders);
      await getActiveReservation(recovery.req, recovery.res);

      expect(recovery.body.reservation).toBeNull();
      expect(recovery.body.placement.request.id).toBe(String(suppressed.request._id));
      expect(recovery.body.placement.request.status).toBe("placed");
      expect(recovery.body.placement.messageSuppressed).toBe(true);
      // Never inside the public request projection, and no text anywhere.
      expect(recovery.body.placement.request).not.toHaveProperty("messageSuppressed");
      expect(JSON.stringify(recovery.body)).not.toMatch(/stupid|bitch|contactMessage/i);

      // A later placement with an allowed (or no) Message is not suppressed:
      // the field is simply absent, never an explicit false.
      await Participant.updateOne(
        { _id: helperParticipantId },
        { $unset: { activeReservationRequestId: 1, activeReservationClaimExpiresAt: 1 } }
      ).exec();
      const allowed = await createClaimedRequest();
      const allowedContext = routeContext(
        String(allowed.request._id),
        bodyWith(allowed.rawToken, ALLOWED)
      );
      await MealRequest.updateOne(
        { _id: suppressed.request._id },
        { $set: { placedAt: new Date(Date.now() - 60 * 60 * 1000) } }
      ).exec();
      await fulfillRequest(allowedContext.req, allowedContext.res);
      expect(allowedContext.statusCode).toBe(200);

      const later = routeContext("unused", undefined, continuationHeaders);
      await getActiveReservation(later.req, later.res);
      expect(later.body.placement.request.id).toBe(String(allowed.request._id));
      expect(later.body.placement).not.toHaveProperty("messageSuppressed");
    });

    it("never exposes the marker through the public request projection", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const context = routeContext(String(request._id), bodyWith(rawToken, BLOCKED));
      await fulfillRequest(context.req, context.res);

      // Selected explicitly, exactly as only the participant-scoped read does.
      const withMarker = await MealRequest.findById(request._id)
        .select("+contactMessageSuppressed")
        .lean();
      expect(withMarker?.contactMessageSuppressed).toBe(true);
      const publicDetail = buildPublicRequestDetailResponse(withMarker as any, new Date());
      expect(JSON.stringify(publicDetail)).not.toMatch(
        /suppress|contactMessage|stupid|bitch/i
      );

      // And an ordinary read does not even carry it.
      const ordinary = await MealRequest.findById(request._id).lean();
      expect(ordinary).not.toHaveProperty("contactMessageSuppressed");
    });

    it("a suppressed Message still commits the placement AND its evidence together", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const context = routeContext(String(request._id), bodyWith(rawToken, BLOCKED));

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      expect(context.body.messageSuppressed).toBe(true);
      expect((await MealRequest.findById(request._id).lean())?.status).toBe("placed");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(1);
    });
  });

  describe("W4-H1a required placed-order evidence", () => {
    const bigPngWithSize = (totalBytes: number) => {
      // Reuse the 1x1 PNG header/IHDR and stretch a valid IDAT: built by hand so
      // the cap boundary is exercised with a structurally valid image.
      const crcTable = new Uint32Array(256).map((_, n) => {
        let c = n;
        for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        return c >>> 0;
      });
      const crc32 = (buffer: Buffer) => {
        let crc = 0xffffffff;
        for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff]! ^ (crc >>> 8);
        return (crc ^ 0xffffffff) >>> 0;
      };
      const chunk = (type: string, data: Buffer) => {
        const length = Buffer.alloc(4);
        length.writeUInt32BE(data.length);
        const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
        const crc = Buffer.alloc(4);
        crc.writeUInt32BE(crc32(body));
        return Buffer.concat([length, body, crc]);
      };
      const ihdr = Buffer.alloc(13);
      ihdr.writeUInt32BE(1, 0);
      ihdr.writeUInt32BE(1, 4);
      ihdr[8] = 8;
      return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        chunk("IHDR", ihdr),
        chunk("IDAT", Buffer.alloc(totalBytes - 57, 0x2a)),
        chunk("IEND", Buffer.alloc(0)),
      ]);
    };

    const withoutEvidence = (rawToken: string) => {
      const body = fulfillmentBody(rawToken);
      delete (body.fulfillment as Record<string, unknown>).placedOrderScreenshot;
      return body;
    };

    it("creates the unique requestId and TTL indexes with the contracted names", async () => {
      const indexes = await PlacementEvidence.collection.indexes();
      expect(indexes).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            name: "placement_evidence_request_unique",
            key: { requestId: 1 },
            unique: true,
          }),
          expect.objectContaining({
            name: "placement_evidence_deleteAt_ttl",
            key: { deleteAt: 1 },
            expireAfterSeconds: 0,
          }),
        ])
      );
    });

    it("refuses a new fulfillment without evidence, in both shapes, leaving the claim untouched", async () => {
      for (const shape of ["token", "continuation"] as const) {
        const { request, rawToken } = await createClaimedRequest();
        const context =
          shape === "token"
            ? routeContext(String(request._id), withoutEvidence(rawToken))
            : routeContext(
                String(request._id),
                { fulfillment: { orderNumber: "70154321", eta: "15 minutes" } },
                continuationHeaders
              );

        await fulfillRequest(context.req, context.res);

        expect(context.statusCode).toBe(400);
        expect(context.body.error.code).toBe("INVALID_PLACED_ORDER_SCREENSHOT");
        const stored = await MealRequest.findById(request._id)
          .select("+claimTokenDigest")
          .lean();
        expect(stored?.status).toBe("claimed");
        expect(stored?.claimTokenDigest).toBeDefined();
        expect(stored).not.toHaveProperty("placedAt");
        expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(0);
        expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(0);
      }
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("refuses invalid and oversized evidence before any mutation", async () => {
      const invalid: unknown[] = [
        { ...validScreenshot(), mimeType: "image/heic" },
        { mimeType: "image/png", imageBase64: "!!not-base64!!" },
        { ...validScreenshot(), mimeType: "image/jpeg" },
        { mimeType: "image/png", imageBase64: bigPngWithSize(1_500_001).toString("base64") },
      ];
      for (const screenshot of invalid) {
        const { request, rawToken } = await createClaimedRequest();
        const body = fulfillmentBody(rawToken);
        body.fulfillment.placedOrderScreenshot = screenshot as never;
        const context = routeContext(String(request._id), body);

        await fulfillRequest(context.req, context.res);

        expect(context.statusCode).toBe(400);
        expect(context.body.error.code).toBe("INVALID_PLACED_ORDER_SCREENSHOT");
        expect((await MealRequest.findById(request._id).lean())?.status).toBe("claimed");
      }
      expect(await Fulfillment.countDocuments()).toBe(0);
      expect(await PlacementEvidence.countDocuments()).toBe(0);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("stores an image exactly at the 1,500,000-byte cap", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const body = fulfillmentBody(rawToken);
      body.fulfillment.placedOrderScreenshot = {
        mimeType: "image/png",
        imageBase64: bigPngWithSize(1_500_000).toString("base64"),
      };
      const context = routeContext(String(request._id), body);

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      const evidence = await PlacementEvidence.findOne({ requestId: request._id }).lean();
      expect(evidence?.byteLength).toBe(1_500_000);
    });

    it("keeps the image private: select:false by default, absent from every public projection and response", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const context = routeContext(String(request._id), fulfillmentBody(rawToken));
      await fulfillRequest(context.req, context.res);

      const ordinary = await PlacementEvidence.findOne({ requestId: request._id }).lean();
      expect(ordinary).not.toBeNull();
      expect(ordinary).not.toHaveProperty("image");

      const stored = await MealRequest.findById(request._id).lean();
      const publicDetail = buildPublicRequestDetailResponse(stored as any, new Date());
      const surfaces = JSON.stringify([
        context.body,
        publicDetail,
        sendFulfillmentEmail.mock.calls,
      ]);
      expect(surfaces).not.toContain(ONE_PIXEL_PNG_BASE64);
      expect(surfaces).not.toMatch(/placedOrderScreenshot|placementEvidence|imageBase64/i);
      // The Request document itself carries no copy either.
      expect(JSON.stringify(await MealRequest.collection.findOne({ _id: request._id as mongoose.Types.ObjectId }))).not.toContain(
        ONE_PIXEL_PNG_BASE64
      );
    });

    it("enforces one evidence row per Request at the database, and the size cap at the schema", async () => {
      const requestId = new mongoose.Types.ObjectId();
      const row = (overrides: Record<string, unknown> = {}) => ({
        requestId,
        image: Buffer.from("evidence"),
        mimeType: "image/jpeg",
        byteLength: 8,
        deleteAt: new Date(Date.now() + 60_000),
        ...overrides,
      });
      await PlacementEvidence.create(row());
      await expect(PlacementEvidence.create(row())).rejects.toMatchObject({ code: 11000 });
      expect(await PlacementEvidence.countDocuments({ requestId })).toBe(1);

      const other = new mongoose.Types.ObjectId();
      await expect(
        PlacementEvidence.create(
          row({ requestId: other, image: Buffer.alloc(1_500_001), byteLength: 1_500_001 })
        )
      ).rejects.toThrow(/exceeds the size cap|outside the size cap/);
      await expect(
        PlacementEvidence.create(row({ requestId: other, byteLength: 1_500_001 }))
      ).rejects.toThrow();
      await expect(
        PlacementEvidence.create(row({ requestId: other, mimeType: "image/heic" }))
      ).rejects.toThrow();
      expect(await PlacementEvidence.countDocuments({ requestId: other })).toBe(0);
    });

    it("aborts the WHOLE placement when the evidence insert fails: no placed Request, no ledger row, no evidence, lock intact, no email", async () => {
      // Forces only the evidence insert to fail: a unique index on `byteLength`
      // plus a pre-existing row of the same length for ANOTHER request.
      const forcedFailureIndex = "test_force_evidence_failure";
      await PlacementEvidence.collection.createIndex(
        { byteLength: 1 },
        { unique: true, name: forcedFailureIndex }
      );
      try {
        const byteLength = Buffer.from(ONE_PIXEL_PNG_BASE64, "base64").length;
        await PlacementEvidence.create({
          requestId: new mongoose.Types.ObjectId(),
          image: Buffer.alloc(byteLength, 1),
          mimeType: "image/png",
          byteLength,
          deleteAt: new Date(Date.now() + 60_000),
        });
        const lockExpiry = new Date(Date.now() + 15 * 60 * 1000);
        const { request, rawToken } = await createClaimedRequest();
        await Participant.updateOne(
          { _id: helperParticipantId },
          {
            $set: {
              activeReservationRequestId: request._id,
              activeReservationClaimExpiresAt: lockExpiry,
            },
          }
        ).exec();
        const context = routeContext(String(request._id), fulfillmentBody(rawToken));

        await fulfillRequest(context.req, context.res);

        expect(context.statusCode).toBe(500);
        expect(context.body.error.code).toBe("INTERNAL_FAILURE");
        const stored = await MealRequest.findById(request._id)
          .select("+claimTokenDigest")
          .lean();
        expect(stored?.status).toBe("claimed");
        expect(stored?.claimTokenDigest).toBeDefined();
        expect(stored).not.toHaveProperty("placedAt");
        expect(stored).not.toHaveProperty("orderNumber");
        expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(0);
        expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(0);
        // The reservation lock is part of the same transaction and is not cleared.
        const participant = await Participant.findById(helperParticipantId)
          .select("+activeReservationRequestId")
          .lean();
        expect(String(participant?.activeReservationRequestId)).toBe(String(request._id));
        expect(sendFulfillmentEmail).not.toHaveBeenCalled();
      } finally {
        await PlacementEvidence.collection.dropIndex(forcedFailureIndex);
        await Participant.updateOne(
          { _id: helperParticipantId },
          { $set: { activeReservationRequestId: null, activeReservationClaimExpiresAt: null } }
        ).exec();
      }
    });

    it("rolls back an evidence row that WAS inserted when the transaction aborts afterwards (the insert shares the placement session)", async () => {
      // The previous case fails the insert itself, which a session-less insert
      // would also survive. This one lets the insert succeed and then aborts the
      // transaction: the row can only disappear if it was written with the same
      // session as the placement.
      const realCreate = PlacementEvidence.create.bind(PlacementEvidence) as (
        ...args: unknown[]
      ) => Promise<unknown>;
      const spy = vi
        .spyOn(PlacementEvidence, "create")
        .mockImplementationOnce((async (...args: unknown[]) => {
          await realCreate(...args);
          expect(await PlacementEvidence.countDocuments({})).toBe(0); // uncommitted: invisible outside the session
          throw new Error("forced abort after the evidence insert");
        }) as never);
      try {
        const { request, rawToken } = await createClaimedRequest();
        const context = routeContext(String(request._id), fulfillmentBody(rawToken));

        await fulfillRequest(context.req, context.res);

        expect(spy).toHaveBeenCalledOnce();
        expect(context.statusCode).toBe(500);
        const stored = await MealRequest.findById(request._id).lean();
        expect(stored?.status).toBe("claimed");
        expect(stored).not.toHaveProperty("placedAt");
        expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(0);
        expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(0);
        expect(sendFulfillmentEmail).not.toHaveBeenCalled();
      } finally {
        spy.mockRestore();
      }
    });

    it("cannot replace or duplicate evidence after placement: a resend is REQUEST_ALREADY_PLACED and the original bytes remain", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const original = routeContext(String(request._id), fulfillmentBody(rawToken));
      await fulfillRequest(original.req, original.res);
      expect(original.statusCode).toBe(200);
      const before = await PlacementEvidence.findOne({ requestId: request._id })
        .select("+image")
        .lean();

      const replacement = fulfillmentBody(rawToken);
      replacement.fulfillment.placedOrderScreenshot = {
        mimeType: "image/png",
        imageBase64: bigPngWithSize(5_000).toString("base64"),
      };
      const resend = routeContext(String(request._id), replacement);
      await fulfillRequest(resend.req, resend.res);

      expect(resend.statusCode).toBe(409);
      expect(resend.body.error.code).toBe("REQUEST_ALREADY_PLACED");
      expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(1);
      const after = await PlacementEvidence.findOne({ requestId: request._id })
        .select("+image")
        .lean();
      expect(after?.byteLength).toBe(before?.byteLength);
      expect(Buffer.from((after!.image as any).buffer ?? after!.image).equals(
        Buffer.from((before!.image as any).buffer ?? before!.image)
      )).toBe(true);
    });

    it("two concurrent attempts with different images leave exactly one winner's evidence", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const first = fulfillmentBody(rawToken);
      const second = fulfillmentBody(rawToken);
      second.fulfillment.placedOrderScreenshot = {
        mimeType: "image/png",
        imageBase64: bigPngWithSize(4_000).toString("base64"),
      };
      const attempts = [
        routeContext(String(request._id), first),
        routeContext(String(request._id), second),
      ];

      await Promise.all(attempts.map((attempt) => fulfillRequest(attempt.req, attempt.res)));

      const winners = attempts.filter((attempt) => attempt.statusCode === 200);
      expect(winners).toHaveLength(1);
      expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(1);
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      const winnerBytes = winners[0] === attempts[0]
        ? Buffer.from(ONE_PIXEL_PNG_BASE64, "base64")
        : bigPngWithSize(4_000);
      const stored = await PlacementEvidence.findOne({ requestId: request._id })
        .select("+image")
        .lean();
      expect(Buffer.from((stored!.image as any).buffer ?? stored!.image).equals(winnerBytes)).toBe(true);
    });

    it("a wrong token or a wrong participant writes no evidence", async () => {
      const { request } = await createClaimedRequest();
      const wrongToken = routeContext(String(request._id), fulfillmentBody(generateClaimToken()));
      await fulfillRequest(wrongToken.req, wrongToken.res);
      expect(wrongToken.statusCode).toBe(403);

      const { request: otherOwned } = await createClaimedRequest({
        helperParticipantId: new mongoose.Types.ObjectId(),
      });
      const wrongParticipant = routeContext(
        String(otherOwned._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );
      await fulfillRequest(wrongParticipant.req, wrongParticipant.res);
      expect(wrongParticipant.statusCode).toBe(403);

      expect(await PlacementEvidence.countDocuments()).toBe(0);
      expect(await Fulfillment.countDocuments()).toBe(0);
    });

    it("commits evidence in the participant-continuation shape, bound to the placed Request", async () => {
      const { request } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      const evidence = await PlacementEvidence.findOne({ requestId: request._id }).lean();
      expect(evidence?.mimeType).toBe("image/png");
      expect((await MealRequest.findById(request._id).lean())?.deleteAt).toEqual(evidence?.deleteAt);
    });
  });
});
