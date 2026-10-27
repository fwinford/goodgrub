import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { resendSend, notifySubscribersForRequest, startHelperNewRequestPush } =
  vi.hoisted(() => ({
    resendSend: vi.fn(),
    notifySubscribersForRequest: vi.fn(),
    startHelperNewRequestPush: vi.fn(),
  }));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));
vi.mock("./notifySubscribers.js", () => ({ notifySubscribersForRequest }));
vi.mock("./helperNewRequestPush.js", () => ({ startHelperNewRequestPush }));

import {
  Request as MealRequest,
  Participant,
  RequestOperation,
} from "../models/db.js";
import {
  createRequest,
  OPERATION_EXPIRED_CODE,
  OPERATION_IDENTITY_HEADER,
  OPERATION_NOT_CREATED_CODE,
  OPERATION_UNAUTHORIZED_CODE,
  REQUEST_TEXT_NOT_ALLOWED_CODE,
  REQUEST_TEXT_NOT_ALLOWED_MESSAGE,
} from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

/**
 * W4-U1.1 requester text boundary at `POST /api/request` (unit level).
 *
 * The semantic ordering under test is: participant/operation authority →
 * exact-operation reconciliation → canonical validation → U1.1 filtering for a
 * genuinely new create attempt → only then quota and every creation side
 * effect. A refusal is a definitive pre-mutation non-create: nothing is
 * written, nothing is sent, and the matched text is never echoed.
 */

const participantId = new mongoose.Types.ObjectId("64c0000000000000000000a1");
const participantSecretText = "request-text-filter-unit-test-secret";
const participantAuthority = signParticipantAuthority(
  participantId,
  1,
  Buffer.from(participantSecretText)
);
const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const createdAt = new Date("2026-07-28T16:00:00.000Z");

/** Distinctive on purpose, so any leak into a response/log/write is detectable. */
const BLOCKED = "you stupid bitch";

function asapMealExchange(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Jasper Kane Cafe",
    timing: "asap",
    menuPath: "meal-exchange",
    mealSwipes: 2,
    mealItems: [{ name: "Vegetable rice bowl" }, { name: "Side salad" }],
    ...overrides,
  };
}

function scheduledMealExchange(overrides: Record<string, unknown> = {}) {
  return asapMealExchange({
    timing: "scheduled",
    windowStart: "2026-07-28T17:00:00.000Z",
    ...overrides,
  });
}

function diningDollarsOnly(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Jasper Kane Cafe",
    timing: "asap",
    menuPath: "dining-dollars",
    mealSwipes: 0,
    orderDetails: "Grain bowl with extra avocado",
    estimatedDiningDollarsCents: 1_850,
    ...overrides,
  };
}

function headers(operationId?: string): Record<string, string> {
  return {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
    ...(operationId ? { [OPERATION_IDENTITY_HEADER]: operationId } : {}),
  };
}

function routeContext(body: unknown, requestHeaders: Record<string, string> = headers()) {
  const req = { body, headers: requestHeaders } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

let countDocuments: ReturnType<typeof vi.spyOn>;
let createDocument: ReturnType<typeof vi.spyOn>;
let createLedgerEntry: ReturnType<typeof vi.spyOn>;
let startSession: ReturnType<typeof vi.spyOn>;
let consoleError: ReturnType<typeof vi.spyOn>;
let consoleInfo: ReturnType<typeof vi.spyOn>;
let consoleLog: ReturnType<typeof vi.spyOn>;

function persisted(input: Record<string, unknown>) {
  return {
    _id: requestId,
    ...input,
    status: "open",
    createdAt,
    updatedAt: createdAt,
    __v: 0,
  };
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(createdAt);
  process.env[PARTICIPANT_SIGNING_SECRET_ENV] = participantSecretText;
  vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi
          .fn()
          .mockResolvedValue({ _id: participantId, email: "requester@nyu.edu" }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
  vi.spyOn(Participant, "findById").mockReturnValue({
    select: () => ({
      session: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue({
            _id: participantId,
            email: "requester@nyu.edu",
            authorityVersion: 1,
          }),
        }),
      }),
      lean: () => ({
        exec: vi.fn().mockResolvedValue({
          _id: participantId,
          email: "requester@nyu.edu",
          authorityVersion: 1,
        }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findById>);
  vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);

  resendSend.mockReset();
  resendSend.mockResolvedValue({ data: { id: "email-id" }, error: null });
  notifySubscribersForRequest.mockReset();
  notifySubscribersForRequest.mockResolvedValue(undefined);
  startHelperNewRequestPush.mockReset();

  countDocuments = vi.spyOn(MealRequest, "countDocuments").mockResolvedValue(0 as never);
  createDocument = vi.spyOn(MealRequest, "create").mockImplementation((async (input: unknown) =>
    Array.isArray(input)
      ? [persisted(input[0] as Record<string, unknown>)]
      : persisted(input as Record<string, unknown>)) as never) as ReturnType<typeof vi.spyOn>;
  // W4-U1.2 create gate: the requester's suspension check inside the create
  // transaction.
  vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1, modifiedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);
  createLedgerEntry = vi.spyOn(RequestOperation, "create").mockResolvedValue([{}] as never);
  startSession = vi.spyOn(mongoose, "startSession").mockResolvedValue({
    withTransaction: vi.fn(async (work: () => Promise<void>) => {
      await work();
    }),
    endSession: vi.fn().mockResolvedValue(undefined),
  } as never);
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
  consoleInfo = vi.spyOn(console, "info").mockImplementation(() => {});
  consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
});

afterEach(() => {
  delete process.env[PARTICIPANT_SIGNING_SECRET_ENV];
  vi.restoreAllMocks();
  vi.useRealTimers();
});

/** Every write, send, and read a refused create must never have reached. */
function expectNoCreateSideEffects(extra: { ledgerLookup?: boolean } = {}) {
  expect(countDocuments).not.toHaveBeenCalled();
  expect(createDocument).not.toHaveBeenCalled();
  expect(createLedgerEntry).not.toHaveBeenCalled();
  expect(startSession).not.toHaveBeenCalled();
  expect(resendSend).not.toHaveBeenCalled();
  expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  expect(startHelperNewRequestPush).not.toHaveBeenCalled();
  void extra;
}

function expectNothingLeaked(context: ReturnType<typeof routeContext>) {
  const everything = JSON.stringify([
    context.json.mock.calls,
    context.status.mock.calls,
    consoleError.mock.calls,
    consoleInfo.mock.calls,
    consoleLog.mock.calls,
  ]);
  expect(everything).not.toMatch(/stupid|bitch/i);
}

describe("fresh submission whose authored text matches the filter", () => {
  it.each([
    ["Meal item name", asapMealExchange({ mealItems: [{ name: BLOCKED }, { name: "Side salad" }] })],
    [
      "second Meal item name",
      asapMealExchange({ mealItems: [{ name: "Vegetable rice bowl" }, { name: BLOCKED }] }),
    ],
    [
      "Meal item details",
      asapMealExchange({
        mealItems: [{ name: "Vegetable rice bowl", details: BLOCKED }, { name: "Side salad" }],
      }),
    ],
    ["Dining Dollars order details", diningDollarsOnly({ orderDetails: BLOCKED })],
    ["scheduled timing", scheduledMealExchange({ mealItems: [{ name: BLOCKED }, { name: "Side salad" }] })],
    [
      "legacy web shape",
      {
        vendor: "Jasper Kane Cafe",
        menuPath: "meal-exchange",
        mealItems: [{ name: BLOCKED }, { name: "Side salad" }],
        email: "requester@nyu.edu",
        pickupWindowText: "ASAP",
        mealSwipes: 2,
      },
    ],
  ])("refuses a match in %s with a definitive structured refusal and zero side effects", async (_label, body) => {
    const context = routeContext(body);

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(422);
    expect(responseBody(context)).toEqual({
      error: {
        code: REQUEST_TEXT_NOT_ALLOWED_CODE,
        message: REQUEST_TEXT_NOT_ALLOWED_MESSAGE,
        fields: null,
      },
    });
    expect(REQUEST_TEXT_NOT_ALLOWED_MESSAGE).toBe(
      "Keep request details respectful and food-related."
    );
    expectNoCreateSideEffects();
    expectNothingLeaked(context);
  });

  it("identifies no field, term, or position in the refusal", async () => {
    const context = routeContext(
      asapMealExchange({ mealItems: [{ name: "Vegetable rice bowl" }, { name: BLOCKED }] })
    );

    await createRequest(context.req, context.res);

    const body = responseBody(context);
    expect(Object.keys(body.error).sort()).toEqual(["code", "fields", "message"]);
    expect(body.error.fields).toBeNull();
    // The approved copy legitimately says "details"; what must be absent is any
    // field path, position, or rule vocabulary that would point at a source.
    expect(JSON.stringify(body)).not.toMatch(/mealItems|orderDetails|\[\d\]|\bindex\b|\brule\b|category|stupid|bitch/i);
  });

  it("refuses obfuscated variants the same way", async () => {
    for (const text of ["n1gger fries", "k y s", "ɴɪɢɢᴇʀ"]) {
      createDocument.mockClear();
      const context = routeContext(
        asapMealExchange({ mealItems: [{ name: text }, { name: "Side salad" }] })
      );

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(422);
      expect(createDocument).not.toHaveBeenCalled();
    }
  });

  it("with an operation identity, refuses before any ledger write or transaction", async () => {
    vi.spyOn(RequestOperation, "findOne").mockReturnValueOnce({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
    } as unknown as ReturnType<typeof RequestOperation.findOne>);
    const context = routeContext(
      asapMealExchange({ mealItems: [{ name: BLOCKED }, { name: "Side salad" }] }),
      headers("op-text-refused-fresh-1")
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(422);
    expect(responseBody(context).error.code).toBe(REQUEST_TEXT_NOT_ALLOWED_CODE);
    // No Request, no ledger row of any kind (not CREATED, not NO-CREATE).
    expectNoCreateSideEffects();
    expectNothingLeaked(context);
  });
});

describe("D2: a filtering refusal is never new evidence about an exact operation", () => {
  function ledgerFound(row: Record<string, unknown>) {
    return vi.spyOn(RequestOperation, "findOne").mockReturnValueOnce({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(row) }) }),
    } as unknown as ReturnType<typeof RequestOperation.findOne>);
  }

  const refusedBody = () =>
    asapMealExchange({ mealItems: [{ name: BLOCKED }, { name: "Side salad" }] });

  it("replay of an operation that already CREATED answers CREATED even though this payload would now be refused", async () => {
    ledgerFound({ operationId: "op-created-1", participantId, requestId });
    vi.spyOn(MealRequest, "findOne").mockReturnValueOnce({
      select: vi.fn().mockResolvedValue({
        _id: requestId,
        vendor: "Jasper Kane Cafe",
        food: "Vegetable rice bowl; Side salad",
        pickupWindowText: "ASAP",
        mealSwipes: 2,
        menuPath: "meal-exchange",
        status: "open",
        createdAt,
        visibleFrom: createdAt,
        expiresAt: new Date(createdAt.getTime() + 3 * 60 * 60 * 1000),
        requesterParticipantId: participantId,
      }),
    } as unknown as ReturnType<typeof MealRequest.findOne>);
    const context = routeContext(refusedBody(), headers("op-created-1"));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    expect(responseBody(context).request.id).toBe(String(requestId));
    expect(createDocument).not.toHaveBeenCalled();
    expect(createLedgerEntry).not.toHaveBeenCalled();
  });

  it("replay of a terminal NO-CREATE operation answers OPERATION_NOT_CREATED, not the filtering refusal", async () => {
    ledgerFound({ operationId: "op-nocreate-1", participantId, outcome: "no-create" });
    const context = routeContext(refusedBody(), headers("op-nocreate-1"));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context).error.code).toBe(OPERATION_NOT_CREATED_CODE);
    expectNoCreateSideEffects();
  });

  it("an operation bound to another participant is refused as unauthorized before any filtering", async () => {
    ledgerFound({
      operationId: "op-foreign-1",
      participantId: new mongoose.Types.ObjectId("64c0000000000000000000b2"),
      requestId,
    });
    const context = routeContext(refusedBody(), headers("op-foreign-1"));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(responseBody(context).error.code).toBe(OPERATION_UNAUTHORIZED_CODE);
    expectNoCreateSideEffects();
  });

  it("an operation whose Request is gone is EXPIRED, never a fresh create or a filtering refusal", async () => {
    ledgerFound({ operationId: "op-expired-1", participantId, requestId });
    vi.spyOn(MealRequest, "findOne").mockReturnValueOnce({
      select: vi.fn().mockResolvedValue(null),
    } as unknown as ReturnType<typeof MealRequest.findOne>);
    const context = routeContext(refusedBody(), headers("op-expired-1"));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(410);
    expect(responseBody(context).error.code).toBe(OPERATION_EXPIRED_CODE);
    expectNoCreateSideEffects();
  });
});

describe("ordering relative to authority and canonical validation", () => {
  it("an unverified caller is refused by the participant gate before the filter can say anything", async () => {
    const context = routeContext(refusedBodyForGate(), {});

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).not.toBe(REQUEST_TEXT_NOT_ALLOWED_CODE);
    expectNoCreateSideEffects();
  });

  function refusedBodyForGate() {
    return asapMealExchange({ mealItems: [{ name: BLOCKED }, { name: "Side salad" }] });
  }

  it("canonical validation wins: a structurally invalid payload keeps INVALID_REQUEST even with matching text", async () => {
    const context = routeContext(
      asapMealExchange({
        mealSwipes: 3,
        mealItems: [{ name: BLOCKED }, { name: "Side salad" }], // wrong count for 3 swipes
      })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_REQUEST");
    expectNoCreateSideEffects();
  });

  it("an unsupported vendor keeps INVALID_VENDOR even with matching text", async () => {
    const context = routeContext(
      asapMealExchange({ vendor: "Not A Vendor", mealItems: [{ name: BLOCKED }, { name: "Side salad" }] })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_VENDOR");
    expectNoCreateSideEffects();
  });

  it("the filter runs before the daily-quota read, so a refused attempt never consumes or reads quota", async () => {
    countDocuments.mockResolvedValue(99 as never); // would be REQUEST_LIMIT_REACHED if reached
    const context = routeContext(
      asapMealExchange({ mealItems: [{ name: BLOCKED }, { name: "Side salad" }] })
    );

    await createRequest(context.req, context.res);

    expect(responseBody(context).error.code).toBe(REQUEST_TEXT_NOT_ALLOWED_CODE);
    expect(countDocuments).not.toHaveBeenCalled();
  });
});

describe("ordinary food/order text is never refused", () => {
  it.each([
    "Slutty Vegan One Night Stand burger",
    "extra fucking cheese please",
    "Bitchin' Sauce on the side",
    "Nigerian jollof rice",
    "https://www.grubhub.com/restaurant/some-spot/123456",
    "text me at 917-555-0142 or student1234@nyu.edu",
    "Crème brûlée latte, no cap",
  ])("creates the request for %j", async (name) => {
    const context = routeContext(
      asapMealExchange({ mealItems: [{ name }, { name: "Side salad", details: "ranch on the side" }] })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledOnce();
    expect(startHelperNewRequestPush).toHaveBeenCalledOnce();
  });

  it("creates an allowed Dining Dollars request and still sends the requester confirmation", async () => {
    const context = routeContext(diningDollarsOnly());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(resendSend).toHaveBeenCalledOnce();
  });

  it("does not re-filter the backend-derived `food` summary when its authored inputs passed", async () => {
    // `food` is `name (details); name (details) + $x Dining Dollars`: composed
    // purely from values that already passed, so it is persisted as derived.
    const context = routeContext(
      asapMealExchange({
        mealItems: [{ name: "Chicken wings", details: "extra spicy" }, { name: "Side salad" }],
      })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
      [
        expect.objectContaining({
          food: "Chicken wings (extra spicy); Side salad",
        }),
      ],
      { session: expect.anything() }
    );
  });
});
