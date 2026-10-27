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
  RequestParticipation,
} from "../models/db.js";
import {
  REQUEST_ALREADY_PARTICIPATED_CODE,
  claimRequest,
  releaseClaim,
} from "./claimRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_claim_participation`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

/**
 * Real verified participants, in the real collection, presenting real
 * credentials (W3-I1) — the W3-H2 invariant is about durable database state,
 * so the gate in front of it has to be the production one.
 *
 * Shares the runner's default database with `claimRoute.mongo.test.ts` and
 * `fulfillmentRoute.mongo.test.ts`: distinct ids and addresses, and never
 * deleted between cases, for the same reason those suites don't.
 */
const participantSecretText = "participation-mongo-participant-secret-32";
const participantSecret = Buffer.from(participantSecretText);
const firstHelperId = new mongoose.Types.ObjectId("64d0000000000000000000d1");
const firstHelperPrincipal = "participation-mongo-first@nyu.edu";
const firstAuthority = signParticipantAuthority(firstHelperId, 1, participantSecret);
const secondHelperId = new mongoose.Types.ObjectId("64d0000000000000000000d2");
const secondHelperPrincipal = "participation-mongo-second@nyu.edu";
const secondAuthority = signParticipantAuthority(secondHelperId, 1, participantSecret);

async function ensureVerifiedHelpers() {
  await Participant.updateOne(
    { _id: firstHelperId },
    {
      $set: { email: firstHelperPrincipal, verifiedAt: new Date() },
      $setOnInsert: { authorityVersion: 1 },
    },
    { upsert: true }
  ).exec();
  await Participant.updateOne(
    { _id: secondHelperId },
    {
      $set: { email: secondHelperPrincipal, verifiedAt: new Date() },
      $setOnInsert: { authorityVersion: 1 },
    },
    { upsert: true }
  ).exec();
}

function routeContext(
  id: string,
  body: unknown = undefined,
  authority: string = firstAuthority
) {
  const req = {
    params: { id },
    body,
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: authority },
  } as unknown as Request;
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

describeMongo("real MongoDB W3-H2 one-successful-participation invariant", () => {
  beforeAll(async () => {
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "real-mongo-participation-test-secret-32b"
    );
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await RequestParticipation.syncIndexes();
    await ensureVerifiedHelpers();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
    await RequestParticipation.deleteMany({});
    await Participant.updateMany(
      {},
      {
        $set: {
          activeReservationRequestId: null,
          activeReservationClaimExpiresAt: null,
        },
      }
    ).exec();
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  async function createClaimableRequest() {
    const now = new Date();
    const deadline = new Date(now.getTime() + 60 * 60 * 1000);
    return await MealRequest.create({
      vendor: "Participation Cafe",
      food: "Rice bowl",
      pickupName: "Only Winner Sees This",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
    });
  }

  it("enforces live-ID and HMAC participation uniqueness indexes", async () => {
    const indexes = await RequestParticipation.collection.indexes();
    expect(indexes).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          name: "request_participation_identity_live_unique",
          key: { requestId: 1, participantId: 1 },
          unique: true,
          partialFilterExpression: { participantId: { $type: "objectId" } },
        }),
        expect.objectContaining({
          name: "request_participation_hmac_unique",
          key: { requestId: 1, participationKeyVersion: 1, participationHmac: 1 },
          unique: true,
          partialFilterExpression: { participationHmac: { $type: "string" } },
        }),
      ])
    );
  });

  it("refuses a participant who released the reservation from ever reclaiming it again, while another participant may", async () => {
    const request = await createClaimableRequest();

    const claim = routeContext(String(request._id));
    await claimRequest(claim.req, claim.res);
    expect(claim.statusCode).toBe(200);
    const rawToken = claim.body.claim.claimToken as string;

    const release = routeContext(String(request._id), { claimToken: rawToken });
    await releaseClaim(release.req, release.res);
    expect(release.statusCode).toBe(200);

    const reclaim = routeContext(String(request._id));
    await claimRequest(reclaim.req, reclaim.res);

    expect(reclaim.statusCode).toBe(409);
    expect(reclaim.body.error.code).toBe(REQUEST_ALREADY_PARTICIPATED_CODE);
    expect(JSON.stringify(reclaim.body)).not.toMatch(/claimToken|pickupName/);

    const otherHelperClaim = routeContext(String(request._id), undefined, secondAuthority);
    await claimRequest(otherHelperClaim.req, otherHelperClaim.res);

    expect(otherHelperClaim.statusCode).toBe(200);
    expect(otherHelperClaim.body.claim.claimToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });

  it("refuses reclaiming after the original claim passively expired rather than being released", async () => {
    const request = await createClaimableRequest();
    const claim = routeContext(String(request._id));
    await claimRequest(claim.req, claim.res);
    expect(claim.statusCode).toBe(200);

    // Simulate passive expiry directly, rather than waiting out
    // `CLAIM_DURATION_MS`: the invariant must survive expiry exactly as it
    // survives an explicit release.
    await MealRequest.updateOne(
      { _id: request._id },
      { $set: { claimExpiresAt: new Date(Date.now() - 1000) } }
    ).exec();

    const reclaim = routeContext(String(request._id));
    await claimRequest(reclaim.req, reclaim.res);

    expect(reclaim.statusCode).toBe(409);
    expect(reclaim.body.error.code).toBe(REQUEST_ALREADY_PARTICIPATED_CODE);
  });

  it("does not consume participation for a raced attempt that never won authority", async () => {
    const request = await createClaimableRequest();
    const attempts = [
      routeContext(String(request._id), undefined, firstAuthority),
      routeContext(String(request._id), undefined, secondAuthority),
    ];

    await Promise.all(
      attempts.map((attempt) => claimRequest(attempt.req, attempt.res))
    );

    const winner = attempts.find((attempt) => attempt.statusCode === 200);
    const loser = attempts.find((attempt) => attempt.statusCode !== 200);
    expect(winner).toBeDefined();
    expect(loser).toBeDefined();
    expect(loser!.body.error.code).not.toBe(REQUEST_ALREADY_PARTICIPATED_CODE);

    const winningParticipantId =
      winner === attempts[0] ? firstHelperId : secondHelperId;
    const losingParticipantId =
      winner === attempts[0] ? secondHelperId : firstHelperId;

    const winningRow = await RequestParticipation.findOne({
      requestId: request._id,
      participantId: winningParticipantId,
    })
      .lean()
      .exec();
    const losingRow = await RequestParticipation.findOne({
      requestId: request._id,
      participantId: losingParticipantId,
    })
      .lean()
      .exec();
    expect(winningRow).not.toBeNull();
    expect(losingRow).toBeNull();
  });

  it("correctly refuses concurrent reacquisition attempts by the same prior holder", async () => {
    const request = await createClaimableRequest();
    const claim = routeContext(String(request._id));
    await claimRequest(claim.req, claim.res);
    expect(claim.statusCode).toBe(200);
    const rawToken = claim.body.claim.claimToken as string;

    const release = routeContext(String(request._id), { claimToken: rawToken });
    await releaseClaim(release.req, release.res);
    expect(release.statusCode).toBe(200);

    const reclaims = [
      routeContext(String(request._id)),
      routeContext(String(request._id)),
    ];
    await Promise.all(
      reclaims.map((attempt) => claimRequest(attempt.req, attempt.res))
    );

    for (const attempt of reclaims) {
      expect(attempt.statusCode).toBe(409);
      expect(attempt.body.error.code).toBe(REQUEST_ALREADY_PARTICIPATED_CODE);
    }

    const rows = await RequestParticipation.find({
      requestId: request._id,
      participantId: firstHelperId,
    })
      .lean()
      .exec();
    expect(rows).toHaveLength(1);
  });

  it("leaves H1's one-active-reservation-per-helper invariant intact alongside the new check", async () => {
    const first = await createClaimableRequest();
    const second = await createClaimableRequest();

    const firstClaim = routeContext(String(first._id));
    await claimRequest(firstClaim.req, firstClaim.res);
    expect(firstClaim.statusCode).toBe(200);

    // The same helper still cannot hold a second reservation elsewhere while
    // one is active — unrelated to, and unweakened by, the participation
    // check above.
    const secondClaim = routeContext(String(second._id));
    await claimRequest(secondClaim.req, secondClaim.res);
    expect(secondClaim.statusCode).toBe(409);
    expect(secondClaim.body.error.code).toBe(
      "HELPER_ALREADY_HAS_ACTIVE_RESERVATION"
    );

    const release = routeContext(String(first._id), {
      claimToken: firstClaim.body.claim.claimToken,
    });
    await releaseClaim(release.req, release.res);
    expect(release.statusCode).toBe(200);

    // A genuinely new request (never participated in) is claimable normally
    // once the lock clears.
    const freshClaim = routeContext(String(second._id));
    await claimRequest(freshClaim.req, freshClaim.res);
    expect(freshClaim.statusCode).toBe(200);
  });

  it("refuses a reacquisition attempt presenting a newly issued authority for the same participant principal, not a reused credential", async () => {
    // Proves enforcement keys off `participantId` in the durable
    // `RequestParticipation` row, not off the literal credential bytes: the
    // reclaim below presents a wholly distinct signed authority string (a
    // different `authorityVersion`, as a real reissue after reverification
    // would produce), yet still resolves to the same principal and is still
    // refused.
    const request = await createClaimableRequest();

    const claim = routeContext(String(request._id));
    await claimRequest(claim.req, claim.res);
    expect(claim.statusCode).toBe(200);
    const rawToken = claim.body.claim.claimToken as string;

    const release = routeContext(String(request._id), { claimToken: rawToken });
    await releaseClaim(release.req, release.res);
    expect(release.statusCode).toBe(200);

    await Participant.updateOne(
      { _id: firstHelperId },
      { $set: { authorityVersion: 2 } }
    ).exec();
    const reissuedAuthority = signParticipantAuthority(
      firstHelperId,
      2,
      participantSecret
    );
    expect(reissuedAuthority).not.toBe(firstAuthority);

    const reclaim = routeContext(
      String(request._id),
      undefined,
      reissuedAuthority
    );
    await claimRequest(reclaim.req, reclaim.res);

    expect(reclaim.statusCode).toBe(409);
    expect(reclaim.body.error.code).toBe(REQUEST_ALREADY_PARTICIPATED_CODE);

    // Restore the shared fixture's stored version so later tests in this
    // file that reuse `firstAuthority` (signed at version 1) keep resolving.
    await Participant.updateOne(
      { _id: firstHelperId },
      { $set: { authorityVersion: 1 } }
    ).exec();
  });
});
