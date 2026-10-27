import express, { type Request, type Response } from "express";
import { readFileSync, readdirSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  type Mock,
  vi,
} from "vitest";

const { resendSend, notifySubscribersForRequest } = vi.hoisted(() => ({
  resendSend: vi.fn(),
  notifySubscribersForRequest: vi.fn(),
}));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

vi.mock("./notifySubscribers.js", () => ({
  notifySubscribersForRequest,
}));

import {
  Installation,
  Request as MealRequest,
  Participant,
  RequestOperation,
  RequestOperationAuthority,
} from "../models/db.js";
import {
  ASAP_WINDOW_TEXT,
  createRequest,
  createRequestRateLimiter,
  INVALID_OPERATION_ID_CODE,
  INVALID_OPERATION_ID_MESSAGE,
  OPERATION_EXPIRED_CODE,
  OPERATION_EXPIRED_MESSAGE,
  OPERATION_IDENTITY_HEADER,
  OPERATION_NOT_CREATED_CODE,
  OPERATION_NOT_CREATED_MESSAGE,
  OPERATION_UNAUTHORIZED_CODE,
  OPERATION_UNAUTHORIZED_MESSAGE,
} from "./createRequestRoute.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_AUTHORITY_INVALID_CODE,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { OPERATION_AUTHORITY_HEADER } from "./requestOperationAuthority.js";
import { SUPPORTED_VENDORS } from "./supportedVendors.js";

/**
 * The verified requester every case in this file acts as (W3-I1).
 *
 * Deliberately a real signed credential in the real header, resolved by the
 * real gate against a stubbed Participant row — nothing between the request and
 * the principal is mocked. That is what lets the assertions below prove the
 * persisted requester comes from the gate rather than from the payload: the
 * fixtures still send `email`, and it still has to be ignored.
 */
const participantId = new mongoose.Types.ObjectId("64c0000000000000000000a1");
const participantPrincipal = "requester@nyu.edu";
const participantSecretText = "participant-create-route-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthority = signParticipantAuthority(
  participantId,
  1,
  participantSecret
);
let fencedPrincipal = participantPrincipal;

function stubVerifiedParticipant(email: string = participantPrincipal) {
  fencedPrincipal = email;
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({ _id: participantId, email }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
/** Frozen backend creation time; the route's `new Date()` resolves to this. */
const createdAt = new Date("2026-07-28T16:00:00.000Z");
/** Three hours after `createdAt` — the W3-R1 ASAP lifetime. */
const asapExpiresAt = new Date("2026-07-28T19:00:00.000Z");
/** The one timing value a scheduled canonical payload carries. */
const scheduledStart = new Date("2026-07-28T17:00:00.000Z");
/** Three hours after `scheduledStart`, derived by the backend. */
const scheduledExpiresAt = new Date("2026-07-28T20:00:00.000Z");

/**
 * W4-R4 canonical Meal Exchange payload: two swipes, one required structured
 * meal-detail entry each, and no Dining Dollar estimate (the optional case).
 * There is deliberately no `food` and no `pickupName` — the first is derived
 * by the backend from the structured fields, and the second no longer exists
 * in the V1 contract at all.
 */
function canonicalAsap(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "  Jasper Kane Cafe  ",
    email: "  REQUESTER@NYU.EDU  ",
    timing: "asap",
    menuPath: "meal-exchange",
    mealSwipes: 2,
    mealItems: [{ name: "  Vegetable rice bowl  " }, { name: "  Side salad  " }],
    ...overrides,
  };
}

function canonicalScheduled(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Jasper Kane Cafe",
    email: "requester@nyu.edu",
    timing: "scheduled",
    windowStart: "2026-07-28T17:00:00.000Z",
    menuPath: "meal-exchange",
    mealSwipes: 2,
    mealItems: [{ name: "Vegetable rice bowl" }, { name: "Side salad" }],
    ...overrides,
  };
}

/** Exactly `count` distinct structured meal-detail entries — one per selected
 * swipe, which is what W4-R4 Meal Exchange validation requires. */
function mealEntries(count: number): Array<{ name: string }> {
  return Array.from({ length: count }, (_, index) => ({ name: `Meal detail ${index + 1}` }));
}

/** The W4-R4 Dining-Dollars-only shape: zero swipes, one required structured
 * order-details value, and a required estimate in exact cents. */
function diningDollarsOnly(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Jasper Kane Cafe",
    email: "requester@nyu.edu",
    timing: "asap",
    menuPath: "dining-dollars",
    mealSwipes: 0,
    orderDetails: "Grain bowl with extra avocado",
    estimatedDiningDollarsCents: 1_850,
    ...overrides,
  };
}

function routeContext(
  body: unknown,
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
  }
) {
  const req = { body, headers } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function persistedDocument(input: Record<string, unknown>) {
  return {
    _id: requestId,
    ...input,
    status: "open",
    createdAt,
    updatedAt: createdAt,
    // Deliberately no `expiresAt` override: the persisted document echoes
    // whatever the route wrote, so the response assertions prove the canonical
    // backend expiration rather than a fixture constant.
    email: input.email,
    claimToken: "private-claim-token",
    orderNumber: "private-order-number",
    notificationStatus: "private-notification-state",
    __v: 0,
  };
}

let countDocuments: ReturnType<typeof vi.spyOn>;
let createDocument: Mock<
  (input: Record<string, unknown>) => Promise<Record<string, unknown>>
>;
let persistedCreate: ReturnType<typeof vi.spyOn>;
// The create may be recorded as a single object or, inside a transaction, as
// `[object], { session }`; assertions care about the persisted object.
function createdInput(call: unknown[]): Record<string, unknown> {
  const first = call[0];
  return (Array.isArray(first) ? first[0] : first) as Record<string, unknown>;
}
let consoleError: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  // Only `Date` is faked, so the route's single backend creation-time value is
  // deterministic without a clock abstraction and without stalling timers.
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(createdAt);

  process.env[PARTICIPANT_SIGNING_SECRET_ENV] = participantSecretText;
  stubVerifiedParticipant();
  vi.spyOn(mongoose, "startSession").mockResolvedValue({
    withTransaction: vi.fn(async (work: () => Promise<void>) => work()),
    endSession: vi.fn().mockResolvedValue(undefined),
  } as never);
  vi.spyOn(Participant, "findById").mockImplementation(((id: unknown) => {
    const query: any = {
      select: () => query,
      session: () => query,
      lean: () => query,
      exec: vi.fn().mockResolvedValue({
        _id: id,
        authorityVersion: 1,
        email: fencedPrincipal,
      }),
    };
    return query;
  }) as never);
  vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1, modifiedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);

  resendSend.mockReset();
  resendSend.mockResolvedValue({ data: { id: "email-id" }, error: null });
  notifySubscribersForRequest.mockReset();
  notifySubscribersForRequest.mockResolvedValue(undefined);

  countDocuments = vi
    .spyOn(MealRequest, "countDocuments")
    .mockResolvedValue(0 as never);
  createDocument = vi.fn<
    (input: Record<string, unknown>) => Promise<Record<string, unknown>>
  >(async (input: Record<string, unknown>) => persistedDocument(input));
  persistedCreate = vi.spyOn(MealRequest, "create").mockImplementation(
    (async (input: unknown) => {
      // The focused request contract assertions care about the persisted
      // payload, while the route uses both single-document and transactional
      // array forms. Normalize the test seam to one persisted document.
      if (Array.isArray(input)) {
        return [await createDocument(input[0] as Record<string, unknown>)] as unknown as Awaited<
          ReturnType<typeof MealRequest.create>
        >;
      }
      return (await createDocument(
        input as unknown as Record<string, unknown>
      )) as unknown as Awaited<ReturnType<typeof MealRequest.create>>;
    }) as never
  );
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  delete process.env[PARTICIPANT_SIGNING_SECRET_ENV];
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("POST /api/request validation and persistence", () => {
  it("keeps a committed create successful when review suppresses its direct confirmation send", async () => {
    vi.stubEnv("NODE_ENV", "review");
    try {
      const context = routeContext(canonicalAsap());
      await createRequest(context.req, context.res);
      expect(createDocument).toHaveBeenCalledOnce();
      expect(context.status).toHaveBeenCalledWith(201);
      expect(resendSend).not.toHaveBeenCalled();
      expect(consoleError).toHaveBeenCalledWith(
        expect.stringContaining("Request confirmation failed after persistence")
      );
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it("persists a valid canonical ASAP request with trimmed private input", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith({
      vendor: "Jasper Kane Cafe",
      // Derived by the backend from the structured entries below, never
      // supplied by the client (W4-R4). Each entry is trimmed exactly as
      // every other requester string on this route already is.
      food: "Vegetable rice bowl; Side salad",
      menuPath: "meal-exchange",
      mealSwipes: 2,
      mealItems: [{ name: "Vegetable rice bowl" }, { name: "Side salad" }],
      // Both written from the verified participant, never from the payload.
      email: participantPrincipal,
      requesterParticipantId: participantId.toString(),
      pickupWindowText: ASAP_WINDOW_TEXT,
      windowStart: undefined,
      windowEnd: undefined,
      status: "open",
      // W4-R5: a newly created request is editable and fenceable from the start.
      contentRevision: 1,
      notificationGeneration: 1,
      visibleFrom: createdAt,
      // Helper-visible at creation, so creation-time dispatch is the
      // initiation and the eligibility sweep never owns this request (W3-N3).
      helperNotification: "initiated",
      closingSoonNotification: "awaiting",
      expiresAt: asapExpiresAt,
      deleteAt: asapExpiresAt,
    });
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it.each([
    {
      windowStart: "2026-07-28T17:00:00.000Z",
    },
    {
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
  ])("rejects canonical ASAP window fields", async (window) => {
    const context = routeContext(canonicalAsap(window));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("persists a valid canonical scheduled request and generates New York display text", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({
        // The advertised window is the availability window: one start, and an
        // end the backend derived rather than one a client asserted.
        pickupWindowText: "Jul 28, 1:00 PM – 4:00 PM",
        windowStart: scheduledStart,
        windowEnd: scheduledExpiresAt,
        visibleFrom: scheduledStart,
        expiresAt: scheduledExpiresAt,
        deleteAt: scheduledExpiresAt,
      })
);
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("refuses a canonical scheduled payload that supplies its own windowEnd", async () => {
    // The requester chooses a start; the end is not theirs to state. `.strict()`
    // refuses it outright rather than accepting and quietly discarding it.
    const context = routeContext(
      canonicalScheduled({ windowEnd: "2026-07-28T18:00:00.000Z" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each(["vendor", "food", "pickupName"])(
    "rejects a missing or blank required %s",
    async (field) => {
      const context = routeContext(
        canonicalAsap({ [field]: field === "vendor" ? "   " : undefined })
      );

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "INVALID_REQUEST",
          message: "Invalid request payload",
        },
      });
      expect(createDocument).not.toHaveBeenCalled();
      expect(resendSend).not.toHaveBeenCalled();
      expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    }
  );

  it("keeps the generic payload message for a blank email", async () => {
    // A present-but-empty field is still a malformed payload, so it stays with
    // `vendor`, `food`, and `pickupName` rather than being answered about
    // identity. An *absent* one is no longer a failure at all — see below.
    const context = routeContext(canonicalAsap({ email: "   " }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("accepts a payload with no email at all", async () => {
    // Since W3-I1 the requester is the verified participant, so there is
    // nothing for this field to supply. Left optional rather than forbidden
    // because the legacy web shape has always required it.
    const body = canonicalAsap();
    delete (body as Record<string, unknown>).email;
    const context = routeContext(body);

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({ email: participantPrincipal })
);
  });

  it.each(["soon", "", 7, null])(
    "rejects invalid canonical timing value %j",
    async (timing) => {
      const context = routeContext(canonicalAsap({ timing }));

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(createDocument).not.toHaveBeenCalled();
    }
  );

  it("rejects a scheduled request with no start", async () => {
    // `windowStart` is now the whole timing input, so its absence leaves the
    // backend nothing to derive visibility or expiration from.
    const context = routeContext(canonicalScheduled({ windowStart: undefined }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    { windowStart: "not-a-timestamp" },
    { windowStart: "2026-07-28T17:00:00.000" },
    { windowStart: 1_780_000_000_000 },
  ])("rejects a scheduled start that is not an offset ISO timestamp", async (window) => {
    const context = routeContext(canonicalScheduled(window));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    ["id", "client-id"],
    ["_id", "64b000000000000000000002"],
    ["status", "placed"],
    ["createdAt", "2020-01-01T00:00:00.000Z"],
    ["updatedAt", "2020-01-01T00:00:00.000Z"],
    ["expiresAt", "2030-01-01T00:00:00.000Z"],
    ["claimToken", "client-claim"],
    ["orderNumber", "client-order"],
    ["pickupWindowText", "client display text"],
  ])("rejects canonical client-supplied field %s", async (field, value) => {
    const context = routeContext(canonicalAsap({ [field]: value }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("returns a canonical public wrapper with backend values and no private fields", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const body = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;
    expect(Object.keys(body)).toEqual(["request"]);
    expect(body.request).toEqual({
      id: requestId.toString(),
      vendor: "Jasper Kane Cafe",
      food: "Vegetable rice bowl; Side salad",
      pickupWindowText: "Jul 28, 1:00 PM – 4:00 PM",
      mealSwipes: 2,
      menuPath: "meal-exchange",
      mealItems: [{ name: "Vegetable rice bowl" }, { name: "Side salad" }],
      orderDetails: null,
      estimatedDiningDollarsCents: null,
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T20:00:00.000Z",
      status: "open",
      createdAt: "2026-07-28T16:00:00.000Z",
      expiresAt: "2026-07-28T20:00:00.000Z",
    });
    expect(body.request).not.toHaveProperty("email");
    expect(body.request).not.toHaveProperty("pickupName");
    expect(body.request).not.toHaveProperty("_id");
    expect(body.request).not.toHaveProperty("claimToken");
    expect(body.request).not.toHaveProperty("orderNumber");
    expect(body.request).not.toHaveProperty("notificationStatus");
    expect(body.request).not.toHaveProperty("deleteAt");
    expect(body.request).not.toHaveProperty("claimedAt");
    expect(body.request).not.toHaveProperty("claimExpiresAt");
    expect(body.request).not.toHaveProperty("claimExtendedAt");
    expect(body.request).not.toHaveProperty("claimTokenDigest");

    const persistedInput = createdInput(createDocument.mock.calls[0]) as Record<
      string,
      unknown
    >;
    expect(persistedInput).not.toHaveProperty("_id");
    expect(persistedInput.status).toBe("open");
    expect(persistedInput).not.toHaveProperty("createdAt");
    // `visibleFrom` and `expiresAt` are written by the backend, unlike the
    // fields above, which stay owned by Mongo/Mongoose. Neither is projected
    // onto the public body beyond the instants already listed there.
    expect(persistedInput.visibleFrom).toEqual(scheduledStart);
    expect(persistedInput.expiresAt).toEqual(scheduledExpiresAt);
    expect(persistedInput.deleteAt).toEqual(persistedInput.expiresAt);
  });
});

describe("POST /api/request meal-swipe quantity (W3-C1)", () => {
  it.each([1, 2, 3, 4, 5])(
    "accepts and persists an exact integer quantity of %d",
    async (mealSwipes) => {
      const context = routeContext(
        canonicalAsap({ mealSwipes, mealItems: mealEntries(mealSwipes) })
      );

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(201);
      expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({
          mealSwipes,
          mealItems: mealEntries(mealSwipes),
        })
);
      const body = context.json.mock.calls[0][0] as {
        request: Record<string, unknown>;
      };
      expect(body.request.mealSwipes).toBe(mealSwipes);
    }
  );

  it.each([
    undefined,
    0,
    -1,
    6,
    1.5,
    "2",
    null,
  ])("rejects an invalid quantity %j", async (mealSwipes) => {
    const context = routeContext(canonicalAsap({ mealSwipes }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("rejects a missing quantity on a canonical scheduled request", async () => {
    const body = canonicalScheduled();
    delete (body as Record<string, unknown>).mealSwipes;
    const context = routeContext(body);

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("accepts a canonical scheduled request with a bounded quantity", async () => {
    const context = routeContext(
      canonicalScheduled({ mealSwipes: 5, mealItems: mealEntries(5) })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({ mealSwipes: 5, mealItems: mealEntries(5) })
);
  });

  it("accepts and persists each exact integer quantity 1-5 on the legacy web shape", async () => {
    for (const mealSwipes of [1, 2, 3, 4, 5]) {
      countDocuments.mockResolvedValue(0 as never);
      const context = routeContext({
        vendor: "Jasper Kane Cafe",
        menuPath: "meal-exchange",
        mealItems: mealEntries(mealSwipes),
        email: "requester@nyu.edu",
        pickupWindowText: "client display text",
        mealSwipes,
      });

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(201);
      expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({ mealSwipes })
);
      const body = context.json.mock.calls[
        context.json.mock.calls.length - 1
      ][0] as { request: Record<string, unknown> };
      expect(body.request.mealSwipes).toBe(mealSwipes);
    }
  });

  it.each([
    undefined,
    0,
    -1,
    6,
    1.5,
    "2",
    null,
  ])("rejects an invalid quantity %j on the legacy web shape", async (mealSwipes) => {
    const context = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "client display text",
      mealSwipes,
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("rejects a legacy web submission omitting the quantity entirely", async () => {
    const context = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "client display text",
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("does not fabricate a default or fallback quantity on any accepted shape", async () => {
    for (const body of [
      canonicalAsap({ mealSwipes: undefined }),
      canonicalScheduled({ mealSwipes: undefined }),
      {
        vendor: "Jasper Kane Cafe",
        menuPath: "meal-exchange",
        mealItems: mealEntries(2),
        email: "requester@nyu.edu",
        pickupWindowText: "client display text",
      },
    ]) {
      const context = routeContext(body);
      await createRequest(context.req, context.res);
      expect(context.status).toHaveBeenCalledWith(400);
    }
    expect(createDocument).not.toHaveBeenCalled();
  });
});

describe("POST /api/request requester gate (W3-I1)", () => {
  function expectNoSideEffect() {
    // The gate runs ahead of shape validation, the daily-limit read, the
    // write, the requester confirmation email, and helper notification, so an
    // unverified attempt leaves nothing behind at all.
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  }

  it("refuses a caller with no participant credential", async () => {
    const context = routeContext(canonicalAsap(), {});

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({
          code: PARTICIPANT_VERIFICATION_REQUIRED_CODE,
        }),
      })
    );
    expectNoSideEffect();
  });

  it("refuses an allowed NYU address that has not verified", async () => {
    // The whole point of the slice: eligibility is not ownership. A perfectly
    // valid `@nyu.edu` address with no proof behind it creates nothing.
    const context = routeContext(
      canonicalAsap({ email: "unverified@nyu.edu" }),
      {}
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expectNoSideEffect();
  });

  it.each([
    ["a malformed credential", "not-a-credential"],
    ["a credential with no signature", `${participantId.toString()}.1`],
    [
      "a credential signed with another secret",
      signParticipantAuthority(
        participantId,
        1,
        Buffer.from("some-other-deployment-signing-secret-value")
      ),
    ],
    [
      "a credential naming a different participant",
      signParticipantAuthority(
        new mongoose.Types.ObjectId("64c0000000000000000000ff"),
        1,
        participantSecret
      ),
    ],
    [
      "a credential signed at a revoked version",
      signParticipantAuthority(participantId, 2, participantSecret),
    ],
  ])("refuses %s and creates nothing", async (_label, credential) => {
    // The stub answers only for `_id` + version 1, so the last two cases fail
    // the database check rather than the signature check — which is the point:
    // a well-formed signature is not authority on its own.
    const context = routeContext(canonicalAsap(), {
      [PARTICIPANT_AUTHORITY_HEADER]: credential,
    });
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
    } as unknown as ReturnType<typeof Participant.findOne>);

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({
          code: PARTICIPANT_AUTHORITY_INVALID_CODE,
        }),
      })
    );
    expectNoSideEffect();
  });

  it("applies to the legacy web shape, which is the browser's only create path", async () => {
    // The cross-client boundary: the gate is on the route, not on a client, so
    // the website's own payload shape — complete, well-formed, and carrying an
    // allowlisted address — creates nothing without a verified participant.
    const context = routeContext(
      {
        vendor: "Jasper Kane Cafe",
        menuPath: "meal-exchange",
        mealItems: mealEntries(2),
        email: participantPrincipal,
        pickupWindowText: "Legacy display",
      },
      {}
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({
          code: PARTICIPANT_VERIFICATION_REQUIRED_CODE,
          // A readable sentence, because the website renders `error.message`
          // from this envelope and has no verification screen of its own.
          message: expect.stringContaining("Verify your NYU email"),
        }),
      })
    );
    expectNoSideEffect();
  });

  it("refuses two credentials in one header rather than choosing one", async () => {
    const context = routeContext(canonicalAsap(), {
      [PARTICIPANT_AUTHORITY_HEADER]: [participantAuthority, participantAuthority],
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expectNoSideEffect();
  });

  it("answers 503 and creates nothing when the gate itself cannot decide", async () => {
    // A definitive no-write outcome, deliberately not a 401: refusing a caller
    // who may well be verified must not read as "you are not verified", and on
    // a non-idempotent POST it must not be an unreadable response either.
    delete process.env[PARTICIPANT_SIGNING_SECRET_ENV];
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expectNoSideEffect();
  });

  it("never echoes the presented credential into an error body or the log", async () => {
    const context = routeContext(canonicalAsap(), {
      [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
    });
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockRejectedValue(new Error("database unavailable")),
        }),
      }),
    } as unknown as ReturnType<typeof Participant.findOne>);

    await createRequest(context.req, context.res);

    expect(JSON.stringify(context.json.mock.calls)).not.toContain(
      participantAuthority
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      participantAuthority
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      participantSecretText
    );
  });
});

describe("POST /api/request requester identity comes from participant authority (W3-I1)", () => {
  /**
   * The NYU allowlist matrix itself is proved once in
   * `allowedEmailDomains.test.ts`, and the point at which it now gates a person
   * — participant verification — is proved in
   * `participantVerificationRoute.test.ts`. What is left to prove here is the
   * thing this route is responsible for: the requester it persists is the
   * verified principal, and a payload cannot name anyone else.
   */
  const MISMATCH_MESSAGE =
    "This action can only use the NYU email you verified.";

  function legacyWeb(email: string) {
    return {
      vendor: "Jasper Kane Cafe",
      email,
      pickupWindowText: "Legacy display",
      menuPath: "meal-exchange",
      mealSwipes: 2,
      mealItems: mealEntries(2),
    };
  }

  it.each([
    ["student@stern.nyu.edu"],
    ["requester+food@nyu.edu"],
  ])("persists %s because that is the verified principal", async (principal) => {
    stubVerifiedParticipant(principal);
    // The payload still carries the old fixture address. It is ignored — this
    // is a mismatch only if a client *claims* an address, and here it claims
    // the same one it verified.
    const context = routeContext(canonicalAsap({ email: principal }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({
        email: principal,
        requesterParticipantId: participantId.toString(),
      })
);
    // The principal is also what the daily abuse-control count and the
    // requester confirmation email use.
    expect(countDocuments).toHaveBeenCalledWith(
      expect.objectContaining({ email: principal })
    );
    expect(resendSend).toHaveBeenCalledWith(
      expect.objectContaining({ to: principal })
    );
  });

  it("persists the principal, not the payload, when a client omits the address entirely", async () => {
    const body = canonicalAsap();
    delete (body as Record<string, unknown>).email;
    const context = routeContext(body);

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({
        email: participantPrincipal,
        requesterParticipantId: participantId.toString(),
      })
);
  });

  it("accepts a payload address that differs only by case and whitespace", async () => {
    // Normalization is what decides sameness, so the exact-principal rule does
    // not turn a capitalized retype into someone else's identity.
    const context = routeContext(
      canonicalAsap({ email: "  REQUESTER@NYU.EDU  " })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({ email: participantPrincipal })
);
  });

  it.each([
    "not-an-email",
    "requester@",
    "@nyu.edu",
    "requester@@nyu.edu",
    "requester @nyu.edu",
    "requester@gmail.com",
    "requester@example.edu",
    "requester@law.nyu.edu",
    "requester@sps.nyu.edu",
    "requester@nyu.edu.fake",
    "requester@fake-nyu.edu",
    "requester@nyu.edu.example.com",
    "requester@notnyu.edu",
    "requester@nyu.education",
    // Allowlisted, and still refused: eligibility was never the question here.
    // Acting as another verified address is acting as another person.
    "someone-else@nyu.edu",
    "someone-else@stern.nyu.edu",
  ])("refuses the payload address %s with no side effect", async (email) => {
    const context = routeContext(canonicalAsap({ email }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "PARTICIPANT_PRINCIPAL_MISMATCH",
        message: MISMATCH_MESSAGE,
      },
    });
    // The refusal precedes every side effect: no daily-limit read, no
    // document, no requester email, no helper alert.
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("applies the same rule to the canonical scheduled and legacy web shapes", async () => {
    const scheduled = routeContext(
      canonicalScheduled({ email: "requester@gmail.com" })
    );
    await createRequest(scheduled.req, scheduled.res);

    const legacy = routeContext(legacyWeb("requester@law.nyu.edu"));
    await createRequest(legacy.req, legacy.res);

    for (const context of [scheduled, legacy]) {
      expect(context.status).toHaveBeenCalledWith(403);
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "PARTICIPANT_PRINCIPAL_MISMATCH",
          message: MISMATCH_MESSAGE,
        },
      });
    }
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();

    const matchingLegacy = routeContext(legacyWeb(participantPrincipal));
    await createRequest(matchingLegacy.req, matchingLegacy.res);

    expect(matchingLegacy.status).toHaveBeenCalledWith(201);
  });

  it.each([
    "requester@gmail.com",
    "requester@law.nyu.edu",
    "requester@evil-nyu.edu",
    "requester@nyu.edu.evil.test",
    "requester@stern.nyu.edu.evil.test",
  ])(
    "creates nothing for a stored principal that is not an allowed NYU address: %s",
    async (storedPrincipal) => {
      // The allowlist still gates every request; it now does so at the gate,
      // against the stored principal, on every use. Verification would never
      // have established one of these, but a persisted row that stops being
      // eligible — a domain removed from the allowlist, a value written by some
      // future path — must return the person to verification rather than post a
      // request on the strength of already existing.
      stubVerifiedParticipant(storedPrincipal);
      const context = routeContext(canonicalAsap({ email: storedPrincipal }));

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(401);
      expect(context.json).toHaveBeenCalledWith(
        expect.objectContaining({
          error: expect.objectContaining({
            code: PARTICIPANT_AUTHORITY_INVALID_CODE,
          }),
        })
      );
      expect(countDocuments).not.toHaveBeenCalled();
      expect(createDocument).not.toHaveBeenCalled();
      expect(resendSend).not.toHaveBeenCalled();
      expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    }
  );

  it("still reports another invalid field as a payload error", async () => {
    // Precedence is unchanged: shape validation still runs first, so a request
    // that is wrong in more than one way keeps the message it has always
    // returned rather than being answered about identity.
    for (const body of [
      canonicalAsap({ email: "requester@gmail.com", vendor: "   " }),
      canonicalAsap({ email: "requester@gmail.com", timing: "soon" }),
      canonicalAsap({ email: "requester@gmail.com", status: "placed" }),
      canonicalScheduled({
        email: "requester@gmail.com",
        windowStart: "2026-07-28T14:00:00.000Z",
        windowEnd: "2026-07-28T15:00:00.000Z",
      }),
    ]) {
      const context = routeContext(body);

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "INVALID_REQUEST",
          message: "Invalid request payload",
        },
      });
    }

    expect(createDocument).not.toHaveBeenCalled();
  });

  it("leaves the daily limit unchanged for the verified principal", async () => {
    countDocuments.mockResolvedValue(3);
    const limited = routeContext(canonicalAsap());
    await createRequest(limited.req, limited.res);

    expect(limited.status).toHaveBeenCalledWith(429);
    expect(limited.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });
});

describe("POST /api/request supported-vendor allowlist", () => {
  const UNSUPPORTED_VENDOR_MESSAGE =
    "Choose a supported CommonPlate dining location.";

  it.each(SUPPORTED_VENDORS.map((vendor) => [vendor.name]))(
    "accepts the supported vendor %s",
    async (name) => {
      const context = routeContext(canonicalAsap({ vendor: name }));

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(201);
      expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({ vendor: name })
);
    }
  );

  it.each([
    "Off-Campus Diner",
    "Crave Nyu",
    "PALLADIUM",
    "palladium",
    "Cafe181",
    "Palladium Hall",
    "Palladium",
    "",
  ])("refuses unsupported vendor %j with INVALID_VENDOR and no side effect", async (vendor) => {
    const context = routeContext(canonicalAsap({ vendor }));

    await createRequest(context.req, context.res);

    if (vendor.trim().length === 0) {
      // A blank vendor is a structural failure, not a catalog mismatch: it
      // keeps the generic payload error rather than a vendor-specific one.
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "INVALID_REQUEST",
          message: "Invalid request payload",
        },
      });
    } else {
      expect(context.json).toHaveBeenCalledWith({
        error: { code: "INVALID_VENDOR", message: UNSUPPORTED_VENDOR_MESSAGE },
      });
    }
    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("does not silently canonicalize a near-match variant", async () => {
    // "jasper kane cafe" and "Jasper Kane Cafe" are different strings; accepting one for
    // the other would be a case-fold the accepted contract explicitly rules
    // out, so the trimmed value must match a catalog entry exactly.
    const context = routeContext(canonicalAsap({ vendor: "jasper kane cafe" }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_VENDOR", message: UNSUPPORTED_VENDOR_MESSAGE },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("applies the same catalog to the canonical scheduled and legacy web shapes", async () => {
    const scheduled = routeContext(
      canonicalScheduled({ vendor: "Off-Campus Diner" })
    );
    await createRequest(scheduled.req, scheduled.res);

    const legacy = routeContext({
      vendor: "Off-Campus Diner",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
      mealSwipes: 2,
    });
    await createRequest(legacy.req, legacy.res);

    for (const context of [scheduled, legacy]) {
      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: { code: "INVALID_VENDOR", message: UNSUPPORTED_VENDOR_MESSAGE },
      });
    }
    expect(createDocument).not.toHaveBeenCalled();

    const allowedLegacy = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
      mealSwipes: 2,
    });
    await createRequest(allowedLegacy.req, allowedLegacy.res);

    expect(allowedLegacy.status).toHaveBeenCalledWith(201);
  });

  it("takes precedence over the email allowlist so it does not mask an unsupported vendor", async () => {
    // Both fields are wrong; the vendor check runs first, so this is the
    // envelope the requester sees rather than INVALID_EMAIL.
    const context = routeContext(
      canonicalAsap({ vendor: "Off-Campus Diner", email: "requester@gmail.com" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_VENDOR", message: UNSUPPORTED_VENDOR_MESSAGE },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("still reports an earlier structural error instead of INVALID_VENDOR", async () => {
    // Precedence is unchanged: an otherwise-malformed payload keeps the
    // generic message even when the vendor is also unsupported.
    const context = routeContext(
      canonicalAsap({ vendor: "Off-Campus Diner", timing: "soon" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("keeps iOS's Picker sourced from the shared catalog instead of a second hardcoded list", () => {
    // The catalog used to be a Swift literal duplicated by hand; this proves
    // it now reads from the same `shared/vendors.json` the backend reads
    // (via a symlink at Resources/SupportedVendors.json), so there is one
    // vendor source, not two that can drift apart.
    const viewSource = readFileSync(
      new URL(
        "../ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift",
        import.meta.url
      ),
      "utf8"
    );

    expect(viewSource).not.toContain("Crave NYU");
    expect(viewSource).toContain("SupportedVendorCatalog.diningSpots");
  });
});

describe("POST /api/request backend-owned visibility and expiration", () => {
  it("makes an ASAP request visible at creation and expires it three hours later", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const persistedInput = createdInput(createDocument.mock.calls[0]) as Record<
      string,
      unknown
    >;
    const persistedVisibility = persistedInput.visibleFrom as Date;
    const persistedExpiration = persistedInput.expiresAt as Date;

    expect(persistedVisibility).toEqual(createdAt);
    expect(persistedExpiration).toEqual(asapExpiresAt);
    expect(
      persistedExpiration.getTime() - persistedVisibility.getTime()
    ).toBe(3 * 60 * 60 * 1000);
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("makes a scheduled request visible at its start and expires it three hours after that", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const persistedInput = createdInput(createDocument.mock.calls[0]) as Record<
      string,
      unknown
    >;

    expect(persistedInput.visibleFrom).toEqual(scheduledStart);
    expect(persistedInput.expiresAt).toEqual(scheduledExpiresAt);
    expect(
      (persistedInput.expiresAt as Date).getTime() -
        (persistedInput.visibleFrom as Date).getTime()
    ).toBe(3 * 60 * 60 * 1000);
    // The advertised end and the availability end are one value, not two.
    expect(persistedInput.windowEnd).toEqual(persistedInput.expiresAt);
  });

  it("does not measure a scheduled request's lifetime from creation", async () => {
    // The distinction the whole Later timing rests on: creation decides
    // nothing about a scheduled request's window.
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const persistedInput = createdInput(createDocument.mock.calls[0]) as Record<
      string,
      unknown
    >;

    expect(persistedInput.visibleFrom).not.toEqual(createdAt);
    expect(persistedInput.expiresAt).not.toEqual(asapExpiresAt);
  });

  it("never leaves a created request on the schema's 24-hour fallback", async () => {
    const dayAfterCreation = new Date(
      createdAt.getTime() + 24 * 60 * 60 * 1000
    );

    for (const body of [canonicalAsap(), canonicalScheduled()]) {
      const context = routeContext(body);
      await createRequest(context.req, context.res);
    }

    for (const call of createDocument.mock.calls) {
      const persistedInput = createdInput(call);
      expect(persistedInput.expiresAt).toBeInstanceOf(Date);
      expect(
        (persistedInput.expiresAt as Date).getTime()
      ).toBeLessThan(dayAfterCreation.getTime());
    }
  });

  it("ignores a client-supplied expiration on both create shapes", async () => {
    const clientExpiration = "2030-01-01T00:00:00.000Z";

    const canonical = routeContext(
      canonicalAsap({ expiresAt: clientExpiration })
    );
    await createRequest(canonical.req, canonical.res);

    const legacy = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
      expiresAt: clientExpiration,
    });
    await createRequest(legacy.req, legacy.res);

    expect(canonical.status).toHaveBeenCalledWith(400);
    expect(legacy.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("returns the canonical expiration in the successful public response", async () => {
    const asap = routeContext(canonicalAsap());
    await createRequest(asap.req, asap.res);

    const scheduled = routeContext(canonicalScheduled());
    await createRequest(scheduled.req, scheduled.res);

    const asapBody = JSON.parse(
      JSON.stringify(asap.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;
    const scheduledBody = JSON.parse(
      JSON.stringify(scheduled.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;

    expect(asapBody.request.expiresAt).toBe("2026-07-28T19:00:00.000Z");
    expect(scheduledBody.request.expiresAt).toBe("2026-07-28T20:00:00.000Z");
    expect(scheduledBody.request.expiresAt).toBe(
      scheduledBody.request.windowEnd
    );
    // The response exposes absolute instants throughout; no wall-clock
    // rendering and no `visibleFrom` field of its own — `windowStart` already
    // carries that instant for a scheduled request.
    expect(scheduledBody.request.windowStart).toBe("2026-07-28T17:00:00.000Z");
    expect(scheduledBody.request).not.toHaveProperty("visibleFrom");
    expect(asapBody.request).not.toHaveProperty("visibleFrom");
  });

  it("accepts a start exactly at the backend's own now", async () => {
    // The accepted boundary. `createdAt` is this handler's `now`, and a request
    // starting at that instant is visible from that instant — the same
    // inclusive bound `isVisibleNow` applies.
    const context = routeContext(
      canonicalScheduled({ windowStart: createdAt.toISOString() })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    const persistedInput = createdInput(createDocument.mock.calls[0]) as Record<
      string,
      unknown
    >;
    expect(persistedInput.visibleFrom).toEqual(createdAt);
    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T19:00:00.000Z")
    );
  });

  it("rejects a start one millisecond before the backend's own now", async () => {
    const context = routeContext(
      canonicalScheduled({
        windowStart: new Date(createdAt.getTime() - 1).toISOString(),
      })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
  });

  it("rejects an elapsed start even while its three hours have time left", async () => {
    // The case the earlier expiration-only rule accepted: one minute past, so
    // 2h59m of lifetime remained. It would have been written visible
    // immediately while advertising a pickup time that had already gone by.
    const context = routeContext(
      canonicalScheduled({ windowStart: "2026-07-28T15:59:00.000Z" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
  });

  it("performs no creation, email, or notification side effect for an elapsed start", async () => {
    const context = routeContext(
      canonicalScheduled({ windowStart: "2026-07-28T13:00:00.000Z" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    // Refused in shape validation, ahead of the daily-limit read, so a rejected
    // create does not even consume a database round trip.
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("refuses an elapsed start outright rather than converting it to ASAP", async () => {
    // The requester chose Later. Silently posting an ASAP request they did not
    // ask for would be a different request under their name; the refusal hands
    // the choice back to them instead.
    const context = routeContext(
      canonicalScheduled({ windowStart: "2026-07-28T12:00:00.000Z" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.status).not.toHaveBeenCalledWith(201);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("accepts a fully future start and holds it back until then", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const persistedInput = createdInput(createDocument.mock.calls[0]) as Record<
      string,
      unknown
    >;
    const body = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;

    expect(context.status).toHaveBeenCalledWith(201);
    expect((persistedInput.visibleFrom as Date).getTime()).toBeGreaterThan(
      createdAt.getTime()
    );
    expect(persistedInput.expiresAt).toEqual(scheduledExpiresAt);
    expect(body.request.expiresAt).toBe("2026-07-28T20:00:00.000Z");
  });

  it("applies the same start rule to the legacy compatibility path", async () => {
    function legacy(windowStart: string, windowEnd: string) {
      return {
        vendor: "Jasper Kane Cafe",
        menuPath: "meal-exchange",
        mealItems: mealEntries(2),
        email: "requester@nyu.edu",
        pickupWindowText: "Legacy display",
        windowStart,
        windowEnd,
        mealSwipes: 2,
      };
    }

    // The legacy end is still shape-validated but no longer decides anything,
    // so each of these is judged on its start alone: anything before the
    // backend `now` is refused, however much of the client's own window it
    // claims is left.
    const longElapsed = routeContext(
      legacy("2026-07-28T12:00:00.000Z", "2026-07-28T15:00:00.000Z")
    );
    await createRequest(longElapsed.req, longElapsed.res);

    const justElapsed = routeContext(
      legacy("2026-07-28T15:59:00.000Z", "2026-07-28T16:30:00.000Z")
    );
    await createRequest(justElapsed.req, justElapsed.res);

    expect(longElapsed.status).toHaveBeenCalledWith(400);
    expect(justElapsed.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();

    const stillAhead = routeContext(
      legacy("2026-07-28T16:30:00.000Z", "2026-07-28T17:00:00.000Z")
    );
    await createRequest(stillAhead.req, stillAhead.res);

    expect(stillAhead.status).toHaveBeenCalledWith(201);
    const persistedInput = createdInput(createDocument.mock.calls[0]) as Record<
      string,
      unknown
    >;
    // Three hours from the start, not the client's 17:00 end.
    expect(persistedInput.visibleFrom).toEqual(
      new Date("2026-07-28T16:30:00.000Z")
    );
    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T19:30:00.000Z")
    );
    expect(persistedInput.windowEnd).toEqual(persistedInput.expiresAt);
  });

  it("creates nothing and expires nothing for an invalid request", async () => {
    const context = routeContext(canonicalScheduled({ windowStart: undefined }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });
});

describe("POST /api/request eligibility-time notification ownership (W3-N3)", () => {
  /**
   * Which path owns starting this request's helper notification is decided
   * once, at creation, from the same visibility rule every other path applies.
   * The sweep in `src/eligibilityNotificationSweep.ts` owns what creation-time
   * dispatch cannot: a request that is not helper-eligible yet.
   */
  function persistedState(): unknown {
    const persistedInput = createdInput(createDocument.mock.calls[0]) as Record<
      string,
      unknown
    >;
    return persistedInput.helperNotification;
  }

  it("records an ASAP request as already initiated at creation", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    // Creation-time dispatch is this request's initiation, exactly as before.
    // Recording that is what keeps the sweep from ever selecting it and
    // producing a second notification for an ASAP request.
    expect(persistedState()).toBe("initiated");
  });

  it("hands a future Later request to eligibility-time initiation", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    expect(persistedState()).toBe("awaiting-eligibility");
  });

  it("keeps a Later start exactly at the backend's now on the creation-time path", async () => {
    // The same inclusive bound as `isVisibleNow` and `isAcceptableScheduledStart`:
    // a request visible at this instant is dispatched for at this instant, and
    // must not also be handed to the sweep.
    const context = routeContext(
      canonicalScheduled({ windowStart: createdAt.toISOString() })
    );

    await createRequest(context.req, context.res);

    expect(persistedState()).toBe("initiated");
  });

  it("applies the same ownership rule to the legacy web scheduled shape", async () => {
    const context = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "ignored legacy display text",
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T18:00:00.000Z",
      mealSwipes: 2,
    });

    await createRequest(context.req, context.res);

    expect(persistedState()).toBe("awaiting-eligibility");
  });

  it("still starts both creation-time dispatches for a future Later request", async () => {
    // Withholding is the dispatchers' shared availability re-check, not the
    // route quietly skipping them. Changing that would make the create path
    // and the sweep path two different behaviors instead of one.
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
  });

  it("refuses a client that tries to name its own notification state", async () => {
    for (const body of [
      canonicalAsap({ helperNotification: "initiated" }),
      canonicalScheduled({ helperNotification: "initiated" }),
    ]) {
      const context = routeContext(body);

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(createDocument).not.toHaveBeenCalled();
    }
  });

  it("keeps the notification state out of the public response", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const body = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;

    expect(body.request).not.toHaveProperty("helperNotification");
  });
});

describe("POST /api/request narrow legacy web compatibility", () => {
  it("infers ASAP only when both window fields are absent and ignores legacy display text", async () => {
    const context = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "Client-owned text must be ignored",
      mealSwipes: 2,
    });

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({
        pickupWindowText: ASAP_WINDOW_TEXT,
        windowStart: undefined,
        windowEnd: undefined,
      })
);
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("infers scheduled only from two valid legacy timestamps and generates canonical text", async () => {
    const context = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "Wrong client display text",
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T18:00:00.000Z",
      mealSwipes: 2,
    });

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({
        // Both the text and the persisted end come from the backend's own
        // three-hour window, not from the client's second timestamp.
        pickupWindowText: "Jul 28, 1:00 PM – 4:00 PM",
        windowStart: scheduledStart,
        windowEnd: scheduledExpiresAt,
        visibleFrom: scheduledStart,
        expiresAt: scheduledExpiresAt,
      })
);
  });

  it.each([
    {
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: undefined,
    },
    {
      windowStart: undefined,
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "invalid",
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "2026-07-28T18:00:00.000Z",
      windowEnd: "2026-07-28T17:00:00.000Z",
    },
  ])("rejects an invalid legacy window pair", async (window) => {
    const context = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
      ...window,
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("requires pickupWindowText when timing is absent and rejects extra fields", async () => {
    const missingCompatibilityMarker = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
    });
    await createRequest(
      missingCompatibilityMarker.req,
      missingCompatibilityMarker.res
    );

    const broadenedLegacyPayload = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
      status: "requested",
    });
    await createRequest(broadenedLegacyPayload.req, broadenedLegacyPayload.res);

    expect(missingCompatibilityMarker.status).toHaveBeenCalledWith(400);
    expect(broadenedLegacyPayload.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });
});

describe("POST /api/request side-effect ordering and errors", () => {
  it("persists and shapes before requester email; helper notification starts after the response", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument.mock.invocationCallOrder[0]).toBeLessThan(
      resendSend.mock.invocationCallOrder[0]
    );
    // Requester email is still awaited before the response; helper email
    // fan-out is started only after the response is sent (Slice 7C).
    expect(resendSend.mock.invocationCallOrder[0]).toBeLessThan(
      context.json.mock.invocationCallOrder[0]
    );
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      notifySubscribersForRequest.mock.invocationCallOrder[0]
    );
    expect(context.status).toHaveBeenCalledWith(201);
    expect(countDocuments).toHaveBeenCalledOnce();
    expect(createDocument).toHaveBeenCalledOnce();
  });

  it("describes later requester email as an attempt in both email bodies", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const submission = resendSend.mock.calls[0][0] as {
      html: string;
      text: string;
    };
    for (const body of [submission.html, submission.text]) {
      expect(body).toContain("will attempt to email you the order details");
      expect(body).toContain(
        "Request creation does not guarantee that later email will be delivered"
      );
      expect(body).not.toContain("We'll notify you");
    }
  });

  it("keeps the persisted success when Resend returns { data, error } failure", async () => {
    resendSend.mockResolvedValue({
      data: null,
      error: { name: "validation_error", message: "recipient rejected" },
    });
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledOnce();
    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({ request: expect.any(Object) })
    );
    expect(consoleError).toHaveBeenCalledWith(
      `[email] Request confirmation failed after persistence for request ${requestId}`
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      "requester@nyu.edu"
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      "Requester Private Name"
    );
  });

  it("keeps the persisted success when requester email throws", async () => {
    resendSend.mockRejectedValue(new Error("network failure"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledOnce();
    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("keeps the persisted success when helper notification throws", async () => {
    notifySubscribersForRequest.mockRejectedValue(
      new Error("subscriber delivery failed")
    );
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);
    // Helper email is detached (Slice 7C): the rejection settles on a
    // microtask after the response has already gone out.
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(createDocument).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
    expect(consoleError).toHaveBeenCalledWith(
      `[notify] Helper email dispatch failed for request ${requestId}`,
      expect.any(Error)
    );
  });

  it("returns REQUEST_CREATION_FAILED only when persistence fails", async () => {
    createDocument.mockRejectedValue(new Error("database unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_CREATION_FAILED",
        message: "Unable to create request",
      },
    });
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("returns REQUEST_LIMIT_REACHED when the best-effort daily abuse-control count is at the limit", async () => {
    countDocuments.mockResolvedValue(3);
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("fails closed when the daily abuse-control count cannot be read", async () => {
    countDocuments.mockRejectedValue(new Error("count unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_CREATION_FAILED",
        message: "Unable to create request",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("creates no record and triggers no side effect for an invalid request", async () => {
    const context = routeContext(canonicalScheduled({ windowEnd: undefined }));

    await createRequest(context.req, context.res);

    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });
});

describe("POST /api/request daily quota uses the NYU campus calendar day", () => {
  /**
   * W3-R1 correction: the quota's start-of-day boundary is the NYU campus
   * calendar day (`America/New_York`), not the Node process's local
   * timezone. These cases pin the exact `createdAt.$gte` the route computes
   * from a fixed backend `now`, so a regression to host-local midnight would
   * fail them regardless of where the test runner's own TZ is set.
   */
  it("counts from NYU midnight, not UTC midnight, for a request made after NYU midnight but before UTC midnight", async () => {
    // 2026-07-28T02:30:00Z is 2026-07-27, 10:30 PM EDT: already the next NYU
    // day relative to UTC's still-current 2026-07-27 calendar date.
    vi.setSystemTime(new Date("2026-07-28T02:30:00.000Z"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(countDocuments).toHaveBeenCalledWith(
      expect.objectContaining({
        createdAt: { $gte: new Date("2026-07-27T04:00:00.000Z") },
      })
    );
  });

  it("rolls the quota window over at NYU midnight, not at the host process's local midnight", async () => {
    // 2026-07-28T04:00:00Z is exactly 00:00:00 EDT: the first instant of the
    // new NYU campus day.
    vi.setSystemTime(new Date("2026-07-28T04:00:00.000Z"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(countDocuments).toHaveBeenCalledWith(
      expect.objectContaining({
        createdAt: { $gte: new Date("2026-07-28T04:00:00.000Z") },
      })
    );
  });

  it("computes the correct boundary across the DST fall-back transition", async () => {
    // Clocks fall back at 2 AM ET on 2026-11-01, so NYU midnight that day is
    // still EDT (UTC-4) while the following NYU midnight is EST (UTC-5).
    vi.setSystemTime(new Date("2026-11-01T20:00:00.000Z"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(countDocuments).toHaveBeenCalledWith(
      expect.objectContaining({
        createdAt: { $gte: new Date("2026-11-01T04:00:00.000Z") },
      })
    );
  });

  it("still blocks the fourth request of the NYU day with the unchanged 429 envelope", async () => {
    vi.setSystemTime(new Date("2026-07-28T04:00:00.000Z"));
    countDocuments.mockResolvedValue(3 as never);
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("still fails closed with the unchanged 500 envelope when the NYU-day count cannot be read", async () => {
    vi.setSystemTime(new Date("2026-07-28T04:00:00.000Z"));
    countDocuments.mockRejectedValue(new Error("count unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_CREATION_FAILED",
        message: "Unable to create request",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });
});

describe("POST /api/request helper push isolation", () => {
  /**
   * Push dispatch is started after the `201` is sent and is never awaited, so
   * the route cannot observe a dispatch outcome and these cases do not try to.
   * They prove the response is unaffected, that dispatch was started, and that
   * no push failure can reach the requester — dispatch behavior itself is
   * tested directly against `dispatchHelperNewRequestPush`.
   *
   * The real `startHelperNewRequestPush` runs here rather than a mock: its
   * totality is precisely what keeps an escaping throw out of `createRequest`'s
   * outer `catch`, which would otherwise attempt a second response on a
   * request whose headers are already flushed.
   */
  let pausedBefore: string | undefined;
  let requestExists: ReturnType<typeof vi.spyOn>;
  let installationFind: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    // The create route is guarded by `pausePublicAction` middleware in
    // `app.ts`; the dispatcher carries its own guard, and it must be off for
    // these cases to reach dispatch at all.
    pausedBefore = process.env[PUBLIC_ACTIONS_PAUSED_ENV];
    process.env[PUBLIC_ACTIONS_PAUSED_ENV] = "false";
    // W4-R5: the dispatcher's availability and notification-generation guard
    // reads the current document (`readCurrentForDispatch`).
    requestExists = vi
      .spyOn(MealRequest, "findOne")
      .mockResolvedValue(null as never) as ReturnType<typeof vi.spyOn>;
    // Nothing may reach a real APNs submission from a route test.
    installationFind = vi
      .spyOn(Installation, "find")
      .mockReturnValue({
        select: () => ({ lean: () => ({ exec: async () => [] }) }),
      } as never) as ReturnType<typeof vi.spyOn>;
    vi.spyOn(console, "log").mockImplementation(() => {});
  });

  afterEach(() => {
    if (pausedBefore === undefined) {
      delete process.env[PUBLIC_ACTIONS_PAUSED_ENV];
    } else {
      process.env[PUBLIC_ACTIONS_PAUSED_ENV] = pausedBefore;
    }
  });

  it("starts helper push after the response, with the persisted document", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(requestExists).toHaveBeenCalledWith(
      expect.objectContaining({
        $and: expect.arrayContaining([{ _id: requestId }]),
      }),
      "+notificationGeneration +contentRevision +requesterParticipantId",
      { lean: true }
    );
    // The response was built and sent before dispatch was started.
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      requestExists.mock.invocationCallOrder[0]
    );
  });

  it("returns 201 without waiting on a dispatch that never settles", async () => {
    vi.useRealTimers();
    requestExists.mockReturnValue(new Promise(() => {}) as never);
    const context = routeContext(canonicalAsap());

    const started = Date.now();
    await createRequest(context.req, context.res);

    // The outstanding dispatch is still in flight; creation did not depend on
    // it, so the response is already sent.
    expect(context.status).toHaveBeenCalledWith(201);
    expect(context.json).toHaveBeenCalledOnce();
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  it("returns 201 and answers once when the dispatcher's promise rejects", async () => {
    vi.useRealTimers();
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);
    requestExists.mockRejectedValue(new Error("push selection failed") as never);
    const context = routeContext(canonicalAsap());

    try {
      await createRequest(context.req, context.res);
      await new Promise((resolve) => setTimeout(resolve, 20));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    expect(context.status).toHaveBeenCalledExactlyOnceWith(201);
    expect(context.json).toHaveBeenCalledOnce();
    // A rejecting dispatch must not reach the outer catch and attempt a
    // second response after the headers are flushed.
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(rejections).toEqual([]);
  });

  it("returns 201 when the start call itself throws synchronously", async () => {
    // A persisted document that stops being able to describe itself once the
    // response is out: every read the route needs succeeds, and only the start
    // call fails. Without a total start function this throw would land in the
    // outer `catch` and answer `500` on an already-sent response.
    const context = routeContext(canonicalAsap());
    createDocument.mockImplementation(async () => ({
      ...persistedDocument(canonicalAsap()),
      get _id() {
        if (context.json.mock.calls.length > 0) {
          throw new Error("identity unavailable");
        }
        return requestId;
      },
    }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledExactlyOnceWith(201);
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledOnce();
  });

  it("starts push even when the helper email path throws", async () => {
    // Email and push are independent channels; neither suppresses the other.
    notifySubscribersForRequest.mockRejectedValue(new Error("alert failed"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(requestExists).toHaveBeenCalled();
  });

  it("starts helper email fan-out after the response, detached (Slice 7C)", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(resendSend).toHaveBeenCalledOnce();
    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
    // Requester email is still awaited before the response.
    expect(resendSend.mock.invocationCallOrder[0]).toBeLessThan(
      context.json.mock.invocationCallOrder[0]
    );
    // Helper email fan-out starts only after the response is sent.
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      notifySubscribersForRequest.mock.invocationCallOrder[0]
    );
  });

  it.each([
    ["a refused payload", () => canonicalAsap({ vendor: "   " }), 400],
    [
      "a payload naming another address",
      () => canonicalAsap({ email: "someone-else@nyu.edu" }),
      403,
    ],
  ])("starts no push for %s", async (_label, body, status) => {
    const context = routeContext(body());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(status);
    expect(requestExists).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
  });

  it("starts no push for an unverified caller", async () => {
    const context = routeContext(canonicalAsap(), {});

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(requestExists).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
  });

  it("starts no push when creation fails", async () => {
    createDocument.mockRejectedValue(new Error("database unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(requestExists).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
  });

  it("starts no push when the daily limit refuses the request", async () => {
    countDocuments.mockResolvedValue(3);
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(requestExists).not.toHaveBeenCalled();
  });
});

describe("POST /api/request installation association (Slice 6E)", () => {
  /**
   * iOS sends its existing installation credential with request creation so
   * the backend can resolve/establish the originating installation for a
   * later best-effort fulfillment push. These cases prove the association is
   * resolved from the credential's digest (never the raw value), persisted
   * internally, never exposed publicly, and never allowed to block request
   * creation.
   */
  const validInstallationCredential = Buffer.alloc(32, 9).toString("base64url");
  const resolvedInstallationId = new mongoose.Types.ObjectId(
    "64e000000000000000000001"
  );

  let installationFindOneAndUpdate: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    installationFindOneAndUpdate = vi
      .spyOn(Installation, "findOneAndUpdate")
      .mockReturnValue({
        select: () => ({
          lean: () => ({
            exec: async () => ({ _id: resolvedInstallationId }),
          }),
        }),
      } as never) as ReturnType<typeof vi.spyOn>;
  });

  it("resolves the association and persists installationId when a valid credential is supplied", async () => {
    const context = routeContext(
      canonicalAsap({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(installationFindOneAndUpdate).toHaveBeenCalledOnce();
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({ installationId: resolvedInstallationId })
);
  });

  it("digests the raw credential and never persists or logs it", async () => {
    const context = routeContext(
      canonicalAsap({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    const filter = installationFindOneAndUpdate.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    expect(filter).not.toHaveProperty("installationCredential");
    expect(JSON.stringify(filter)).not.toContain(validInstallationCredential);
    expect(
      JSON.stringify(createdInput(createDocument.mock.calls[0]))
    ).not.toContain(validInstallationCredential);
  });

  it("resolves no association, and persists no installationId, when no credential is supplied", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(installationFindOneAndUpdate).not.toHaveBeenCalled();
    expect(createDocument).toHaveBeenCalledWith(
expect.not.objectContaining({ installationId: expect.anything() })
);
  });

  it.each([
    ["too short", "a".repeat(20)],
    ["too long", "a".repeat(60)],
    ["invalid characters", "!".repeat(43)],
    ["empty", ""],
    ["not a string", 12345],
  ])("rejects a malformed installationCredential (%s) as a structural failure", async (_name, value) => {
    const context = routeContext(
      canonicalAsap({ installationCredential: value })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_REQUEST", message: "Invalid request payload" },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(installationFindOneAndUpdate).not.toHaveBeenCalled();
  });

  it("accepts a scheduled canonical request with an installation credential too", async () => {
    const context = routeContext(
      canonicalScheduled({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({ installationId: resolvedInstallationId })
);
  });

  it("never exposes the association through the public create response", async () => {
    const context = routeContext(
      canonicalAsap({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    const body = JSON.parse(JSON.stringify(context.json.mock.calls[0][0]));
    expect(JSON.stringify(body)).not.toMatch(
      /installationId|installationCredential/i
    );
  });

  it("still creates the request when resolving the association fails, with no installationId", async () => {
    installationFindOneAndUpdate.mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: async () => {
            throw new Error("database unavailable");
          },
        }),
      }),
    } as never);
    const context = routeContext(
      canonicalAsap({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.not.objectContaining({ installationId: expect.anything() })
);
    expect(consoleError).toHaveBeenCalledWith(
      "[route] Could not resolve the request-installation association"
    );
  });

  it("legacy web requests remain valid without an installation credential", async () => {
    const context = routeContext({
      vendor: "Jasper Kane Cafe",
      menuPath: "meal-exchange",
      mealItems: mealEntries(2),
      email: "requester@nyu.edu",
      pickupWindowText: "ASAP",
      mealSwipes: 2,
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(installationFindOneAndUpdate).not.toHaveBeenCalled();
  });
});

describe("POST /api/request helper email isolation (Slice 7C)", () => {
  /**
   * Mirrors the push isolation suite above. Helper-email fan-out is started
   * after the `201` is sent and is never awaited, so these cases prove the
   * response is unaffected and that dispatch was started — not what the
   * dispatch itself does, which `notifySubscribers.test.ts` already covers.
   * `startNotifySubscribersForRequest` runs for real here (only the
   * `notifySubscribersForRequest` it wraps is mocked), because its totality is
   * exactly what keeps an escaping throw or rejection out of `createRequest`'s
   * outer `catch`.
   */
  it("starts helper email after the response, with the persisted document", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(notifySubscribersForRequest).toHaveBeenCalledWith(
      expect.objectContaining({ _id: requestId })
    );
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      notifySubscribersForRequest.mock.invocationCallOrder[0]
    );
  });

  it("returns 201 without waiting on a helper-email dispatch that never settles", async () => {
    vi.useRealTimers();
    notifySubscribersForRequest.mockReturnValue(new Promise(() => {}));
    const context = routeContext(canonicalAsap());

    const started = Date.now();
    await createRequest(context.req, context.res);

    // The outstanding dispatch is still in flight; creation did not depend on
    // it, so the response is already sent.
    expect(context.status).toHaveBeenCalledWith(201);
    expect(context.json).toHaveBeenCalledOnce();
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  it("returns 201 and answers once when the helper-email dispatch's promise rejects", async () => {
    vi.useRealTimers();
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);
    notifySubscribersForRequest.mockRejectedValue(
      new Error("subscriber delivery failed")
    );
    const context = routeContext(canonicalAsap());

    try {
      await createRequest(context.req, context.res);
      await new Promise((resolve) => setTimeout(resolve, 20));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    expect(context.status).toHaveBeenCalledExactlyOnceWith(201);
    expect(context.json).toHaveBeenCalledOnce();
    // A rejecting dispatch must not reach the outer catch and attempt a
    // second response after the headers are flushed.
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(rejections).toEqual([]);
  });

  it("returns 201 when starting helper-email dispatch itself throws synchronously", async () => {
    // Without a total start function this throw would land in the outer
    // `catch` and answer `500` on an already-sent response.
    notifySubscribersForRequest.mockImplementation(() => {
      throw new Error("dispatch setup failed");
    });
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledExactlyOnceWith(201);
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledOnce();
  });

});

describe("ASAP window text carries no duration to go stale", () => {
  /**
   * `REQUEST_VISIBLE_DURATION_MS` is three hours, and the iOS requester is
   * told this once, at the timing choice, before submission. Under the
   * revised W3-R1 presentation contract `ASAP_WINDOW_TEXT` no longer restates
   * that duration on every downstream surface that renders a request, so
   * there is no prose duration left to drift out of sync — which is exactly
   * what the earlier "within the next hour" and "within the next 5 hours"
   * phrasings did.
   */
  const PRODUCTION_SOURCES = [
    "src",
    "public",
    "ios/CommonPlateios/CommonPlateios",
  ];

  function productionFiles(directory: string): string[] {
    const root = new URL(`../${directory}/`, import.meta.url);
    return readdirSync(root, { recursive: true, encoding: "utf8" })
      .filter((entry) => /\.(ts|js|html|swift)$/.test(entry))
      // Tests and sourcemaps are not surfaces anyone reads a request on.
      .filter((entry) => !entry.includes(".test."))
      .map((entry) => `${directory}/${entry}`);
  }

  it.each(["within the next hour", "within the next 5 hours"])(
    "leaves no production occurrence of the superseded %s phrasing",
    (phrase) => {
      const offenders = PRODUCTION_SOURCES.flatMap(productionFiles).filter(
        (file) =>
          readFileSync(new URL(`../${file}`, import.meta.url), "utf8").includes(
            phrase
          )
      );

      expect(offenders).toEqual([]);
    }
  );

  it("persists the shared ASAP label and the real three-hour deadline separately", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const persisted = createdInput(createDocument.mock.calls[0]) as Record<string, unknown>;
    expect(persisted.pickupWindowText).toBe(ASAP_WINDOW_TEXT);
    expect(ASAP_WINDOW_TEXT).not.toMatch(/\d+\s+hours?/i);
    // The duration truth lives in the instants, not in prose.
    expect(persisted.expiresAt).toEqual(asapExpiresAt);
    expect(persisted.deleteAt).toEqual(asapExpiresAt);
    expect(
      (asapExpiresAt.getTime() - createdAt.getTime()) / (60 * 60 * 1000)
    ).toBe(3);
  });

  it("names no other duration on any production request surface", () => {
    // The requester-facing sentences and the helper-facing window text are
    // separate strings in separate languages; this is the guard that keeps
    // them describing one contract.
    const offenders = PRODUCTION_SOURCES.flatMap(productionFiles).filter(
      (file) => {
        const source = readFileSync(
          new URL(`../${file}`, import.meta.url),
          "utf8"
        );
        return /expire[sd]?\s+in\s+(?!3\s+hours)\d+\s+hours?/i.test(source);
      }
    );

    expect(offenders).toEqual([]);
  });
});

describe("POST /api/request rate limiting is a definitive pre-write refusal", () => {
  /**
   * Exercised over real HTTP because the limiter is middleware, not part of the
   * handler. What matters is the *shape* of the sixth response: iOS classifies
   * an undecodable failure on this non-idempotent POST as ambiguous, which
   * locks request creation for the rest of the process. A throttled attempt
   * never reaches validation or the write, so it must decode as a definitive
   * `RATE_LIMITED` envelope instead.
   */
  it("allows five creations, then refuses the sixth with the envelope and no write", async () => {
    vi.useRealTimers();

    const testApp = express();
    testApp.use(express.json());
    testApp.post("/api/request", createRequestRateLimiter, createRequest);
    const server = createServer(testApp);
    await new Promise<void>((resolve) =>
      server.listen(0, "127.0.0.1", resolve)
    );

    try {
      const { port } = server.address() as AddressInfo;
      const post = () =>
        fetch(`http://127.0.0.1:${port}/api/request`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
          },
          body: JSON.stringify(canonicalAsap()),
        });

      for (let attempt = 1; attempt <= 5; attempt += 1) {
        const allowed = await post();
        expect(allowed.status).toBe(201);
      }
      expect(createDocument).toHaveBeenCalledTimes(5);

      const refused = await post();

      expect(refused.status).toBe(429);
      await expect(refused.json()).resolves.toEqual({
        error: {
          code: "RATE_LIMITED",
          message: "Too many attempts. Please wait a moment and try again.",
          fields: null,
        },
      });
      // The refusal happened ahead of the handler entirely: no daily-limit
      // read, no document, no requester email, no subscriber notification.
      expect(createDocument).toHaveBeenCalledTimes(5);
      expect(countDocuments).toHaveBeenCalledTimes(5);
      expect(resendSend).toHaveBeenCalledTimes(5);
      expect(notifySubscribersForRequest).toHaveBeenCalledTimes(5);
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      );
    }
  });
});

describe("POST /api/request durable create-operation identity (W3-D1)", () => {
  const otherParticipantId = new mongoose.Types.ObjectId(
    "64c0000000000000000000b2"
  );

  function headersWithOperation(
    operationId: string | string[],
    overrides: Record<string, string | string[]> = {}
  ) {
    return {
      [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
      ...overrides,
    };
  }

  /**
   * `createRequestWithOperation` opens a real `mongoose.startSession()` and
   * runs the Request-plus-ledger insert inside `session.withTransaction`
   * (W3-D1). The default double just runs the work once, the same pattern
   * `claimRoute.test.ts` and `fulfillmentRoute.test.ts` already establish, so
   * a test that only cares about the resulting Request/ledger writes does not
   * also have to stand up its own session.
   */
  let sessionMock: {
    withTransaction: ReturnType<typeof vi.fn>;
    endSession: ReturnType<typeof vi.fn>;
  };

  function mockSession() {
    sessionMock = {
      withTransaction: vi.fn(async (work: () => Promise<void>) => {
        await work();
      }),
      endSession: vi.fn().mockResolvedValue(undefined),
    };
    vi.spyOn(mongoose, "startSession").mockResolvedValue(
      sessionMock as never
    );
    return sessionMock;
  }

  /** Stubs `RequestOperation.findOne(...).select(...).lean().exec()` for one
   * or more successive lookups, in call order, matching how
   * `reconcileOperation` reads the durable ledger. */
  function stubLedgerLookups(
    ...results: Array<Record<string, unknown> | null>
  ) {
    const spy = vi.spyOn(RequestOperation, "findOne");
    for (const result of results) {
      spy.mockReturnValueOnce({
        select: () => ({
          lean: () => ({ exec: vi.fn().mockResolvedValue(result) }),
        }),
      } as unknown as ReturnType<typeof RequestOperation.findOne>);
    }
    return spy;
  }

  /** Stubs `MealRequest.findOne(...).select(...)` for one or more successive
   * lookups, matching the ledger-to-Request follow-up `reconcileOperation`
   * performs once a ledger row is found. */
  function stubRequestLookups(
    ...results: Array<Record<string, unknown> | null>
  ) {
    const spy = vi.spyOn(MealRequest, "findOne");
    for (const result of results) {
      spy.mockReturnValueOnce({
        select: vi.fn().mockResolvedValue(result),
      } as unknown as ReturnType<typeof MealRequest.findOne>);
    }
    return spy;
  }

  function ledgerRow(overrides: Record<string, unknown> = {}) {
    return {
      operationId: "op-generic",
      participantId,
      requestId,
      ...overrides,
    };
  }

  function existingOperationDocument(
    overrides: Record<string, unknown> = {}
  ) {
    return {
      _id: requestId,
      vendor: "Jasper Kane Cafe",
      food: "Vegetable rice bowl",
      pickupWindowText: ASAP_WINDOW_TEXT,
      mealSwipes: 2,
      windowStart: undefined,
      windowEnd: undefined,
      status: "open",
      createdAt,
      visibleFrom: createdAt,
      expiresAt: asapExpiresAt,
      requesterParticipantId: participantId,
      ...overrides,
    };
  }

  let createLedgerEntry: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    mockSession();
    createLedgerEntry = vi
      .spyOn(RequestOperation, "create")
      .mockResolvedValue([{}] as never);
  });

  it("creates one Request and persists the operation identity only in the durable ledger, on a first, genuinely new operation", async () => {
    stubLedgerLookups(null);
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-first-attempt-1")
    );

    await createRequest(context.req, context.res);

    // The Request document itself carries no operation identity — only the
    // ledger does, so cleanup of the Request can never free the identity for
    // reuse.
    expect(persistedCreate).toHaveBeenCalledWith(
      [expect.not.objectContaining({ operationId: expect.anything() })],
      expect.objectContaining({ session: sessionMock })
    );
    expect(createLedgerEntry).toHaveBeenCalledWith(
      [
        expect.objectContaining({
          operationId: "op-first-attempt-1",
          // The route resolves the verified participant to its stringified
          // principal id (`participantAuthorityGate.ts`), never the raw
          // `ObjectId` — the ledger row carries that same string.
          participantId: String(participantId),
        }),
      ],
      expect.objectContaining({ session: sessionMock })
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("reconciles a sequential replay to the already-created Request without creating another or re-checking quota", async () => {
    stubLedgerLookups(ledgerRow({ operationId: "op-replay-1" }));
    stubRequestLookups(existingOperationDocument());
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-replay-1")
    );

    await createRequest(context.req, context.res);

    expect(createDocument).not.toHaveBeenCalled();
    expect(createLedgerEntry).not.toHaveBeenCalled();
    expect(countDocuments).not.toHaveBeenCalled();
    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        request: expect.objectContaining({ id: String(requestId) }),
      })
    );
  });

  it("refuses a suspended requester inside the operation-bearing transaction: no Request, no ledger row", async () => {
    stubLedgerLookups(null);
    vi.spyOn(Participant, "updateOne").mockReturnValue({
      exec: vi.fn().mockResolvedValue({ matchedCount: 0, modifiedCount: 0 }),
    } as unknown as ReturnType<typeof Participant.updateOne>);
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-suspended-1")
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(createDocument).not.toHaveBeenCalled();
    expect(createLedgerEntry).not.toHaveBeenCalled();
  });

  it("creates at most one Request when two concurrent attempts race the same operation identity", async () => {
    // The pre-write ledger lookup finds nothing, so this attempt reaches the
    // transactional write. The ledger insert then loses the unique-index
    // race, exactly as it would against a real concurrent insert, and the
    // race-fallback reconciliation's ledger + Request lookups find the
    // winner's row.
    stubLedgerLookups(null, ledgerRow({ operationId: "op-concurrent-1" }));
    stubRequestLookups(existingOperationDocument());
    createLedgerEntry.mockRejectedValueOnce(
      Object.assign(new Error("duplicate key"), { code: 11000 })
    );
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-concurrent-1")
    );

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledTimes(1);
    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        request: expect.objectContaining({ id: String(requestId) }),
      })
    );
  });

  it("creates a distinct Request for a second, genuinely distinct operation identity with an identical payload", async () => {
    stubLedgerLookups(null);
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-distinct-2")
    );

    await createRequest(context.req, context.res);

    expect(createLedgerEntry).toHaveBeenCalledWith(
      [expect.objectContaining({ operationId: "op-distinct-2" })],
      expect.anything()
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("refuses cross-participant replay without creating a Request or exposing the existing one", async () => {
    stubLedgerLookups(
      ledgerRow({
        operationId: "op-owned-by-someone-else",
        participantId: otherParticipantId,
      })
    );
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-owned-by-someone-else")
    );

    await createRequest(context.req, context.res);

    expect(createDocument).not.toHaveBeenCalled();
    expect(context.status).toHaveBeenCalledWith(403);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: OPERATION_UNAUTHORIZED_CODE,
        message: OPERATION_UNAUTHORIZED_MESSAGE,
      },
    });
  });

  it("refuses the same cross-participant collision when it surfaces as a create-time race", async () => {
    stubLedgerLookups(
      null,
      ledgerRow({
        operationId: "op-raced-by-someone-else",
        participantId: otherParticipantId,
      })
    );
    createLedgerEntry.mockRejectedValueOnce(
      Object.assign(new Error("duplicate key"), { code: 11000 })
    );
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-raced-by-someone-else")
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: OPERATION_UNAUTHORIZED_CODE,
        message: OPERATION_UNAUTHORIZED_MESSAGE,
      },
    });
  });

  it("resolves a terminal expired/unrecoverable outcome, and creates zero Requests, once the recovered Request is gone", async () => {
    stubLedgerLookups(ledgerRow({ operationId: "op-expired-1" }));
    stubRequestLookups(null);
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-expired-1")
    );

    await createRequest(context.req, context.res);

    expect(createDocument).not.toHaveBeenCalled();
    expect(createLedgerEntry).not.toHaveBeenCalled();
    expect(context.status).toHaveBeenCalledWith(410);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: OPERATION_EXPIRED_CODE,
        message: OPERATION_EXPIRED_MESSAGE,
      },
    });
  });

  it("keeps repeating the terminal expired outcome for the same exact identity, never falling through to a fresh create", async () => {
    stubLedgerLookups(
      ledgerRow({ operationId: "op-expired-repeat" }),
      ledgerRow({ operationId: "op-expired-repeat" })
    );
    stubRequestLookups(null, null);

    const first = routeContext(
      canonicalAsap(),
      headersWithOperation("op-expired-repeat")
    );
    await createRequest(first.req, first.res);
    expect(first.status).toHaveBeenCalledWith(410);

    const second = routeContext(
      canonicalAsap(),
      headersWithOperation("op-expired-repeat")
    );
    await createRequest(second.req, second.res);
    expect(second.status).toHaveBeenCalledWith(410);

    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    { label: "empty string", value: "" },
    { label: "disallowed characters", value: "op id with spaces" },
    { label: "over the length bound", value: "o".repeat(129) },
  ])(
    "refuses a malformed operation identity ($label) before any read or write",
    async ({ value }) => {
      const lookup = stubLedgerLookups(null);
      const context = routeContext(
        canonicalAsap(),
        headersWithOperation(value)
      );

      await createRequest(context.req, context.res);

      expect(lookup).not.toHaveBeenCalled();
      expect(createDocument).not.toHaveBeenCalled();
      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: INVALID_OPERATION_ID_CODE,
          message: INVALID_OPERATION_ID_MESSAGE,
        },
      });
    }
  );

  it("refuses a repeated operation-identity header the same way, without guessing which value was meant", async () => {
    const lookup = stubLedgerLookups(null);
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation(["op-a", "op-b"])
    );

    await createRequest(context.req, context.res);

    expect(lookup).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: INVALID_OPERATION_ID_CODE,
        message: INVALID_OPERATION_ID_MESSAGE,
      },
    });
  });

  it("still refuses a definitively invalid payload the same way when an operation identity is present, and does not poison it for a later corrected create", async () => {
    stubLedgerLookups(null);
    const context = routeContext(
      canonicalAsap({ vendor: "   " }),
      headersWithOperation("op-invalid-payload-1")
    );

    await createRequest(context.req, context.res);

    expect(createDocument).not.toHaveBeenCalled();
    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_REQUEST", message: "Invalid request payload" },
    });

    // The corrected retry uses a new operation identity, exactly as the
    // contract requires, and is unaffected by the earlier rejection.
    stubLedgerLookups(null);
    const retry = routeContext(
      canonicalAsap(),
      headersWithOperation("op-invalid-payload-2")
    );
    await createRequest(retry.req, retry.res);
    expect(createDocument).toHaveBeenCalledTimes(1);
    expect(retry.status).toHaveBeenCalledWith(201);
  });

  /** The exact body a pre-R4 iOS build sent, which W4-R4 iOS recovery now
   * replays verbatim for a pending operation that build persisted. */
  function preR4IosBody() {
    return {
      vendor: "Jasper Kane Cafe",
      food: "Chicken over rice",
      pickupName: "Requester Name",
      timing: "asap",
      mealSwipes: 2,
    };
  }

  it("reconciles a pre-R4 body under an already-created operation identity before validating its shape", async () => {
    stubLedgerLookups(ledgerRow({ operationId: "op-pre-r4-created" }));
    stubRequestLookups(existingOperationDocument());
    const context = routeContext(
      preR4IosBody(),
      headersWithOperation("op-pre-r4-created")
    );

    await createRequest(context.req, context.res);

    expect(createDocument).not.toHaveBeenCalled();
    expect(createLedgerEntry).not.toHaveBeenCalled();
    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        request: expect.objectContaining({ id: String(requestId) }),
      })
    );
  });

  it("refuses a pre-R4 body under a never-created operation identity as a definitive non-create", async () => {
    stubLedgerLookups(null);
    const context = routeContext(
      preR4IosBody(),
      headersWithOperation("op-pre-r4-not-found")
    );

    await createRequest(context.req, context.res);

    expect(createDocument).not.toHaveBeenCalled();
    expect(createLedgerEntry).not.toHaveBeenCalled();
    expect(countDocuments).not.toHaveBeenCalled();
    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_REQUEST", message: "Invalid request payload" },
    });
  });

  it("refuses a suspended requester at the create gate on the legacy path: nothing created, nothing disclosed", async () => {
    vi.spyOn(Participant, "updateOne").mockReturnValue({
      exec: vi.fn().mockResolvedValue({ matchedCount: 0, modifiedCount: 0 }),
    } as unknown as ReturnType<typeof Participant.updateOne>);
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).not.toHaveBeenCalled();
    expect(context.status).toHaveBeenCalledWith(403);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "PARTICIPANT_SUSPENDED",
        message: "You can't post or help with new requests.",
        fields: null,
      },
    });
    expect(resendSend).not.toHaveBeenCalled();
  });

  it("fences ordinary creation without consulting the operation ledger", async () => {
    const lookup = vi.spyOn(RequestOperation, "findOne");
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(lookup).not.toHaveBeenCalled();
    expect(sessionMock.withTransaction).toHaveBeenCalledOnce();
    expect(createDocument).toHaveBeenCalledWith(
      expect.not.objectContaining({ operationId: expect.anything() })
    );
    expect(persistedCreate).toHaveBeenCalledWith(
      [expect.not.objectContaining({ operationId: expect.anything() })],
      expect.objectContaining({ session: sessionMock })
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  // W4-D2: terminal NO-CREATE on the create path.

  function noCreateRow(overrides: Record<string, unknown> = {}) {
    return {
      operationId: "op-generic",
      participantId,
      outcome: "no-create",
      ...overrides,
    };
  }

  const notCreatedBody = {
    error: {
      code: OPERATION_NOT_CREATED_CODE,
      message: OPERATION_NOT_CREATED_MESSAGE,
    },
  };

  it("records a created ledger row with an explicit created outcome", async () => {
    stubLedgerLookups(null);
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-created-outcome")
    );

    await createRequest(context.req, context.res);

    expect(createLedgerEntry).toHaveBeenCalledWith(
      [
        expect.objectContaining({
          operationId: "op-created-outcome",
          outcome: "created",
          requestId,
        }),
      ],
      expect.anything()
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it.each([
    { label: "a valid payload", body: () => canonicalAsap() },
    { label: "an invalid payload", body: () => canonicalAsap({ vendor: "   " }) },
    { label: "a pre-R4 body", body: () => preR4IosBody() },
  ])(
    "answers a terminalized identity with NO-CREATE for $label, never validating, counting, creating, or notifying",
    async ({ body }) => {
      stubLedgerLookups(noCreateRow({ operationId: "op-terminalized" }));
      const requestLookup = vi.spyOn(MealRequest, "findOne");
      const context = routeContext(
        body(),
        headersWithOperation("op-terminalized")
      );

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(409);
      expect(context.json).toHaveBeenCalledWith(notCreatedBody);
      expect(requestLookup).not.toHaveBeenCalled();
      expect(countDocuments).not.toHaveBeenCalled();
      expect(createDocument).not.toHaveBeenCalled();
      expect(createLedgerEntry).not.toHaveBeenCalled();
      expect(resendSend).not.toHaveBeenCalled();
      expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    }
  );

  it("keeps answering NO-CREATE for the same terminalized identity on every later replay", async () => {
    stubLedgerLookups(
      noCreateRow({ operationId: "op-terminal-repeat" }),
      noCreateRow({ operationId: "op-terminal-repeat" })
    );
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const context = routeContext(
        canonicalAsap(),
        headersWithOperation("op-terminal-repeat")
      );
      await createRequest(context.req, context.res);
      expect(context.status).toHaveBeenCalledWith(409);
      expect(context.json).toHaveBeenCalledWith(notCreatedBody);
    }
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("resolves an in-flight create that loses the identity to terminalization as NO-CREATE, not a write-uncertain failure", async () => {
    // Nothing existed at the pre-write check; terminalization then won the
    // unique identity before this create's ledger insert, so the insert
    // loses and the transaction (Request included) rolls back.
    stubLedgerLookups(null, noCreateRow({ operationId: "op-lost-to-terminal" }));
    createLedgerEntry.mockRejectedValueOnce(
      Object.assign(new Error("duplicate key"), { code: 11000 })
    );
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-lost-to-terminal")
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(context.status).not.toHaveBeenCalledWith(201);
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith(notCreatedBody);
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("refuses another participant's terminalized identity generically, without revealing that it is terminalized", async () => {
    stubLedgerLookups(
      noCreateRow({
        operationId: "op-terminalized-by-someone-else",
        participantId: otherParticipantId,
      })
    );
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-terminalized-by-someone-else")
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: OPERATION_UNAUTHORIZED_CODE,
        message: OPERATION_UNAUTHORIZED_MESSAGE,
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  // W4-D2: a create that names a ledger authority is served only by it.

  const ledgerAuthority = "7d8f1c2a-3b4e-4f60-8a71-92b3c4d5e6f7";

  function stubLedgerAuthority(
    row: Record<string, unknown> | null | Error = {
      _id: "request-operation-ledger",
      authorityId: ledgerAuthority,
    }
  ) {
    return vi.spyOn(RequestOperationAuthority, "findById").mockReturnValue({
      lean: () =>
        row instanceof Error ? Promise.reject(row) : Promise.resolve(row),
    } as unknown as ReturnType<typeof RequestOperationAuthority.findById>);
  }

  it("creates normally when the named ledger authority is this database's", async () => {
    stubLedgerAuthority();
    stubLedgerLookups(null);
    const context = routeContext(canonicalAsap(), {
      ...headersWithOperation("op-matching-authority"),
      [OPERATION_AUTHORITY_HEADER]: ledgerAuthority,
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createLedgerEntry).toHaveBeenCalledTimes(1);
  });

  it("never reads the authority row when no authority is named, keeping pre-D2 behavior", async () => {
    const authorityLookup = stubLedgerAuthority();
    stubLedgerLookups(null);
    const context = routeContext(
      canonicalAsap(),
      headersWithOperation("op-no-authority")
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(authorityLookup).not.toHaveBeenCalled();
  });

  it.each([
    {
      label: "a different ledger",
      header: "0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3",
      row: undefined,
      status: 409,
      code: "OPERATION_AUTHORITY_MISMATCH",
    },
    {
      label: "a malformed authority",
      header: "https://commonplate.example",
      row: undefined,
      status: 409,
      code: "OPERATION_AUTHORITY_MISMATCH",
    },
    {
      label: "a database with no ledger identity",
      header: ledgerAuthority,
      row: null,
      status: 503,
      code: "OPERATION_AUTHORITY_UNAVAILABLE",
    },
    {
      label: "an unreadable ledger identity",
      header: ledgerAuthority,
      row: new Error("connection reset"),
      status: 503,
      code: "OPERATION_AUTHORITY_UNAVAILABLE",
    },
  ])(
    "refuses $label before the ledger, validation, quota, or any write",
    async ({ header, row, status, code }) => {
      stubLedgerAuthority(row);
      const ledgerLookup = vi.spyOn(RequestOperation, "findOne");
      const context = routeContext(canonicalAsap(), {
        ...headersWithOperation("op-other-authority"),
        [OPERATION_AUTHORITY_HEADER]: header,
      });

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(status);
      expect(context.json).toHaveBeenCalledWith(
        expect.objectContaining({ error: expect.objectContaining({ code }) })
      );
      expect(ledgerLookup).not.toHaveBeenCalled();
      expect(countDocuments).not.toHaveBeenCalled();
      expect(createDocument).not.toHaveBeenCalled();
      expect(createLedgerEntry).not.toHaveBeenCalled();
      expect(resendSend).not.toHaveBeenCalled();
      expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    }
  );

  it("resolves participant authority before reading the ledger authority", async () => {
    const authorityLookup = stubLedgerAuthority();
    const context = routeContext(canonicalAsap(), {
      [OPERATION_IDENTITY_HEADER]: "op-unverified-authority",
      [OPERATION_AUTHORITY_HEADER]: ledgerAuthority,
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(authorityLookup).not.toHaveBeenCalled();
  });
});

describe("W4-R4 structured request representation", () => {
  it("persists a Dining-Dollars-only request with zero swipes and exact cents", async () => {
    const context = routeContext(diningDollarsOnly());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({
        menuPath: "dining-dollars",
        mealSwipes: 0,
        mealItems: [],
        orderDetails: "Grain bowl with extra avocado",
        // Exactly the submitted cents, never a float and never rescaled.
        estimatedDiningDollarsCents: 1_850,
        food: "Grain bowl with extra avocado ($18.50 Dining Dollars)",
      })
);
  });

  it("persists an optional Meal Exchange estimate exactly, and omits the field entirely when there is none", async () => {
    const withEstimate = routeContext(
      canonicalAsap({ estimatedDiningDollarsCents: 1_250 })
    );
    await createRequest(withEstimate.req, withEstimate.res);

    expect(withEstimate.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
expect.objectContaining({
        estimatedDiningDollarsCents: 1_250,
        food: "Vegetable rice bowl; Side salad + $12.50 Dining Dollars",
      })
);

    createDocument.mockClear();
    const withoutEstimate = routeContext(canonicalAsap());
    await createRequest(withoutEstimate.req, withoutEstimate.res);

    expect(withoutEstimate.status).toHaveBeenCalledWith(201);
    const persisted = createdInput(createDocument.mock.calls[0]);
    // Absent, not `$0.00` and not an explicit `undefined` key: the requester
    // needed no Dining Dollars and the document says so by carrying nothing.
    expect(persisted).not.toHaveProperty("estimatedDiningDollarsCents");
    expect(persisted.food).toBe("Vegetable rice bowl; Side salad");
  });

  it("projects the structured representation on the public wrapper for a Dining-Dollars-only request", async () => {
    const context = routeContext(diningDollarsOnly());

    await createRequest(context.req, context.res);

    const body = context.json.mock.calls[0][0] as {
      request: Record<string, unknown>;
    };
    expect(body.request).toMatchObject({
      menuPath: "dining-dollars",
      mealSwipes: 0,
      mealItems: [],
      orderDetails: "Grain bowl with extra avocado",
      estimatedDiningDollarsCents: 1_850,
    });
    // No private field rides along with the new representation.
    expect(body.request).not.toHaveProperty("email");
    expect(body.request).not.toHaveProperty("pickupName");
    expect(body.request).not.toHaveProperty("requesterParticipantId");
  });

  it.each([
    ["canonical ASAP", () => canonicalAsap({ pickupName: "Requester Name" })],
    [
      "canonical scheduled",
      () => canonicalScheduled({ pickupName: "Requester Name" }),
    ],
    [
      "Dining-Dollars-only",
      () => diningDollarsOnly({ pickupName: "Requester Name" }),
    ],
  ])(
    "refuses a %s payload still carrying the removed pickupName field",
    async (_label, build) => {
      const context = routeContext(build());

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: { code: "INVALID_REQUEST", message: "Invalid request payload" },
      });
      expect(createDocument).not.toHaveBeenCalled();
    }
  );

  it("refuses a legacy web payload still carrying pickupName", async () => {
    const context = routeContext({
      vendor: "Jasper Kane Cafe",
      email: participantPrincipal,
      pickupWindowText: "Legacy display",
      pickupName: "Requester Name",
      menuPath: "meal-exchange",
      mealSwipes: 2,
      mealItems: mealEntries(2),
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("refuses a client-supplied food summary on every accepted shape", async () => {
    for (const body of [
      canonicalAsap({ food: "Client summary" }),
      canonicalScheduled({ food: "Client summary" }),
      diningDollarsOnly({ food: "Client summary" }),
    ]) {
      const context = routeContext(body);

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
    }

    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    [
      "a Meal Exchange request with fewer entries than swipes",
      () => canonicalAsap({ mealSwipes: 3, mealItems: mealEntries(2) }),
    ],
    [
      "a Meal Exchange request with a blank entry",
      () => canonicalAsap({ mealSwipes: 2, mealItems: [{ name: "Rice bowl" }, { name: "   " }] }),
    ],
    [
      "a Meal Exchange request with an estimate above $25.00",
      () => canonicalAsap({ estimatedDiningDollarsCents: 2_501 }),
    ],
    [
      "a Dining-Dollars-only request with swipes",
      () => diningDollarsOnly({ mealSwipes: 2 }),
    ],
    [
      "a Dining-Dollars-only request with no estimate",
      () => {
        const body = diningDollarsOnly();
        delete (body as Record<string, unknown>).estimatedDiningDollarsCents;
        return body;
      },
    ],
    [
      "a Dining-Dollars-only request with an estimate above $50.00",
      () => diningDollarsOnly({ estimatedDiningDollarsCents: 5_001 }),
    ],
    [
      "a Dining-Dollars-only request with no order details",
      () => {
        const body = diningDollarsOnly();
        delete (body as Record<string, unknown>).orderDetails;
        return body;
      },
    ],
    [
      "a Meal Exchange request carrying order details",
      () => canonicalAsap({ orderDetails: "Wrong path" }),
    ],
  ])("refuses %s before any side effect", async (_label, build) => {
    const context = routeContext(build());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("creates requests whose meal details and order details exceed 500 characters", async () => {
    const longText = "Long detail ".repeat(42).trim();
    expect(longText.length).toBeGreaterThan(500);

    for (const body of [
      canonicalAsap({ mealSwipes: 1, mealItems: [{ name: longText }]}),
      diningDollarsOnly({ orderDetails: longText }),
    ]) {
      createDocument.mockClear();
      const context = routeContext(body);

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(201);
      const persisted = createdInput(createDocument.mock.calls[0]) as {
        mealItems: Array<{ name: string }>;
        orderDetails?: string;
      };
      expect([...persisted.mealItems.map(({ name }) => name), persisted.orderDetails]).toContain(longText);
    }
  });

  it("excludes hidden higher-index meal content by refusing more entries than swipes", async () => {
    // The requester lowered their swipe count to 1; the draft still holds the
    // second entry's text, but a payload carrying it is refused rather than
    // posting content the requester hid.
    const context = routeContext(
      canonicalAsap({
        mealSwipes: 1,
        mealItems: [{ name: "Rice bowl" }, { name: "Hidden second-swipe content" }],
      })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("names the derived summary, and no pickup name, in the requester confirmation email", async () => {
    vi.stubEnv("FROM_EMAIL", "GoodGrub <noreply@goodgrubapp.com>");
    try {
      const context = routeContext(diningDollarsOnly());

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(201);
      const [email] = resendSend.mock.calls[0] as [
        { html: string; text: string; to: string; from: string },
      ];
      expect(email.to).toBe(participantPrincipal);
      expect(email.from).toBe("GoodGrub <noreply@goodgrubapp.com>");
      expect(email.html).toContain(
        "Grain bowl with extra avocado ($18.50 Dining Dollars)"
      );
      expect(email.text).toContain(
        "Grain bowl with extra avocado ($18.50 Dining Dollars)"
      );
      expect(email.html).not.toContain("Pickup Name");
      expect(email.text).not.toContain("Pickup Name");
    } finally {
      vi.unstubAllEnvs();
    }
  });
});
