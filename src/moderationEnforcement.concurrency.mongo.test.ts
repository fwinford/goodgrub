import type { Request, Response } from "express";
import { ClientSession } from "mongodb";
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

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import {
  Fulfillment,
  Participant,
  ParticipantBlock,
  PlacementEvidence,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
import {
  MODERATION_MODELS,
  establishModerationIndexes,
} from "../models/moderation.js";
import { claimRequest, extendClaim, releaseClaim } from "./claimRoute.js";
import { fulfillRequest } from "./fulfillmentRoute.js";
import {
  RequesterSuspendedError,
  assertRequesterNotSuspendedWithinSession,
  suspendHelper,
  suspendRequester,
} from "./moderationEnforcement.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import { createParticipantBlock } from "./participantBlockRoute.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import {
  SAFETY_IDENTITY_KEYRING_ENV,
  readSafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

/**
 * W4-U1.2 CP2 (boundary contract EO) deterministic concurrency proof on a real
 * replica set.
 *
 * Each interaction is forced into a known overlap: the FIRST operation runs
 * every write of its transaction and is then held at its commit; the SECOND
 * operation starts while those writes are uncommitted and is observed to
 * collide with them (a transient write conflict that aborts and retries its
 * transaction) before the first is allowed to commit. The second therefore
 * retries against the first's committed state, so the serialization order is
 * known and each ordering is proved separately. The authoritative outcome
 * (status, deadline, helper binding, M/L/E, participant lock and fences,
 * availability) is asserted after both finish.
 */

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_moderation_concurrency`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const signingSecretText = "moderation-concurrency-mongo-signing-secret-32b";
const signingSecret = Buffer.from(signingSecretText);
const keyring = readSafetyIdentityKeyring({
  [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
    current: "k1",
    keys: { k1: Buffer.alloc(32, 0x22).toString("base64url") },
  }),
});

// `ada` helps, `bea` requests, `cy` is an unrelated helper.
const ada = new mongoose.Types.ObjectId("64e0000000000000000000e1");
const bea = new mongoose.Types.ObjectId("64e0000000000000000000e2");
const cy = new mongoose.Types.ObjectId("64e0000000000000000000e3");
const principal: Record<string, string> = {
  [String(ada)]: "concurrency-ada@nyu.edu",
  [String(bea)]: "concurrency-bea@nyu.edu",
  [String(cy)]: "concurrency-cy@nyu.edu",
};

const PLACED_ORDER_SCREENSHOT = {
  mimeType: "image/png",
  imageBase64:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
};

interface Call {
  statusCode: number;
  body: any;
}

function makeCall(
  params: Record<string, string>,
  body: unknown,
  as: mongoose.Types.ObjectId
) {
  const req = {
    params,
    body,
    headers: {
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(as, 1, signingSecret),
    },
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
async function extend(requestId: unknown, as: mongoose.Types.ObjectId) {
  const { req, res, call } = makeCall({ id: String(requestId) }, {}, as);
  await extendClaim(req, res);
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
async function block(
  requestId: unknown,
  as: mongoose.Types.ObjectId,
  body: Record<string, unknown> = {}
) {
  const { req, res, call } = makeCall({ id: String(requestId) }, body, as);
  await createParticipantBlock(req, res);
  return call;
}
async function fulfill(requestId: unknown, as: mongoose.Types.ObjectId) {
  const { req, res, call } = makeCall(
    { id: String(requestId) },
    {
      fulfillment: {
        orderNumber: "000123",
        eta: "ASAP",
        placedOrderScreenshot: PLACED_ORDER_SCREENSHOT,
      },
    },
    as
  );
  await fulfillRequest(req, res);
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

function suspensionInput(
  session: mongoose.ClientSession,
  id: mongoose.Types.ObjectId,
  now: Date = new Date()
) {
  return {
    session,
    now,
    keyring,
    participantId: id,
    email: principal[String(id)],
    origin: "manual" as const,
    rationale: "concurrency rationale",
  };
}
const suspendHelperTx = (id: mongoose.Types.ObjectId, now?: Date) =>
  inTransaction((session) => suspendHelper(suspensionInput(session, id, now)));
const suspendRequesterTx = (id: mongoose.Types.ObjectId) =>
  inTransaction((session) => suspendRequester(suspensionInput(session, id)));

function createAsBea() {
  return inTransaction(async (session) => {
    await assertRequesterNotSuspendedWithinSession(bea, session);
    const [document] = await MealRequest.create(
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
    return document;
  });
}

const PRIVATE_FIELDS =
  "+helperParticipantId +claimTokenDigest +externalOrderAffirmed +moderationUnavailable +reservationLapseHold";

async function board() {
  const rows = await MealRequest.find({
    ...buildEffectiveAvailabilityFilter(new Date()),
  }).lean();
  return new Set(rows.map((entry) => String(entry._id)));
}

/** The authoritative state every invariant below is asserted against. */
async function stateOf(requestId: unknown) {
  const request = await MealRequest.findById(requestId).select(PRIVATE_FIELDS).lean();
  if (!request) throw new Error("request missing");
  const r = request as any;
  return {
    status: r.status as string,
    hasDeadline: r.claimExpiresAt != null,
    claimExpiresAt: r.claimExpiresAt ? new Date(r.claimExpiresAt).getTime() : null,
    helper: r.helperParticipantId ? String(r.helperParticipantId) : null,
    hasTokenDigest: Boolean(r.claimTokenDigest),
    M: r.moderationUnavailable === true,
    L: r.reservationLapseHold === true,
    E: r.externalOrderAffirmed === true,
    onBoard: (await board()).has(String(requestId)),
  };
}

async function participantOf(id: mongoose.Types.ObjectId) {
  const p = (await Participant.findById(id)
    .select(
      "+suspended +suspensionFenceEpoch +blockFenceEpoch +activeReservationRequestId +activeReservationClaimExpiresAt"
    )
    .lean()) as any;
  return {
    lockDeadline: p.activeReservationClaimExpiresAt
      ? new Date(p.activeReservationClaimExpiresAt).getTime()
      : null,
    lock: p.activeReservationRequestId ? String(p.activeReservationRequestId) : null,
    suspended: p.suspended === true,
    suspensionFenceEpoch: p.suspensionFenceEpoch ?? 0,
    blockFenceEpoch: p.blockFenceEpoch ?? 0,
  };
}

function settled<T>(result: PromiseSettledResult<T>): T {
  if (result.status !== "fulfilled") throw result.reason;
  return result.value;
}

interface OverlapResult<A, B> {
  first: PromiseSettledResult<A>;
  second: PromiseSettledResult<B>;
  /** The second operation hit the first's uncommitted writes. */
  collided: boolean;
}

/**
 * Runs `first` until it is about to commit, starts `second`, waits until
 * `second` has either collided with the held writes (a transaction abort) or
 * settled, then lets `first` commit and awaits both.
 */
async function overlap<A, B>(
  first: () => Promise<A>,
  second: () => Promise<B>,
  options: { quietMs?: number } = {}
): Promise<OverlapResult<A, B>> {
  let openGate!: () => void;
  const gate = new Promise<void>((resolve) => {
    openGate = resolve;
  });
  let reachedCommit!: () => void;
  const atCommit = new Promise<void>((resolve) => {
    reachedCommit = resolve;
  });
  let held = false;
  let aborts = 0;
  const proto = ClientSession.prototype as any;
  const realCommit = proto.commitTransaction;
  const realAbort = proto.abortTransaction;

  proto.commitTransaction = async function (this: unknown, ...args: unknown[]) {
    if (!held) {
      held = true;
      reachedCommit();
      await gate;
    }
    return realCommit.apply(this, args);
  };
  proto.abortTransaction = async function (this: unknown, ...args: unknown[]) {
    aborts += 1;
    return realAbort.apply(this, args);
  };

  try {
    const firstPromise = first();
    const firstSettled = firstPromise.then(
      () => undefined,
      () => undefined
    );
    await Promise.race([atCommit, firstSettled]);
    if (!held) {
      throw new Error("the first operation never reached a transaction commit");
    }

    aborts = 0;
    const secondPromise = second();
    let secondDone = false;
    void secondPromise.then(
      () => (secondDone = true),
      () => (secondDone = true)
    );
    const deadline = Date.now() + (options.quietMs ?? 10_000);
    while (aborts === 0 && !secondDone && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const collided = aborts > 0;

    openGate();
    const [firstResult, secondResult] = await Promise.allSettled([
      firstPromise,
      secondPromise,
    ]);
    return { first: firstResult, second: secondResult, collided };
  } finally {
    openGate();
    proto.commitTransaction = realCommit;
    proto.abortTransaction = realAbort;
  }
}

describeMongo(
  "real MongoDB W4-U1.2 EO deterministic concurrency",
  { timeout: 60_000 },
  () => {
    async function resetState() {
      await MealRequest.deleteMany({});
      await RequestParticipation.deleteMany({});
      await ParticipantBlock.deleteMany({});
      await Fulfillment.deleteMany({});
      await PlacementEvidence.deleteMany({});
      for (const model of MODERATION_MODELS) await model.deleteMany({});
      await Participant.updateMany(
        {},
        {
          $set: {
            activeReservationRequestId: null,
            activeReservationClaimExpiresAt: null,
          },
          $unset: { suspended: 1, suspensionFenceEpoch: 1, blockFenceEpoch: 1 },
        }
      ).exec();
    }

    beforeAll(async () => {
      vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "moderation-concurrency-claim-secret!!!");
      vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, signingSecretText);
      await mongoose.connect(mongoUri!);
      await prepareParticipantIdentityMongoTestState();
      await MealRequest.syncIndexes();
      await Participant.createIndexes();
      await RequestParticipation.syncIndexes();
      await Fulfillment.syncIndexes();
      await PlacementEvidence.syncIndexes();
      await ParticipantBlock.syncIndexes();
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
      sendFulfillmentEmail.mockReset();
      sendFulfillmentEmail.mockResolvedValue(undefined);
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

    async function held() {
      const request = await createRequest(bea);
      expect((await claim(request._id, ada)).statusCode).toBe(200);
      return request;
    }

    describe("claim versus suspension", () => {
      it("requester suspension commits first: the claim is refused, nothing is reserved, M holds", async () => {
        const request = await createRequest(bea);

        const race = await overlap(
          () => suspendRequesterTx(bea),
          () => claim(request._id, ada)
        );

        expect(race.collided).toBe(true);
        settled(race.first);
        expect(settled(race.second).statusCode).toBeGreaterThanOrEqual(400);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          hasDeadline: false,
          helper: null,
          M: true,
          L: false,
          E: false,
          onBoard: false,
        });
        expect((await participantOf(ada)).lock).toBeNull();
      });

      it("claim commits first: requester suspension marks M and leaves the reservation untouched", async () => {
        const request = await createRequest(bea);

        const race = await overlap(
          () => claim(request._id, ada),
          () => suspendRequesterTx(bea)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        settled(race.second);
        const after = await stateOf(request._id);
        expect(after).toMatchObject({
          status: "claimed",
          hasDeadline: true,
          helper: String(ada),
          M: true,
          L: false,
          E: false,
          onBoard: false,
        });
        expect((await participantOf(ada)).lock).toBe(String(request._id));
      });

      it("helper suspension commits first: the claim is refused and no reservation or lock appears", async () => {
        const request = await createRequest(bea);

        const race = await overlap(
          () => suspendHelperTx(ada),
          () => claim(request._id, ada)
        );

        expect(race.collided).toBe(true);
        settled(race.first);
        expect(settled(race.second).statusCode).toBeGreaterThanOrEqual(400);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          helper: null,
          M: false,
          L: false,
          onBoard: true,
        });
        expect(await participantOf(ada)).toMatchObject({ lock: null, suspended: true });
      });

      it("claim commits first: helper suspension pins L to that exact reservation", async () => {
        const request = await createRequest(bea);

        const race = await overlap(
          () => claim(request._id, ada),
          () => suspendHelperTx(ada)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        settled(race.second);
        expect(await stateOf(request._id)).toMatchObject({
          status: "claimed",
          hasDeadline: true,
          helper: String(ada),
          L: true,
          M: false,
          E: false,
          onBoard: false,
        });
        expect(await participantOf(ada)).toMatchObject({
          lock: String(request._id),
          suspended: true,
        });
      });
    });

    describe("Stop versus Block", () => {
      it("Stop commits first, then Block Yes: the Yes is refused with no Block, no E, request open", async () => {
        const request = await held();

        const race = await overlap(
          () => release(request._id, ada),
          () => block(request._id, ada, { externalOrderPlaced: true })
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        expect(settled(race.second).statusCode).toBe(409);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          hasDeadline: false,
          helper: null,
          E: false,
          onBoard: true,
        });
        expect(await ParticipantBlock.countDocuments({})).toBe(0);
        expect((await participantOf(bea)).blockFenceEpoch).toBe(0);
        expect((await participantOf(ada)).lock).toBeNull();
      });

      it("Block Yes commits first, then Stop: E holds, Stop retires in place and never reopens", async () => {
        const request = await held();

        const race = await overlap(
          () => block(request._id, ada, { externalOrderPlaced: true }),
          () => release(request._id, ada)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        settled(race.second);
        expect(await stateOf(request._id)).toMatchObject({
          status: "claimed",
          hasDeadline: false,
          helper: null,
          hasTokenDigest: false,
          E: true,
          onBoard: false,
        });
        expect(await ParticipantBlock.countDocuments({})).toBe(1);
        expect((await participantOf(ada)).lock).toBeNull();
      });

      it("Block No commits first, then Stop: one release only, the stale Stop is refused", async () => {
        const request = await held();

        const race = await overlap(
          () => block(request._id, ada, { externalOrderPlaced: false }),
          () => release(request._id, ada)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        expect(settled(race.second).statusCode).toBeGreaterThanOrEqual(400);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          hasDeadline: false,
          helper: null,
          E: false,
          M: false,
          L: false,
          onBoard: true,
        });
        expect((await participantOf(ada)).lock).toBeNull();
      });

      it("L request: Stop commits first and retires in place; the later Block No releases nothing and never reopens", async () => {
        const request = await held();
        await suspendHelperTx(ada);

        const race = await overlap(
          () => release(request._id, ada),
          () => block(request._id, ada, { externalOrderPlaced: false })
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        settled(race.second);
        expect(await stateOf(request._id)).toMatchObject({
          status: "claimed",
          hasDeadline: false,
          helper: null,
          L: true,
          E: false,
          onBoard: false,
        });
        expect((await participantOf(ada)).lock).toBeNull();
      });

      it("L request: Block No (confirmed No) commits first, reopens and clears L; the stale Stop is refused", async () => {
        const request = await held();
        await suspendHelperTx(ada);

        const race = await overlap(
          () => block(request._id, ada, { externalOrderPlaced: false }),
          () => release(request._id, ada)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        expect(settled(race.second).statusCode).toBeGreaterThanOrEqual(400);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          hasDeadline: false,
          helper: null,
          L: false,
          E: false,
          M: false,
          onBoard: true,
        });
      });

      it("M request: Block No retires in place and never reopens, whatever the Stop does", async () => {
        const request = await held();
        await suspendRequesterTx(bea);

        const race = await overlap(
          () => block(request._id, ada, { externalOrderPlaced: false }),
          () => release(request._id, ada)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        settled(race.second);
        expect(await stateOf(request._id)).toMatchObject({
          status: "claimed",
          hasDeadline: false,
          helper: null,
          M: true,
          onBoard: false,
        });
        expect((await participantOf(ada)).lock).toBeNull();
      });
    });

    describe("helper suspension versus release, expiry, extension and fulfillment", () => {
      it("suspension commits first: L is pinned and the later Stop retires in place", async () => {
        const request = await held();

        const race = await overlap(
          () => suspendHelperTx(ada),
          () => release(request._id, ada)
        );

        expect(race.collided).toBe(true);
        settled(race.first);
        expect(settled(race.second).statusCode).toBe(200);
        expect(await stateOf(request._id)).toMatchObject({
          status: "claimed",
          hasDeadline: false,
          helper: null,
          L: true,
          onBoard: false,
        });
        expect((await participantOf(ada)).lock).toBeNull();
      });

      it("Stop commits first: the request reopens and the later suspension finds nothing to mark", async () => {
        const request = await held();

        const race = await overlap(
          () => release(request._id, ada),
          () => suspendHelperTx(ada)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        settled(race.second);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          helper: null,
          L: false,
          M: false,
          E: false,
          onBoard: true,
        });
        expect(await participantOf(ada)).toMatchObject({ lock: null, suspended: true });
      });

      it("suspension commits first, then Add 5 minutes: the extension stays inside the one-use rules and L survives", async () => {
        const request = await held();

        const race = await overlap(
          () => suspendHelperTx(ada),
          () => extend(request._id, ada)
        );

        settled(race.first);
        settled(race.second);
        const after = await stateOf(request._id);
        expect(after).toMatchObject({
          status: "claimed",
          helper: String(ada),
          hasDeadline: true,
          L: true,
          onBoard: false,
        });
        expect((await participantOf(ada)).lock).toBe(String(request._id));
      });

      // The competing "expiry" is the production lapse takeover: another helper's
      // claim, granted only because the reservation's deadline has truly passed
      // (`claimExpiresAt <= now`). The deadline sits 1.5s ahead so the
      // suspension's snapshot sees a live reservation while the takeover runs
      // after the deadline in wall-clock time.
      const LAPSE_MS = 1500;
      async function shortReservation() {
        const request = await held();
        const deadline = new Date(Date.now() + LAPSE_MS);
        await MealRequest.updateOne(
          { _id: request._id },
          { $set: { claimExpiresAt: deadline } }
        ).exec();
        await Participant.updateOne(
          { _id: ada },
          { $set: { activeReservationClaimExpiresAt: deadline } }
        ).exec();
        return { request, deadline };
      }
      const untilAfter = async (deadline: Date) => {
        while (Date.now() <= deadline.getTime() + 50) {
          await new Promise((resolve) => setTimeout(resolve, 25));
        }
      };

      it("suspension holds uncommitted while the deadline passes and another helper takes the lapsed claim: they collide, L wins, the reservation and both deadlines are unchanged", async () => {
        const { request, deadline } = await shortReservation();

        const race = await overlap(
          () => suspendHelperTx(ada),
          async () => {
            await untilAfter(deadline);
            return claim(request._id, cy);
          }
        );

        expect(Date.now()).toBeGreaterThan(deadline.getTime());
        expect(race.collided).toBe(true);
        settled(race.first);
        expect(settled(race.second).statusCode).toBeGreaterThanOrEqual(400);
        expect(await stateOf(request._id)).toMatchObject({
          status: "claimed",
          helper: String(ada),
          claimExpiresAt: deadline.getTime(),
          L: true,
          M: false,
          E: false,
          onBoard: false,
        });
        expect(await participantOf(ada)).toMatchObject({
          lock: String(request._id),
          lockDeadline: deadline.getTime(),
          suspended: true,
        });
        expect(await participantOf(cy)).toMatchObject({ lock: null, lockDeadline: null });
      });

      it("takeover of the lapsed claim holds uncommitted while a suspension reads the earlier live reservation: they collide, the takeover stands and no L is written", async () => {
        const { request, deadline } = await shortReservation();
        const beforeDeadline = new Date(deadline.getTime() - 500);

        const race = await overlap(
          async () => {
            await untilAfter(deadline);
            return claim(request._id, cy);
          },
          () => suspendHelperTx(ada, beforeDeadline)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        settled(race.second);
        const after = await stateOf(request._id);
        expect(after).toMatchObject({
          status: "claimed",
          helper: String(cy),
          L: false,
          M: false,
          E: false,
        });
        expect(after.claimExpiresAt).toBeGreaterThan(deadline.getTime());
        expect(after.hasTokenDigest).toBe(true);
        expect(await participantOf(cy)).toMatchObject({ lock: String(request._id) });
        expect((await participantOf(cy)).lockDeadline).toBe(after.claimExpiresAt);
        expect((await participantOf(ada)).suspended).toBe(true);
      });

      it("a reservation that lapsed before the suspension is not marked: it simply reopens", async () => {
        const request = await held();
        const lapsed = new Date(Date.now() - 1000);
        await MealRequest.updateOne(
          { _id: request._id },
          { $set: { claimExpiresAt: lapsed } }
        ).exec();
        await Participant.updateOne(
          { _id: ada },
          { $set: { activeReservationClaimExpiresAt: lapsed } }
        ).exec();

        await suspendHelperTx(ada);

        expect(await stateOf(request._id)).toMatchObject({ L: false, onBoard: true });
      });

      it("suspension commits first: the fulfillment still places, settles L, and the request never reopens", async () => {
        const request = await held();

        const race = await overlap(
          () => suspendHelperTx(ada),
          () => fulfill(request._id, ada)
        );

        expect(race.collided).toBe(true);
        settled(race.first);
        expect(settled(race.second).statusCode).toBe(200);
        expect(await stateOf(request._id)).toMatchObject({
          status: "placed",
          hasDeadline: false,
          L: false,
          M: false,
          E: false,
          onBoard: false,
        });
        const placed = await MealRequest.findById(request._id).lean();
        expect(placed!.orderNumber).toBe("000123");
        expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
        expect((await participantOf(ada)).lock).toBeNull();
      });

      it("fulfillment commits first: placement is authoritative and the later suspension marks nothing on the Request", async () => {
        const request = await held();

        const race = await overlap(
          () => fulfill(request._id, ada),
          () => suspendHelperTx(ada)
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        settled(race.second);
        expect(await stateOf(request._id)).toMatchObject({
          status: "placed",
          L: false,
          M: false,
          onBoard: false,
        });
        expect(await participantOf(ada)).toMatchObject({ lock: null, suspended: true });
      });

      it("requester suspension commits first: the fulfillment still commits and M does not hide placed", async () => {
        const request = await held();

        const race = await overlap(
          () => suspendRequesterTx(bea),
          () => fulfill(request._id, ada)
        );

        expect(race.collided).toBe(true);
        settled(race.first);
        expect(settled(race.second).statusCode).toBe(200);
        expect(await stateOf(request._id)).toMatchObject({
          status: "placed",
          M: true,
          onBoard: false,
        });
        expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      });
    });

    describe("placement settles L", () => {
      it("a committed placement clears L only: M and the placed order are kept and it never reopens", async () => {
        const request = await held();
        await suspendHelperTx(ada);
        await suspendRequesterTx(bea);
        expect(await stateOf(request._id)).toMatchObject({ L: true, M: true });

        expect((await fulfill(request._id, ada)).statusCode).toBe(200);

        expect(await stateOf(request._id)).toMatchObject({
          status: "placed",
          hasDeadline: false,
          helper: String(ada),
          L: false,
          M: true,
          E: false,
          onBoard: false,
        });
        // Nothing afterwards can bring a placed order back.
        const stop = await release(request._id, ada);
        expect(stop.statusCode).toBeGreaterThanOrEqual(400);
        expect(await stateOf(request._id)).toMatchObject({ status: "placed", onBoard: false });
      });

      it("placement under L alone also leaves nothing for a later release to act on", async () => {
        const request = await held();
        await suspendHelperTx(ada);

        expect((await fulfill(request._id, ada)).statusCode).toBe(200);

        const stored = (await MealRequest.findById(request._id)
          .select("+reservationLapseHold")
          .lean()) as any;
        expect(stored.reservationLapseHold).toBeUndefined();
        expect(stored.status).toBe("placed");
        expect(
          (await release(request._id, ada, { externalOrderPlaced: false })).statusCode
        ).toBeGreaterThanOrEqual(400);
        expect((await stateOf(request._id)).status).toBe("placed");
      });
    });

    describe("concurrent Yes and No decisions (FD-1 Option B)", () => {
      async function heldWithL() {
        const request = await held();
        await suspendHelperTx(ada);
        return request;
      }

      it("Yes commits first: E holds, the later No is refused with no write, the reservation is untouched", async () => {
        const request = await heldWithL();
        const before = await stateOf(request._id);

        const race = await overlap(
          () => release(request._id, ada, { externalOrderPlaced: true }),
          () => release(request._id, ada, { externalOrderPlaced: false })
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        expect(settled(race.second).statusCode).toBe(409);
        const after = await stateOf(request._id);
        expect(after).toMatchObject({
          status: "claimed",
          hasDeadline: true,
          claimExpiresAt: before.claimExpiresAt,
          helper: String(ada),
          E: true,
          L: true,
          onBoard: false,
        });
        expect((await participantOf(ada)).lock).toBe(String(request._id));
      });

      it("No commits first: the request reopens and clears L, the later Yes is refused and writes no E", async () => {
        const request = await heldWithL();

        const race = await overlap(
          () => release(request._id, ada, { externalOrderPlaced: false }),
          () => release(request._id, ada, { externalOrderPlaced: true })
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        expect(settled(race.second).statusCode).toBe(409);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          hasDeadline: false,
          helper: null,
          E: false,
          L: false,
          M: false,
          onBoard: true,
        });
        expect((await participantOf(ada)).lock).toBeNull();
      });

      it("Block Yes commits first, then the Stop-question No: refused, E holds and the reservation is untouched", async () => {
        const request = await heldWithL();

        const race = await overlap(
          () => block(request._id, ada, { externalOrderPlaced: true }),
          () => release(request._id, ada, { externalOrderPlaced: false })
        );

        expect(race.collided).toBe(true);
        expect(settled(race.first).statusCode).toBe(200);
        expect(settled(race.second).statusCode).toBe(409);
        expect(await stateOf(request._id)).toMatchObject({
          status: "claimed",
          hasDeadline: true,
          helper: String(ada),
          E: true,
          L: true,
          onBoard: false,
        });
      });

      it("two concurrent No answers: exactly one releases, the other is refused, the request is open once", async () => {
        const request = await heldWithL();

        const race = await overlap(
          () => release(request._id, ada, { externalOrderPlaced: false }),
          () => release(request._id, ada, { externalOrderPlaced: false })
        );

        expect(race.collided).toBe(true);
        const statuses = [
          settled(race.first).statusCode,
          settled(race.second).statusCode,
        ].sort();
        expect(statuses).toEqual([200, 409]);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          helper: null,
          L: false,
          onBoard: true,
        });
      });
    });

    describe("stale and repeated confirmed-No attempts", () => {
      it("a repeated No after the reopen is refused with no write", async () => {
        const request = await held();
        await suspendHelperTx(ada);
        expect(
          (await release(request._id, ada, { externalOrderPlaced: false })).statusCode
        ).toBe(200);
        const reopened = await MealRequest.findById(request._id).lean();

        const repeated = await release(request._id, ada, { externalOrderPlaced: false });

        expect(repeated.statusCode).toBeGreaterThanOrEqual(400);
        const after = await MealRequest.findById(request._id).lean();
        expect(after!.updatedAt).toEqual(reopened!.updatedAt);
        expect(await stateOf(request._id)).toMatchObject({
          status: "open",
          L: false,
          E: false,
          onBoard: true,
        });
      });

      it("a stale No never releases another helper's later reservation of the same request", async () => {
        const request = await held();
        await suspendHelperTx(ada);
        expect(
          (await release(request._id, ada, { externalOrderPlaced: false })).statusCode
        ).toBe(200);
        expect((await claim(request._id, cy)).statusCode).toBe(200);
        const cyHeld = await stateOf(request._id);

        const stale = await release(request._id, ada, { externalOrderPlaced: false });

        expect(stale.statusCode).toBeGreaterThanOrEqual(400);
        expect(await stateOf(request._id)).toEqual(cyHeld);
        expect(cyHeld).toMatchObject({ status: "claimed", helper: String(cy), L: false });
        expect((await participantOf(cy)).lock).toBe(String(request._id));
      });

      it("a stale Yes never writes E onto another helper's later reservation", async () => {
        const request = await held();
        await suspendHelperTx(ada);
        expect(
          (await release(request._id, ada, { externalOrderPlaced: false })).statusCode
        ).toBe(200);
        expect((await claim(request._id, cy)).statusCode).toBe(200);

        const stale = await release(request._id, ada, { externalOrderPlaced: true });

        expect(stale.statusCode).toBeGreaterThanOrEqual(400);
        expect(await stateOf(request._id)).toMatchObject({
          status: "claimed",
          helper: String(cy),
          E: false,
        });
      });

      it("a No for a reservation extended after the answer began is refused, not released", async () => {
        const request = await held();
        await suspendHelperTx(ada);

        const race = await overlap(
          () => extend(request._id, ada),
          () => release(request._id, ada, { externalOrderPlaced: false })
        );

        settled(race.first);
        const outcome = settled(race.second);
        const after = await stateOf(request._id);
        // Whichever serialization applied, the request is never both reopened
        // and still reserved, and never reopens with L carried over.
        if (outcome.statusCode === 200) {
          expect(after).toMatchObject({ status: "open", helper: null, L: false, onBoard: true });
        } else {
          expect(after).toMatchObject({ status: "claimed", helper: String(ada), L: true });
        }
      });
    });

    describe("create versus requester suspension", () => {
      it("create commits first: the suspension then marks the new request M; nothing available remains", async () => {
        const race = await overlap(createAsBea, () => suspendRequesterTx(bea));

        expect(race.collided).toBe(true);
        const created = settled(race.first);
        settled(race.second);
        expect(await stateOf(created._id)).toMatchObject({
          status: "open",
          M: true,
          onBoard: false,
        });
        expect(await board()).toEqual(new Set());
        // The create gate advanced the fence once; the suspension once more.
        expect(await participantOf(bea)).toMatchObject({
          suspended: true,
          suspensionFenceEpoch: 2,
        });
      });

      it("suspension commits first: the create is refused, no Request is authored, the epoch is not advanced by the refusal", async () => {
        const race = await overlap(() => suspendRequesterTx(bea), createAsBea);

        expect(race.collided).toBe(true);
        settled(race.first);
        expect(race.second.status).toBe("rejected");
        expect((race.second as PromiseRejectedResult).reason).toBeInstanceOf(
          RequesterSuspendedError
        );
        expect(await MealRequest.countDocuments({})).toBe(0);
        expect(await participantOf(bea)).toMatchObject({
          suspended: true,
          suspensionFenceEpoch: 1,
        });
      });
    });
  }
);
