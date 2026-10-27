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
import * as participantAccountFence from "./participantAccountFence.js";
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
  BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED_CODE,
  RESERVATION_STATE_CHANGED_CODE,
  createParticipantBlock,
  deleteParticipantBlock,
  listParticipantBlocks,
} from "./participantBlockRoute.js";
import * as participantBlocks from "./participantBlocks.js";
import { buildParticipantFenceFilter } from "./participantBlocks.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { getActiveReservation } from "./reservationRoute.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_participant_block`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const signingSecretText = "participant-block-mongo-signing-secret-32b";
const signingSecret = Buffer.from(signingSecretText);

// Three distinct verified participants. `ada` helps, `bea` requests, `cy` is
// an unrelated third party.
const ada = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const bea = new mongoose.Types.ObjectId("64e0000000000000000000b2");
const cy = new mongoose.Types.ObjectId("64e0000000000000000000c3");
const principal = {
  [String(ada)]: "block-ada@nyu.edu",
  [String(bea)]: "block-bea@nyu.edu",
  [String(cy)]: "block-cy@nyu.edu",
};
const authority = (id: mongoose.Types.ObjectId) =>
  signParticipantAuthority(id, 1, signingSecret);

interface Call {
  statusCode: number;
  body: any;
  headers: Record<string, string>;
}

function makeCall(
  params: Record<string, string>,
  body: unknown,
  as: mongoose.Types.ObjectId | null
) {
  const headers: Record<string, string> = {};
  const req = {
    params,
    body,
    headers: as ? { [PARTICIPANT_AUTHORITY_HEADER]: authority(as) } : {},
  } as unknown as Request;
  const call: Call = { statusCode: 200, body: undefined, headers };
  const res = {} as Response;
  res.status = vi.fn((code: number) => {
    call.statusCode = code;
    return res;
  }) as never;
  res.json = vi.fn((value: unknown) => {
    call.body = value;
    return res;
  }) as never;
  res.setHeader = vi.fn((name: string, value: string) => {
    headers[name] = value;
    return res;
  }) as never;
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
async function release(requestId: unknown, as: mongoose.Types.ObjectId) {
  const { req, res, call } = makeCall({ id: String(requestId) }, {}, as);
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
  contactMessage?: string
) {
  const { req, res, call } = makeCall(
    { id: String(requestId) },
    {
      fulfillment: {
        orderNumber: "000123",
        eta: "ASAP",
        placedOrderScreenshot: PLACED_ORDER_SCREENSHOT,
        ...(contactMessage === undefined ? {} : { contactMessage }),
      },
    },
    as
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
async function listBlocks(as: mongoose.Types.ObjectId) {
  const { req, res, call } = makeCall({}, undefined, as);
  await listParticipantBlocks(req, res);
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
  requester: mongoose.Types.ObjectId | null,
  overrides: Record<string, unknown> = {}
) {
  const now = new Date();
  const deadline = new Date(now.getTime() + 60 * 60 * 1000);
  return await MealRequest.create({
    vendor: "Jasper Kane Cafe",
    food: "Rice bowl",
    pickupWindowText: "ASAP",
    email: "requester@example.edu",
    status: "open",
    expiresAt: deadline,
    deleteAt: deadline,
    ...(requester ? { requesterParticipantId: requester } : {}),
    ...overrides,
  });
}

/** Helper claims and places a request for `requester`, as the real flow does. */
async function placeRequest(
  requester: mongoose.Types.ObjectId,
  helper: mongoose.Types.ObjectId
) {
  const request = await createRequest(requester);
  expect((await claim(request._id, helper)).statusCode).toBe(200);
  const placed = await fulfill(request._id, helper);
  expect(placed.statusCode).toBe(200);
  return request;
}

const NOT_FOUND_BODY = { error: "Request not found" };
const day4NotFound = {
  error: {
    code: "REQUEST_NOT_FOUND",
    message: "This request could not be found.",
    fields: null,
  },
};

describeMongo("real MongoDB W4-U1.3 participant blocking and fencing", () => {
  beforeAll(async () => {
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "participant-block-claim-secret-32b!");
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, signingSecretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await RequestParticipation.syncIndexes();
    await Fulfillment.syncIndexes();
    await PlacementEvidence.syncIndexes();
    await ParticipantBlock.syncIndexes();
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
    // The pause fails closed when unset, so every case states it explicitly;
    // the paused-behavior cases below flip it to "true".
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
  });

  afterEach(async () => {
    vi.restoreAllMocks();
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
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  // ------------------------------------------------------------------ persistence

  it("enforces one owned block per (owner, target) and indexes the reverse lookup", async () => {
    const indexes = await ParticipantBlock.collection.indexes();
    expect(indexes).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          name: "participant_block_owner_target_live_unique",
          key: { blockerParticipantId: 1, blockedParticipantId: 1 },
          unique: true,
          partialFilterExpression: {
            blockedParticipantId: { $type: "objectId" },
          },
        }),
        expect.objectContaining({
          name: "participant_block_owner_safety_unique",
          key: {
            blockerParticipantId: 1,
            blockedSafetyKeyVersion: 1,
            blockedSafetyHmac: 1,
          },
          unique: true,
        }),
        expect.objectContaining({
          name: "participant_block_blocked_lookup",
          key: { blockedParticipantId: 1 },
        }),
      ])
    );
  });

  it("creates a helper → requester block from Request Detail context and exposes only interaction context", async () => {
    const request = await createRequest(bea);

    const result = await block(request._id, ada);

    expect(result.statusCode).toBe(200);
    expect(result.body.reservationReleased).toBe(false);
    expect(Object.keys(result.body.block).sort()).toEqual([
      "blockedRole",
      "createdAt",
      "diningLocation",
      "id",
      "interactionAt",
    ]);
    expect(result.body.block).toMatchObject({
      blockedRole: "requester",
      diningLocation: "Jasper Kane Cafe",
    });
    // No participant identifier or address anywhere in the response.
    const serialized = JSON.stringify(result.body);
    expect(serialized).not.toContain(String(ada));
    expect(serialized).not.toContain(String(bea));
    expect(serialized).not.toContain("block-");
    expect(serialized).not.toMatch(
      /blockerParticipantId|blockedParticipantId|blockedSafetyKeyVersion|blockedSafetyHmac|emailBinding|recoveryCapability/
    );

    const rows = await ParticipantBlock.find({})
      .select("+blockerParticipantId +blockedParticipantId")
      .lean();
    expect(rows).toHaveLength(1);
    expect(String(rows[0].blockerParticipantId)).toBe(String(ada));
    expect(String(rows[0].blockedParticipantId)).toBe(String(bea));
  });

  it("is idempotent: blocking the same participant again keeps one row and the original snapshot", async () => {
    const first = await createRequest(bea, { vendor: "Jasper Kane Cafe" });
    const second = await createRequest(bea, { vendor: "Kimmel" });

    const one = await block(first._id, ada);
    const two = await block(second._id, ada);

    expect(one.statusCode).toBe(200);
    expect(two.statusCode).toBe(200);
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
    expect(two.body.block.id).toBe(one.body.block.id);
    expect(two.body.block.diningLocation).toBe("Jasper Kane Cafe");
  });

  it("refuses every non-contextual target without creating a row", async () => {
    const future = await createRequest(bea, {
      visibleFrom: new Date(Date.now() + 60 * 60 * 1000),
    });
    const legacy = await createRequest(null);
    const ownUnplaced = await createRequest(ada);
    const unreservedOwn = await createRequest(ada);

    for (const id of [
      new mongoose.Types.ObjectId(), // no such request
      future._id, // never shown to anyone yet
      legacy._id, // no participant behind it
      ownUnplaced._id, // own request, no helper relationship
      unreservedOwn._id, // own request with no reservation: no helper context
    ]) {
      const result = await block(id, ada);
      expect(result.statusCode).toBe(404);
      expect(result.body).toEqual(day4NotFound);
    }
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
  });

  it("refuses a malformed body and an unverified caller", async () => {
    const request = await createRequest(bea);

    const smuggled = await block(request._id, ada, { participantId: String(bea) });
    expect(smuggled.statusCode).toBe(400);
    expect(smuggled.body.error.code).toBe("INVALID_BLOCK_PAYLOAD");

    const anonymous = await block(request._id, null as never);
    expect(anonymous.statusCode).toBe(401);
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
  });

  it("creates a requester → helper block from reservation start", async () => {
    const reserved = await createRequest(bea);
    expect((await claim(reserved._id, ada)).statusCode).toBe(200);
    const atReservation = await block(reserved._id, bea);
    expect(atReservation.statusCode).toBe(200);
    expect(atReservation.body.block.blockedRole).toBe("helper");
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
  });

  it("creates a requester → helper block after placement, targeting the recorded helper", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    expect((await fulfill(request._id, ada)).statusCode).toBe(200);
    const afterPlacement = await block(request._id, bea);

    expect(afterPlacement.statusCode).toBe(200);
    expect(afterPlacement.body.block.blockedRole).toBe("helper");
    expect(afterPlacement.body.reservationReleased).toBe(false);
    const row = await ParticipantBlock.findOne({})
      .select("+blockerParticipantId +blockedParticipantId")
      .lean();
    expect(String(row!.blockerParticipantId)).toBe(String(bea));
    expect(String(row!.blockedParticipantId)).toBe(String(ada));
    // Placement truth is untouched by the block.
    const placed = await MealRequest.findById(request._id).lean();
    expect(placed!.status).toBe("placed");
  });

  it("lists only the caller's own blocks as context and never the reverse direction", async () => {
    const mine = await createRequest(bea);
    const theirs = await createRequest(ada);
    await placeRequest(ada, cy);
    expect((await block(mine._id, ada)).statusCode).toBe(200);
    // bea blocks ada back from her own request context? ada's request `theirs`
    // is open and unplaced, so bea blocks via ada's visible request.
    expect((await block(theirs._id, bea)).statusCode).toBe(200);

    const adasList = await listBlocks(ada);
    const beasList = await listBlocks(bea);

    expect(adasList.statusCode).toBe(200);
    expect(adasList.body.blocks).toHaveLength(1);
    expect(adasList.body.blocks[0].blockedRole).toBe("requester");
    expect(beasList.body.blocks).toHaveLength(1);
    expect(adasList.headers["Cache-Control"]).toBe("private, no-store");
    for (const list of [adasList, beasList]) {
      const serialized = JSON.stringify(list.body);
      for (const id of [ada, bea, cy]) {
        expect(serialized).not.toContain(String(id));
      }
      expect(serialized).not.toMatch(/@nyu\.edu/);
      expect(serialized).not.toMatch(
        /blockerParticipantId|blockedParticipantId|blockedSafetyKeyVersion|blockedSafetyHmac|emailBinding|recoveryCapability/
      );
    }
  });

  it("keeps the block and its snapshot after the request is TTL-deleted", async () => {
    const request = await createRequest(bea);
    const created = await block(request._id, ada);
    expect(created.statusCode).toBe(200);

    await MealRequest.deleteMany({});

    const list = await listBlocks(ada);
    expect(list.body.blocks).toHaveLength(1);
    expect(list.body.blocks[0]).toMatchObject({
      id: created.body.block.id,
      blockedRole: "requester",
      diningLocation: "Jasper Kane Cafe",
    });
  });

  // ------------------------------------------------------------------- unblock

  it("lets only the owner unblock; another participant gets the same answer as a missing block", async () => {
    const request = await createRequest(bea);
    const created = await block(request._id, ada);

    const byBlocked = await unblock(created.body.block.id, bea);
    const byStranger = await unblock(created.body.block.id, cy);
    const missing = await unblock(new mongoose.Types.ObjectId(), ada);

    for (const refused of [byBlocked, byStranger, missing]) {
      expect(refused.statusCode).toBe(404);
      expect(refused.body.error.code).toBe("BLOCK_NOT_FOUND");
    }
    expect(byBlocked.body).toEqual(missing.body);
    expect(await ParticipantBlock.countDocuments({})).toBe(1);

    const owner = await unblock(created.body.block.id, ada);
    expect(owner.statusCode).toBe(200);
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
  });

  it("treats a double-block as two records: one side's Unblock leaves the pair fenced", async () => {
    const adasRequest = await createRequest(ada);
    const beasRequest = await createRequest(bea);
    const adaBlocksBea = await block(beasRequest._id, ada);
    const beaBlocksAda = await block(adasRequest._id, bea);
    expect(await ParticipantBlock.countDocuments({})).toBe(2);

    expect((await unblock(adaBlocksBea.body.block.id, ada)).statusCode).toBe(200);

    expect(await ParticipantBlock.countDocuments({})).toBe(1);
    const stillFenced = await claim(beasRequest._id, ada);
    expect(stillFenced.statusCode).toBe(404);
    expect((await detail(beasRequest._id, ada)).statusCode).toBe(404);

    expect((await unblock(beaBlocksAda.body.block.id, bea)).statusCode).toBe(200);
    expect((await claim(beasRequest._id, ada)).statusCode).toBe(200);
  });

  it("unblocks prospectively: no resurrected reservation, participation intact, placement untouched", async () => {
    const placed = await placeRequest(bea, ada);
    const released = await createRequest(bea);
    expect((await claim(released._id, ada)).statusCode).toBe(200);
    // Helper blocks while holding it and has not placed: truthful release.
    const blocked = await block(released._id, ada, { externalOrderPlaced: false });
    expect(blocked.statusCode).toBe(200);
    const participationBefore = await RequestParticipation.countDocuments({});

    expect((await unblock(blocked.body.block.id, ada)).statusCode).toBe(200);

    expect(await RequestParticipation.countDocuments({})).toBe(participationBefore);
    const reopened = await MealRequest.findById(released._id)
      .select("+helperParticipantId")
      .lean();
    expect(reopened!.status).toBe("open");
    expect(reopened!.helperParticipantId).toBeUndefined();
    // The released request is not recreated for her: participation still bars it.
    const again = await claim(released._id, ada);
    expect(again.statusCode).toBe(409);
    expect(again.body.error.code).toBe(REQUEST_ALREADY_PARTICIPATED_CODE);
    expect((await MealRequest.findById(placed._id).lean())!.status).toBe("placed");
    expect(await Fulfillment.countDocuments({ requestId: placed._id })).toBe(1);
  });

  // --------------------------------------------------------------------- board

  it("excludes a fenced pair's requests from the board in both directions and leaves others", async () => {
    const fromAda = await createRequest(ada);
    const fromBea = await createRequest(bea);
    const fromCy = await createRequest(cy);
    expect((await block(fromBea._id, ada)).statusCode).toBe(200);

    const board = async (as: mongoose.Types.ObjectId | null) => {
      const filter = await buildParticipantFenceFilter(as ? String(as) : null);
      const rows = await MealRequest.find({
        ...buildEffectiveAvailabilityFilter(new Date()),
        ...filter,
      })
        .select("_id")
        .lean();
      return new Set(rows.map((row) => String(row._id)));
    };

    const adaSees = await board(ada);
    const beaSees = await board(bea);
    const cySees = await board(cy);
    const anonymousSees = await board(null);

    expect(adaSees.has(String(fromBea._id))).toBe(false);
    expect(adaSees.has(String(fromAda._id))).toBe(true);
    expect(adaSees.has(String(fromCy._id))).toBe(true);
    expect(beaSees.has(String(fromAda._id))).toBe(false);
    expect(beaSees.has(String(fromBea._id))).toBe(true);
    expect(beaSees.has(String(fromCy._id))).toBe(true);
    // Unrelated participant and anonymous callers are unaffected.
    expect(cySees.size).toBe(3);
    expect(anonymousSees.size).toBe(3);
  });

  it("applies the fence in the query so a fenced request cannot occupy a limited slot", async () => {
    const fenced = await createRequest(bea);
    const visible = await createRequest(cy);
    expect((await block(fenced._id, ada)).statusCode).toBe(200);

    const filter = await buildParticipantFenceFilter(String(ada));
    const limited = await MealRequest.find({
      ...buildEffectiveAvailabilityFilter(new Date()),
      ...filter,
    })
      .limit(1)
      .select("_id")
      .lean();

    expect(limited.map((row) => String(row._id))).toEqual([String(visible._id)]);
  });

  // -------------------------------------------------------------------- detail

  it("answers a fenced counterpart's direct request id exactly like a missing request", async () => {
    const beasRequest = await createRequest(bea);
    const adasRequest = await createRequest(ada);
    expect((await block(beasRequest._id, ada)).statusCode).toBe(200);

    const missing = await detail(new mongoose.Types.ObjectId(), ada);
    const blockedByAda = await detail(beasRequest._id, ada);
    const blockedByBea = await detail(adasRequest._id, bea);

    expect(missing.statusCode).toBe(404);
    expect(missing.body).toEqual(NOT_FOUND_BODY);
    for (const fenced of [blockedByAda, blockedByBea]) {
      expect(fenced.statusCode).toBe(404);
      expect(fenced.body).toEqual(missing.body);
    }
  });

  it("keeps ownership, anonymous, and unrelated detail behavior and never projects block state", async () => {
    const beasRequest = await createRequest(bea);
    expect((await block(beasRequest._id, ada)).statusCode).toBe(200);

    const own = await detail(beasRequest._id, bea);
    const unrelated = await detail(beasRequest._id, cy);
    const anonymous = await detail(beasRequest._id, null);

    expect(own.statusCode).toBe(200);
    expect(own.body.request.isOwnRequest).toBe(true);
    expect(unrelated.statusCode).toBe(200);
    expect(unrelated.body.request.isOwnRequest).toBe(false);
    // W4-R5: an anonymous caller is refused outright, with no request.
    expect(anonymous.statusCode).toBe(401);
    expect(anonymous.body).not.toHaveProperty("request");
    for (const ok of [own, unrelated, anonymous]) {
      expect(JSON.stringify(ok.body)).not.toMatch(
        /block|fence|requesterParticipantId|helperParticipantId/i
      );
    }
  });

  it("does not fence a not-yet-visible request differently from a missing one for a fenced caller", async () => {
    const visibleLater = await createRequest(bea, {
      visibleFrom: new Date(Date.now() + 60 * 60 * 1000),
    });
    const earlier = await createRequest(bea);
    expect((await block(earlier._id, ada)).statusCode).toBe(200);

    const fencedFuture = await detail(visibleLater._id, ada);
    const nonexistent = await detail(new mongoose.Types.ObjectId(), ada);
    const unfencedFuture = await detail(visibleLater._id, cy);

    expect(fencedFuture.statusCode).toBe(404);
    expect(fencedFuture.body).toEqual(nonexistent.body);
    // Unfenced callers still get the accepted not-yet-available refusal.
    expect(unfencedFuture.statusCode).toBe(409);
  });

  it("fences a stale last helper once the reservation has expired, while a live reservation keeps its continuity", async () => {
    const beasRequest = await createRequest(bea);
    expect((await claim(beasRequest._id, ada)).statusCode).toBe(200);
    // Ada blocks Bea while still holding the live reservation ("already placed").
    expect(
      (await block(beasRequest._id, ada, { externalOrderPlaced: true })).statusCode
    ).toBe(200);

    // Live reservation: the holder keeps the request they are completing.
    const live = await detail(beasRequest._id, ada);
    expect(live.statusCode).toBe(200);

    // The reservation lapses. Expiry never clears the helper binding.
    await MealRequest.updateOne(
      { _id: beasRequest._id },
      { $set: { claimExpiresAt: new Date(Date.now() - 1000) } }
    ).exec();
    const stale = await MealRequest.findById(beasRequest._id)
      .select("+helperParticipantId")
      .lean();
    expect(stale!.status).toBe("claimed");
    expect(String(stale!.helperParticipantId)).toBe(String(ada));

    const missing = await detail(new mongoose.Types.ObjectId(), ada);
    const lapsed = await detail(beasRequest._id, ada);
    expect(lapsed.statusCode).toBe(404);
    expect(lapsed.body).toEqual(missing.body);

    // Nobody else's view of the same request changes.
    const own = await detail(beasRequest._id, bea);
    const unrelated = await detail(beasRequest._id, cy);
    const anonymous = await detail(beasRequest._id, null);
    expect(own.statusCode).toBe(200);
    expect(own.body.request.isOwnRequest).toBe(true);
    expect(unrelated.statusCode).toBe(200);
    // W4-R5: anonymous reads are refused, not served.
    expect(anonymous.statusCode).toBe(401);
  });

  it("keeps a placed helper's detail continuity for a blocked pair in both owner directions", async () => {
    const placed = await placeRequest(bea, ada);
    // Requester-owned block (requester → helper, after placement).
    expect((await block(placed._id, bea)).statusCode).toBe(200);
    expect((await detail(placed._id, ada)).statusCode).toBe(200);
    // Helper-owned block of the same requester as well.
    expect((await block(placed._id, ada)).statusCode).toBe(200);
    const helperView = await detail(placed._id, ada);
    expect(helperView.statusCode).toBe(200);

    const own = await detail(placed._id, bea);
    expect(own.statusCode).toBe(200);
    expect(own.body.request.isOwnRequest).toBe(true);
    // A participant who never held it is a different, unfenced principal.
    expect((await detail(placed._id, cy)).statusCode).toBe(200);
    expect((await detail(placed._id, null)).statusCode).toBe(401);
  });

  it("mints a requester post-Block report handoff only while pickup is unconfirmed", async () => {
    vi.stubEnv("SAFETY_IDENTITY_KEYRING", JSON.stringify({
      current: "k1",
      keys: { k1: Buffer.alloc(32, 0x71).toString("base64url") },
    }));
    const pending = await placeRequest(bea, ada);
    const before = await block(pending._id, bea);
    expect(before.statusCode).toBe(200);
    expect(typeof (before.body as { reportAuthorization?: unknown }).reportAuthorization).toBe("string");

    await unblock((before.body as { block: { id: string } }).block.id, bea);
    const pickedUp = await placeRequest(bea, ada);
    await MealRequest.updateOne(
      { _id: pickedUp._id },
      { $set: { requesterPickupConfirmedAt: new Date() } }
    );
    const after = await block(pickedUp._id, bea);
    expect(after.statusCode).toBe(200);
    expect(after.body).not.toHaveProperty("reportAuthorization");
  });

  // --------------------------------------------------------------------- claim

  it("refuses a new claim between a fenced pair in both directions without revealing why", async () => {
    const beasRequest = await createRequest(bea);
    const adasRequest = await createRequest(ada);
    expect((await block(beasRequest._id, ada)).statusCode).toBe(200);

    const adaClaims = await claim(beasRequest._id, ada);
    const beaClaims = await claim(adasRequest._id, bea);
    const missing = await claim(new mongoose.Types.ObjectId(), ada);

    for (const refused of [adaClaims, beaClaims]) {
      expect(refused.statusCode).toBe(404);
      expect(refused.body).toEqual(day4NotFound);
      expect(refused.body).toEqual(missing.body);
    }
    expect(await RequestParticipation.countDocuments({})).toBe(0);
    const untouched = await MealRequest.findById(beasRequest._id)
      .select("+helperParticipantId")
      .lean();
    expect(untouched!.status).toBe("open");
    expect(untouched!.helperParticipantId).toBeUndefined();
  });

  it("preserves self-help, unrelated claims, availability, and one-active-reservation around the fence", async () => {
    const own = await createRequest(ada);
    const fromBea = await createRequest(bea);
    const fromCy = await createRequest(cy);
    const secondFromCy = await createRequest(cy);
    expect((await block(fromBea._id, ada)).statusCode).toBe(200);

    const self = await claim(own._id, ada);
    expect(self.statusCode).toBe(409);
    expect(self.body.error.code).toBe(REQUEST_OWN_REQUEST_CODE);

    expect((await claim(fromCy._id, ada)).statusCode).toBe(200);
    const second = await claim(secondFromCy._id, ada);
    expect(second.statusCode).toBe(409);
    expect(second.body.error.code).toBe("HELPER_ALREADY_HAS_ACTIVE_RESERVATION");

    const taken = await claim(fromCy._id, bea);
    expect(taken.statusCode).toBe(409);
    expect(taken.body.error.code).toBe("REQUEST_ALREADY_CLAIMED");
  });

  // ---------------------------------------------------------- concurrency proof

  it("serializes a block against an in-flight claim: the claim cannot commit across a block it did not see", async () => {
    const beasRequest = await createRequest(bea);
    const original = participantBlocks.isParticipantPairFenced;
    let reachedFence!: () => void;
    const reached = new Promise<void>((resolve) => (reachedFence = resolve));
    let openGate!: () => void;
    const gate = new Promise<void>((resolve) => (openGate = resolve));
    let calls = 0;
    vi.spyOn(participantBlocks, "isParticipantPairFenced").mockImplementation(
      async (...args) => {
        const answer = await original(...args);
        calls += 1;
        if (calls === 1) {
          // The claim has now read "no block" in its snapshot. Hold it there.
          reachedFence();
          await gate;
        }
        return answer;
      }
    );

    const claiming = claim(beasRequest._id, ada);
    await reached;
    // Ada's own block commits while her claim transaction is mid-flight.
    const blocking = await block(beasRequest._id, ada);
    expect(blocking.statusCode).toBe(200);
    openGate();
    const claimed = await claiming;

    expect(claimed.statusCode).toBe(404);
    expect(claimed.body).toEqual(day4NotFound);
    expect(calls).toBeGreaterThanOrEqual(2); // retried against a fresh snapshot
    const row = await MealRequest.findById(beasRequest._id)
      .select("+helperParticipantId")
      .lean();
    expect(row!.status).toBe("open");
    expect(row!.helperParticipantId).toBeUndefined();
    expect(await RequestParticipation.countDocuments({})).toBe(0);
  });

  it("serializes a requester-owned block against the blocked helper's in-flight claim on another request", async () => {
    await placeRequest(bea, ada); // bea can now block ada from the placed request
    const second = await createRequest(bea);
    const placed = await MealRequest.findOne({ status: "placed" }).lean();
    const original = participantBlocks.isParticipantPairFenced;
    let reachedFence!: () => void;
    const reached = new Promise<void>((resolve) => (reachedFence = resolve));
    let openGate!: () => void;
    const gate = new Promise<void>((resolve) => (openGate = resolve));
    let calls = 0;
    vi.spyOn(participantBlocks, "isParticipantPairFenced").mockImplementation(
      async (...args) => {
        const answer = await original(...args);
        calls += 1;
        if (calls === 1) {
          reachedFence();
          await gate;
        }
        return answer;
      }
    );

    const claiming = claim(second._id, ada);
    await reached;
    expect((await block(placed!._id, bea)).statusCode).toBe(200);
    openGate();
    const claimed = await claiming;

    expect(claimed.statusCode).toBe(404);
    expect((await MealRequest.findById(second._id).lean())!.status).toBe("open");
  });

  it("negative control: without the fence write the same interleaving grants a claim across the block", async () => {
    const beasRequest = await createRequest(bea);
    vi.spyOn(
      participantAccountFence,
      "touchParticipantAccountsInSession"
    ).mockImplementation(async (participantIds) =>
      new Map(
        participantIds.map((id) => {
          const participantId = String(id);
          return [
            participantId,
            {
              participantId,
              authorityVersion: 1,
              principal: principal[participantId],
            },
          ];
        })
      )
    );
    vi.spyOn(participantBlocks, "bumpBlockFence").mockResolvedValue(2);
    const original = participantBlocks.isParticipantPairFenced;
    let reachedFence!: () => void;
    const reached = new Promise<void>((resolve) => (reachedFence = resolve));
    let openGate!: () => void;
    const gate = new Promise<void>((resolve) => (openGate = resolve));
    let calls = 0;
    vi.spyOn(participantBlocks, "isParticipantPairFenced").mockImplementation(
      async (...args) => {
        const answer = await original(...args);
        calls += 1;
        if (calls === 1) {
          reachedFence();
          await gate;
        }
        return answer;
      }
    );

    const claiming = claim(beasRequest._id, ada);
    await reached;
    await block(beasRequest._id, ada);
    openGate();
    const claimed = await claiming;

    // This is the write skew the fence write exists to prevent.
    expect(claimed.statusCode).toBe(200);
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
  });

  it("lets an in-flight extension and a Yes block both commit: the reservation continues extended and the request is fenced", async () => {
    const beasRequest = await createRequest(bea);
    expect((await claim(beasRequest._id, ada)).statusCode).toBe(200);
    const before = await MealRequest.findById(beasRequest._id).lean();

    // Extension is no longer serialized against a Block (W4-U1.3 post-Block
    // autonomy): both writes touch the same Request, so Mongo orders them and
    // the loser is retried against the winner — either order converges.
    const [extended, blocked] = await Promise.all([
      extend(beasRequest._id, ada),
      block(beasRequest._id, ada, { externalOrderPlaced: true }),
    ]);

    expect(extended.statusCode).toBe(200);
    expect(blocked.statusCode).toBe(200);
    const after = await MealRequest.findById(beasRequest._id)
      .select("+externalOrderAffirmed +helperParticipantId")
      .lean();
    expect(after!.status).toBe("claimed");
    expect(after!.claimExtendedAt).toBeInstanceOf(Date);
    expect(after!.claimExpiresAt!.getTime()).toBe(
      before!.claimExpiresAt!.getTime() + claimRoute.CLAIM_EXTENSION_MS
    );
    expect(after!.externalOrderAffirmed).toBe(true);
    expect(String(after!.helperParticipantId)).toBe(String(ada));
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
  });

  // --------------------------------------------------- active-reservation flow

  it("block + 'not placed': truthfully releases the reservation and the request becomes ordinarily claimable by others", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);

    const result = await block(request._id, ada, { externalOrderPlaced: false });

    expect(result.statusCode).toBe(200);
    expect(result.body.reservationReleased).toBe(true);
    const row = await MealRequest.findById(request._id)
      .select("+helperParticipantId +claimTokenDigest")
      .lean();
    expect(row!.status).toBe("open");
    expect(row!.helperParticipantId).toBeUndefined();
    expect(row!.claimTokenDigest).toBeUndefined();
    const lock = await Participant.findById(ada)
      .select("+activeReservationRequestId")
      .lean();
    expect(lock!.activeReservationRequestId).toBeNull();
    // Nothing placed or fabricated.
    expect(await Fulfillment.countDocuments({})).toBe(0);
    expect(await RequestParticipation.countDocuments({})).toBe(1);
    // Fenced from the blocker, open to everyone else.
    expect((await claim(request._id, ada)).statusCode).toBe(404);
    expect((await claim(request._id, cy)).statusCode).toBe(200);
  });

  it("requires the external-order answer while a reservation is live and commits nothing without it", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);

    const unanswered = await block(request._id, ada, {});

    expect(unanswered.statusCode).toBe(400);
    expect(unanswered.body.error.code).toBe(
      BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED_CODE
    );
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
    const row = await MealRequest.findById(request._id).lean();
    expect(row!.status).toBe("claimed");
  });

  it("block + 'already placed': never reopens, exposes nothing to a second helper, and still allows the ordinary extension", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    const before = await MealRequest.findById(request._id).lean();

    const result = await block(request._id, ada, { externalOrderPlaced: true });

    expect(result.statusCode).toBe(200);
    expect(result.body.reservationReleased).toBe(false);
    const after = await MealRequest.findById(request._id)
      .select("+helperParticipantId")
      .lean();
    expect(after!.status).toBe("claimed");
    expect(String(after!.helperParticipantId)).toBe(String(ada));
    expect(after!.claimExpiresAt!.getTime()).toBe(before!.claimExpiresAt!.getTime());

    const secondHelper = await claim(request._id, cy);
    expect(secondHelper.statusCode).toBe(409);
    expect(secondHelper.body.error.code).toBe("REQUEST_ALREADY_CLAIMED");
    // The current holder's one-time extension is governed only by the
    // ordinary timing and one-use rules; a Block no longer withholds it.
    const extension = await extend(request._id, ada);
    expect(extension.statusCode).toBe(200);
    const extended = await MealRequest.findById(request._id).lean();
    expect(extended!.claimExtendedAt).toBeInstanceOf(Date);
    expect(extended!.claimExpiresAt!.getTime()).toBe(
      before!.claimExpiresAt!.getTime() + claimRoute.CLAIM_EXTENSION_MS
    );
    expect(await Fulfillment.countDocuments({})).toBe(0);
  });

  it("records the already-placed order only through the existing placement path, withholding contact", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    expect(
      (await block(request._id, ada, { externalOrderPlaced: true })).statusCode
    ).toBe(200);

    const placed = await fulfill(request._id, ada, "Thanks so much!");

    expect(placed.statusCode).toBe(200);
    expect(placed.body.request.status).toBe("placed");
    expect(placed.body.messageSuppressed).toBe(true);
    // Told apart from a text-filter refusal, so the helper is shown the
    // restriction copy rather than the guidelines copy.
    expect(placed.body.messageWithheld).toBe(true);
    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
    const args = sendFulfillmentEmail.mock.calls[0];
    expect(args[1]).toBe("000123"); // order number still delivered
    expect(args[2]).toBe("ASAP");
    expect(args[3]).toBeUndefined(); // Message withheld
    expect(args[4]).toBeUndefined(); // no helper Reply-To
    const row = await MealRequest.findById(request._id)
      .select("+contactMessageSuppressed +contactMessageWithheld +helperParticipantId")
      .lean();
    expect(row!.status).toBe("placed");
    expect(row!.contactMessageSuppressed).toBe(true);
    expect(row!.contactMessageWithheld).toBe(true);
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
    // Ordinary placed-order continuity survives for the helper.
    const recovered = await activeReservation(ada);
    expect(recovered.body.placement.request.id).toBe(String(request._id));
    expect(recovered.body.placement.messageSuppressed).toBe(true);
    expect(recovered.body.placement.messageWithheld).toBe(true);
  });

  it("aborts the whole block when the reservation moved after the attempt began", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    const stale = await MealRequest.findById(request._id).lean();
    vi.spyOn(claimRoute, "readReleaseReservationVersion").mockResolvedValue({
      claimExpiresAt: new Date(stale!.claimExpiresAt!.getTime() - 60_000),
      claimExtendedAt: null,
    });

    const result = await block(request._id, ada, { externalOrderPlaced: false });

    expect(result.statusCode).toBe(409);
    expect(result.body.error.code).toBe(RESERVATION_STATE_CHANGED_CODE);
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
    expect((await MealRequest.findById(request._id).lean())!.status).toBe("claimed");
  });

  it("lets a fenced helper Stop after Yes, ending their reservation without ever reopening the request", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    expect(
      (await block(request._id, ada, { externalOrderPlaced: true })).statusCode
    ).toBe(200);

    const released = await release(request._id, ada);

    // The same acknowledgement an ordinary release gives...
    expect(released.statusCode).toBe(200);
    expect(released.body).toEqual({ released: true });
    // ...but the request is never set back to open: a real external order may
    // exist, so no other helper may be offered it.
    const row = await MealRequest.findById(request._id)
      .select("+helperParticipantId +claimTokenDigest +externalOrderAffirmed")
      .lean();
    expect(row!.status).toBe("claimed");
    expect(row!.externalOrderAffirmed).toBe(true);
    expect(row!.helperParticipantId).toBeUndefined();
    expect(row!.claimTokenDigest).toBeUndefined();
    expect(row!.claimExpiresAt).toBeUndefined();
    expect((await claim(request._id, cy)).statusCode).toBe(409);
  });

  it("does not let a block on the pair cancel a claim, but a requester-owned block still fences helper contact on a second request", async () => {
    // Ada places bea's first request, then bea blocks her; ada holds a second.
    const first = await placeRequest(bea, ada);
    const second = await createRequest(bea);
    expect((await claim(second._id, ada)).statusCode).toBe(200);
    expect((await block(first._id, bea)).statusCode).toBe(200);
    // The existing reservation is untouched by a requester-owned block.
    expect((await MealRequest.findById(second._id).lean())!.status).toBe("claimed");

    const placed = await fulfill(second._id, ada, "hello!");

    expect(placed.statusCode).toBe(200);
    // The first call recorded the earlier, unblocked placement; the last call
    // is the placement under the requester-owned block.
    const lastCall = sendFulfillmentEmail.mock.calls.at(-1)!;
    expect(sendFulfillmentEmail).toHaveBeenCalledTimes(2);
    expect(lastCall[3]).toBeUndefined();
    expect(lastCall[4]).toBeUndefined();
  });

  // ------------------------------------------------- operational pause (U1.3)

  it("keeps ordinary Block and Unblock available while public actions are paused", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    const request = await createRequest(bea);

    const blocked = await block(request._id, ada);
    expect(blocked.statusCode).toBe(200);
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
    expect((await listBlocks(ada)).statusCode).toBe(200);

    const removed = await unblock(blocked.body.block.id, ada);
    expect(removed.statusCode).toBe(200);
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
  });

  it("lets 'already placed: yes' commit while paused, keeping the reservation and placement authority", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    const before = await MealRequest.findById(request._id)
      .select("+helperParticipantId")
      .lean();
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");

    const result = await block(request._id, ada, { externalOrderPlaced: true });

    expect(result.statusCode).toBe(200);
    expect(result.body.reservationReleased).toBe(false);
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
    const after = await MealRequest.findById(request._id)
      .select("+helperParticipantId")
      .lean();
    expect(after!.status).toBe("claimed");
    expect(String(after!.helperParticipantId)).toBe(String(ada));
    expect(after!.claimExpiresAt!.getTime()).toBe(before!.claimExpiresAt!.getTime());
    // Extension is governed only by ordinary timing and one-use rules, so the
    // holder's one-time extension is not refused because of the Block. (The
    // route-level pause middleware, not this handler, is what the pause gates.)
    expect((await extend(request._id, ada)).statusCode).toBe(200);
    // The placement path is not behind the pause and still records the order,
    // with direct contact withheld.
    const placed = await fulfill(request._id, ada, "thanks");
    expect(placed.statusCode).toBe(200);
    expect(placed.body.request.status).toBe("placed");
    expect(placed.body.messageWithheld).toBe(true);
    expect(sendFulfillmentEmail.mock.calls[0][4]).toBeUndefined();
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
  });

  it("commits neither the Block nor the release for 'not placed' while release is paused, then does both atomically after unpause", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    const snapshot = async () => ({
      request: await MealRequest.findById(request._id)
        .select("+helperParticipantId +claimTokenDigest")
        .lean(),
      lock: await Participant.findById(ada)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt +blockFenceEpoch")
        .lean(),
      beaFence: (await Participant.findById(bea).select("+blockFenceEpoch").lean())!
        .blockFenceEpoch,
    });
    const before = await snapshot();
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");

    const paused = await block(request._id, ada, { externalOrderPlaced: false });

    expect(paused.statusCode).toBe(503);
    expect(paused.body).toEqual({
      error: {
        code: "PUBLIC_ACTIONS_PAUSED",
        message: claimRoute.CLAIM_UNAVAILABLE_MESSAGE,
        fields: null,
      },
    });
    // No Block, no fence write, no release, no change to the reservation.
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
    const during = await snapshot();
    expect(during.request).toEqual(before.request);
    expect(during.lock).toEqual(before.lock);
    expect(during.beaFence).toEqual(before.beaFence);
    expect(during.request!.status).toBe("claimed");
    expect(String(during.lock!.activeReservationRequestId)).toBe(String(request._id));

    // Once the pause ends, the same flow retried creates the Block and ends the
    // reservation together.
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    const retried = await block(request._id, ada, { externalOrderPlaced: false });

    expect(retried.statusCode).toBe(200);
    expect(retried.body.reservationReleased).toBe(true);
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
    const after = await snapshot();
    expect(after.request!.status).toBe("open");
    expect(after.request!.helperParticipantId).toBeUndefined();
    expect(after.lock!.activeReservationRequestId).toBeNull();
    expect(await Fulfillment.countDocuments({})).toBe(0);
  });

  it("does not pause a 'not placed' Block when there is no live reservation to release", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    const viewed = await createRequest(bea);
    const lapsed = await createRequest(cy);
    expect((await claim(lapsed._id, ada)).statusCode).toBe(200);
    await MealRequest.updateOne(
      { _id: lapsed._id },
      { $set: { claimExpiresAt: new Date(Date.now() - 1000) } }
    );

    const noReservation = await block(viewed._id, ada, { externalOrderPlaced: false });
    const lapsedReservation = await block(lapsed._id, ada, { externalOrderPlaced: false });

    expect(noReservation.statusCode).toBe(200);
    expect(noReservation.body.reservationReleased).toBe(false);
    expect(lapsedReservation.statusCode).toBe(200);
    expect(lapsedReservation.body.reservationReleased).toBe(false);
    expect(await ParticipantBlock.countDocuments({})).toBe(2);
  });

  // ----------------------------------------------------------------- fulfilment

  it("leaves unblocked fulfillment unchanged: Reply-To and an allowed Message are delivered", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);

    const placed = await fulfill(request._id, ada, "See you soon");

    expect(placed.statusCode).toBe(200);
    expect(placed.body.messageSuppressed).toBeUndefined();
    const args = sendFulfillmentEmail.mock.calls[0];
    expect(args[3]).toBe("See you soon");
    expect(args[4]).toBe(principal[String(ada)]);
  });

  it("keeps the U1.1 text filter behavior for an unblocked pair", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);

    const placed = await fulfill(request._id, ada, "retard");

    expect(placed.statusCode).toBe(200);
    expect(placed.body.messageSuppressed).toBe(true);
    // A filter refusal is not a restriction: U1.1's signal is unchanged and
    // carries nothing about any block.
    expect(placed.body.messageWithheld).toBeUndefined();
    const args = sendFulfillmentEmail.mock.calls[0];
    expect(args[3]).toBeUndefined();
    // Filtering withholds the Message only; the Reply-To is unaffected.
    expect(args[4]).toBe(principal[String(ada)]);
    const row = await MealRequest.findById(request._id)
      .select("+contactMessageSuppressed +contactMessageWithheld")
      .lean();
    expect(row!.contactMessageSuppressed).toBe(true);
    expect(row!.contactMessageWithheld).toBeUndefined();
    const recovered = await activeReservation(ada);
    expect(recovered.body.placement.messageSuppressed).toBe(true);
    expect(recovered.body.placement.messageWithheld).toBeUndefined();
  });

  it("gives a blocked pair the restriction signal even for a Message the filter would also refuse", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    expect(
      (await block(request._id, ada, { externalOrderPlaced: true })).statusCode
    ).toBe(200);

    const placed = await fulfill(request._id, ada, "retard");

    expect(placed.statusCode).toBe(200);
    // Both flags, but the refinement is what selects the copy — so the verdict
    // of the text filter is never revealed across a block.
    expect(placed.body.messageSuppressed).toBe(true);
    expect(placed.body.messageWithheld).toBe(true);
    expect(sendFulfillmentEmail.mock.calls[0][3]).toBeUndefined();
  });

  // ---------------------------------------------- reservation reconstruction

  it("reports contact as restricted on a reconstructed reservation after the helper's own block", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    expect(
      (await block(request._id, ada, { externalOrderPlaced: true })).statusCode
    ).toBe(200);

    // The relaunched client has no in-memory record of the block: this read is
    // all it has.
    const rebuilt = await activeReservation(ada);

    expect(rebuilt.statusCode).toBe(200);
    expect(rebuilt.body.reservation.request.id).toBe(String(request._id));
    expect(rebuilt.body.reservation.directContactRestricted).toBe(true);
    // Reservation and placement authority are what they were.
    expect(rebuilt.body.reservation.claimExpiresAt).toBeDefined();
    const placed = await fulfill(request._id, ada);
    expect(placed.statusCode).toBe(200);
    expect(placed.body.request.status).toBe("placed");
  });

  it("reports the same restriction when the requester owns the block, without saying who", async () => {
    const first = await placeRequest(bea, ada);
    const second = await createRequest(bea);
    expect((await claim(second._id, ada)).statusCode).toBe(200);
    expect((await block(first._id, bea)).statusCode).toBe(200);

    const rebuilt = await activeReservation(ada);

    expect(rebuilt.body.reservation.directContactRestricted).toBe(true);
    const serialized = JSON.stringify(rebuilt.body);
    for (const id of [ada, bea, cy]) {
      expect(serialized).not.toContain(String(id));
    }
    expect(serialized).not.toMatch(/block|fence|requesterParticipantId|helperParticipantId/i);
  });

  it("leaves an unrelated or unblocked reconstructed reservation unrestricted", async () => {
    const blockedRequest = await createRequest(bea);
    expect((await block(blockedRequest._id, cy)).statusCode).toBe(200); // cy ↔ bea only
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);

    const rebuilt = await activeReservation(ada);

    expect(rebuilt.body.reservation.request.id).toBe(String(request._id));
    expect(rebuilt.body.reservation.directContactRestricted).toBeUndefined();
  });

  it("stops reporting restriction once the owner unblocks", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    const blocked = await block(request._id, ada, { externalOrderPlaced: true });
    expect((await activeReservation(ada)).body.reservation.directContactRestricted).toBe(true);

    expect((await unblock(blocked.body.block.id, ada)).statusCode).toBe(200);

    expect(
      (await activeReservation(ada)).body.reservation.directContactRestricted
    ).toBeUndefined();
  });

  it("withholds the Reply-To for a blocked pair even when no Message was submitted", async () => {
    const request = await createRequest(bea);
    expect((await claim(request._id, ada)).statusCode).toBe(200);
    expect(
      (await block(request._id, ada, { externalOrderPlaced: true })).statusCode
    ).toBe(200);

    const placed = await fulfill(request._id, ada);

    expect(placed.statusCode).toBe(200);
    expect(placed.body.messageSuppressed).toBeUndefined();
    expect(sendFulfillmentEmail.mock.calls[0][4]).toBeUndefined();
  });

  // ------------------------------------------- requester → helper (2026-10-14)

  it("refuses requester-owned creation for a placed request with no recorded helper or an expired deleteAt", async () => {
    const noHelper = await createRequest(bea, { status: "placed" });
    const expired = await placeRequest(bea, ada);
    await MealRequest.updateOne(
      { _id: expired._id },
      { $set: { deleteAt: new Date(Date.now() - 1000) } }
    );

    for (const id of [noHelper._id, expired._id]) {
      const refused = await block(id, bea);
      expect(refused.statusCode).toBe(404);
      expect(refused.body).toEqual(day4NotFound);
    }
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
  });

  it("lets a requester create their own block after the helper owns one, as two records with no ownership oracle", async () => {
    const request = await placeRequest(bea, ada);
    const control = await placeRequest(cy, ada);
    const controlBlock = await block(control._id, cy);
    expect(controlBlock.statusCode).toBe(200);

    expect((await block(request._id, ada)).statusCode).toBe(200);
    const requesterBlock = await block(request._id, bea);

    expect(requesterBlock.statusCode).toBe(200);
    expect(await ParticipantBlock.countDocuments({})).toBe(3);
    const owned = await ParticipantBlock.countDocuments({
      blockerParticipantId: bea,
      blockedParticipantId: ada,
    });
    expect(owned).toBe(1);
    // The response shape is identical whether or not the opposite direction
    // exists: only the caller's own record is described.
    expect(Object.keys(requesterBlock.body).sort()).toEqual(
      Object.keys(controlBlock.body).sort()
    );
    expect(Object.keys(requesterBlock.body.block).sort()).toEqual(
      Object.keys(controlBlock.body.block).sort()
    );
    expect(requesterBlock.body.block.blockedRole).toBe("helper");
    expect(await listBlocks(bea)).toMatchObject({ statusCode: 200 });
    expect((await listBlocks(bea)).body.blocks).toHaveLength(1);
  });

  it("restores eligibility when the sole requester-owned block is removed", async () => {
    const request = await placeRequest(bea, ada);
    const other = await createRequest(bea);
    const created = await block(request._id, bea);
    expect(created.statusCode).toBe(200);
    expect((await claim(other._id, ada)).statusCode).toBe(404);

    expect((await unblock(created.body.block.id, bea)).statusCode).toBe(200);

    expect((await claim(other._id, ada)).statusCode).toBe(200);
  });

  it("refuses a requester removing a helper-owned block exactly like a missing block", async () => {
    const request = await placeRequest(bea, ada);
    const helperOwned = await block(request._id, ada);
    expect(helperOwned.statusCode).toBe(200);

    const byRequester = await unblock(helperOwned.body.block.id, bea);
    const missing = await unblock(new mongoose.Types.ObjectId(), bea);

    expect(byRequester.statusCode).toBe(404);
    expect(byRequester.body).toEqual(missing.body);
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
  });

  it("keeps one pair record across two placed requests with the same helper and changes neither request", async () => {
    const first = await placeRequest(bea, ada);
    const second = await placeRequest(bea, ada);
    const beforeFirst = await MealRequest.findById(first._id).lean();
    const beforeSecond = await MealRequest.findById(second._id).lean();
    const fulfillmentsBefore = await Fulfillment.find({}).sort({ requestId: 1 }).lean();

    const viaFirst = await block(first._id, bea);
    const viaSecond = await block(second._id, bea);

    expect(viaFirst.statusCode).toBe(200);
    expect(viaSecond.statusCode).toBe(200);
    expect(viaSecond.body.block.id).toBe(viaFirst.body.block.id);
    expect(await ParticipantBlock.countDocuments({})).toBe(1);
    // Placed truth is byte-for-byte what it was.
    expect(await MealRequest.findById(first._id).lean()).toEqual(beforeFirst);
    expect(await MealRequest.findById(second._id).lean()).toEqual(beforeSecond);
    expect(await Fulfillment.find({}).sort({ requestId: 1 }).lean()).toEqual(
      fulfillmentsBefore
    );
    // Both continuations remain reachable to their helper.
    expect((await detail(first._id, ada)).statusCode).toBe(200);
    expect((await detail(second._id, ada)).statusCode).toBe(200);
  });

  it("keeps a requester-owned block and its management and Unblock after the creation-context request is deleted", async () => {
    const request = await placeRequest(bea, ada);
    const created = await block(request._id, bea);
    expect(created.statusCode).toBe(200);

    await MealRequest.deleteMany({});
    await Fulfillment.deleteMany({});

    const list = await listBlocks(bea);
    expect(list.body.blocks).toHaveLength(1);
    expect(list.body.blocks[0]).toMatchObject({
      id: created.body.block.id,
      blockedRole: "helper",
      diningLocation: "Jasper Kane Cafe",
    });
    expect((await unblock(created.body.block.id, bea)).statusCode).toBe(200);
    expect(await ParticipantBlock.countDocuments({})).toBe(0);
  });

  it("does not couple blocking to reporting: no report surface or record is created", async () => {
    const request = await createRequest(bea);
    await block(request._id, ada);
    // Registered moderation models may auto-create their (empty) collections
    // once enforcement imports them; what matters is that blocking writes none.
    const collections = (await mongoose.connection.db!.listCollections().toArray())
      .map((collection) => collection.name)
      .filter((name) => name.toLowerCase().includes("report"));
    for (const name of collections) {
      expect(await mongoose.connection.db!.collection(name).countDocuments({})).toBe(0);
    }
  });
});
