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
import { Participant, Request as MealRequest } from "../models/db.js";
import {
  CLAIM_EXTENSION_MS,
  HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE,
  REQUEST_OWN_REQUEST_CODE,
  claimRequest,
  extendClaim,
  releaseClaim,
} from "./claimRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((fulfill) => {
    resolve = fulfill;
  });
  return { promise, resolve };
}

/**
 * A real verified helper, in the real collection, presenting a real credential
 * (W3-I1). The concurrency claims below are about the claim mutation, so the
 * gate in front of it has to be the production one rather than a stub.
 *
 * Its own address and id, and never deleted between cases: this suite shares
 * the runner's default database with the fulfillment suite, and the unique
 * address index would otherwise let one suite's cleanup break the other's.
 */
const participantSecretText = "claim-mongo-participant-signing-secret-32";
const participantSecret = Buffer.from(participantSecretText);
const helperParticipantId = new mongoose.Types.ObjectId(
  "64d0000000000000000000c1"
);
const helperPrincipal = "claim-mongo-helper@nyu.edu";
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);

/** A second, independent verified helper (W3-H1: different principals must
 * be able to reserve independently). */
const secondHelperParticipantId = new mongoose.Types.ObjectId(
  "64d0000000000000000000c2"
);
const secondHelperPrincipal = "claim-mongo-second-helper@nyu.edu";
const secondParticipantAuthority = signParticipantAuthority(
  secondHelperParticipantId,
  1,
  participantSecret
);

async function ensureVerifiedHelper() {
  await Participant.updateOne(
    { _id: helperParticipantId },
    {
      $set: { email: helperPrincipal, verifiedAt: new Date() },
      $setOnInsert: { authorityVersion: 1 },
    },
    { upsert: true }
  ).exec();
  await Participant.updateOne(
    { _id: secondHelperParticipantId },
    {
      $set: { email: secondHelperPrincipal, verifiedAt: new Date() },
      $setOnInsert: { authorityVersion: 1 },
    },
    { upsert: true }
  ).exec();
}

function routeContext(
  id: string,
  body?: unknown,
  authority: string = participantAuthority
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

describeMongo("real MongoDB claim atomicity", () => {
  beforeAll(async () => {
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "real-mongo-test-secret-material-32-bytes"
    );
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await ensureVerifiedHelper();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
    // The two helper Participant rows persist across cases (their unique
    // `email` index is what makes recreating them per case unsafe); their
    // one-active-reservation lock must not, or one case's reservation would
    // wrongly block the next case's.
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
      vendor: "Concurrency Cafe",
      food: "Rice bowl",
      pickupName: "Only Winner Sees This",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
    });
  }

  it("creates only the deleteAt TTL index", async () => {
    const indexes = await MealRequest.collection.indexes();
    const ttlIndexes = indexes.filter(
      (index) => index.expireAfterSeconds !== undefined
    );

    expect(ttlIndexes).toEqual([
      expect.objectContaining({
        name: "request_deleteAt_ttl",
        key: { deleteAt: 1 },
        expireAfterSeconds: 0,
      }),
    ]);
    expect(indexes).not.toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          key: { expiresAt: 1 },
          expireAfterSeconds: 0,
        }),
      ])
    );
  });

  it("allows exactly one concurrent claim and issues claimant data only once", async () => {
    const request = await createClaimableRequest();
    const attempts = [
      routeContext(String(request._id)),
      routeContext(String(request._id)),
    ];

    await Promise.all(
      attempts.map((attempt) => claimRequest(attempt.req, attempt.res))
    );

    const winners = attempts.filter(
      (attempt) => attempt.statusCode === 200 && attempt.body?.claim
    );
    // Same participant, same target, concurrently: the loser's retry (after
    // a write conflict on the target document) may now find, via the W3-H1
    // rollout-compatibility read, that this exact participant already holds
    // the reservation the winner just won — `HELPER_ALREADY_HAS_ACTIVE_RESERVATION`
    // — rather than the ordinary "someone else" `REQUEST_ALREADY_CLAIMED`.
    // Both are truthful 409 refusals for this exact interleaving; which one
    // lands is a timing detail of whether the retry observes the winner's
    // commit, not a correctness distinction this test asserts.
    const losers = attempts.filter(
      (attempt) =>
        attempt.statusCode === 409 &&
        (attempt.body?.error?.code === "REQUEST_ALREADY_CLAIMED" ||
          attempt.body?.error?.code ===
            HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE)
    );
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(winners[0].body.claim.claimToken).toMatch(
      /^[A-Za-z0-9_-]{43}$/
    );
    // W4-R4: pickup name is gone from the request contract, so even the
    // winning claimant's private half no longer carries one. The fixture
    // still sets the field, so this proves removal rather than absent input.
    expect(winners[0].body.claim).not.toHaveProperty("pickupName");
    expect(JSON.stringify(winners[0].body)).not.toMatch(/Only Winner/);
    expect(JSON.stringify(losers[0].body)).not.toMatch(
      /pickupName|claimToken|Only Winner/
    );

    const stored = await MealRequest.collection.findOne({
      // Raw-driver boundary: mongoose types `_id` as `unknown`, while the
      // driver's filter expects an ObjectId.
      _id: request._id as mongoose.Types.ObjectId,
    });
    expect(stored?.status).toBe("claimed");
    expect(stored?.claimTokenDigest).toMatch(/^[a-f0-9]{64}$/);
    expect(stored?.claimTokenDigest).not.toBe(
      winners[0].body.claim.claimToken
    );
    expect(stored).not.toHaveProperty("claimToken");
  });

  it("authoritatively refuses a verified participant claiming their own request (W4-H2)", async () => {
    const now = new Date();
    const deadline = new Date(now.getTime() + 60 * 60 * 1000);
    const request = await MealRequest.create({
      vendor: "Concurrency Cafe",
      food: "Rice bowl",
      pickupName: "Only Winner Sees This",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
      requesterParticipantId: helperParticipantId,
    });

    const attempt = routeContext(String(request._id));
    await claimRequest(attempt.req, attempt.res);

    expect(attempt.statusCode).toBe(409);
    expect(attempt.body?.error?.code).toBe(REQUEST_OWN_REQUEST_CODE);
    expect(JSON.stringify(attempt.body)).not.toMatch(
      /pickupName|claimToken|Only Winner/
    );

    // No reservation side effect for the rejected self-claim, and no
    // durable participation record either.
    const stored = await MealRequest.collection.findOne({
      _id: request._id as mongoose.Types.ObjectId,
    });
    expect(stored?.status).toBe("open");
    expect(stored?.claimTokenDigest).toBeUndefined();

    // A different eligible participant can still claim it normally.
    const otherAttempt = routeContext(
      String(request._id),
      undefined,
      secondParticipantAuthority
    );
    await claimRequest(otherAttempt.req, otherAttempt.res);
    expect(otherAttempt.statusCode).toBe(200);
    expect(otherAttempt.body?.claim).not.toHaveProperty("pickupName");
    expect(otherAttempt.body?.claim?.claimToken).toEqual(expect.any(String));
  });

  it("allows exactly one of two concurrent extension attempts", async () => {
    const request = await createClaimableRequest();
    const claim = routeContext(String(request._id));
    await claimRequest(claim.req, claim.res);
    expect(claim.statusCode).toBe(200);
    const rawToken = claim.body.claim.claimToken as string;
    const originalExpiration = new Date(
      claim.body.claim.claimExpiresAt
    ).getTime();

    const attempts = [
      routeContext(String(request._id), { claimToken: rawToken }),
      routeContext(String(request._id), { claimToken: rawToken }),
    ];
    await Promise.all(
      attempts.map((attempt) => extendClaim(attempt.req, attempt.res))
    );

    const winners = attempts.filter(
      (attempt) => attempt.statusCode === 200 && attempt.body?.claim
    );
    const losers = attempts.filter(
      (attempt) =>
        attempt.statusCode === 409 &&
        attempt.body?.error?.code === "CLAIM_EXTENSION_ALREADY_USED"
    );
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(
      new Date(winners[0].body.claim.claimExpiresAt).getTime()
    ).toBe(originalExpiration + CLAIM_EXTENSION_MS);
    expect(JSON.stringify(winners[0].body)).not.toMatch(
      /claimToken|pickupName|request/
    );
    expect(JSON.stringify(losers[0].body)).not.toMatch(
      /claimToken|pickupName/
    );
  });

  it("caps a new claim at the original request expiration", async () => {
    const claimInstant = new Date();
    const deadline = new Date(claimInstant.getTime() + 7 * 60 * 1000);
    const request = await MealRequest.create({
      vendor: "Short Window Cafe",
      food: "Soup",
      pickupName: "Short Window Winner",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
    });
    const claim = routeContext(String(request._id));

    await claimRequest(claim.req, claim.res);

    expect(claim.statusCode).toBe(200);
    expect(new Date(claim.body.claim.claimExpiresAt)).toEqual(deadline);
  });

  it("atomically replaces an expired claim and resets one-time extension state", async () => {
    const mutationInstant = new Date();
    const deadline = new Date(mutationInstant.getTime() + 60 * 60 * 1000);
    const oldDigest = "a".repeat(64);
    const request = await MealRequest.create({
      vendor: "Replacement Cafe",
      food: "Salad",
      pickupName: "Replacement Winner",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "claimed",
      expiresAt: deadline,
      deleteAt: deadline,
      claimedAt: new Date(mutationInstant.getTime() - 30 * 60 * 1000),
      claimExpiresAt: new Date(mutationInstant.getTime() - 1),
      claimExtendedAt: new Date(mutationInstant.getTime() - 20 * 60 * 1000),
      claimTokenDigest: oldDigest,
    });
    const replacement = routeContext(String(request._id));

    await claimRequest(replacement.req, replacement.res);

    expect(replacement.statusCode).toBe(200);
    const stored = await MealRequest.collection.findOne({
      // Raw-driver boundary: mongoose types `_id` as `unknown`, while the
      // driver's filter expects an ObjectId.
      _id: request._id as mongoose.Types.ObjectId,
    });
    expect(stored?.claimExtendedAt).toBeNull();
    expect(stored?.claimTokenDigest).not.toBe(oldDigest);
    expect(stored?.claimedAt.getTime()).toBeGreaterThan(
      mutationInstant.getTime() - 1000
    );
  });
});

describeMongo("real MongoDB one-active-reservation lock (W3-H1)", () => {
  beforeAll(async () => {
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "real-mongo-test-h1-secret-material-32b"
    );
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await ensureVerifiedHelper();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
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

  async function createClaimableRequest(pickupName: string) {
    const now = new Date();
    const deadline = new Date(now.getTime() + 60 * 60 * 1000);
    return await MealRequest.create({
      vendor: "H1 Lock Cafe",
      food: "Grain bowl",
      pickupName,
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
    });
  }

  it("allows only one of two concurrent reservations by the same verified helper on different requests", async () => {
    const requestA = await createClaimableRequest("Winner A");
    const requestB = await createClaimableRequest("Winner B");

    const attempts = [
      routeContext(String(requestA._id)),
      routeContext(String(requestB._id)),
    ];
    await Promise.all(
      attempts.map((attempt) => claimRequest(attempt.req, attempt.res))
    );

    const winners = attempts.filter((attempt) => attempt.statusCode === 200);
    const losers = attempts.filter(
      (attempt) =>
        attempt.statusCode === 409 &&
        attempt.body?.error?.code ===
          HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE
    );
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);

    // The losing attempt's target request must still be open: the target-
    // request conditional mutation and the reservation lock are one
    // transaction, so a refused lock leaves nothing claimed behind.
    const loserRequestId =
      losers[0].req.params.id === String(requestA._id)
        ? requestA._id
        : requestB._id;
    const loserStored = await MealRequest.collection.findOne({
      _id: loserRequestId as mongoose.Types.ObjectId,
    });
    expect(loserStored?.status).toBe("open");

    const lock = await Participant.findById(helperParticipantId)
      .select("+activeReservationRequestId")
      .lean()
      .exec();
    const winnerRequestId =
      winners[0].req.params.id === String(requestA._id)
        ? requestA._id
        : requestB._id;
    expect(String(lock?.activeReservationRequestId)).toBe(
      String(winnerRequestId)
    );
  });

  it("lets a different verified helper reserve independently", async () => {
    const requestA = await createClaimableRequest("Helper One's Meal");
    const requestB = await createClaimableRequest("Helper Two's Meal");

    const first = routeContext(String(requestA._id));
    const second = routeContext(String(requestB._id), undefined, secondParticipantAuthority);
    await Promise.all([
      claimRequest(first.req, first.res),
      claimRequest(second.req, second.res),
    ]);

    expect(first.statusCode).toBe(200);
    expect(second.statusCode).toBe(200);
  });

  it("does not block a new reservation once the earlier one has expired", async () => {
    const expired = await MealRequest.create({
      vendor: "H1 Lock Cafe",
      food: "Grain bowl",
      pickupName: "Already Expired",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "claimed",
      expiresAt: new Date(Date.now() + 60 * 60 * 1000),
      deleteAt: new Date(Date.now() + 60 * 60 * 1000),
      claimedAt: new Date(Date.now() - 20 * 60 * 1000),
      claimExpiresAt: new Date(Date.now() - 60 * 1000),
      claimTokenDigest: "b".repeat(64),
      helperParticipantId,
    });
    await Participant.updateOne(
      { _id: helperParticipantId },
      {
        $set: {
          activeReservationRequestId: expired._id,
          activeReservationClaimExpiresAt: new Date(Date.now() - 60 * 1000),
        },
      }
    ).exec();

    const nextRequest = await createClaimableRequest("Fresh Reservation");
    const attempt = routeContext(String(nextRequest._id));

    await claimRequest(attempt.req, attempt.res);

    expect(attempt.statusCode).toBe(200);
  });

  // Rollout-compatibility (independent-review MUST FIX): a claim granted
  // before the Participant lock existed never wrote
  // `activeReservationRequestId` at all — this reproduces that exact row
  // shape by binding a live Request to the helper without ever touching the
  // Participant document, so the lock-only check alone would read this
  // participant as lock-free.
  it("refuses a new claim when the verified helper already holds a live pre-H1-bound request with no Participant lock written", async () => {
    const legacyBoundRequest = await MealRequest.create({
      vendor: "H1 Lock Cafe",
      food: "Grain bowl",
      pickupName: "Pre-H1 Reservation",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "claimed",
      expiresAt: new Date(Date.now() + 60 * 60 * 1000),
      deleteAt: new Date(Date.now() + 60 * 60 * 1000),
      claimedAt: new Date(),
      claimExpiresAt: new Date(Date.now() + 15 * 60 * 1000),
      claimTokenDigest: "c".repeat(64),
      helperParticipantId,
    });
    const lockBefore = await Participant.findById(helperParticipantId)
      .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
      .lean()
      .exec();
    expect(lockBefore?.activeReservationRequestId).toBeNull();

    const nextRequest = await createClaimableRequest("Second Attempt");
    const attempt = routeContext(String(nextRequest._id));

    await claimRequest(attempt.req, attempt.res);

    expect(attempt.statusCode).toBe(409);
    expect(attempt.body?.error?.code).toBe(
      HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE
    );
    const nextStored = await MealRequest.collection.findOne({
      _id: nextRequest._id as mongoose.Types.ObjectId,
    });
    expect(nextStored?.status).toBe("open");
    const legacyStillLive = await MealRequest.collection.findOne({
      _id: legacyBoundRequest._id as mongoose.Types.ObjectId,
    });
    expect(legacyStillLive?.status).toBe("claimed");
  });

  describe("extension versus a later reservation lock (independent-review MUST FIX 2)", () => {
    // The delayed-extension race: old claim approaches expiry, a later
    // reservation for the same participant acquires the Participant lock,
    // and the old, now-stale extension attempt finally resumes. This
    // manufactures the end state a genuinely delayed extension could resume
    // into directly — Request A's own state is left exactly as claiming it
    // produced (still reading as claimed and unexpired, an artifact of this
    // manufactured setup rather than something reachable through the normal
    // routes given the rollout-compatibility check above), while the
    // Participant lock has already moved to a real, live Request B — and
    // proves the real transactional `extendClaim` refuses to commit A's
    // renewal rather than silently extending it while B holds the lock,
    // which would otherwise let a stale extension keep two reservations
    // alive for one participant.
    it("refuses to commit A's renewal once the lock has moved to a later claim", async () => {
      const requestA = await createClaimableRequest("Old Claim A");
      const claimA = routeContext(String(requestA._id));
      await claimRequest(claimA.req, claimA.res);
      expect(claimA.statusCode).toBe(200);
      const rawTokenA = claimA.body.claim.claimToken as string;

      const requestB = await createClaimableRequest("Later Claim B");
      // Simulates "a later reservation acquires the participant lock":
      // granted directly, bypassing A's still-live Request state, exactly
      // as the delayed extension's resumed commit would find things — A's
      // own claimExpiresAt is untouched here and still in the future.
      await MealRequest.updateOne(
        { _id: requestB._id },
        {
          $set: {
            status: "claimed",
            claimedAt: new Date(),
            claimExpiresAt: new Date(Date.now() + 15 * 60 * 1000),
            claimTokenDigest: "d".repeat(64),
            helperParticipantId,
          },
        }
      ).exec();
      await Participant.updateOne(
        { _id: helperParticipantId },
        {
          $set: {
            activeReservationRequestId: requestB._id,
            activeReservationClaimExpiresAt: new Date(
              Date.now() + 15 * 60 * 1000
            ),
          },
        }
      ).exec();

      const storedABefore = await MealRequest.collection.findOne({
        _id: requestA._id as mongoose.Types.ObjectId,
      });

      // The delayed old extension resumes.
      const extend = routeContext(String(requestA._id), {
        claimToken: rawTokenA,
      });
      await extendClaim(extend.req, extend.res);

      expect(extend.statusCode).not.toBe(200);
      const storedAAfter = await MealRequest.collection.findOne({
        _id: requestA._id as mongoose.Types.ObjectId,
      });
      // Not renewed: the whole transaction rolled back, so A's deadline is
      // byte-for-byte what it was before the resumed extension attempt —
      // the one-time extension was never granted and remains available to
      // whoever legitimately still owns this reservation.
      expect(storedAAfter?.claimExpiresAt).toEqual(
        storedABefore?.claimExpiresAt
      );
      expect(storedAAfter?.claimExtendedAt).toBeNull();

      // The lock itself is untouched by the refused extension: it still
      // points to B, exactly as this scenario set up, and B's own mirrored
      // deadline was not overwritten by A's rolled-back attempt.
      const lock = await Participant.findById(helperParticipantId)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
        .lean()
        .exec();
      expect(String(lock?.activeReservationRequestId)).toBe(
        String(requestB._id)
      );
    });

    it("self-heals a pre-H1-bound claim's never-written lock on its first extension", async () => {
      // The claim itself is real and current (granted through the normal
      // route), but its Participant lock was never written — reproducing
      // the pre-H1 rollout gap directly. Preserved safe handling requires
      // this extension to still succeed and to establish the lock rather
      // than refuse a legitimate helper.
      const request = await createClaimableRequest("Pre-H1 Bound Claim");
      const claim = routeContext(String(request._id));
      await claimRequest(claim.req, claim.res);
      expect(claim.statusCode).toBe(200);
      const rawToken = claim.body.claim.claimToken as string;
      await Participant.updateOne(
        { _id: helperParticipantId },
        {
          $set: {
            activeReservationRequestId: null,
            activeReservationClaimExpiresAt: null,
          },
        }
      ).exec();

      const extend = routeContext(String(request._id), { claimToken: rawToken });
      await extendClaim(extend.req, extend.res);

      expect(extend.statusCode).toBe(200);
      const lock = await Participant.findById(helperParticipantId)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
        .lean()
        .exec();
      expect(String(lock?.activeReservationRequestId)).toBe(
        String(request._id)
      );
      expect(lock?.activeReservationClaimExpiresAt).toEqual(
        extend.body.claim.claimExpiresAt
      );
    });
  });

  describe("release versus extension reservation-version CAS", () => {
    async function claimWithMarker(
      marker: "absent" | "null" | "date"
    ) {
      const request = await createClaimableRequest(`CAS ${marker}`);
      const claim = routeContext(String(request._id));
      await claimRequest(claim.req, claim.res);
      expect(claim.statusCode).toBe(200);
      const rawToken = claim.body.claim.claimToken as string;

      if (marker === "absent") {
        await MealRequest.collection.updateOne(
          { _id: request._id as mongoose.Types.ObjectId },
          { $unset: { claimExtendedAt: 1 } }
        );
      } else if (marker === "date") {
        const extension = routeContext(String(request._id), { claimToken: rawToken });
        await extendClaim(extension.req, extension.res);
        expect(extension.statusCode).toBe(200);
      }

      return { request, rawToken };
    }

    it.each(["absent", "null", "date"] as const)(
      "releases a current claim with a physically %s extension marker",
      async (marker) => {
        const { request, rawToken } = await claimWithMarker(marker);
        const before = await MealRequest.collection.findOne({
          _id: request._id as mongoose.Types.ObjectId,
        });
        if (marker === "absent") {
          expect(before).not.toHaveProperty("claimExtendedAt");
        } else if (marker === "null") {
          expect(before?.claimExtendedAt).toBeNull();
        } else {
          expect(before?.claimExtendedAt).toBeInstanceOf(Date);
        }

        const release = routeContext(String(request._id), { claimToken: rawToken });
        await releaseClaim(release.req, release.res);

        expect(release.statusCode).toBe(200);
        const after = await MealRequest.collection.findOne({
          _id: request._id as mongoose.Types.ObjectId,
        });
        expect(after?.status).toBe("open");
      }
    );

    it.each([
      {
        name: "explicit-null CAS does not match a physically absent marker",
        captured: "null" as const,
        mutation: { $unset: { claimExtendedAt: 1 } },
      },
      {
        name: "absent CAS does not match an explicit-null marker",
        captured: "absent" as const,
        mutation: { $set: { claimExtendedAt: null } },
      },
      {
        name: "date CAS does not match a different captured date",
        captured: "date" as const,
        mutation: { $set: { claimExtendedAt: new Date("2026-08-09T00:00:00.000Z") } },
      },
    ])("$name", async ({ captured, mutation }) => {
      const { request, rawToken } = await claimWithMarker(captured);
      const versionCaptured = deferred();
      const releaseMayContinue = deferred();
      const originalFindById = MealRequest.findById;
      const findByIdSpy = vi
        .spyOn(MealRequest, "findById")
        .mockImplementation(((...args: any[]) => {
          const query = originalFindById.apply(MealRequest, args as any) as any;
          const originalExec = query.exec.bind(query);
          query.exec = async () => {
            const result = await originalExec();
            versionCaptured.resolve();
            await releaseMayContinue.promise;
            return result;
          };
          return query;
        }) as any);
      const release = routeContext(String(request._id), { claimToken: rawToken });

      try {
        const releasePromise = releaseClaim(release.req, release.res);
        await versionCaptured.promise;
        await MealRequest.collection.updateOne(
          { _id: request._id as mongoose.Types.ObjectId },
          mutation
        );
        releaseMayContinue.resolve();
        await releasePromise;
      } finally {
        releaseMayContinue.resolve();
        findByIdSpy.mockRestore();
      }

      expect(release.statusCode).not.toBe(200);
      const stored = await MealRequest.collection.findOne({
        _id: request._id as mongoose.Types.ObjectId,
      });
      expect(stored?.status).toBe("claimed");
      if (captured === "null") {
        expect(stored).not.toHaveProperty("claimExtendedAt");
      } else if (captured === "absent") {
        expect(stored?.claimExtendedAt).toBeNull();
      } else {
        expect(stored?.claimExtendedAt).toEqual(
          (mutation as { $set: { claimExtendedAt: Date } }).$set.claimExtendedAt
        );
      }
    });

    it("lets extension win without allowing the stale racing release to adopt its newer version", async () => {
      const request = await createClaimableRequest("Extension Wins");
      const claim = routeContext(String(request._id));
      await claimRequest(claim.req, claim.res);
      expect(claim.statusCode).toBe(200);
      const rawToken = claim.body.claim.claimToken as string;
      const originalExpiration = new Date(claim.body.claim.claimExpiresAt);

      // Hold release immediately after its real Mongo version read. Extension
      // then commits while release is still in flight; when release resumes,
      // its immutable pre-transaction CAS must miss the newer deadline rather
      // than silently adopting it as a withTransaction retry otherwise could.
      const versionCaptured = deferred();
      const releaseMayContinue = deferred();
      const originalFindById = MealRequest.findById;
      const findByIdSpy = vi
        .spyOn(MealRequest, "findById")
        .mockImplementation(((...args: any[]) => {
          const query = originalFindById.apply(MealRequest, args as any) as any;
          const originalExec = query.exec.bind(query);
          query.exec = async () => {
            const result = await originalExec();
            versionCaptured.resolve();
            await releaseMayContinue.promise;
            return result;
          };
          return query;
        }) as any);

      const release = routeContext(String(request._id), {
        claimToken: rawToken,
      });
      const extension = routeContext(String(request._id), {
        claimToken: rawToken,
      });

      try {
        const releasePromise = releaseClaim(release.req, release.res);
        await versionCaptured.promise;

        const extensionPromise = extendClaim(extension.req, extension.res);
        await extensionPromise;
        expect(extension.statusCode).toBe(200);

        releaseMayContinue.resolve();
        await Promise.all([releasePromise, extensionPromise]);
      } finally {
        releaseMayContinue.resolve();
        findByIdSpy.mockRestore();
      }

      expect(
        Number(release.statusCode === 200) +
          Number(extension.statusCode === 200)
      ).toBe(1);
      expect(release.statusCode).not.toBe(200);

      const stored = await MealRequest.findById(request._id)
        .select("+helperParticipantId")
        .lean();
      expect(stored?.status).toBe("claimed");
      expect(stored?.claimExtendedAt).toBeTruthy();
      expect(stored?.claimExpiresAt).toEqual(
        new Date(originalExpiration.getTime() + CLAIM_EXTENSION_MS)
      );
      expect(String(stored?.helperParticipantId)).toBe(
        String(helperParticipantId)
      );

      const lock = await Participant.findById(helperParticipantId)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
        .lean();
      expect(String(lock?.activeReservationRequestId)).toBe(
        String(request._id)
      );
      expect(lock?.activeReservationClaimExpiresAt).toEqual(
        stored?.claimExpiresAt
      );
    });

    it("lets release win without allowing the already-started extension to succeed afterward", async () => {
      const request = await createClaimableRequest("Release Wins");
      const claim = routeContext(String(request._id));
      await claimRequest(claim.req, claim.res);
      expect(claim.statusCode).toBe(200);
      const rawToken = claim.body.claim.claimToken as string;

      // Pause only the extension pipeline's real Mongo execution after the
      // route has started. Release commits while that operation is in flight;
      // the resumed extension must then miss `status: claimed`.
      const extensionReady = deferred();
      const extensionMayContinue = deferred();
      const originalFindOneAndUpdate = MealRequest.findOneAndUpdate;
      const mutationSpy = vi
        .spyOn(MealRequest, "findOneAndUpdate")
        .mockImplementation(((...args: any[]) => {
          const query = originalFindOneAndUpdate.apply(
            MealRequest,
            args as any
          ) as any;
          if (Array.isArray(args[1])) {
            const originalExec = query.exec.bind(query);
            query.exec = async () => {
              extensionReady.resolve();
              await extensionMayContinue.promise;
              return await originalExec();
            };
          }
          return query;
        }) as any);

      const extension = routeContext(String(request._id), {
        claimToken: rawToken,
      });
      const release = routeContext(String(request._id), {
        claimToken: rawToken,
      });

      try {
        const extensionPromise = extendClaim(extension.req, extension.res);
        await extensionReady.promise;

        const releasePromise = releaseClaim(release.req, release.res);
        await releasePromise;
        expect(release.statusCode).toBe(200);

        extensionMayContinue.resolve();
        await Promise.all([extensionPromise, releasePromise]);
      } finally {
        extensionMayContinue.resolve();
        mutationSpy.mockRestore();
      }

      expect(
        Number(release.statusCode === 200) +
          Number(extension.statusCode === 200)
      ).toBe(1);
      expect(extension.statusCode).not.toBe(200);

      const stored = await MealRequest.findById(request._id)
        .select("+helperParticipantId +claimTokenDigest")
        .lean();
      expect(stored?.status).toBe("open");
      expect(stored).not.toHaveProperty("claimExpiresAt");
      expect(stored).not.toHaveProperty("claimExtendedAt");
      expect(stored).not.toHaveProperty("helperParticipantId");
      expect(stored).not.toHaveProperty("claimTokenDigest");

      const lock = await Participant.findById(helperParticipantId)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
        .lean();
      expect(lock?.activeReservationRequestId).toBeNull();
      expect(lock?.activeReservationClaimExpiresAt).toBeNull();
    });

    it("allows a sequential release that starts after extension completed", async () => {
      const request = await createClaimableRequest(
        "Sequential Extended Release"
      );
      const claim = routeContext(String(request._id));
      await claimRequest(claim.req, claim.res);
      expect(claim.statusCode).toBe(200);
      const rawToken = claim.body.claim.claimToken as string;

      const extension = routeContext(String(request._id), {
        claimToken: rawToken,
      });
      await extendClaim(extension.req, extension.res);
      expect(extension.statusCode).toBe(200);

      const release = routeContext(String(request._id), {
        claimToken: rawToken,
      });
      await releaseClaim(release.req, release.res);
      expect(release.statusCode).toBe(200);

      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe("open");
      expect(stored).not.toHaveProperty("claimExpiresAt");
      expect(stored).not.toHaveProperty("claimExtendedAt");

      const lock = await Participant.findById(helperParticipantId)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
        .lean();
      expect(lock?.activeReservationRequestId).toBeNull();
      expect(lock?.activeReservationClaimExpiresAt).toBeNull();
    });
  });

  it("release restores availability and clears the lock so the same helper can reserve again", async () => {
    const first = await createClaimableRequest("Released Meal");
    const claim = routeContext(String(first._id));
    await claimRequest(claim.req, claim.res);
    expect(claim.statusCode).toBe(200);
    const rawToken = claim.body.claim.claimToken as string;

    const release = routeContext(String(first._id), { claimToken: rawToken });
    await releaseClaim(release.req, release.res);

    expect(release.statusCode).toBe(200);
    expect(release.body).toEqual({ released: true });
    const releasedStored = await MealRequest.collection.findOne({
      _id: first._id as mongoose.Types.ObjectId,
    });
    expect(releasedStored?.status).toBe("open");
    expect(releasedStored).not.toHaveProperty("helperParticipantId");
    expect(releasedStored).not.toHaveProperty("claimTokenDigest");

    const second = await createClaimableRequest("Second Reservation");
    const secondClaim = routeContext(String(second._id));
    await claimRequest(secondClaim.req, secondClaim.res);

    expect(secondClaim.statusCode).toBe(200);
  });

  it("cannot release a different helper's active reservation", async () => {
    const request = await createClaimableRequest("Not Yours");
    const claim = routeContext(String(request._id));
    await claimRequest(claim.req, claim.res);
    expect(claim.statusCode).toBe(200);
    const rawToken = claim.body.claim.claimToken as string;

    // Second helper's own valid credential, but naming a reservation that
    // is not theirs — token mismatch classifies it the ordinary way.
    const wrongHolderRelease = routeContext(
      String(request._id),
      {},
      secondParticipantAuthority
    );
    await releaseClaim(wrongHolderRelease.req, wrongHolderRelease.res);
    expect(wrongHolderRelease.statusCode).toBe(403);

    const stillClaimed = await MealRequest.collection.findOne({
      _id: request._id as mongoose.Types.ObjectId,
    });
    expect(stillClaimed?.status).toBe("claimed");

    // The rightful holder can still release it afterward.
    const rightfulRelease = routeContext(String(request._id), {
      claimToken: rawToken,
    });
    await releaseClaim(rightfulRelease.req, rightfulRelease.res);
    expect(rightfulRelease.statusCode).toBe(200);
  });
});
