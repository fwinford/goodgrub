import type { NextFunction, Request, Response } from "express";
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
  ParticipantBlock,
  PlacementEvidence,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import * as claimRoute from "./claimRoute.js";
import {
  claimRequest,
  extendClaim,
  releaseClaim,
  REQUEST_ALREADY_PARTICIPATED_CODE,
  REQUEST_OWN_REQUEST_CODE,
} from "./claimRoute.js";
import { fulfillRequest } from "./fulfillmentRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  createParticipantBlock,
  deleteParticipantBlock,
} from "./participantBlockRoute.js";
import { buildParticipantFenceFilter } from "./participantBlocks.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { getActiveReservation } from "./reservationRoute.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";
import {
  buildEffectiveAvailabilityFilter,
  isEffectivelyAvailable,
} from "./requestAvailability.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";
import {
  buildPublicRequestDetailResponse,
  buildPublicRequestListResponse,
  type PublicRequestDocument,
  type RequestListDocument,
} from "./requestListResponse.js";

/**
 * W4-U1.3 post-Block autonomy: the durable post-Yes external-order-risk
 * authority, the ordinary one-time extension for a fenced holder, and the safe
 * post-Yes Stop. A focused file beside `participantBlock.mongo.test.ts`, with
 * its own database, because `Request` is shared by concurrently running suites.
 */

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_participant_block_post_yes`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const signingSecretText = "participant-post-yes-mongo-signing-secret-32";
const signingSecret = Buffer.from(signingSecretText);

// `ada` helps, `bea` requests, `cy` is an unrelated helper, `dee` is a second
// requester used for the requester-owned-block comparison scenario.
const ada = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const bea = new mongoose.Types.ObjectId("64e0000000000000000000b2");
const cy = new mongoose.Types.ObjectId("64e0000000000000000000c3");
const dee = new mongoose.Types.ObjectId("64e0000000000000000000d4");
const principal: Record<string, string> = {
  [String(ada)]: "post-yes-ada@nyu.edu",
  [String(bea)]: "post-yes-bea@nyu.edu",
  [String(cy)]: "post-yes-cy@nyu.edu",
  [String(dee)]: "post-yes-dee@nyu.edu",
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
async function extend(
  requestId: unknown,
  as: mongoose.Types.ObjectId,
  claimToken?: string
) {
  const { req, res, call } = makeCall(
    { id: String(requestId) },
    claimToken ? { claimToken } : {},
    claimToken ? null : as
  );
  await extendClaim(req, res);
  return call;
}
async function release(
  requestId: unknown,
  as: mongoose.Types.ObjectId,
  claimToken?: string
) {
  const { req, res, call } = makeCall(
    { id: String(requestId) },
    claimToken ? { claimToken } : {},
    claimToken ? null : as
  );
  await releaseClaim(req, res);
  return call;
}
// Smallest well-formed 1x1 PNG: the required W4-H1a placed-order screenshot,
// valid under the same structural checks a real one meets.
const PLACED_ORDER_SCREENSHOT = {
  mimeType: "image/png",
  imageBase64:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
};

async function fulfill(
  requestId: unknown,
  as: mongoose.Types.ObjectId,
  claimToken?: string,
  extra: Record<string, unknown> = {},
  withScreenshot = true
) {
  const { req, res, call } = makeCall(
    { id: String(requestId) },
    {
      ...(claimToken ? { claimToken } : {}),
      fulfillment: {
        orderNumber: "000123",
        eta: "ASAP",
        ...(withScreenshot ? { placedOrderScreenshot: PLACED_ORDER_SCREENSHOT } : {}),
        ...extra,
      },
    },
    claimToken ? null : as
  );
  await fulfillRequest(req, res);
  return call;
}
async function block(
  requestId: unknown,
  as: mongoose.Types.ObjectId,
  body: unknown = {}
) {
  const { req, res, call } = makeCall({ id: String(requestId) }, body, as);
  await createParticipantBlock(req, res);
  return call;
}
async function unblock(blockId: unknown, as: mongoose.Types.ObjectId) {
  const { req, res, call } = makeCall({ blockId: String(blockId) }, undefined, as);
  await deleteParticipantBlock(req, res);
  return call;
}
async function detail(requestId: unknown, as: mongoose.Types.ObjectId | null) {
  const { req, res, call } = makeCall({ id: String(requestId) }, undefined, as);
  await getPublicRequestDetail(req, res, vi.fn() as unknown as NextFunction);
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
  "+helperParticipantId +claimTokenDigest +externalOrderAffirmed +requesterParticipantId";

async function row(requestId: unknown) {
  return await MealRequest.findById(requestId).select(PRIVATE_FIELDS).lean();
}

/** Every participant's Block fence epoch and reservation lock, for "nothing moved" proof. */
async function participantState() {
  const rows = await Participant.find({ _id: { $in: [ada, bea, cy, dee] } })
    .select(
      "+blockFenceEpoch +activeReservationRequestId +activeReservationClaimExpiresAt"
    )
    .sort({ _id: 1 })
    .lean();
  return rows.map((entry) => ({
    id: String(entry._id),
    blockFenceEpoch: (entry as { blockFenceEpoch?: number }).blockFenceEpoch ?? 0,
    activeReservationRequestId: entry.activeReservationRequestId
      ? String(entry.activeReservationRequestId)
      : null,
    activeReservationClaimExpiresAt:
      entry.activeReservationClaimExpiresAt?.getTime() ?? null,
  }));
}

/** The reservation fields a refused Yes must leave byte-for-byte as they were. */
function reservationFields(document: Awaited<ReturnType<typeof row>>) {
  return {
    status: document!.status,
    helperParticipantId: document!.helperParticipantId
      ? String(document!.helperParticipantId)
      : undefined,
    claimTokenDigest: document!.claimTokenDigest,
    claimExpiresAt: document!.claimExpiresAt?.getTime(),
    claimExtendedAt: document!.claimExtendedAt?.getTime() ?? null,
    externalOrderAffirmed: document!.externalOrderAffirmed,
    updatedAt: document!.updatedAt?.getTime(),
  };
}

const STATE_CHANGED = {
  error: {
    code: "RESERVATION_STATE_CHANGED",
    message: "Your reservation changed. Check its status and try again.",
    fields: null,
  },
};

/** The board as the app builds it: effective availability plus the fence. */
async function board(as: mongoose.Types.ObjectId | null) {
  const filter = await buildParticipantFenceFilter(as ? String(as) : null);
  const rows = await MealRequest.find({
    ...buildEffectiveAvailabilityFilter(new Date()),
    ...filter,
  })
    .select("+requesterParticipantId")
    .lean();
  return new Set(rows.map((entry) => String(entry._id)));
}

/** Simulates the passage of the reservation deadline without any mutation path. */
async function lapseReservation(requestId: unknown) {
  const lapsed = new Date(Date.now() - 1000);
  const held = await MealRequest.findById(requestId)
    .select("+helperParticipantId")
    .lean();
  await MealRequest.updateOne(
    { _id: requestId },
    { $set: { claimExpiresAt: lapsed } }
  ).exec();
  // The one-active-reservation lock mirrors the deadline, so it lapses with it.
  if (held?.helperParticipantId) {
    await Participant.updateOne(
      { _id: held.helperParticipantId },
      { $set: { activeReservationClaimExpiresAt: lapsed } }
    ).exec();
  }
}

/** Helper claims, answers Yes on a Block, and returns the raw claim token. */
async function holdAndAnswerYes(
  requester: mongoose.Types.ObjectId,
  helper: mongoose.Types.ObjectId,
  overrides: Record<string, unknown> = {}
) {
  const request = await createRequest(requester, overrides);
  const claimed = await claim(request._id, helper);
  expect(claimed.statusCode).toBe(200);
  const blocked = await block(request._id, helper, { externalOrderPlaced: true });
  expect(blocked.statusCode).toBe(200);
  return { request, claimToken: claimed.body.claim.claimToken as string };
}

const FORBIDDEN_MARKER = /externalOrderAffirmed|affirmed/i;

// A file-local ceiling, like `scripts/qa-environment.mongo.test.ts`: every case
// here runs several real transactions, and the first one also pays for index
// synchronization while sibling Mongo suites run concurrently.
describeMongo(
  "real MongoDB W4-U1.3 post-Yes autonomy and external-order authority",
  { timeout: 30_000 },
  () => {
  async function resetState() {
    await MealRequest.deleteMany({});
    await RequestParticipation.deleteMany({});
    await Fulfillment.deleteMany({});
    await PlacementEvidence.deleteMany({});
    await ParticipantBlock.deleteMany({});
    await Participant.updateMany(
      {},
      {
        $set: {
          activeReservationRequestId: null,
          activeReservationClaimExpiresAt: null,
        },
      }
    ).exec();
  }

  beforeAll(async () => {
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "participant-post-yes-claim-secret-32b!");
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, signingSecretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await RequestParticipation.syncIndexes();
    await Fulfillment.syncIndexes();
    await PlacementEvidence.syncIndexes();
    await ParticipantBlock.syncIndexes();
    for (const id of [ada, bea, cy, dee]) {
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

  // ------------------------------------------- Add 5 minutes under a Block

  describe("current holder extension across a Block", () => {
    it("extends under the ordinary rules for a helper-owned Block, and keeps the one-use rule", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      const before = await row(request._id);

      const extended = await extend(request._id, ada);

      expect(extended.statusCode).toBe(200);
      expect(Object.keys(extended.body)).toEqual(["claim"]);
      expect(Object.keys(extended.body.claim).sort()).toEqual([
        "claimExpiresAt",
        "claimExtendedAt",
      ]);
      const after = await row(request._id);
      expect(after!.claimExpiresAt!.getTime()).toBe(
        before!.claimExpiresAt!.getTime() + claimRoute.CLAIM_EXTENSION_MS
      );
      // The lock mirrors the new deadline exactly as for any extension.
      const lock = await Participant.findById(ada)
        .select("+activeReservationClaimExpiresAt")
        .lean();
      expect(lock!.activeReservationClaimExpiresAt!.getTime()).toBe(
        after!.claimExpiresAt!.getTime()
      );
      const second = await extend(request._id, ada);
      expect(second.statusCode).toBe(409);
      expect(second.body.error.code).toBe("CLAIM_EXTENSION_ALREADY_USED");
    });

    it("extends identically when the requester owns the Block, with no ownership oracle", async () => {
      // Helper-owned: ada answers Yes on bea's request.
      const helperOwned = await holdAndAnswerYes(bea, ada);
      // Requester-owned: dee blocks cy after cy placed a first request, while
      // cy holds a second one.
      const first = await createRequest(dee);
      expect((await claim(first._id, cy)).statusCode).toBe(200);
      expect((await fulfill(first._id, cy)).statusCode).toBe(200);
      const second = await createRequest(dee);
      expect((await claim(second._id, cy)).statusCode).toBe(200);
      expect((await block(first._id, dee)).statusCode).toBe(200);

      const a = await extend(helperOwned.request._id, ada);
      const b = await extend(second._id, cy);

      expect(a.statusCode).toBe(200);
      expect(b.statusCode).toBe(200);
      expect(Object.keys(a.body)).toEqual(Object.keys(b.body));
      expect(Object.keys(a.body.claim).sort()).toEqual(
        Object.keys(b.body.claim).sort()
      );
      // The reconstructed read cannot tell the two apart either.
      const readA = await activeReservation(ada);
      const readB = await activeReservation(cy);
      expect(readA.body.reservation.directContactRestricted).toBe(true);
      expect(readB.body.reservation.directContactRestricted).toBe(true);
      expect(Object.keys(readA.body.reservation).sort()).toEqual(
        Object.keys(readB.body.reservation).sort()
      );
    });

    it.each([
      {
        name: "request does not have five more minutes",
        shape: async (id: unknown) => {
          // The reservation is capped by the request's own deadline.
          await MealRequest.updateOne(
            { _id: id },
            { $set: { expiresAt: new Date(Date.now() + 10 * 60 * 1000) } }
          ).exec();
          await MealRequest.updateOne(
            { _id: id },
            { $min: { claimExpiresAt: new Date(Date.now() + 10 * 60 * 1000) } }
          ).exec();
        },
        code: "CLAIM_EXTENSION_INSUFFICIENT_TIME",
      },
      {
        name: "reservation already lapsed",
        shape: async (id: unknown) => lapseReservation(id),
        code: "CLAIM_EXPIRED",
      },
    ])(
      "keeps the ordinary refusal when the $name, identical to an unblocked helper",
      async ({ shape, code }) => {
        const blocked = await holdAndAnswerYes(bea, ada);
        const plain = await createRequest(dee);
        expect((await claim(plain._id, cy)).statusCode).toBe(200);
        await shape(blocked.request._id);
        await shape(plain._id);

        const withBlock = await extend(blocked.request._id, ada);
        const withoutBlock = await extend(plain._id, cy);

        expect(withBlock.statusCode).toBe(409);
        expect(withBlock.body.error.code).toBe(code);
        expect(withBlock).toEqual(withoutBlock);
      }
    );

    it("still fences every new claim, every other helper, and the blocked pair", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      // The holder is free to leave, so the fence — not the one-active-
      // reservation lock — is what the next claims below are answered by.
      expect((await release(request._id, ada)).statusCode).toBe(200);
      const another = await createRequest(bea);
      const unrelated = await createRequest(dee);

      // A different request of the same requester: fenced for ada, open to cy.
      const adaAnother = await claim(another._id, ada);
      expect(adaAnother.statusCode).toBe(404);
      expect(adaAnother.body.error.code).toBe("REQUEST_NOT_FOUND");
      expect((await claim(another._id, cy)).statusCode).toBe(200);
      // An unrelated request is unaffected by the pair's Block.
      expect((await claim(unrelated._id, ada)).statusCode).toBe(200);
      // The marked request is not offered to another helper either.
      expect((await claim(request._id, dee)).statusCode).toBe(409);
    });
  });

  // --------------------------- durable authority, atomic with the Yes Block

  describe("durable post-Yes authority", () => {
    it("is established by a Yes Block on the caller's live reservation and by nothing else", async () => {
      // Yes.
      const yes = await createRequest(bea);
      expect((await claim(yes._id, ada)).statusCode).toBe(200);
      expect((await row(yes._id))!.externalOrderAffirmed).toBeUndefined();
      const fenceBefore = await participantState();
      expect(
        (await block(yes._id, ada, { externalOrderPlaced: true })).statusCode
      ).toBe(200);
      // One transaction: the Block row, both fence bumps, and the marker.
      expect((await row(yes._id))!.externalOrderAffirmed).toBe(true);
      expect(await ParticipantBlock.countDocuments({})).toBe(1);
      const fenceAfter = await participantState();
      for (const id of [ada, bea]) {
        const before = fenceBefore.find((entry) => entry.id === String(id))!;
        const after = fenceAfter.find((entry) => entry.id === String(id))!;
        expect(after.blockFenceEpoch).toBe(before.blockFenceEpoch + 1);
      }
      await resetState();

      // No.
      const no = await createRequest(bea);
      expect((await claim(no._id, ada)).statusCode).toBe(200);
      expect(
        (await block(no._id, ada, { externalOrderPlaced: false })).statusCode
      ).toBe(200);
      expect((await row(no._id))!.externalOrderAffirmed).toBeUndefined();
      await resetState();

      // Pre-help Block: no answer, no reservation, no marker.
      const pre = await createRequest(bea);
      expect((await block(pre._id, ada)).statusCode).toBe(200);
      expect((await row(pre._id))!.externalOrderAffirmed).toBeUndefined();
      await resetState();

      // A Yes about a reservation the caller never held is refused (C1),
      // whether the request is open or someone else holds it, and writes
      // nothing: no Block, no fence, no marker.
      const never = await createRequest(bea);
      const held = await createRequest(bea);
      expect((await claim(held._id, cy)).statusCode).toBe(200);
      const heldBefore = reservationFields(await row(held._id));
      const before = await participantState();
      for (const target of [never, held]) {
        const refused = await block(target._id, ada, { externalOrderPlaced: true });
        expect(refused.statusCode).toBe(409);
        expect(refused.body).toEqual(STATE_CHANGED);
        expect((await row(target._id))!.externalOrderAffirmed).toBeUndefined();
      }
      expect(await ParticipantBlock.countDocuments({})).toBe(0);
      expect(await participantState()).toEqual(before);
      expect(reservationFields(await row(held._id))).toEqual(heldBefore);
    });

    it("is written in the same transaction as the Block: an aborted Block leaves no marker and no row", async () => {
      const request = await createRequest(bea);
      expect((await claim(request._id, ada)).statusCode).toBe(200);
      const original = MealRequest.updateOne.bind(MealRequest);
      // Runs the marker write for real inside the Block's transaction, then
      // fails the Block: a separate, non-transactional write would survive.
      vi.spyOn(MealRequest, "updateOne").mockImplementationOnce(((
        ...args: Parameters<typeof original>
      ) => {
        const query = original(...args);
        return {
          exec: async () => {
            await query.exec();
            throw new Error("injected failure after the marker write");
          },
        };
      }) as never);

      const failed = await block(request._id, ada, { externalOrderPlaced: true });

      expect(failed.statusCode).toBe(500);
      expect(await ParticipantBlock.countDocuments({})).toBe(0);
      const after = await row(request._id);
      expect(after!.externalOrderAffirmed).toBeUndefined();
      expect(after!.status).toBe("claimed");
      expect(String(after!.helperParticipantId)).toBe(String(ada));
    });

    it("is written when the Yes arrives just after the deadline, before anyone re-claimed", async () => {
      const request = await createRequest(bea);
      expect((await claim(request._id, ada)).statusCode).toBe(200);
      // The client sent the Yes while the reservation was live; by the time
      // the server processes it the deadline has passed. Expiry never clears
      // the binding, so it is still the caller's reservation.
      await lapseReservation(request._id);

      const result = await block(request._id, ada, { externalOrderPlaced: true });

      expect(result.statusCode).toBe(200);
      expect((await row(request._id))!.externalOrderAffirmed).toBe(true);
      // The request that passive expiry would otherwise have reopened is not
      // offered to anyone.
      expect((await board(cy)).has(String(request._id))).toBe(false);
      const refused = await claim(request._id, cy);
      expect(refused.statusCode).toBe(409);
      expect(refused.body.error.code).toBe("REQUEST_ALREADY_CLAIMED");
    });

    it("refuses a Yes whose reservation was already released, writing nothing (C1)", async () => {
      const request = await createRequest(bea);
      expect((await claim(request._id, ada)).statusCode).toBe(200);
      // An ordinary release committed first, before any Yes was affirmed.
      expect((await release(request._id, ada)).statusCode).toBe(200);
      const requestBefore = reservationFields(await row(request._id));
      const before = await participantState();

      const result = await block(request._id, ada, { externalOrderPlaced: true });

      // There is no reservation left to attach the answer to, so the Yes
      // cannot succeed: no Block, no fence bump, no marker, no success body.
      expect(result.statusCode).toBe(409);
      expect(result.body).toEqual(STATE_CHANGED);
      expect(await ParticipantBlock.countDocuments({})).toBe(0);
      expect(await participantState()).toEqual(before);
      expect(reservationFields(await row(request._id))).toEqual(requestBefore);
      expect((await row(request._id))!.status).toBe("open");
      // The pair is not fenced by the refused attempt: the request is still
      // ordinarily offered, including to unrelated helpers.
      expect((await board(cy)).has(String(request._id))).toBe(true);
      // The helper may retry Block from the ordinary surfaces (no answer).
      const retried = await block(request._id, ada);
      expect(retried.statusCode).toBe(200);
      expect((await row(request._id))!.externalOrderAffirmed).toBeUndefined();
    });

    it("refuses a Yes after the helper's own placement superseded the reservation (C1)", async () => {
      const request = await createRequest(bea);
      expect((await claim(request._id, ada)).statusCode).toBe(200);
      expect((await fulfill(request._id, ada)).statusCode).toBe(200);
      const requestBefore = reservationFields(await row(request._id));
      const before = await participantState();

      const result = await block(request._id, ada, { externalOrderPlaced: true });

      expect(result.statusCode).toBe(409);
      expect(result.body).toEqual(STATE_CHANGED);
      expect(await ParticipantBlock.countDocuments({})).toBe(0);
      expect(await participantState()).toEqual(before);
      // Placement truth is untouched.
      expect(reservationFields(await row(request._id))).toEqual(requestBefore);
      expect((await row(request._id))!.status).toBe("placed");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(1);
    });

    it("refuses a repeated Yes after a post-Yes Stop retired the reservation (C1)", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      expect((await release(request._id, ada)).statusCode).toBe(200);
      const requestBefore = reservationFields(await row(request._id));
      const before = await participantState();
      const blockRows = await ParticipantBlock.find({}).lean();

      const result = await block(request._id, ada, { externalOrderPlaced: true });

      expect(result.statusCode).toBe(409);
      expect(result.body).toEqual(STATE_CHANGED);
      expect(await ParticipantBlock.find({}).lean()).toEqual(blockRows);
      expect(await participantState()).toEqual(before);
      expect(reservationFields(await row(request._id))).toEqual(requestBefore);
    });

    it("refuses a Yes once the request itself has expired, even with the binding intact (C1)", async () => {
      const request = await createRequest(bea);
      expect((await claim(request._id, ada)).statusCode).toBe(200);
      await lapseReservation(request._id);
      // The whole request is past its own deadline; expiry never clears the
      // helper binding, so only the request deadline distinguishes this from
      // the accepted expiry-boundary case.
      await MealRequest.updateOne(
        { _id: request._id },
        { $set: { expiresAt: new Date(Date.now() - 500) } }
      ).exec();
      const requestBefore = reservationFields(await row(request._id));
      const before = await participantState();

      const result = await block(request._id, ada, { externalOrderPlaced: true });

      expect(result.statusCode).toBe(409);
      expect(result.body).toEqual(STATE_CHANGED);
      expect(await ParticipantBlock.countDocuments({})).toBe(0);
      expect(await participantState()).toEqual(before);
      expect(reservationFields(await row(request._id))).toEqual(requestBefore);
    });

    it("is idempotent for a repeated Yes and keeps the original Block row", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);

      const again = await block(request._id, ada, { externalOrderPlaced: true });

      expect(again.statusCode).toBe(200);
      expect(await ParticipantBlock.countDocuments({})).toBe(1);
      expect((await row(request._id))!.externalOrderAffirmed).toBe(true);
    });
  });

  // ------------------------------------------------------- post-Yes Stop

  describe("Stop after Yes", () => {
    it("retires the helper's reservation and lock without reopening the request", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);

      const stopped = await release(request._id, ada);

      expect(stopped.statusCode).toBe(200);
      expect(stopped.body).toEqual({ released: true });
      const after = await row(request._id);
      expect(after!.status).toBe("claimed"); // never `open`
      expect(after!.externalOrderAffirmed).toBe(true);
      expect(after!.helperParticipantId).toBeUndefined();
      expect(after!.claimTokenDigest).toBeUndefined();
      expect(after!.claimExpiresAt).toBeUndefined();
      expect(after!.claimedAt).toBeUndefined();
      const lock = await Participant.findById(ada)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
        .lean();
      expect(lock!.activeReservationRequestId).toBeNull();
      expect(lock!.activeReservationClaimExpiresAt).toBeNull();
      // Nothing placed, fabricated, or recorded; the Block and participation stay.
      expect(await Fulfillment.countDocuments({})).toBe(0);
      expect(await ParticipantBlock.countDocuments({})).toBe(1);
      expect(
        await RequestParticipation.countDocuments({ requestId: request._id })
      ).toBe(1);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("accepts the raw claim token as authority exactly like participant authority", async () => {
      const { request, claimToken } = await holdAndAnswerYes(bea, ada);

      const stopped = await release(request._id, ada, claimToken);

      expect(stopped.statusCode).toBe(200);
      expect(stopped.body).toEqual({ released: true });
      expect((await row(request._id))!.status).toBe("claimed");
    });

    it("frees the same helper to claim another eligible request, and nobody else can claim the stopped one", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      expect((await release(request._id, ada)).statusCode).toBe(200);
      const other = await createRequest(dee);

      const next = await claim(other._id, ada);

      expect(next.statusCode).toBe(200);
      // Another helper, the requester, and the stopped helper herself.
      const byOther = await claim(request._id, cy);
      expect(byOther.statusCode).toBe(409);
      expect(byOther.body.error.code).toBe("REQUEST_ALREADY_CLAIMED");
      expect((await claim(request._id, bea)).body.error.code).toBe(
        REQUEST_OWN_REQUEST_CODE
      );
      expect((await claim(request._id, ada)).statusCode).toBe(409); // holds `other`
      expect((await row(request._id))!.status).toBe("claimed");
    });

    it("cannot be resumed or fulfilled with the retired authority, in either mode", async () => {
      const { request, claimToken } = await holdAndAnswerYes(bea, ada);
      expect((await release(request._id, ada)).statusCode).toBe(200);

      const byParticipant = await fulfill(request._id, ada);
      const byToken = await fulfill(request._id, ada, claimToken);
      const extendedByParticipant = await extend(request._id, ada);
      const extendedByToken = await extend(request._id, ada, claimToken);

      for (const call of [
        byParticipant,
        byToken,
        extendedByParticipant,
        extendedByToken,
      ]) {
        expect(call.statusCode).toBe(409);
        expect(call.body.error.code).toBe("REQUEST_NOT_CLAIMED");
      }
      expect(await Fulfillment.countDocuments({})).toBe(0);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
      expect((await row(request._id))!.status).toBe("claimed");
      // Nor does it surface as a reservation to continue.
      const rebuilt = await activeReservation(ada);
      expect(rebuilt.body).toMatchObject({
        reservation: null,
        placement: null,
        placements: [],
      });
    });

    it("answers a repeated Stop exactly like a repeated ordinary release, so nothing about the marker is learned", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      // The ordinary comparison: requester-owned fence, no marker.
      const first = await createRequest(dee);
      expect((await claim(first._id, cy)).statusCode).toBe(200);
      expect((await fulfill(first._id, cy)).statusCode).toBe(200);
      const plain = await createRequest(dee);
      expect((await claim(plain._id, cy)).statusCode).toBe(200);
      expect((await block(first._id, dee)).statusCode).toBe(200);

      const stopped = await release(request._id, ada);
      const plainStopped = await release(plain._id, cy);
      expect(stopped).toEqual(plainStopped);
      expect((await row(plain._id))!.status).toBe("open");

      for (const action of [release, extend, fulfill] as const) {
        const withMarker = await action(request._id, ada);
        const without = await action(plain._id, cy);
        expect(withMarker.statusCode).toBe(without.statusCode);
        expect(withMarker.body).toEqual(without.body);
      }
    });

    it("is excluded from the board and every projection, whatever the viewer", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      expect((await release(request._id, ada)).statusCode).toBe(200);

      for (const viewer of [ada, bea, cy, null]) {
        expect((await board(viewer)).has(String(request._id))).toBe(false);
      }
      // Detail answers for the requester and a bystander with the reserved
      // status — never `open`, which would advertise it.
      for (const viewer of [bea, cy]) {
        const read = await detail(request._id, viewer);
        expect(read.statusCode).toBe(200);
        expect(read.body.request.status).toBe("claimed");
      }
      // W4-R5: an unverified viewer is refused, never shown the status.
      expect((await detail(request._id, null)).statusCode).toBe(401);
      // The stopped helper is a fenced counterpart again: indistinguishable
      // from a request that does not exist.
      const missing = await detail(new mongoose.Types.ObjectId(), ada);
      expect((await detail(request._id, ada)).body).toEqual(missing.body);
    });

    it("refuses a second Block's 'not placed' answer from reopening a request that carries the authority", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);

      // A contradictory later answer must not undo the earlier, safer one.
      const contradictory = await block(request._id, ada, {
        externalOrderPlaced: false,
      });

      expect(contradictory.statusCode).toBe(200);
      const after = await row(request._id);
      expect(after!.status).toBe("claimed");
      expect(after!.externalOrderAffirmed).toBe(true);
      expect(after!.helperParticipantId).toBeUndefined();
      expect((await claim(request._id, cy)).statusCode).toBe(409);
    });

    it("leaves ordinary release without the authority exactly as it was", async () => {
      const first = await createRequest(dee);
      expect((await claim(first._id, cy)).statusCode).toBe(200);
      expect((await fulfill(first._id, cy)).statusCode).toBe(200);
      const second = await createRequest(dee);
      expect((await claim(second._id, cy)).statusCode).toBe(200);
      // Requester-owned Block: the helper's later Stop is an ordinary release.
      expect((await block(first._id, dee)).statusCode).toBe(200);

      const stopped = await release(second._id, cy);

      expect(stopped.body).toEqual({ released: true });
      const after = await row(second._id);
      expect(after!.status).toBe("open");
      expect(after!.helperParticipantId).toBeUndefined();
      expect(after!.externalOrderAffirmed).toBeUndefined();
      // Open to unfenced helpers; fenced from the blocked helper.
      expect((await board(ada)).has(String(second._id))).toBe(true);
      expect((await claim(second._id, ada)).statusCode).toBe(200);
    });
  });

  // ----------------------------------------------------- passive expiry

  describe("passive expiry", () => {
    it("does not reopen a request carrying the authority, while an ordinary lapse still does", async () => {
      const marked = await holdAndAnswerYes(bea, ada);
      const ordinary = await createRequest(dee);
      expect((await claim(ordinary._id, cy)).statusCode).toBe(200);
      await lapseReservation(marked.request._id);
      await lapseReservation(ordinary._id);

      const now = new Date();
      // The shared predicate used by the board, digest, alert, push, and sweep.
      expect(
        await MealRequest.exists({
          _id: marked.request._id,
          ...buildEffectiveAvailabilityFilter(now),
        })
      ).toBeNull();
      expect(
        await MealRequest.exists({
          _id: ordinary._id,
          ...buildEffectiveAvailabilityFilter(now),
        })
      ).not.toBeNull();
      expect((await board(cy)).has(String(marked.request._id))).toBe(false);
      // Detail never advertises it as open.
      expect((await detail(marked.request._id, cy)).body.request.status).toBe(
        "claimed"
      );
      // Claim: refused for the marked request, granted for the ordinary one.
      const refused = await claim(marked.request._id, dee);
      expect(refused.statusCode).toBe(409);
      expect(refused.body.error.code).toBe("REQUEST_ALREADY_CLAIMED");
      expect((await claim(ordinary._id, ada)).statusCode).toBe(200);
      // And nothing mutated: still claimed, marker intact.
      const after = await row(marked.request._id);
      expect(after!.status).toBe("claimed");
      expect(after!.externalOrderAffirmed).toBe(true);
    });

    it("stays unavailable after Stop and then the original deadline passes", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      expect((await release(request._id, ada)).statusCode).toBe(200);
      await MealRequest.updateOne(
        { _id: request._id },
        { $set: { updatedAt: new Date(Date.now() - 60 * 60 * 1000) } }
      ).exec();

      expect(
        await MealRequest.exists({
          _id: request._id,
          ...buildEffectiveAvailabilityFilter(new Date(Date.now() + 60 * 60 * 1000)),
        })
      ).toBeNull();
      expect((await claim(request._id, cy)).statusCode).toBe(409);
    });

    it("keeps ordinary Request TTL: retention is unchanged and the row and authority go together", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      const created = await row(request._id);
      expect((await release(request._id, ada)).statusCode).toBe(200);

      const stopped = await MealRequest.findById(request._id).lean();
      // Neither Yes nor Stop touched the retention horizon.
      expect(stopped!.deleteAt!.getTime()).toBe(created!.deleteAt!.getTime());
      expect(stopped!.expiresAt!.getTime()).toBe(created!.expiresAt!.getTime());

      // The existing cleanup predicate is the only thing that ends it.
      await MealRequest.updateOne(
        { _id: request._id },
        { $set: { deleteAt: new Date(Date.now() - 1000) } }
      ).exec();
      await MealRequest.deleteMany({ deleteAt: { $lte: new Date() } });
      expect(await MealRequest.findById(request._id)).toBeNull();
      // The Participant Block has its own, separately accepted persistence.
      expect(await ParticipantBlock.countDocuments({})).toBe(1);
      const blockRow = await ParticipantBlock.findOne({}).lean();
      expect(JSON.stringify(blockRow)).not.toMatch(FORBIDDEN_MARKER);
    });
  });

  // -------------------------------------------------------------- Unblock

  describe("Unblock", () => {
    it("never reopens a post-Yes-stopped request", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      expect((await release(request._id, ada)).statusCode).toBe(200);
      const blockRow = await ParticipantBlock.findOne({}).select("_id").lean();

      const removed = await unblock(blockRow!._id, ada);

      expect(removed.statusCode).toBe(200);
      expect(await ParticipantBlock.countDocuments({})).toBe(0);
      const after = await row(request._id);
      expect(after!.status).toBe("claimed");
      expect(after!.externalOrderAffirmed).toBe(true);
      expect((await board(cy)).has(String(request._id))).toBe(false);
      expect((await board(ada)).has(String(request._id))).toBe(false);
      expect((await claim(request._id, cy)).statusCode).toBe(409);
      // Prospective only: the stopped helper's durable participation remains.
      const rebuilt = await claim(request._id, ada);
      expect(rebuilt.statusCode).toBe(409);
      expect(rebuilt.body.error.code).toBe(REQUEST_ALREADY_PARTICIPATED_CODE);
    });

    it("never reopens a Yes-blocked request whose reservation is still live or has lapsed", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      const blockRow = await ParticipantBlock.findOne({}).select("_id").lean();
      expect((await unblock(blockRow!._id, ada)).statusCode).toBe(200);
      await lapseReservation(request._id);

      expect((await board(cy)).has(String(request._id))).toBe(false);
      expect((await claim(request._id, cy)).statusCode).toBe(409);
    });
  });

  // ---------------------------------------------------------------- races

  describe("one coherent winner", () => {
    it("fulfillment before Stop wins: placed is authoritative and a later Stop cannot undo it", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      const placed = await fulfill(request._id, ada);
      expect(placed.statusCode).toBe(200);
      expect(placed.body.request.status).toBe("placed");

      const late = await release(request._id, ada);

      expect(late.statusCode).toBe(409);
      expect(late.body.error.code).toBe("REQUEST_ALREADY_PLACED");
      const after = await row(request._id);
      expect(after!.status).toBe("placed");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      expect((await claim(request._id, cy)).body.error.code).toBe(
        "REQUEST_ALREADY_PLACED"
      );
    });

    it("Stop before fulfillment wins: the helper exits and the retired authority cannot commit", async () => {
      const { request, claimToken } = await holdAndAnswerYes(bea, ada);
      expect((await release(request._id, ada)).statusCode).toBe(200);

      const late = await fulfill(request._id, ada, claimToken);

      expect(late.statusCode).toBe(409);
      expect(await Fulfillment.countDocuments({})).toBe(0);
      expect((await row(request._id))!.status).toBe("claimed");
    });

    it("extension first: the same reservation continues, and a Stop that met the earlier version is classified existing-style and never adopts it", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      const original = await row(request._id);
      // `releaseClaim` captures the reservation version, *then* opens its
      // session. Committing the extension at that exact seam is the
      // interleaving where the Stop met the earlier version.
      const startSession = mongoose.startSession.bind(mongoose);
      vi.spyOn(mongoose, "startSession").mockImplementationOnce((async (
        ...args: Parameters<typeof startSession>
      ) => {
        expect((await extend(request._id, ada)).statusCode).toBe(200);
        return await startSession(...args);
      }) as never);

      const lost = await release(request._id, ada);

      expect(lost.statusCode).toBe(500);
      expect(lost.body.error.code).toBe("INTERNAL_FAILURE");
      const after = await row(request._id);
      expect(after!.status).toBe("claimed");
      expect(after!.externalOrderAffirmed).toBe(true);
      expect(String(after!.helperParticipantId)).toBe(String(ada));
      expect(after!.claimExtendedAt).toBeInstanceOf(Date);
      expect(after!.claimExpiresAt!.getTime()).toBe(
        original!.claimExpiresAt!.getTime() + claimRoute.CLAIM_EXTENSION_MS
      );
      // A fresh Stop against the current version then succeeds.
      vi.restoreAllMocks();
      expect((await release(request._id, ada)).statusCode).toBe(200);
      expect((await row(request._id))!.helperParticipantId).toBeUndefined();
    });

    it("Stop, extension and fulfillment racing leave exactly one outcome and never an open or claimable request", async () => {
      for (let attempt = 0; attempt < 12; attempt += 1) {
        await resetState();
        const { request } = await holdAndAnswerYes(bea, ada);

        const [stopped, extended, placed] = await Promise.all([
          release(request._id, ada),
          extend(request._id, ada),
          fulfill(request._id, ada),
        ]);

        const after = await row(request._id);
        const fulfilled = await Fulfillment.countDocuments({
          requestId: request._id,
        });
        expect(after!.status).not.toBe("open");
        if (fulfilled === 1) {
          // Fulfillment won: placed is authoritative, nothing else changed it.
          expect(after!.status).toBe("placed");
          expect(placed.statusCode).toBe(200);
          expect(stopped.statusCode).not.toBe(200);
        } else {
          // Stop won: retired, non-claimable, nothing fabricated.
          expect(after!.status).toBe("claimed");
          expect(stopped.statusCode).toBe(200);
          expect(placed.statusCode).toBe(409);
          expect(after!.helperParticipantId).toBeUndefined();
          expect(after!.claimTokenDigest).toBeUndefined();
          expect(after!.claimExpiresAt).toBeUndefined();
          expect(after!.externalOrderAffirmed).toBe(true);
        }
        // Whichever won, the extension never produced an authority the loser
        // could use, and the helper's lock is clear.
        expect([200, 409]).toContain(extended.statusCode);
        const lock = await Participant.findById(ada)
          .select("+activeReservationRequestId")
          .lean();
        expect(lock!.activeReservationRequestId).toBeNull();
        expect((await claim(request._id, cy)).statusCode).not.toBe(200);
      }
    }, 90_000);

    // Server-side, a Stop that commits strictly before the Yes is an ordinary
    // release (no Yes had been affirmed yet) and the request reopens; the
    // iOS client never issues the two together (`canReleaseActiveClaim` is
    // false while a Block is in flight). What this proves is that the two can
    // never combine into an *open request that carries the authority*, and
    // that a Yes that lost never reports success or writes anything (C1).
    it("Yes Block racing an ordinary Stop has one coherent winner and never a false Block success", async () => {
      const outcomes = new Set<string>();
      for (let attempt = 0; attempt < 12; attempt += 1) {
        await resetState();
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);
        const fenceBefore = await participantState();

        const [stopped, blocked] = await Promise.all([
          release(request._id, ada),
          block(request._id, ada, { externalOrderPlaced: true }),
        ]);

        const after = await row(request._id);
        expect(stopped.statusCode).toBe(200);
        if (blocked.statusCode === 200) {
          // Yes committed first: Block + authority together, and the Stop
          // then retired without reopening.
          outcomes.add("yes-first");
          expect(after!.externalOrderAffirmed).toBe(true);
          expect(after!.status).toBe("claimed");
          expect(after!.helperParticipantId).toBeUndefined();
          expect(await ParticipantBlock.countDocuments({})).toBe(1);
        } else {
          // Stop committed first, when no Yes had been affirmed: ordinary
          // release, and the late Yes wrote nothing at all.
          outcomes.add("stop-first");
          expect(blocked.statusCode).toBe(409);
          expect(blocked.body).toEqual(STATE_CHANGED);
          expect(after!.status).toBe("open");
          expect(after!.externalOrderAffirmed).toBeUndefined();
          expect(await ParticipantBlock.countDocuments({})).toBe(0);
          const fenceAfter = await participantState();
          expect(fenceAfter.map((entry) => entry.blockFenceEpoch)).toEqual(
            fenceBefore.map((entry) => entry.blockFenceEpoch)
          );
        }
        const lock = await Participant.findById(ada)
          .select("+activeReservationRequestId")
          .lean();
        expect(lock!.activeReservationRequestId).toBeNull();
      }
      // Recorded, not required: which orderings this run happened to exercise.
      expect(outcomes.size).toBeGreaterThan(0);
    }, 90_000);

    it("a Yes whose reservation was already re-claimed by another helper is refused and touches nothing of theirs (C1)", async () => {
      const request = await createRequest(bea);
      expect((await claim(request._id, ada)).statusCode).toBe(200);
      await lapseReservation(request._id);
      await Participant.updateOne(
        { _id: ada },
        { $set: { activeReservationClaimExpiresAt: new Date(Date.now() - 1000) } }
      ).exec();
      expect((await claim(request._id, cy)).statusCode).toBe(200);
      const cysReservation = reservationFields(await row(request._id));
      const before = await participantState();

      const result = await block(request._id, ada, { externalOrderPlaced: true });

      // Refused: no Block success body, no Block row, no fence bump on anyone,
      // no marker, and cy's reservation — status, binding, digest, deadline,
      // one-use marker, lock — byte-for-byte as it was.
      expect(result.statusCode).toBe(409);
      expect(result.body).toEqual(STATE_CHANGED);
      expect(await ParticipantBlock.countDocuments({})).toBe(0);
      expect(await participantState()).toEqual(before);
      const after = await row(request._id);
      expect(reservationFields(after)).toEqual(cysReservation);
      expect(after!.externalOrderAffirmed).toBeUndefined();
      expect(String(after!.helperParticipantId)).toBe(String(cy));
      // cy keeps every ordinary action on their own reservation.
      expect((await extend(request._id, cy)).statusCode).toBe(200);
      expect((await fulfill(request._id, cy)).statusCode).toBe(200);
    });

    it("a Yes racing another helper's re-claim of the lapsed reservation has one coherent winner", async () => {
      const outcomes = new Set<string>();
      for (let attempt = 0; attempt < 12; attempt += 1) {
        await resetState();
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);
        await lapseReservation(request._id);
        const fenceBefore = await participantState();

        const [reclaimed, blocked] = await Promise.all([
          claim(request._id, cy),
          block(request._id, ada, { externalOrderPlaced: true }),
        ]);

        const after = await row(request._id);
        if (blocked.statusCode === 200) {
          // The Yes committed against ada's still-bound reservation: the
          // authority exists, and cy's claim lost and was never granted.
          outcomes.add("yes-first");
          expect(after!.externalOrderAffirmed).toBe(true);
          expect(String(after!.helperParticipantId)).toBe(String(ada));
          expect(reclaimed.statusCode).toBe(409);
          expect(reclaimed.body.error.code).toBe("REQUEST_ALREADY_CLAIMED");
          expect(await ParticipantBlock.countDocuments({})).toBe(1);
          expect(
            await RequestParticipation.countDocuments({ participantId: cy })
          ).toBe(0);
        } else {
          // cy's claim committed first: the Yes is refused and writes nothing.
          outcomes.add("reclaim-first");
          expect(blocked.statusCode).toBe(409);
          expect(blocked.body).toEqual(STATE_CHANGED);
          expect(reclaimed.statusCode).toBe(200);
          expect(String(after!.helperParticipantId)).toBe(String(cy));
          expect(after!.externalOrderAffirmed).toBeUndefined();
          expect(await ParticipantBlock.countDocuments({})).toBe(0);
          const fenceAfter = await participantState();
          expect(fenceAfter.map((entry) => entry.blockFenceEpoch)).toEqual(
            fenceBefore.map((entry) => entry.blockFenceEpoch)
          );
        }
        // Never both: no request carries the authority while another helper
        // holds it, and none is offered.
        expect((await board(dee)).has(String(request._id))).toBe(false);
      }
      expect(outcomes.size).toBeGreaterThan(0);
    }, 90_000);

    // Deterministic form of the races above: the competing mutation commits
    // *after* the Yes transaction has read its snapshot (the caller still
    // bound) and before its first write. Only MongoDB's write-conflict on the
    // Block's own writes can then save the Yes from committing against a
    // reservation the caller no longer holds: the callback must be retried on a
    // fresh snapshot and refused, writing nothing.
    for (const scenario of [
      {
        name: "an explicit release",
        lapse: false,
        interleave: (requestId: unknown) => release(requestId, ada),
        expected: { status: "open", helper: undefined as string | undefined },
      },
      {
        name: "another helper's re-claim of the lapsed reservation",
        lapse: true,
        interleave: (requestId: unknown) => claim(requestId, cy),
        expected: { status: "claimed", helper: String(cy) },
      },
      {
        name: "the helper's own placement",
        lapse: false,
        interleave: (requestId: unknown) => fulfill(requestId, ada),
        expected: { status: "placed", helper: String(ada) },
      },
    ]) {
      it(`refuses a Yes when ${scenario.name} commits inside its transaction window (C1)`, async () => {
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);
        if (scenario.lapse) await lapseReservation(request._id);
        const fenceBefore = await participantState();
        let interleaved: Call | undefined;
        const original = ParticipantBlock.findOneAndUpdate.bind(ParticipantBlock);
        const upsert = vi
          .spyOn(ParticipantBlock, "findOneAndUpdate")
          .mockImplementationOnce(((...args: Parameters<typeof original>) => {
            const query = original(...args);
            return {
              lean: () => ({
                exec: async () => {
                  // The snapshot already read the caller as bound.
                  interleaved = await scenario.interleave(request._id);
                  return await query.lean().exec();
                },
              }),
            };
          }) as never);

        const result = await block(request._id, ada, { externalOrderPlaced: true });

        // The competing mutation really did commit inside the window.
        expect(upsert).toHaveBeenCalled();
        expect(interleaved!.statusCode).toBe(200);
        // And the Yes was refused on the retried snapshot, writing nothing.
        expect(result.statusCode).toBe(409);
        expect(result.body).toEqual(STATE_CHANGED);
        expect(await ParticipantBlock.countDocuments({})).toBe(0);
        const fenceAfter = await participantState();
        expect(fenceAfter.map((entry) => entry.blockFenceEpoch)).toEqual(
          fenceBefore.map((entry) => entry.blockFenceEpoch)
        );
        const after = await row(request._id);
        expect(after!.externalOrderAffirmed).toBeUndefined();
        expect(after!.status).toBe(scenario.expected.status);
        expect(
          after!.helperParticipantId ? String(after!.helperParticipantId) : undefined
        ).toBe(scenario.expected.helper);
      });
    }

    it("a Yes racing the helper's own fulfillment never reports a Block without the authority", async () => {
      const outcomes = new Set<string>();
      for (let attempt = 0; attempt < 12; attempt += 1) {
        await resetState();
        const request = await createRequest(bea);
        expect((await claim(request._id, ada)).statusCode).toBe(200);

        const [placed, blocked] = await Promise.all([
          fulfill(request._id, ada),
          block(request._id, ada, { externalOrderPlaced: true }),
        ]);

        const after = await row(request._id);
        // Fulfillment is authoritative whichever came first: a Yes Block
        // never prevents the order being recorded.
        expect(placed.statusCode).toBe(200);
        expect(after!.status).toBe("placed");
        expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
        if (blocked.statusCode === 200) {
          outcomes.add("yes-first");
          expect(after!.externalOrderAffirmed).toBe(true);
          expect(await ParticipantBlock.countDocuments({})).toBe(1);
        } else {
          outcomes.add("placement-first");
          expect(blocked.statusCode).toBe(409);
          expect(blocked.body).toEqual(STATE_CHANGED);
          expect(after!.externalOrderAffirmed).toBeUndefined();
          expect(await ParticipantBlock.countDocuments({})).toBe(0);
        }
      }
      expect(outcomes.size).toBeGreaterThan(0);
    }, 90_000);
  });

  // --------------------------------- post-Yes Stop destination signal (C3)

  describe("post-Yes Stop destination after Unblock (C3)", () => {
    const RESERVATION_KEYS = ["claimExpiresAt", "claimExtendedAt", "request"];

    it("is reported to the holder once no pair restriction remains, and survives their Unblock", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);

      // Pair restriction authoritative: the restriction alone, never the signal.
      const restricted = await activeReservation(ada);
      expect(restricted.body.reservation.directContactRestricted).toBe(true);
      expect(restricted.body.reservation).not.toHaveProperty("stopReturnsHome");

      const blockRow = await ParticipantBlock.findOne({}).select("_id").lean();
      expect((await unblock(blockRow!._id, ada)).statusCode).toBe(200);

      // No restriction remains; the durable authority still exists, and its
      // one lifecycle consequence is reported, affirmatively, to the holder.
      expect((await row(request._id))!.externalOrderAffirmed).toBe(true);
      const unrestricted = await activeReservation(ada);
      expect(unrestricted.statusCode).toBe(200);
      expect(unrestricted.body.reservation.request.id).toBe(String(request._id));
      expect(unrestricted.body.reservation).not.toHaveProperty(
        "directContactRestricted"
      );
      expect(unrestricted.body.reservation.stopReturnsHome).toBe(true);
      expect(Object.keys(unrestricted.body.reservation).sort()).toEqual(
        [...RESERVATION_KEYS, "stopReturnsHome"].sort()
      );
      // Nothing that names the authority, an owner, a direction, or a Block.
      expect(JSON.stringify(unrestricted.body)).not.toMatch(FORBIDDEN_MARKER);
      expect(JSON.stringify(unrestricted.body)).not.toMatch(
        /block|owner|direction|fence|ParticipantId/i
      );
    });

    it("keeps post-Yes Stop semantics after the Unblock: retired, non-claimable, nothing fabricated", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      const blockRow = await ParticipantBlock.findOne({}).select("_id").lean();
      expect((await unblock(blockRow!._id, ada)).statusCode).toBe(200);

      const stopped = await release(request._id, ada);

      // The same acknowledgement every Stop gets.
      expect(stopped.statusCode).toBe(200);
      expect(stopped.body).toEqual({ released: true });
      const after = await row(request._id);
      expect(after!.status).toBe("claimed");
      expect(after!.externalOrderAffirmed).toBe(true);
      expect(after!.helperParticipantId).toBeUndefined();
      expect(after!.claimExpiresAt).toBeUndefined();
      expect(after!.claimTokenDigest).toBeUndefined();
      const lock = await Participant.findById(ada)
        .select("+activeReservationRequestId")
        .lean();
      expect(lock!.activeReservationRequestId).toBeNull();
      expect(await Fulfillment.countDocuments({})).toBe(0);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
      // Not offered to anyone, now that the pair is unfenced, and the stopped
      // helper cannot re-claim it.
      for (const viewer of [ada, cy, dee, null]) {
        expect((await board(viewer)).has(String(request._id))).toBe(false);
      }
      expect((await claim(request._id, cy)).body.error.code).toBe(
        "REQUEST_ALREADY_CLAIMED"
      );
      expect((await claim(request._id, ada)).body.error.code).toBe(
        REQUEST_ALREADY_PARTICIPATED_CODE
      );
      // Nothing to continue: the signal ends with the reservation.
      expect((await activeReservation(ada)).body).toMatchObject({
        reservation: null,
        placement: null,
        placements: [],
      });
    });

    it("is never reported for an ordinary reservation, restricted or not", async () => {
      // No Block at all.
      const plain = await createRequest(bea);
      expect((await claim(plain._id, ada)).statusCode).toBe(200);
      const unblocked = await activeReservation(ada);
      expect(Object.keys(unblocked.body.reservation).sort()).toEqual(
        RESERVATION_KEYS
      );
      await resetState();

      // A `No` Block releases; nothing is left to report.
      const answeredNo = await createRequest(bea);
      expect((await claim(answeredNo._id, ada)).statusCode).toBe(200);
      expect(
        (await block(answeredNo._id, ada, { externalOrderPlaced: false })).body
          .reservationReleased
      ).toBe(true);
      expect((await activeReservation(ada)).body.reservation).toBeNull();
      await resetState();

      // A pre-help Block of another of the requester's requests, then an
      // Unblock, while holding an ordinary reservation of a third requester.
      const viewed = await createRequest(bea);
      const held = await createRequest(dee);
      expect((await claim(held._id, ada)).statusCode).toBe(200);
      const preHelp = await block(viewed._id, ada);
      expect(preHelp.statusCode).toBe(200);
      expect((await unblock(preHelp.body.block.id, ada)).statusCode).toBe(200);
      expect(Object.keys((await activeReservation(ada)).body.reservation).sort()).toEqual(
        RESERVATION_KEYS
      );
    });

    it("creates no marker oracle while a pair restriction remains: requester-owned and helper-owned Yes reads have the same shape", async () => {
      // Helper-owned Yes Block: marker present, helper-owned restriction.
      await holdAndAnswerYes(bea, ada);
      // Requester-owned restriction with no Yes and no marker: dee blocks cy
      // after a placed request, while cy holds another of dee's requests.
      const first = await createRequest(dee);
      expect((await claim(first._id, cy)).statusCode).toBe(200);
      expect((await fulfill(first._id, cy)).statusCode).toBe(200);
      const plain = await createRequest(dee);
      expect((await claim(plain._id, cy)).statusCode).toBe(200);
      expect((await block(first._id, dee)).statusCode).toBe(200);
      expect((await row(plain._id))!.externalOrderAffirmed).toBeUndefined();

      const withMarker = (await activeReservation(ada)).body.reservation;
      const without = (await activeReservation(cy)).body.reservation;

      expect(Object.keys(withMarker).sort()).toEqual(Object.keys(without).sort());
      expect(withMarker.directContactRestricted).toBe(true);
      expect(without.directContactRestricted).toBe(true);
      expect(withMarker).not.toHaveProperty("stopReturnsHome");
      expect(without).not.toHaveProperty("stopReturnsHome");
    });

    it("stays withheld after the helper's own Unblock while the requester's independent Block remains", async () => {
      // A placed request between the pair gives the requester a Block entry.
      const first = await createRequest(bea);
      expect((await claim(first._id, ada)).statusCode).toBe(200);
      expect((await fulfill(first._id, ada)).statusCode).toBe(200);
      const { request } = await holdAndAnswerYes(bea, ada);
      expect((await block(first._id, bea)).statusCode).toBe(200);
      const adasBlock = await ParticipantBlock.findOne({ blockedRole: "requester" })
        .select("_id")
        .lean();
      expect((await unblock(adasBlock!._id, ada)).statusCode).toBe(200);
      expect(await ParticipantBlock.countDocuments({})).toBe(1);

      const read = (await activeReservation(ada)).body.reservation;

      // Still restricted, so still no signal: identical to any restricted read.
      expect(read.request.id).toBe(String(request._id));
      expect(read.directContactRestricted).toBe(true);
      expect(read).not.toHaveProperty("stopReturnsHome");
      // And a Stop still keeps the post-Yes semantics.
      expect((await release(request._id, ada)).statusCode).toBe(200);
      expect((await row(request._id))!.status).toBe("claimed");
      expect((await claim(request._id, cy)).statusCode).toBe(409);
    });

    it("appears on no board, detail, requester, claim, extension, release, or fulfillment response", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      const blockRow = await ParticipantBlock.findOne({}).select("_id").lean();
      expect((await unblock(blockRow!._id, ada)).statusCode).toBe(200);
      // The one participant-authorized surface that carries it.
      expect((await activeReservation(ada)).body.reservation.stopReturnsHome).toBe(
        true
      );

      const calls: Call[] = [
        await detail(request._id, bea),
        await detail(request._id, cy),
        await detail(request._id, ada),
        await detail(request._id, null),
        await claim(request._id, cy),
        await activeReservation(cy),
        await activeReservation(bea),
        await extend(request._id, ada),
        await release(request._id, ada),
        await release(request._id, ada),
        await fulfill(request._id, ada),
        await detail(request._id, bea),
      ];
      for (const call of calls) {
        const serialized = JSON.stringify(call.body ?? null);
        expect(serialized).not.toMatch(/stopReturnsHome/);
        expect(serialized).not.toMatch(FORBIDDEN_MARKER);
      }
      const marked = (await MealRequest.findById(request._id)
        .select(PRIVATE_FIELDS)
        .lean()) as unknown as PublicRequestDocument;
      for (const ownership of [
        { kind: "resolved" as const, participantId: String(bea) },
        { kind: "resolved" as const, participantId: String(ada) },
        { kind: "anonymous" as const },
      ]) {
        expect(
          JSON.stringify(buildPublicRequestDetailResponse(marked, new Date(), ownership))
        ).not.toMatch(/stopReturnsHome|affirmed/i);
        expect(
          JSON.stringify(
            buildPublicRequestListResponse(
              [marked as unknown as RequestListDocument],
              new Date(),
              ownership
            )
          )
        ).not.toMatch(/stopReturnsHome|affirmed/i);
      }
    });
  });

  // ------------------------------------------- W4-H1a required evidence

  describe("W4-H1a required placed-order evidence under an active Block", () => {
    it("still requires the screenshot after Yes: a screenshot-less completion is refused and the reservation survives", async () => {
      const { request, claimToken } = await holdAndAnswerYes(bea, ada);
      const requestBefore = reservationFields(await row(request._id));

      for (const result of [
        await fulfill(request._id, ada, undefined, {}, false),
        await fulfill(request._id, ada, claimToken, {}, false),
      ]) {
        expect(result.statusCode).toBe(400);
        expect(result.body.error.code).toBe("INVALID_PLACED_ORDER_SCREENSHOT");
      }

      expect(reservationFields(await row(request._id))).toEqual(requestBefore);
      expect((await row(request._id))!.status).toBe("claimed");
      expect(await Fulfillment.countDocuments({})).toBe(0);
      expect(await PlacementEvidence.countDocuments({})).toBe(0);
    });

    it("completes with the screenshot after Yes: placement, ledger and evidence commit, and the Message stays withheld", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);

      const placed = await fulfill(request._id, ada, undefined, {
        contactMessage: "Thanks, text me when you are outside",
      });

      expect(placed.statusCode).toBe(200);
      expect(placed.body.request.status).toBe("placed");
      expect(placed.body.messageSuppressed).toBe(true);
      expect(placed.body.messageWithheld).toBe(true);
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      const evidence = await PlacementEvidence.findOne({ requestId: request._id }).lean();
      expect(evidence?.mimeType).toBe("image/png");
      // Nothing about the evidence reaches the helper response.
      expect(JSON.stringify(placed.body)).not.toContain(PLACED_ORDER_SCREENSHOT.imageBase64);
    });
  });

  // ------------------------------------------------- privacy / projection

  describe("privacy", () => {
    it("never appears in any projection, response, or reconstruction", async () => {
      const { request } = await holdAndAnswerYes(bea, ada);
      const calls: Call[] = [];
      calls.push(await activeReservation(ada));
      calls.push(await extend(request._id, ada));
      calls.push(await detail(request._id, bea));
      calls.push(await detail(request._id, cy));
      calls.push(await detail(request._id, ada));
      calls.push(await detail(request._id, null));
      calls.push(await claim(request._id, cy));
      calls.push(await release(request._id, ada));
      calls.push(await release(request._id, ada));
      calls.push(await fulfill(request._id, ada));
      calls.push(await activeReservation(ada));
      calls.push(await detail(request._id, bea));

      for (const call of calls) {
        expect(JSON.stringify(call.body ?? null)).not.toMatch(FORBIDDEN_MARKER);
      }

      // The projections themselves, with the private field present on input.
      const marked = (await MealRequest.findById(request._id)
        .select(PRIVATE_FIELDS)
        .lean()) as unknown as PublicRequestDocument;
      expect(
        JSON.stringify(
          buildPublicRequestDetailResponse(marked, new Date(), {
            kind: "resolved",
            participantId: String(bea),
          })
        )
      ).not.toMatch(FORBIDDEN_MARKER);
      expect(
        JSON.stringify(
          buildPublicRequestListResponse(
            [marked as unknown as RequestListDocument],
            new Date(),
            { kind: "resolved", participantId: String(bea) }
          )
        )
      ).not.toMatch(FORBIDDEN_MARKER);
      // A marked row is not available even when handed to the in-memory form.
      expect(
        isEffectivelyAvailable(
          marked as unknown as Parameters<typeof isEffectivelyAvailable>[0],
          new Date(Date.now() + 24 * 60 * 60 * 1000)
        )
      ).toBe(false);
    });

    it("keeps the Block row free of the authority and of any request link", async () => {
      await holdAndAnswerYes(bea, ada);
      const blockRow = await ParticipantBlock.findOne({})
        .select("+blockerParticipantId +blockedParticipantId")
        .lean();
      expect(Object.keys(blockRow!).sort()).toEqual(
        [
          "__v",
          "_id",
          "blockedParticipantId",
          "blockedRole",
          "blockerParticipantId",
          "createdAt",
          "diningLocation",
          "interactionAt",
          "updatedAt",
        ].sort()
      );
    });
  });
  }
);
