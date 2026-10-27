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
  Participant,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
import {
  MODERATION_MODELS,
  establishModerationIndexes,
} from "../models/moderation.js";
import { claimRequest, releaseClaim } from "./claimRoute.js";
import {
  RequesterSuspendedError,
  assertRequesterNotSuspendedWithinSession,
  reinstateParticipant,
  suspendHelper,
  suspendRequester,
} from "./moderationEnforcement.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { getActiveReservation } from "./reservationRoute.js";
import {
  buildEffectiveAvailabilityFilter,
  isEffectivelyAvailable,
} from "./requestAvailability.js";
import {
  SAFETY_IDENTITY_KEYRING_ENV,
  readSafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

/**
 * W4-U1.2 Checkpoint 2 (boundary contract EO): markers M and L, the claim and
 * create gates, `confirmedNo`, FD-1 Option B, and the suspension/reinstatement
 * transactions, on real MongoDB with its own database.
 */

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_moderation_enforcement`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const signingSecretText = "moderation-enforcement-mongo-signing-secret-32";
const signingSecret = Buffer.from(signingSecretText);
const keyring = readSafetyIdentityKeyring({
  [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
    current: "k1",
    keys: { k1: Buffer.alloc(32, 0x11).toString("base64url") },
  }),
});

// `ada` helps, `bea` requests, `cy` is an unrelated helper.
const ada = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const bea = new mongoose.Types.ObjectId("64e0000000000000000000b2");
const cy = new mongoose.Types.ObjectId("64e0000000000000000000c3");
const principal: Record<string, string> = {
  [String(ada)]: "enforce-ada@nyu.edu",
  [String(bea)]: "enforce-bea@nyu.edu",
  [String(cy)]: "enforce-cy@nyu.edu",
};
const authority = (id: mongoose.Types.ObjectId) =>
  signParticipantAuthority(id, 1, signingSecret);

interface Call {
  statusCode: number;
  body: any;
}

function makeCall(
  params: Record<string, string>,
  body: unknown,
  as: mongoose.Types.ObjectId | null
) {
  const req = {
    params,
    body,
    headers: as ? { [PARTICIPANT_AUTHORITY_HEADER]: authority(as) } : {},
  } as unknown as Request;
  const call: Call = { statusCode: 200, body: undefined };
  const res = {} as Response;
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

async function claim(requestId: unknown, as: mongoose.Types.ObjectId) {
  const { req, res, call } = makeCall({ id: String(requestId) }, undefined, as);
  await claimRequest(req, res);
  return call;
}

async function release(
  requestId: unknown,
  as: mongoose.Types.ObjectId,
  body: Record<string, unknown> = {}
) {
  const { req, res, call } = makeCall({ id: String(requestId) }, body, as);
  await releaseClaim(req, res);
  return call;
}

async function activeReservation(as: mongoose.Types.ObjectId) {
  const { req, res, call } = makeCall({}, undefined, as);
  await getActiveReservation(req, res);
  return call;
}

async function createRequest(
  requester: mongoose.Types.ObjectId,
  overrides: Record<string, unknown> = {}
) {
  const deadline = new Date(Date.now() + 60 * 60 * 1000);
  return await MealRequest.create({
    vendor: "Jasper Kane Cafe",
    food: "Rice bowl",
    pickupWindowText: "ASAP",
    email: "requester@example.edu",
    status: "open",
    expiresAt: deadline,
    deleteAt: deadline,
    requesterParticipantId: requester,
    ...overrides,
  });
}

const PRIVATE_FIELDS =
  "+helperParticipantId +claimTokenDigest +externalOrderAffirmed +moderationUnavailable +reservationLapseHold";

async function row(requestId: unknown) {
  return await MealRequest.findById(requestId).select(PRIVATE_FIELDS).lean();
}

async function board() {
  const rows = await MealRequest.find({
    ...buildEffectiveAvailabilityFilter(new Date()),
  }).lean();
  return new Set(rows.map((entry) => String(entry._id)));
}

async function inTransaction<T>(
  work: (session: mongoose.ClientSession) => Promise<T>
): Promise<T> {
  const session = await mongoose.startSession();
  try {
    let result: T | undefined;
    await session.withTransaction(async () => {
      result = await work(session);
    });
    return result as T;
  } finally {
    await session.endSession();
  }
}

function suspendHelperTx(id: mongoose.Types.ObjectId) {
  return inTransaction((session) =>
    suspendHelper({
      session,
      now: new Date(),
      keyring,
      participantId: id,
      email: principal[String(id)],
      origin: "manual",
      rationale: "test rationale",
    })
  );
}

function suspendRequesterTx(id: mongoose.Types.ObjectId) {
  return inTransaction((session) =>
    suspendRequester({
      session,
      now: new Date(),
      keyring,
      participantId: id,
      email: principal[String(id)],
      origin: "manual",
      rationale: "test rationale",
    })
  );
}

async function lapseReservation(requestId: unknown) {
  const lapsed = new Date(Date.now() - 1000);
  const held = await MealRequest.findById(requestId)
    .select("+helperParticipantId")
    .lean();
  await MealRequest.updateOne(
    { _id: requestId },
    { $set: { claimExpiresAt: lapsed } }
  ).exec();
  if (held?.helperParticipantId) {
    await Participant.updateOne(
      { _id: held.helperParticipantId },
      { $set: { activeReservationClaimExpiresAt: lapsed } }
    ).exec();
  }
}

const STATE_CHANGED_CODE = "RESERVATION_STATE_CHANGED";

describeMongo(
  "real MongoDB W4-U1.2 external-order enforcement (EO)",
  { timeout: 30_000 },
  () => {
    async function resetState() {
      await MealRequest.deleteMany({});
      await RequestParticipation.deleteMany({});
      for (const model of MODERATION_MODELS) await model.deleteMany({});
      await Participant.updateMany(
        {},
        {
          $set: {
            activeReservationRequestId: null,
            activeReservationClaimExpiresAt: null,
          },
          $unset: { suspended: 1, suspensionFenceEpoch: 1 },
        }
      ).exec();
    }

    beforeAll(async () => {
      vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "moderation-enforcement-claim-secret!!");
      vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, signingSecretText);
      await mongoose.connect(mongoUri!);
      await prepareParticipantIdentityMongoTestState();
      await MealRequest.syncIndexes();
      await Participant.createIndexes();
      await RequestParticipation.syncIndexes();
      await establishModerationIndexes();
      for (const id of [ada, bea, cy]) {
        await Participant.updateOne(
          { _id: id },
          {
            $set: { email: principal[String(id)], verifiedAt: new Date() },
            $setOnInsert: { authorityVersion: 1 },
          },
          { upsert: true }
        ).exec();
      }
    });

    beforeEach(() => {
      vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    });

    afterEach(async () => {
      vi.restoreAllMocks();
      await resetState();
    });

    afterAll(async () => {
      await mongoose.disconnect();
      vi.unstubAllEnvs();
    });

    describe("requester suspension", () => {
      it("marks every non-placed request with M, leaves placed ones, and never reopens on reinstatement", async () => {
        const open = await createRequest(bea);
        const claimed = await createRequest(bea);
        expect((await claim(claimed._id, ada)).statusCode).toBe(200);
        const placed = await createRequest(bea, {
          status: "placed",
          placedAt: new Date(),
        });
        const other = await createRequest(cy);

        const { suspensionId } = await suspendRequesterTx(bea);

        expect((await row(open._id))!.moderationUnavailable).toBe(true);
        expect((await row(claimed._id))!.moderationUnavailable).toBe(true);
        expect((await row(placed._id))!.moderationUnavailable).toBeUndefined();
        expect((await row(other._id))!.moderationUnavailable).toBeUndefined();
        expect((await row(placed._id))!.status).toBe("placed");
        expect(await board()).toEqual(new Set([String(other._id)]));

        // A new claim on the marked request is answered as any unavailable one.
        const refused = await claim(open._id, cy);
        expect(refused.statusCode).toBeGreaterThanOrEqual(400);
        expect(JSON.stringify(refused.body)).not.toMatch(/suspend|moderation/i);

        await inTransaction((session) =>
          reinstateParticipant({
            session,
            now: new Date(),
            keyring,
            suspensionId,
            participantId: bea,
          })
        );
        const after = await Participant.findById(bea).select("+suspended").lean();
        expect((after as { suspended?: boolean }).suspended).toBeUndefined();
        // Reinstatement revives nothing.
        expect((await row(open._id))!.moderationUnavailable).toBe(true);
        expect(await board()).toEqual(new Set([String(other._id)]));
      });

      it("Stop on an M request retires in place: never open, lock cleared", async () => {
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);
        await suspendRequesterTx(bea);

        const stopped = await release(request._id, ada);
        expect(stopped.statusCode).toBe(200);
        expect(stopped.body).toEqual({ released: true });
        const after = await row(request._id);
        expect(after!.status).toBe("claimed");
        expect(after!.helperParticipantId).toBeUndefined();
        expect(after!.claimExpiresAt).toBeUndefined();
        expect(await board()).toEqual(new Set());
        const lock = await Participant.findById(ada)
          .select("+activeReservationRequestId")
          .lean();
        expect(lock!.activeReservationRequestId ?? null).toBeNull();
      });
    });

    describe("helper suspension and L", () => {
      it("pins L to the live reservation; a plain Stop retires in place and a lapse never reopens", async () => {
        const stopRequest = await createRequest(bea);
        expect((await claim(stopRequest._id, ada)).statusCode).toBe(200);
        await suspendHelperTx(ada);
        expect((await row(stopRequest._id))!.reservationLapseHold).toBe(true);

        const stopped = await release(stopRequest._id, ada);
        expect(stopped.body).toEqual({ released: true });
        const after = await row(stopRequest._id);
        expect(after!.status).toBe("claimed");
        expect(after!.reservationLapseHold).toBe(true);
        expect(await board()).toEqual(new Set());

        await resetState();
        const lapseRequest = await createRequest(bea);
        expect((await claim(lapseRequest._id, ada)).statusCode).toBe(200);
        await suspendHelperTx(ada);
        await lapseReservation(lapseRequest._id);
        expect(await board()).toEqual(new Set());
        expect(
          isEffectivelyAvailable(
            { ...(await row(lapseRequest._id)) } as never,
            new Date()
          )
        ).toBe(false);
      });

      it("refuses a new claim by a suspended helper, visible only to them", async () => {
        const request = await createRequest(bea);
        await suspendHelperTx(ada);
        const refused = await claim(request._id, ada);
        expect(refused.statusCode).toBe(403);
        expect(refused.body.error.code).toBe("PARTICIPANT_SUSPENDED");
        expect((await row(request._id))!.status).toBe("open");
      });

      it("does not mark a placed reservation or one already carrying E", async () => {
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);
        await MealRequest.updateOne(
          { _id: request._id },
          { $set: { externalOrderAffirmed: true } }
        ).exec();
        await suspendHelperTx(ada);
        expect((await row(request._id))!.reservationLapseHold).toBeUndefined();
      });
    });

    describe("FD-1 Option B release answers", () => {
      async function heldWithL() {
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);
        await suspendHelperTx(ada);
        return request;
      }

      it("reports stopAsksOrderQuestion only on backend truth", async () => {
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);
        const before = await activeReservation(ada);
        expect(before.body.reservation).not.toHaveProperty("stopAsksOrderQuestion");
        await suspendHelperTx(ada);
        const after = await activeReservation(ada);
        expect(after.body.reservation.stopAsksOrderQuestion).toBe(true);
        expect(JSON.stringify(after.body)).not.toMatch(/reservationLapseHold/);
      });

      it("Yes writes E pinned and leaves the reservation intact", async () => {
        const request = await heldWithL();
        const before = await row(request._id);

        const answered = await release(request._id, ada, {
          externalOrderPlaced: true,
        });
        expect(answered.statusCode).toBe(200);
        expect(answered.body).toEqual({ released: false });
        const after = await row(request._id);
        expect(after!.externalOrderAffirmed).toBe(true);
        expect(after!.status).toBe("claimed");
        expect(after!.claimTokenDigest).toBe(before!.claimTokenDigest);
        expect(after!.claimExpiresAt!.getTime()).toBe(before!.claimExpiresAt!.getTime());
        expect(String(after!.helperParticipantId)).toBe(String(ada));
        const lock = await Participant.findById(ada)
          .select("+activeReservationRequestId")
          .lean();
        expect(String(lock!.activeReservationRequestId)).toBe(String(request._id));

        // A second answer is outside its question now (E present): no write.
        const again = await release(request._id, ada, { externalOrderPlaced: true });
        expect(again.statusCode).toBe(409);
        expect(again.body.error.code).toBe(STATE_CHANGED_CODE);
      });

      it("No on L-only reopens and clears L", async () => {
        const request = await heldWithL();
        const answered = await release(request._id, ada, {
          externalOrderPlaced: false,
        });
        expect(answered.body).toEqual({ released: true });
        const after = await row(request._id);
        expect(after!.status).toBe("open");
        expect(after!.reservationLapseHold).toBeUndefined();
        expect(await board()).toEqual(new Set([String(request._id)]));
      });

      it("No on L plus M retires in place and never yields open", async () => {
        const request = await heldWithL();
        await MealRequest.updateOne(
          { _id: request._id },
          { $set: { moderationUnavailable: true } }
        ).exec();
        const answered = await release(request._id, ada, {
          externalOrderPlaced: false,
        });
        expect(answered.body).toEqual({ released: true });
        const after = await row(request._id);
        expect(after!.status).toBe("claimed");
        expect(await board()).toEqual(new Set());
      });

      it("refuses an answer outside its question with no write", async () => {
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);
        const before = await row(request._id);
        for (const externalOrderPlaced of [true, false]) {
          const refused = await release(request._id, ada, { externalOrderPlaced });
          expect(refused.statusCode).toBe(409);
          expect(refused.body.error.code).toBe(STATE_CHANGED_CODE);
        }
        const after = await row(request._id);
        expect(after!.status).toBe("claimed");
        expect(after!.externalOrderAffirmed).toBeUndefined();
        expect(after!.updatedAt!.getTime()).toBe(before!.updatedAt!.getTime());
      });

      it("rejects a non-boolean answer", async () => {
        const request = await heldWithL();
        const refused = await release(request._id, ada, {
          externalOrderPlaced: "yes",
        });
        expect(refused.statusCode).toBe(400);
      });
    });

    describe("create gate", () => {
      it("matches only while not suspended and conflicts with a suspension", async () => {
        await inTransaction((session) =>
          assertRequesterNotSuspendedWithinSession(bea, session)
        );
        const epoch = await Participant.findById(bea)
          .select("+suspensionFenceEpoch")
          .lean();
        expect((epoch as { suspensionFenceEpoch?: number }).suspensionFenceEpoch).toBe(1);

        await suspendRequesterTx(bea);
        await expect(
          inTransaction((session) =>
            assertRequesterNotSuspendedWithinSession(bea, session)
          )
        ).rejects.toBeInstanceOf(RequesterSuspendedError);
      });

      it("serializes a concurrent create and requester suspension: no available request authored after the suspension", async () => {
        const attempts = await Promise.allSettled([
          inTransaction(async (session) => {
            await assertRequesterNotSuspendedWithinSession(bea, session);
            await MealRequest.create(
              [
                {
                  vendor: "Jasper Kane Cafe",
                  food: "Rice bowl",
                  pickupWindowText: "ASAP",
                  email: "requester@example.edu",
                  status: "open",
                  expiresAt: new Date(Date.now() + 3_600_000),
                  deleteAt: new Date(Date.now() + 3_600_000),
                  requesterParticipantId: bea,
                },
              ],
              { session }
            );
          }),
          suspendRequesterTx(bea),
        ]);
        expect(attempts[1].status).toBe("fulfilled");
        // Whichever order the two serialized in, nothing available remains
        // authored by the suspended requester.
        expect(await board()).toEqual(new Set());
      });
    });
  }
);
