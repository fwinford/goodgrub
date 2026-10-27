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

const startHelperPickupConfirmedPush = vi.hoisted(() => vi.fn());
vi.mock("./helperPickupConfirmedPush.js", () => ({
  startHelperPickupConfirmedPush,
}));

import {
  Fulfillment,
  Participant,
  PlacementEvidence,
  Request as MealRequest,
} from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  confirmPlacedOrderPickup,
  getPlacedOrderDetail,
  getPlacedOrderEvidence,
  getPlacedOrderList,
  hasUnfinishedPlacedPickupObligation,
} from "./placedOrderRoutes.js";
import { campusDayEnd } from "./placedHomeVisibility.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_placed_orders`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const secretText = "placed-orders-mongo-participant-secret-32";
const secret = Buffer.from(secretText);
const requesterId = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const otherRequesterId = new mongoose.Types.ObjectId(
  "64e0000000000000000000b2"
);
const helperId = new mongoose.Types.ObjectId("64e0000000000000000000c3");
const requesterAuthority = signParticipantAuthority(requesterId, 1, secret);
const otherRequesterAuthority = signParticipantAuthority(
  otherRequesterId,
  1,
  secret
);
const onePixelPng = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64"
);

function routeCall(
  requestId: string,
  authority = requesterAuthority
) {
  const headers: Record<string, string> = {
    [PARTICIPANT_AUTHORITY_HEADER]: authority,
  };
  const req = {
    params: { requestId },
    headers,
  } as unknown as Request;
  const call: {
    statusCode: number;
    body?: unknown;
    bytes?: Buffer;
    headers: Record<string, string>;
  } = { statusCode: 200, headers };
  const res = {} as Response;
  res.status = vi.fn((statusCode: number) => {
    call.statusCode = statusCode;
    return res;
  }) as never;
  res.json = vi.fn((body: unknown) => {
    call.body = body;
    return res;
  }) as never;
  res.send = vi.fn((bytes: Buffer) => {
    call.bytes = bytes;
    return res;
  }) as never;
  res.type = vi.fn((type: string) => {
    headers["Content-Type"] = type;
    return res;
  }) as never;
  res.setHeader = vi.fn((name: string, value: string) => {
    headers[name] = value;
    return res;
  }) as never;
  return { req, res, call };
}

async function createPlacedOrder(
  ownerId = requesterId,
  overrides: Record<string, unknown> = {}
) {
  const placedAt = new Date(Date.now() - 30 * 60_000);
  const deleteAt = new Date(placedAt.getTime() + 7 * 24 * 60 * 60_000);
  const request = await MealRequest.create({
    vendor: "Jasper Kane Cafe",
    food: "Chicken bowl · brown rice · black beans",
    pickupWindowText: "ASAP",
    menuPath: "meal-exchange",
    mealSwipes: 2,
    mealItems: [{ name: "Chicken bowl" }, { name: "Brown rice" }],
    email: "requester@nyu.edu",
    status: "placed",
    orderNumber: "000123",
    etaText: "30 minutes",
    placedAt,
    deleteAt,
    expiresAt: new Date(Date.now() + 2 * 60 * 60_000),
    requesterParticipantId: ownerId,
    helperParticipantId: helperId,
    fulfillerEmail: "helper@nyu.edu",
    ...overrides,
  });
  await Fulfillment.create({
    requestId: request._id,
    orderNumber: String(request.orderNumber),
    etaText: String(request.etaText),
    placedAt,
  });
  return { request, placedAt, deleteAt };
}

describeMongo("W4-R3 placed-order routes against real MongoDB", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, secretText);
    await mongoose.connect(mongoUri!);
    await Promise.all([
      Participant.init(),
      MealRequest.init(),
      Fulfillment.init(),
      PlacementEvidence.init(),
    ]);
    await Participant.create([
      {
        _id: requesterId,
        email: "r3-requester@nyu.edu",
        authorityVersion: 1,
        verifiedAt: new Date(),
      },
      {
        _id: otherRequesterId,
        email: "r3-other-requester@nyu.edu",
        authorityVersion: 1,
        verifiedAt: new Date(),
      },
      {
        _id: helperId,
        email: "r3-helper@nyu.edu",
        authorityVersion: 1,
        verifiedAt: new Date(),
      },
    ]);
  }, 30_000);

  afterEach(async () => {
    await Promise.all([
      MealRequest.deleteMany({}),
      Fulfillment.deleteMany({}),
      PlacementEvidence.deleteMany({}),
    ]);
    await Participant.collection.updateMany(
      {},
      { $unset: { suspended: 1 } }
    );
  });

  afterAll(async () => {
    await Promise.all([
      MealRequest.deleteMany({}),
      Fulfillment.deleteMany({}),
      PlacementEvidence.deleteMany({}),
      Participant.deleteMany({
        _id: { $in: [requesterId, otherRequesterId, helperId] },
      }),
    ]);
    vi.unstubAllEnvs();
    await mongoose.disconnect();
  });

  it("establishes the requester placed-order and unique evidence indexes in Mongo", async () => {
    const requestIndexes = await MealRequest.collection.indexes();
    const placedOrderIndex = requestIndexes.find(
      (index) => index.name === "request_requester_placed"
    );
    expect(placedOrderIndex?.key).toEqual({
      requesterParticipantId: 1,
      status: 1,
      createdAt: -1,
    });
    expect(placedOrderIndex?.partialFilterExpression).toEqual({
      status: "placed",
    });

    const evidenceIndexes = await PlacementEvidence.collection.indexes();
    const evidenceUniqueIndex = evidenceIndexes.find(
      (index) => index.name === "placement_evidence_request_unique"
    );
    expect(evidenceUniqueIndex?.key).toEqual({ requestId: 1 });
    expect(evidenceUniqueIndex?.unique).toBe(true);

    const { request, deleteAt } = await createPlacedOrder();
    const evidence = {
      requestId: request._id,
      image: onePixelPng,
      mimeType: "image/png",
      byteLength: onePixelPng.length,
      deleteAt,
    };
    await PlacementEvidence.create(evidence);
    await expect(PlacementEvidence.create(evidence)).rejects.toMatchObject({
      code: 11000,
    });
    expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(1);
  });

  it("lists only the current participant's retained, unconfirmed placements", async () => {
    const { request } = await createPlacedOrder();
    await createPlacedOrder(otherRequesterId);
    await createPlacedOrder(requesterId, {
      requesterPickupConfirmedAt: new Date(),
    });
    await createPlacedOrder(requesterId, {
      deleteAt: new Date(Date.now() - 1),
    });

    const { req, res, call } = routeCall("");
    await getPlacedOrderList(req, res);

    expect(call.statusCode).toBe(200);
    const body = call.body as {
      orders: Array<Record<string, unknown>>;
      serverNow: Date;
    };
    expect(body.orders.map((order) => order.id)).toEqual([
      String(request._id),
    ]);
    expect(body.orders[0].isOwnRequest).toBe(true);
    expect(body.orders[0].status).toBe("placed");
    expect(body.orders[0].estimatedReadyAt).toBeInstanceOf(Date);
    expect(call.headers["Cache-Control"]).toBe("private, no-store");
    expect(call.headers.Vary).toBe(PARTICIPANT_AUTHORITY_HEADER);
  });

  it("keeps requester detail and helper contact private to the verified owner", async () => {
    const { request } = await createPlacedOrder();
    const own = routeCall(String(request._id));
    await getPlacedOrderDetail(own.req, own.res);
    expect(own.call.statusCode).toBe(200);
    expect(
      (own.call.body as { order: Record<string, unknown> }).order
        .contactHelperEmail
    ).toBe("helper@nyu.edu");

    const other = routeCall(String(request._id), otherRequesterAuthority);
    await getPlacedOrderDetail(other.req, other.res);
    expect(other.call.statusCode).toBe(404);
    const absent = routeCall(new mongoose.Types.ObjectId().toString());
    await getPlacedOrderDetail(absent.req, absent.res);
    expect(other.call.body).toEqual(absent.call.body);

    await Participant.collection.updateOne(
      { _id: helperId },
      { $set: { suspended: true } }
    );
    const restricted = routeCall(String(request._id));
    await getPlacedOrderDetail(restricted.req, restricted.res);
    expect(
      (restricted.call.body as { order: Record<string, unknown> }).order
    ).not.toHaveProperty("contactHelperEmail");
  });

  it("rechecks ownership and retention before serving screenshot bytes", async () => {
    const { request, deleteAt } = await createPlacedOrder();
    await PlacementEvidence.create({
      requestId: request._id,
      image: onePixelPng,
      mimeType: "image/png",
      byteLength: onePixelPng.length,
      deleteAt,
    });

    const authorized = routeCall(String(request._id));
    await getPlacedOrderEvidence(authorized.req, authorized.res);
    expect(authorized.call.statusCode).toBe(200);
    expect(authorized.call.bytes).toEqual(onePixelPng);
    expect(authorized.call.headers["Content-Type"]).toBe("image/png");
    expect(authorized.call.headers["X-Content-Type-Options"]).toBe("nosniff");
    expect(authorized.call.headers["Cache-Control"]).toBe("private, no-store");

    const other = routeCall(String(request._id), otherRequesterAuthority);
    await getPlacedOrderEvidence(other.req, other.res);
    expect(other.call.statusCode).toBe(404);
    expect(other.call.bytes).toBeUndefined();
  });

  it("isolates each valid participant's placed data and evidence from the other", async () => {
    const first = await createPlacedOrder(requesterId, {
      vendor: "Jasper Kane Cafe",
      orderNumber: "11111111",
    });
    const second = await createPlacedOrder(otherRequesterId, {
      vendor: "Cafe 370",
      orderNumber: "22222222",
    });
    await Promise.all([
      PlacementEvidence.create({
        requestId: first.request._id,
        image: onePixelPng,
        mimeType: "image/png",
        byteLength: onePixelPng.length,
        deleteAt: first.deleteAt,
      }),
      PlacementEvidence.create({
        requestId: second.request._id,
        image: Buffer.from(onePixelPng).reverse(),
        mimeType: "image/png",
        byteLength: onePixelPng.length,
        deleteAt: second.deleteAt,
      }),
    ]);

    const firstList = routeCall("", requesterAuthority);
    const secondList = routeCall("", otherRequesterAuthority);
    await Promise.all([
      getPlacedOrderList(firstList.req, firstList.res),
      getPlacedOrderList(secondList.req, secondList.res),
    ]);
    expect(
      (firstList.call.body as { orders: Array<{ id: string }> }).orders.map(
        (order) => order.id
      )
    ).toEqual([String(first.request._id)]);
    expect(
      (secondList.call.body as { orders: Array<{ id: string }> }).orders.map(
        (order) => order.id
      )
    ).toEqual([String(second.request._id)]);

    const crossedDetail = routeCall(
      String(second.request._id),
      requesterAuthority
    );
    await getPlacedOrderDetail(crossedDetail.req, crossedDetail.res);
    expect(crossedDetail.call.statusCode).toBe(404);
    expect(JSON.stringify(crossedDetail.call.body)).not.toContain("22222222");

    const crossedEvidence = routeCall(
      String(first.request._id),
      otherRequesterAuthority
    );
    await getPlacedOrderEvidence(crossedEvidence.req, crossedEvidence.res);
    expect(crossedEvidence.call.statusCode).toBe(404);
    expect(crossedEvidence.call.bytes).toBeUndefined();
  });

  it("fails closed on malformed persisted order numbers in list and detail reads", async () => {
    const { request } = await createPlacedOrder();
    await MealRequest.collection.updateOne(
      { _id: new mongoose.Types.ObjectId(String(request._id)) },
      { $set: { orderNumber: "ORDER-123" } }
    );

    const list = routeCall("", requesterAuthority);
    await getPlacedOrderList(list.req, list.res);
    expect(list.call.statusCode).toBe(503);
    expect(JSON.stringify(list.call.body)).not.toContain("ORDER-123");

    const detail = routeCall(String(request._id), requesterAuthority);
    await getPlacedOrderDetail(detail.req, detail.res);
    expect(detail.call.statusCode).toBe(503);
    expect(JSON.stringify(detail.call.body)).not.toContain("ORDER-123");
  });

  it("converges concurrent and replayed pickup confirmation on one timestamp", async () => {
    const { request, placedAt, deleteAt } = await createPlacedOrder();
    startHelperPickupConfirmedPush.mockClear();
    await PlacementEvidence.create({
      requestId: request._id,
      image: onePixelPng,
      mimeType: "image/png",
      byteLength: onePixelPng.length,
      deleteAt,
    });

    const first = routeCall(String(request._id));
    const second = routeCall(String(request._id));
    await Promise.all([
      confirmPlacedOrderPickup(first.req, first.res),
      confirmPlacedOrderPickup(second.req, second.res),
    ]);
    expect(first.call.statusCode).toBe(200);
    expect(second.call.statusCode).toBe(200);
    const firstTimestamp = (
      first.call.body as { pickupConfirmation: { confirmedAt: Date } }
    ).pickupConfirmation.confirmedAt;
    const secondTimestamp = (
      second.call.body as { pickupConfirmation: { confirmedAt: Date } }
    ).pickupConfirmation.confirmedAt;
    expect(firstTimestamp).toEqual(secondTimestamp);
    expect(startHelperPickupConfirmedPush).toHaveBeenCalledTimes(1);
    expect(startHelperPickupConfirmedPush).toHaveBeenCalledWith({
      requestId: String(request._id),
      helperParticipantId: helperId,
      requesterParticipantId: requesterId,
    });

    const replay = routeCall(String(request._id));
    await confirmPlacedOrderPickup(replay.req, replay.res);
    expect(
      (replay.call.body as { pickupConfirmation: { confirmedAt: Date } })
        .pickupConfirmation.confirmedAt
    ).toEqual(firstTimestamp);
    expect(startHelperPickupConfirmedPush).toHaveBeenCalledTimes(1);

    const stored = await MealRequest.findById(request._id)
      .select("+requesterPickupConfirmedAt")
      .lean()
      .exec();
    expect(stored?.status).toBe("placed");
    expect(stored?.requesterPickupConfirmedAt).toEqual(firstTimestamp);
    expect(stored?.deleteAt).toEqual(deleteAt);
    expect(
      await Fulfillment.findOne({ requestId: request._id })
        .select("+requesterPickupConfirmedAt")
        .lean()
        .exec()
    ).toMatchObject({ requesterPickupConfirmedAt: firstTimestamp });
    expect(
      await PlacementEvidence.countDocuments({ requestId: request._id })
    ).toBe(1);
    const retainedEvidence = await PlacementEvidence.findOne({
      requestId: request._id,
    })
      .select("+image")
      .lean()
      .exec();
    expect(retainedEvidence?.deleteAt).toEqual(
      new Date(placedAt.getTime() + 7 * 24 * 60 * 60_000)
    );
    expect(retainedEvidence?.deleteAt).toEqual(deleteAt);

    const evidenceAfterPickup = routeCall(String(request._id));
    await getPlacedOrderEvidence(evidenceAfterPickup.req, evidenceAfterPickup.res);
    expect(evidenceAfterPickup.call.statusCode).toBe(200);
    expect(evidenceAfterPickup.call.bytes).toEqual(onePixelPng);
    expect(evidenceAfterPickup.call.headers["Cache-Control"]).toBe(
      "private, no-store"
    );
  });

  it("reconciles a committed pickup whose response was lost without rewriting it", async () => {
    const { request } = await createPlacedOrder();
    const lost = routeCall(String(request._id));
    await confirmPlacedOrderPickup(lost.req, lost.res);
    expect(lost.call.statusCode).toBe(200);
    const committed = await MealRequest.findById(request._id)
      .select("+requesterPickupConfirmedAt")
      .lean()
      .exec();
    const committedAt = committed?.requesterPickupConfirmedAt;
    expect(committedAt).toBeInstanceOf(Date);

    const read = routeCall(String(request._id));
    await getPlacedOrderDetail(read.req, read.res);
    const order = (read.call.body as { order: Record<string, unknown> }).order;
    expect(order.pickupConfirmation).toEqual({
      status: "confirmed",
      confirmedAt: committedAt,
    });
    expect(order).not.toHaveProperty("contactHelperEmail");

    const list = routeCall("");
    await getPlacedOrderList(list.req, list.res);
    expect((list.call.body as { orders: unknown[] }).orders).toEqual([]);

    const retry = routeCall(String(request._id));
    await confirmPlacedOrderPickup(retry.req, retry.res);
    expect(
      (retry.call.body as { pickupConfirmation: { confirmedAt: Date } })
        .pickupConfirmation.confirmedAt
    ).toEqual(committedAt);
    const after = await MealRequest.findById(request._id)
      .select("+requesterPickupConfirmedAt")
      .lean()
      .exec();
    expect(after?.requesterPickupConfirmedAt).toEqual(committedAt);
    expect(after?.status).toBe("placed");
  });

  it("reports an unfinished requester obligation only for an owned, retained, unconfirmed placement", async () => {
    const now = new Date();
    const requester = String(requesterId);
    expect(await hasUnfinishedPlacedPickupObligation(requester, now)).toBe(false);

    await createPlacedOrder(requesterId, { requesterPickupConfirmedAt: now });
    await createPlacedOrder(requesterId, { deleteAt: new Date(now.getTime() - 1) });
    await createPlacedOrder(requesterId, { status: "withdrawn" });
    await createPlacedOrder(otherRequesterId);
    expect(await hasUnfinishedPlacedPickupObligation(requester, now)).toBe(false);
    expect(
      await hasUnfinishedPlacedPickupObligation(String(helperId), now),
      "the helper's obligation ended when the request left claimed"
    ).toBe(false);

    const { request } = await createPlacedOrder();
    expect(await hasUnfinishedPlacedPickupObligation(requester, now)).toBe(true);
    expect(
      await hasUnfinishedPlacedPickupObligation(String(otherRequesterId), now)
    ).toBe(true);

    const { req, res } = routeCall(String(request._id));
    await confirmPlacedOrderPickup(req, res);
    expect(await hasUnfinishedPlacedPickupObligation(requester, new Date())).toBe(false);
  });

  it("ends the obligation at requester homeVisibleUntil without writing pickup truth, status or retention", async () => {
    const { request, placedAt, deleteAt } = await createPlacedOrder();
    const requester = String(requesterId);
    // Ready = placedAt + 30m. Requester cutoff = end of that campus day.
    const readyAt = new Date(placedAt.getTime() + 30 * 60_000);
    const cutoff = campusDayEnd(readyAt);
    const helperCutoff = new Date(readyAt.getTime() + 60 * 60_000);

    expect(
      await hasUnfinishedPlacedPickupObligation(requester, new Date(cutoff.getTime() - 1))
    ).toBe(true);
    if (helperCutoff.getTime() < cutoff.getTime()) {
      expect(
        await hasUnfinishedPlacedPickupObligation(requester, helperCutoff),
        "helper ETA+1h expiry alone must not clear B1"
      ).toBe(true);
    }
    expect(await hasUnfinishedPlacedPickupObligation(requester, cutoff)).toBe(false);

    const stored = await MealRequest.findById(request._id)
      .select("+requesterPickupConfirmedAt +deleteAt +status")
      .lean()
      .exec();
    expect(stored?.requesterPickupConfirmedAt).toBeUndefined();
    expect(stored?.status).toBe("placed");
    expect(stored?.deleteAt).toEqual(deleteAt);
  });

  it("rejects, never false, for a retained unconfirmed placement with an invalid required ETA, writing nothing", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { request, deleteAt } = await createPlacedOrder(requesterId, {
      etaText: "whenever",
    });
    await expect(
      hasUnfinishedPlacedPickupObligation(String(requesterId), new Date())
    ).rejects.toThrow("Placed-order fulfillment invariant failed");

    const stored = await MealRequest.findById(request._id)
      .select("+requesterPickupConfirmedAt +deleteAt +status")
      .lean()
      .exec();
    expect(stored?.requesterPickupConfirmedAt).toBeUndefined();
    expect(stored?.status).toBe("placed");
    expect(stored?.deleteAt).toEqual(deleteAt);
  });

  it("rejects rather than clearing an obligation it cannot read", async () => {
    await expect(
      hasUnfinishedPlacedPickupObligation("not-an-object-id", new Date())
    ).rejects.toThrow();
  });

  it("refuses a logically expired order regardless of TTL cleanup", async () => {
    const { request } = await createPlacedOrder(requesterId, {
      deleteAt: new Date(Date.now() - 1),
    });
    const { req, res, call } = routeCall(String(request._id));

    await confirmPlacedOrderPickup(req, res);

    expect(call.statusCode).toBe(404);
    const stored = await MealRequest.findById(request._id)
      .select("+requesterPickupConfirmedAt")
      .lean()
      .exec();
    expect(stored?.requesterPickupConfirmedAt).toBeUndefined();
  });
});
