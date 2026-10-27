import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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

const pairFence = vi.hoisted(() => vi.fn());
vi.mock("./participantBlocks.js", () => ({
  isParticipantPairFenced: pairFence,
}));

// D-N1-5 (W4-N1 Increment B): the route only needs to trigger the dispatch
// with the correct target, exactly once, and only on the commit branch.
// The dispatcher's own eligibility/dedup/APNs behavior is proved in
// `helperPickupConfirmedPush.test.ts`.
const startHelperPickupConfirmedPush = vi.hoisted(() => vi.fn());
vi.mock("./helperPickupConfirmedPush.js", () => ({
  startHelperPickupConfirmedPush,
}));

import {
  confirmPlacedOrderPickup,
  getPlacedOrderDetail,
  getPlacedOrderEvidence,
  getHelperPlacementContact,
  getPlacedOrderList,
  hasUnfinishedPlacedPickupObligation,
  PICKUP_CONFIRMATION_UNAVAILABLE_CODE,
  PLACED_ORDER_EVIDENCE_UNAVAILABLE_CODE,
  PLACED_ORDER_NOT_FOUND_CODE,
  PLACED_ORDERS_UNAVAILABLE_CODE,
} from "./placedOrderRoutes.js";

const participantId = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const helperId = new mongoose.Types.ObjectId("64e0000000000000000000b2");
const requestId = "64e000000000000000000001";
const signingSecretText = "placed-order-route-unit-signing-secret";
const authority = signParticipantAuthority(
  participantId,
  1,
  Buffer.from(signingSecretText)
);

function orderDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: new mongoose.Types.ObjectId(requestId),
    vendor: "Palladium",
    food: "Chicken bowl · brown rice · black beans",
    pickupWindowText: "ASAP",
    mealSwipes: 2,
    menuPath: "meal-exchange",
    mealItems: [{ name: "Chicken bowl" }, { name: "Brown rice" }],
    orderDetails: undefined,
    estimatedDiningDollarsCents: undefined,
    windowStart: undefined,
    windowEnd: undefined,
    status: "placed",
    createdAt: new Date("2026-10-19T16:00:00.000Z"),
    expiresAt: new Date("2026-10-19T18:00:00.000Z"),
    deleteAt: new Date("2026-10-26T16:30:00.000Z"),
    orderNumber: "000123",
    etaText: "30 minutes",
    placedAt: new Date("2026-10-19T16:30:00.000Z"),
    requesterParticipantId: participantId,
    helperParticipantId: helperId,
    fulfillerEmail: "helper@nyu.edu",
    requesterPickupConfirmedAt: undefined,
    email: "requester@nyu.edu",
    claimTokenDigest: "must-not-leak",
    contactMessageSuppressed: true,
    deleteAtPrivate: "must-not-leak",
    ...overrides,
  };
}

function mockQuery<T>(result: T) {
  const chain = {
    select: vi.fn(() => chain),
    session: vi.fn(() => chain),
    sort: vi.fn(() => chain),
    lean: vi.fn(() => chain),
    exec: vi.fn().mockResolvedValue(result),
  };
  return chain;
}

interface Call {
  statusCode: number;
  body?: unknown;
  bytes?: Buffer;
  headers: Record<string, string>;
}

function routeContext(
  requestIdParam = requestId,
  withAuthority = true
) {
  const headers: Record<string, string> = withAuthority
    ? { [PARTICIPANT_AUTHORITY_HEADER]: authority }
    : {};
  const call: Call = { statusCode: 200, headers };
  const res = {
    status: vi.fn((statusCode: number) => {
      call.statusCode = statusCode;
      return res;
    }),
    json: vi.fn((body: unknown) => {
      call.body = body;
      return res;
    }),
    send: vi.fn((bytes: Buffer) => {
      call.bytes = bytes;
      return res;
    }),
    type: vi.fn((type: string) => {
      headers["Content-Type"] = type;
      return res;
    }),
    setHeader: vi.fn((name: string, value: string) => {
      headers[name] = value;
      return res;
    }),
  };
  const req = {
    params: { requestId: requestIdParam },
    headers,
  } as unknown as Request;
  return { req, res: res as unknown as Response, call };
}

function mockAuthority(): void {
  vi.spyOn(Participant, "findOne").mockReturnValue(
    mockQuery({
      _id: participantId,
      email: "requester@nyu.edu",
    }) as unknown as ReturnType<typeof Participant.findOne>
  );
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-10-19T17:00:00.000Z"));
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, signingSecretText);
  pairFence.mockResolvedValue(false);
  startHelperPickupConfirmedPush.mockClear();
  mockAuthority();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  pairFence.mockReset();
});

describe("private placed-order reads", () => {
  it("returns only the allowlisted unconfirmed owner rows with server readiness", async () => {
    const record = orderDocument();
    const find = vi
      .spyOn(MealRequest, "find")
      .mockReturnValue(mockQuery([record]) as never);
    const { req, res, call } = routeContext();

    await getPlacedOrderList(req, res);

    expect(find).toHaveBeenCalledWith({
      requesterParticipantId: participantId,
      status: "placed",
      requesterPickupConfirmedAt: { $exists: false },
      deleteAt: { $gt: new Date("2026-10-19T17:00:00.000Z") },
    });
    const body = call.body as {
      orders: Array<Record<string, unknown>>;
      serverNow: Date;
    };
    expect(body.serverNow).toEqual(new Date("2026-10-19T17:00:00.000Z"));
    expect(body.orders).toHaveLength(1);
    expect(body.orders[0]).toMatchObject({
      id: requestId,
      status: "placed",
      isOwnRequest: true,
      orderNumber: "000123",
      etaText: "30 minutes",
      placedAt: new Date("2026-10-19T16:30:00.000Z"),
      estimatedReadyAt: new Date("2026-10-19T17:00:00.000Z"),
    });
    expect(Object.keys(body.orders[0])).toEqual([
      "id",
      "vendor",
      "food",
      "pickupWindowText",
      "mealSwipes",
      "menuPath",
      "mealItems",
      "orderDetails",
      "estimatedDiningDollarsCents",
      "windowStart",
      "windowEnd",
      "status",
      "createdAt",
      "expiresAt",
      "isOwnRequest",
      "orderNumber",
      "etaText",
      "placedAt",
      "estimatedReadyAt",
      "homeVisibleUntil",
    ]);
    // 17:00Z ready on 2026-10-19 (EDT) -> end of campus day is 04:00Z next day.
    expect(body.orders[0].homeVisibleUntil).toEqual(
      new Date("2026-10-20T04:00:00.000Z")
    );
    const serialized = JSON.stringify(body);
    for (const privateValue of [
      "requesterParticipantId",
      "helperParticipantId",
      "requester@nyu.edu",
      "helper@nyu.edu",
      "must-not-leak",
    ]) {
      expect(serialized).not.toContain(privateValue);
    }
    expect(call.headers["Cache-Control"]).toBe("private, no-store");
    expect(call.headers.Vary).toBe(PARTICIPANT_AUTHORITY_HEADER);
  });

  it("fails closed on unrecognized readiness input", async () => {
    vi.spyOn(MealRequest, "find").mockReturnValue(
      mockQuery([
        orderDocument({
          etaText: "soon",
          placedAt: new Date("2026-10-19T16:30:00.000Z"),
        }),
      ]) as never
    );
    const { req, res, call } = routeContext();

    await getPlacedOrderList(req, res);

    const body = call.body as { orders: Array<Record<string, unknown>> };
    expect(body.orders).toEqual([]);
  });

  it("drops only the order past its requester campus-day cutoff, keeping others", async () => {
    // Server now is 2026-10-19T17:00Z. Ready 2026-10-18 -> day ended already.
    vi.spyOn(MealRequest, "find").mockReturnValue(
      mockQuery([
        orderDocument({
          _id: new mongoose.Types.ObjectId("64e000000000000000000002"),
          placedAt: new Date("2026-10-18T16:30:00.000Z"),
        }),
        orderDocument(),
      ]) as never
    );
    const { req, res, call } = routeContext();

    await getPlacedOrderList(req, res);

    const orders = (call.body as { orders: Array<{ id: string }> }).orders;
    expect(orders.map((order) => order.id)).toEqual([requestId]);
  });

  it("still lists a requester order after the helper's one-hour window ended", async () => {
    // Ready 14:30Z -> helper cutoff 15:30Z already passed at 17:00Z.
    vi.spyOn(MealRequest, "find").mockReturnValue(
      mockQuery([
        orderDocument({
          placedAt: new Date("2026-10-19T14:15:00.000Z"),
          etaText: "15 minutes",
        }),
      ]) as never
    );
    const { req, res, call } = routeContext();

    await getPlacedOrderList(req, res);

    const orders = (call.body as { orders: unknown[] }).orders;
    expect(orders).toHaveLength(1);
  });

  it("does not narrow the B1 unfinished-obligation filter or touch pickup truth", async () => {
    const update = vi.spyOn(MealRequest, "updateOne");
    vi.spyOn(MealRequest, "find").mockReturnValue(
      mockQuery([orderDocument({ placedAt: new Date("2026-10-18T16:30:00.000Z") })]) as never
    );
    const { req, res } = routeContext();

    await getPlacedOrderList(req, res);

    expect(update).not.toHaveBeenCalled();
  });

  it.each([
    ["one digit", "1", 200],
    ["multi-digit", "000123", 200],
    ["50 digits", "1".repeat(50), 200],
    ["empty", "", 503],
    ["letters", "XQZ", 503],
    ["hyphenated", "12-34", 503],
    ["trailing line break", "12\n", 503],
    ["more than 50 digits", "1".repeat(51), 503],
  ])("enforces the order-number format for %s", async (_label, orderNumber, statusCode) => {
    vi.spyOn(MealRequest, "find").mockReturnValue(
      mockQuery([orderDocument({ orderNumber })]) as never
    );
    const { req, res, call } = routeContext();

    await getPlacedOrderList(req, res);

    expect(call.statusCode).toBe(statusCode);
    if (statusCode === 200) {
      const body = call.body as { orders: Array<Record<string, unknown>> };
      expect(body.orders[0].orderNumber).toBe(orderNumber);
    } else {
      expect(call.body).toMatchObject({
        error: { code: PLACED_ORDERS_UNAVAILABLE_CODE },
      });
      if (orderNumber.length > 0) {
        expect(JSON.stringify(call.body)).not.toContain(orderNumber);
      }
    }
  });

  it("fails closed when persisted detail has a malformed order number", async () => {
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      mockQuery(orderDocument({ orderNumber: "ORDER-123" })) as never
    );
    const { req, res, call } = routeContext();

    await getPlacedOrderDetail(req, res);

    expect(call.statusCode).toBe(503);
    expect(call.body).toMatchObject({
      error: { code: PLACED_ORDERS_UNAVAILABLE_CODE },
    });
    expect(JSON.stringify(call.body)).not.toContain("ORDER-123");
  });

  it.each([
    ["ASAP", 15],
    ["15 minutes", 15],
    ["30 minutes", 30],
    ["45 minutes", 45],
    ["60 minutes", 60],
  ])(
    "derives the accepted %s readiness estimate from placement time",
    async (etaText, minutes) => {
      vi.spyOn(MealRequest, "find").mockReturnValue(
        mockQuery([
          orderDocument({
            etaText,
            placedAt: new Date("2026-10-19T16:30:00.000Z"),
          }),
        ]) as never
      );
      const { req, res, call } = routeContext();

      await getPlacedOrderList(req, res);

      const order = (call.body as { orders: Array<Record<string, unknown>> })
        .orders[0];
      expect(order.estimatedReadyAt).toEqual(
        new Date(
          new Date("2026-10-19T16:30:00.000Z").getTime() +
            Number(minutes) * 60_000
        )
      );
    }
  );

  it("returns exact detail state and omits helper contact when a pair is fenced", async () => {
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      mockQuery(orderDocument()) as never
    );
    pairFence.mockResolvedValue(true);
    const contactCheck = vi
      .spyOn(Participant.collection, "findOne")
      .mockResolvedValue(null as never);
    const { req, res, call } = routeContext();

    await getPlacedOrderDetail(req, res);

    const order = (call.body as { order: Record<string, unknown> }).order;
    expect(order.pickupConfirmation).toEqual({ status: "pending" });
    expect(order).not.toHaveProperty("contactHelperEmail");
    expect(contactCheck).toHaveBeenCalledWith(
      {
        _id: { $in: [participantId, helperId] },
        suspended: true,
      },
      { projection: { _id: 1 } }
    );
    expect(JSON.stringify(order)).not.toContain("requesterParticipantId");
    expect(JSON.stringify(order)).not.toContain("helperParticipantId");
  });

  it("uses the same not-found refusal for malformed and unavailable orders", async () => {
    const findOne = vi
      .spyOn(MealRequest, "findOne")
      .mockReturnValue(mockQuery(null) as never);
    const invalid = routeContext("not-an-id");
    await getPlacedOrderDetail(invalid.req, invalid.res);
    const absent = routeContext("64e0000000000000000000ff");
    await getPlacedOrderDetail(absent.req, absent.res);

    expect(invalid.call.statusCode).toBe(404);
    expect(absent.call.statusCode).toBe(404);
    expect(invalid.call.body).toEqual(absent.call.body);
    expect(invalid.call.body).toMatchObject({
      error: { code: PLACED_ORDER_NOT_FOUND_CODE },
    });
    expect(findOne).toHaveBeenCalledTimes(1);
  });

  it("requires authority before validating IDs or querying requests", async () => {
    const findOne = vi.spyOn(MealRequest, "findOne");
    const { req, res, call } = routeContext("bad-id", false);

    await getPlacedOrderDetail(req, res);

    expect(call.statusCode).toBe(401);
    expect(findOne).not.toHaveBeenCalled();
    expect(call.headers["Cache-Control"]).toBe("private, no-store");
    expect(call.headers.Vary).toBe(PARTICIPANT_AUTHORITY_HEADER);
  });

  it.each([
    ["list", getPlacedOrderList],
    ["evidence", getPlacedOrderEvidence],
    ["pickup", confirmPlacedOrderPickup],
  ] as const)(
    "%s route resolves authority before any request work",
    async (_name, handler) => {
      const find = vi.spyOn(MealRequest, "find");
      const findOne = vi.spyOn(MealRequest, "findOne");
      const update = vi.spyOn(MealRequest, "findOneAndUpdate");
      const evidence = vi.spyOn(PlacementEvidence, "findOne");
      const { req, res, call } = routeContext("bad-id", false);

      await handler(req, res);

      expect(call.statusCode).toBe(401);
      for (const spy of [find, findOne, update, evidence]) {
        expect(spy).not.toHaveBeenCalled();
      }
      expect(call.headers["Cache-Control"]).toBe("private, no-store");
      expect(call.headers.Vary).toBe(PARTICIPANT_AUTHORITY_HEADER);
    }
  );

  it("omits the helper address once pickup is confirmed, without restriction reads", async () => {
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      mockQuery(
        orderDocument({
          requesterPickupConfirmedAt: new Date("2026-10-19T16:55:00.000Z"),
        })
      ) as never
    );
    const contactCheck = vi.spyOn(Participant.collection, "findOne");
    const { req, res, call } = routeContext();

    await getPlacedOrderDetail(req, res);

    const order = (call.body as { order: Record<string, unknown> }).order;
    expect(order.pickupConfirmation).toEqual({
      status: "confirmed",
      confirmedAt: new Date("2026-10-19T16:55:00.000Z"),
    });
    expect(order).not.toHaveProperty("contactHelperEmail");
    expect(JSON.stringify(call.body)).not.toContain("helper@nyu.edu");
    expect(pairFence).not.toHaveBeenCalled();
    expect(contactCheck).not.toHaveBeenCalled();
  });
});

describe("private placement evidence", () => {
  it("rechecks ownership and returns raw bytes without cacheable metadata", async () => {
    const image = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      mockQuery({ _id: new mongoose.Types.ObjectId(requestId) }) as never
    );
    vi.spyOn(PlacementEvidence, "findOne").mockReturnValue(
      mockQuery({
        image,
        byteLength: image.length,
        mimeType: "image/jpeg",
      }) as never
    );
    const { req, res, call } = routeContext();

    await getPlacedOrderEvidence(req, res);

    expect(call.statusCode).toBe(200);
    expect(call.bytes).toEqual(image);
    expect(call.headers["Content-Type"]).toBe("image/jpeg");
    expect(call.headers["X-Content-Type-Options"]).toBe("nosniff");
    expect(call.headers["Cache-Control"]).toBe("private, no-store");
    expect(call.headers.Vary).toBe(PARTICIPANT_AUTHORITY_HEADER);
  });

  it("reports missing required evidence without fabricating bytes", async () => {
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      mockQuery({ _id: new mongoose.Types.ObjectId(requestId) }) as never
    );
    vi.spyOn(PlacementEvidence, "findOne").mockReturnValue(
      mockQuery(null) as never
    );
    const { req, res, call } = routeContext();

    await getPlacedOrderEvidence(req, res);

    expect(call.statusCode).toBe(503);
    expect(call.body).toMatchObject({
      error: { code: PLACED_ORDER_EVIDENCE_UNAVAILABLE_CODE },
    });
    expect(call.bytes).toBeUndefined();
  });
});

describe("requester pickup confirmation", () => {
  function stubTransaction() {
    const session = {
      withTransaction: vi.fn(async (operation: () => Promise<void>) => operation()),
      endSession: vi.fn().mockResolvedValue(undefined),
    };
    vi.spyOn(mongoose, "startSession").mockResolvedValue(session as never);
    vi.spyOn(Fulfillment, "updateOne").mockReturnValue({
      exec: vi.fn().mockResolvedValue({ matchedCount: 1 }),
    } as never);
    return session;
  }

  it("atomically sets only the backend confirmation timestamp", async () => {
    const confirmedAt = new Date("2026-10-19T17:00:00.000Z");
    const session = stubTransaction();
    const update = vi
      .spyOn(MealRequest, "findOneAndUpdate")
      .mockReturnValue(
        mockQuery({ requesterPickupConfirmedAt: confirmedAt }) as never
      );
    const { req, res, call } = routeContext();

    await confirmPlacedOrderPickup(req, res);

    expect(update).toHaveBeenCalledWith(
      {
        _id: requestId,
        requesterParticipantId: participantId,
        status: "placed",
        deleteAt: { $gt: confirmedAt },
        requesterPickupConfirmedAt: { $exists: false },
      },
      { $set: { requesterPickupConfirmedAt: confirmedAt } },
      { new: true, runValidators: true, session }
    );
    expect(Fulfillment.updateOne).toHaveBeenCalledWith(
      { requestId: new mongoose.Types.ObjectId(requestId) },
      { $set: { requesterPickupConfirmedAt: confirmedAt } },
      { session }
    );
    expect(call.body).toEqual({
      requestId,
      pickupConfirmation: { status: "confirmed", confirmedAt },
    });
    expect(call.headers["Cache-Control"]).toBe("private, no-store");
  });

  it("reconciles a replay to the exact already-confirmed timestamp", async () => {
    const confirmedAt = new Date("2026-10-19T16:58:00.000Z");
    stubTransaction();
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue(
      mockQuery(null) as never
    );
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      mockQuery({ requesterPickupConfirmedAt: confirmedAt }) as never
    );
    const { req, res, call } = routeContext();

    await confirmPlacedOrderPickup(req, res);

    expect(call.statusCode).toBe(200);
    expect(call.body).toEqual({
      requestId,
      pickupConfirmation: { status: "confirmed", confirmedAt },
    });
  });

  it("D-N1-5: triggers the helper pickup-confirmed push exactly once, for the recorded helper, on the commit that actually set the timestamp", async () => {
    stubTransaction();
    const confirmedAt = new Date("2026-10-19T17:00:00.000Z");
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue(
      mockQuery({
        requesterPickupConfirmedAt: confirmedAt,
        helperParticipantId: helperId,
      }) as never
    );
    const { req, res } = routeContext();

    await confirmPlacedOrderPickup(req, res);

    expect(startHelperPickupConfirmedPush).toHaveBeenCalledTimes(1);
    expect(startHelperPickupConfirmedPush).toHaveBeenCalledWith({
      requestId,
      helperParticipantId: helperId,
      requesterParticipantId: participantId,
    });
  });

  it("D-N1-5: does not trigger a second push on a replayed/idempotent confirmation", async () => {
    stubTransaction();
    const confirmedAt = new Date("2026-10-19T16:58:00.000Z");
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue(
      mockQuery(null) as never
    );
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      mockQuery({ requesterPickupConfirmedAt: confirmedAt }) as never
    );
    const { req, res } = routeContext();

    await confirmPlacedOrderPickup(req, res);

    expect(startHelperPickupConfirmedPush).not.toHaveBeenCalled();
  });

  it("D-N1-5: does not trigger a push when the mutation outcome is unavailable", async () => {
    stubTransaction();
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockRejectedValue(new Error("database unavailable")),
        }),
      }),
    } as never);
    const { req, res } = routeContext();

    await confirmPlacedOrderPickup(req, res);

    expect(startHelperPickupConfirmedPush).not.toHaveBeenCalled();
  });

  it("does not dispatch until the Request and Fulfillment transaction commits", async () => {
    const session = stubTransaction();
    const confirmedAt = new Date("2026-10-19T17:00:00.000Z");
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue(
      mockQuery({ requesterPickupConfirmedAt: confirmedAt, helperParticipantId: helperId }) as never
    );
    session.withTransaction.mockImplementation(async (operation) => {
      await operation();
      expect(Fulfillment.updateOne).toHaveBeenCalledOnce();
      expect(startHelperPickupConfirmedPush).not.toHaveBeenCalled();
    });
    const { req, res, call } = routeContext();
    await confirmPlacedOrderPickup(req, res);
    expect(call.statusCode).toBe(200);
    expect(startHelperPickupConfirmedPush).toHaveBeenCalledOnce();
  });

  it("does not dispatch when durable proof is missing or commit is unestablished", async () => {
    stubTransaction();
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue(
      mockQuery({ requesterPickupConfirmedAt: new Date(), helperParticipantId: helperId }) as never
    );
    vi.mocked(Fulfillment.updateOne).mockReturnValue({
      exec: vi.fn().mockResolvedValue({ matchedCount: 0 }),
    } as never);
    const { req, res, call } = routeContext();
    await confirmPlacedOrderPickup(req, res);
    expect(call.statusCode).toBe(503);
    expect(startHelperPickupConfirmedPush).not.toHaveBeenCalled();
  });

  it("clears speculative dispatch state when a transaction retries into a replay", async () => {
    const session = stubTransaction();
    const confirmedAt = new Date();
    vi.spyOn(MealRequest, "findOneAndUpdate")
      .mockReturnValueOnce(mockQuery({ requesterPickupConfirmedAt: confirmedAt, helperParticipantId: helperId }) as never)
      .mockReturnValueOnce(mockQuery(null) as never);
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      mockQuery({ requesterPickupConfirmedAt: confirmedAt }) as never
    );
    session.withTransaction.mockImplementation(async (operation) => {
      await operation();
      await operation();
    });
    const { req, res, call } = routeContext();
    await confirmPlacedOrderPickup(req, res);
    expect(call.statusCode).toBe(200);
    expect(startHelperPickupConfirmedPush).not.toHaveBeenCalled();
  });

  it("keeps an unclassifiable mutation outcome explicitly unavailable", async () => {
    stubTransaction();
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockRejectedValue(new Error("database unavailable")),
        }),
      }),
    } as never);
    const { req, res, call } = routeContext();

    await confirmPlacedOrderPickup(req, res);

    expect(call.statusCode).toBe(503);
    expect(call.body).toMatchObject({
      error: { code: PICKUP_CONFIRMATION_UNAVAILABLE_CODE },
    });
  });
});

describe("unfinished placed-order obligation (R3 → B1 email-replacement gate)", () => {
  // Placed 16:30Z, ETA 30 minutes -> ready 17:00Z (EDT).
  // Helper cutoff 18:00Z; requester cutoff 04:00Z next day.
  const candidate = { placedAt: new Date("2026-10-19T16:30:00.000Z"), etaText: "30 minutes" };

  function mockCandidates(rows: unknown[]) {
    return vi.spyOn(MealRequest, "find").mockReturnValue(mockQuery(rows) as never);
  }

  it("A: is true before requester homeVisibleUntil and queries the owned, retained, unconfirmed set", async () => {
    const now = new Date("2026-10-19T17:00:00.000Z");
    const find = mockCandidates([candidate]);

    await expect(
      hasUnfinishedPlacedPickupObligation(String(participantId), now)
    ).resolves.toBe(true);
    expect(find).toHaveBeenCalledWith({
      requesterParticipantId: participantId,
      status: "placed",
      requesterPickupConfirmedAt: { $exists: false },
      deleteAt: { $gt: now },
    });
  });

  it("B: is false after requester homeVisibleUntil even though still unconfirmed and retained", async () => {
    mockCandidates([candidate]);
    await expect(
      hasUnfinishedPlacedPickupObligation(
        String(participantId),
        new Date("2026-10-20T04:00:00.000Z")
      )
    ).resolves.toBe(false);
    await expect(
      hasUnfinishedPlacedPickupObligation(
        String(participantId),
        new Date("2026-10-20T03:59:59.999Z")
      )
    ).resolves.toBe(true);
  });

  it("E: helper ETA+1h expiry alone does not clear the obligation", async () => {
    mockCandidates([candidate]);
    // 18:00Z is exactly the helper cutoff; 20:00Z is well past it.
    for (const at of ["2026-10-19T18:00:00.000Z", "2026-10-19T20:00:00.000Z"]) {
      await expect(
        hasUnfinishedPlacedPickupObligation(String(participantId), new Date(at))
      ).resolves.toBe(true);
    }
  });

  it("is true while any one of several placements is still active", async () => {
    mockCandidates([
      { placedAt: new Date("2026-10-18T16:30:00.000Z"), etaText: "30 minutes" },
      candidate,
    ]);
    await expect(
      hasUnfinishedPlacedPickupObligation(
        String(participantId),
        new Date("2026-10-19T17:00:00.000Z")
      )
    ).resolves.toBe(true);
  });

  it("C: a malformed or missing ETA rejects (fail closed) and is never false", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const now = new Date("2026-10-19T17:00:00.000Z");
    for (const rows of [
      [{ placedAt: candidate.placedAt, etaText: "soon" }],
      [{ placedAt: candidate.placedAt }],
      [{ etaText: "30 minutes" }],
      // An expired valid row beside an invalid one cannot prove "no obligation".
      [
        { placedAt: new Date("2026-10-18T16:30:00.000Z"), etaText: "30 minutes" },
        { placedAt: candidate.placedAt, etaText: "later" },
      ],
    ]) {
      mockCandidates(rows);
      await expect(
        hasUnfinishedPlacedPickupObligation(String(participantId), now)
      ).rejects.toThrow("Placed-order fulfillment invariant failed");
      vi.restoreAllMocks();
      vi.spyOn(console, "error").mockImplementation(() => {});
    }
    expect(consoleError).toHaveBeenCalledWith(
      "[route] Placed-order fulfillment invariant failed"
    );
  });

  it("a valid active placement still answers true beside an invalid row", async () => {
    mockCandidates([{ placedAt: candidate.placedAt, etaText: "soon" }, candidate]);
    await expect(
      hasUnfinishedPlacedPickupObligation(
        String(participantId),
        new Date("2026-10-19T17:00:00.000Z")
      )
    ).resolves.toBe(true);
  });

  it("E: requester Home omits the corrupt row without fabricating a cutoff", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(MealRequest, "find").mockReturnValue(
      mockQuery([orderDocument({ etaText: "soon" }), orderDocument({
        _id: new mongoose.Types.ObjectId("64e000000000000000000002"),
      })]) as never
    );
    const { req, res, call } = routeContext();
    await getPlacedOrderList(req, res);
    const orders = (call.body as { orders: Array<{ id: string }> }).orders;
    expect(orders.map((order) => order.id)).toEqual(["64e000000000000000000002"]);
  });

  it("C/D: time expiry and invalid ETA are read-only: no write of pickup truth, status or retention", async () => {
    const writes = [
      vi.spyOn(MealRequest, "updateOne"),
      vi.spyOn(MealRequest, "updateMany"),
      vi.spyOn(MealRequest, "findOneAndUpdate"),
      vi.spyOn(MealRequest, "deleteOne"),
      vi.spyOn(MealRequest, "deleteMany"),
    ];
    vi.spyOn(console, "error").mockImplementation(() => {});
    mockCandidates([candidate]);
    await hasUnfinishedPlacedPickupObligation(
      String(participantId),
      new Date("2026-10-21T00:00:00.000Z")
    );
    mockCandidates([{ placedAt: candidate.placedAt, etaText: "soon" }]);
    await expect(
      hasUnfinishedPlacedPickupObligation(String(participantId), new Date("2026-10-19T17:00:00.000Z"))
    ).rejects.toThrow();
    for (const write of writes) expect(write).not.toHaveBeenCalled();
  });

  it("propagates an unreadable store so the consuming gate fails closed", async () => {
    vi.spyOn(MealRequest, "find").mockReturnValue({
      select: () => ({ lean: () => ({ exec: () => Promise.reject(new Error("store unavailable")) }) }),
    } as never);

    await expect(
      hasUnfinishedPlacedPickupObligation(String(participantId), new Date())
    ).rejects.toThrow("store unavailable");
  });
});

describe("helper placement contact (requester email to the claiming helper only)", () => {
  const requesterId = new mongoose.Types.ObjectId("64e0000000000000000000c3");

  function mockPlacement(
    placement: Record<string, unknown> | null,
    requesterEmail: string | undefined = "requester@nyu.edu"
  ) {
    const findOne = vi
      .spyOn(MealRequest, "findOne")
      .mockReturnValue(mockQuery(placement) as never);
    vi.spyOn(Participant, "findById").mockReturnValue(
      mockQuery(requesterEmail ? { email: requesterEmail } : null) as never
    );
    vi.spyOn(Participant.collection, "findOne").mockResolvedValue(null as never);
    return findOne;
  }

  const placement = {
    requesterParticipantId: requesterId,
    helperParticipantId: participantId,
    placedAt: new Date("2026-10-19T16:30:00.000Z"),
    etaText: "30 minutes",
  };

  it("returns only the requester email, scoped to the caller's own live placement", async () => {
    const findOne = mockPlacement(placement);
    const { req, res, call } = routeContext();

    await getHelperPlacementContact(req, res);

    expect(call.statusCode).toBe(200);
    expect(call.body).toEqual({ contactRequesterEmail: "requester@nyu.edu" });
    expect(findOne).toHaveBeenCalledWith({
      _id: requestId,
      helperParticipantId: participantId,
      status: "placed",
      requesterPickupConfirmedAt: null,
      deleteAt: { $gt: new Date("2026-10-19T17:00:00.000Z") },
    });
  });

  it("uses one uniform 404 for unowned, retired, fenced, suspended, missing-email and malformed", async () => {
    const outcomes: Call[] = [];

    mockPlacement(null);
    let ctx = routeContext();
    await getHelperPlacementContact(ctx.req, ctx.res);
    outcomes.push(ctx.call);
    vi.restoreAllMocks();
    mockAuthority();

    mockPlacement(placement);
    pairFence.mockResolvedValue(true);
    ctx = routeContext();
    await getHelperPlacementContact(ctx.req, ctx.res);
    outcomes.push(ctx.call);
    vi.restoreAllMocks();
    mockAuthority();
    pairFence.mockResolvedValue(false);

    mockPlacement(placement);
    vi.spyOn(Participant.collection, "findOne").mockResolvedValue({ _id: requesterId } as never);
    ctx = routeContext();
    await getHelperPlacementContact(ctx.req, ctx.res);
    outcomes.push(ctx.call);
    vi.restoreAllMocks();
    mockAuthority();

    mockPlacement(placement, "");
    ctx = routeContext();
    await getHelperPlacementContact(ctx.req, ctx.res);
    outcomes.push(ctx.call);

    ctx = routeContext("not-an-id");
    await getHelperPlacementContact(ctx.req, ctx.res);
    outcomes.push(ctx.call);

    for (const outcome of outcomes) {
      expect(outcome.statusCode).toBe(404);
      expect(outcome.body).toEqual(outcomes[0].body);
      expect(JSON.stringify(outcome.body)).not.toContain("@");
    }
  });

  it("stops disclosing the email once the helper window (ETA + 1h) has lapsed", async () => {
    mockPlacement({ ...placement, placedAt: new Date("2026-10-19T14:00:00.000Z") });
    const { req, res, call } = routeContext();

    await getHelperPlacementContact(req, res);

    expect(call.statusCode).toBe(404);
    expect(JSON.stringify(call.body)).not.toContain("@");
  });

  it("requires participant authority", async () => {
    const findOne = mockPlacement(placement);
    const { req, res, call } = routeContext(requestId, false);

    await getHelperPlacementContact(req, res);

    expect(call.statusCode).toBeGreaterThanOrEqual(400);
    expect(findOne).not.toHaveBeenCalled();
    expect(JSON.stringify(call.body ?? {})).not.toContain("requester@nyu.edu");
  });
});
