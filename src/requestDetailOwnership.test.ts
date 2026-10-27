import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Participant,
  ParticipantBlock,
} from "../models/db.js";
import { Request as MealRequest } from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";
import {
  buildPublicRequestDetailResponse,
  callerOwnershipFor,
} from "./requestListResponse.js";
import * as requestParticipation from "./requestParticipation.js";

/**
 * W4-H2 caller-relative ownership on `GET /api/request/:id`.
 *
 * The detail route previously derived no ownership at all, which left an
 * owner's own request indistinguishable on this route from a stranger's — so
 * a request reached by direct navigation, a deep link, or a notification tap
 * could present Reserve to its own requester. These cases prove the route now
 * derives the same affirmative-only signal the list does, and that it still
 * exposes no identity material while doing so.
 */

const OWNER_ID = "64c000000000000000000a01";
const OTHER_ID = "64c000000000000000000b02";
const REQUEST_ID = "64b000000000000000000001";

function requestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: new mongoose.Types.ObjectId(REQUEST_ID),
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    pickupWindowText: "1:00 PM – 2:00 PM",
    mealSwipes: 3,
    email: "requester@example.edu",
    windowStart: new Date("2026-07-26T20:00:00.000Z"),
    windowEnd: new Date("2026-07-26T21:00:00.000Z"),
    status: "open",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    requesterParticipantId: new mongoose.Types.ObjectId(OWNER_ID),
    __v: 0,
    ...overrides,
  };
}

function mockFindById(result: unknown): void {
  vi.spyOn(MealRequest, "findById").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue(result),
      }),
    }),
  } as unknown as ReturnType<typeof MealRequest.findById>);
}

const SECRET_TEXT = "request-detail-ownership-unit-secret";
const SECRET = Buffer.from(SECRET_TEXT);

/** Resolves the given participant id as a valid current authority. */
function mockParticipant(participantId: string): string {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, SECRET_TEXT);
  const objectId = new mongoose.Types.ObjectId(participantId);
  // Same resolution path the accepted W3-H2 detail coverage stubs:
  // `resolveOptionalParticipantAuthority` reads the principal through
  // `Participant.findOne(...).select().lean().exec()`.
  vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({
          _id: objectId,
          email: "owner@nyu.edu",
        }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
  vi.spyOn(requestParticipation, "findParticipatedRequestIds").mockResolvedValue(
    new Set()
  );

  // W4-U1.3: no block exists, so the participant fence never masks the
  // ownership signal these cases are asserting on.
  vi.spyOn(ParticipantBlock, "findOne").mockReturnValue({
    lean: () => ({ exec: vi.fn().mockResolvedValue(null) }),
  } as unknown as ReturnType<typeof ParticipantBlock.findOne>);

  return signParticipantAuthority(objectId, 1, SECRET);
}

function routeContext(headers: Record<string, string> = {}) {
  const req = {
    params: { id: REQUEST_ID },
    headers,
  } as unknown as Request;
  const json = vi.fn();
  const status = vi.fn().mockReturnValue({ json });
  const setHeaders: Record<string, string> = {};
  const setHeader = vi.fn((name: string, value: string) => {
    setHeaders[name] = value;
  });
  const res = { json, status, setHeader } as unknown as Response;
  const next = vi.fn() as unknown as NextFunction;
  return { req, res, next, json, status, setHeaders };
}

beforeEach(() => {
  // W4-R5: an expired request is answered as expired, so fixtures naming a
  // fixed window are read at a fixed instant inside it.
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-07-26T18:00:00.000Z"));
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

const resolved = (participantId: string) =>
  ({ kind: "resolved", participantId }) as const;

describe("callerOwnershipFor", () => {
  it("is true only for a resolved caller whose id matches the binding", () => {
    expect(
      callerOwnershipFor({ requesterParticipantId: OWNER_ID }, resolved(OWNER_ID))
    ).toBe(true);
  });

  it("is an explicit false for a resolved non-owner", () => {
    expect(
      callerOwnershipFor({ requesterParticipantId: OWNER_ID }, resolved(OTHER_ID))
    ).toBe(false);
    expect(callerOwnershipFor({}, resolved(OWNER_ID))).toBe(false);
    expect(
      callerOwnershipFor({ requesterParticipantId: null }, resolved(OWNER_ID))
    ).toBe(false);
  });

  // `undefined` means "omit the field". Anonymous and unresolved are both
  // unknowable, but for different reasons — the client separates them using
  // its own knowledge of whether it presented a credential.
  it("is undefined for an anonymous caller", () => {
    expect(
      callerOwnershipFor({ requesterParticipantId: OWNER_ID }, { kind: "anonymous" })
    ).toBeUndefined();
  });

  it("is undefined when a presented authority could not be resolved", () => {
    expect(
      callerOwnershipFor({ requesterParticipantId: OWNER_ID }, { kind: "unresolved" })
    ).toBeUndefined();
  });

  it("never returns the internal context or the raw binding", () => {
    const value = callerOwnershipFor(
      { requesterParticipantId: OWNER_ID },
      resolved(OWNER_ID)
    );
    expect(typeof value).toBe("boolean");
  });
});

describe("buildPublicRequestDetailResponse ownership projection", () => {
  const now = new Date("2026-07-26T19:30:00.000Z");

  it("states isOwnRequest: false for a resolved non-owner", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument() as never,
      now,
      resolved(OTHER_ID)
    );
    expect(response.request.isOwnRequest).toBe(false);
  });

  it("states isOwnRequest: true for the owner", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument() as never,
      now,
      resolved(OWNER_ID)
    );
    expect(response.request.isOwnRequest).toBe(true);
  });

  it("omits isOwnRequest for an anonymous caller", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument() as never,
      now,
      { kind: "anonymous" }
    );
    expect(response.request).not.toHaveProperty("isOwnRequest");
  });

  it("omits isOwnRequest when the presented authority could not be resolved", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument() as never,
      now,
      { kind: "unresolved" }
    );
    expect(response.request).not.toHaveProperty("isOwnRequest");
  });

  // List and detail must answer identically for the same caller/document.
  it("matches the list projection semantics for the same caller", () => {
    const owner = buildPublicRequestDetailResponse(
      requestDocument() as never,
      now,
      resolved(OWNER_ID)
    );
    const other = buildPublicRequestDetailResponse(
      requestDocument() as never,
      now,
      resolved(OTHER_ID)
    );
    expect(owner.request.isOwnRequest).toBe(true);
    expect(other.request.isOwnRequest).toBe(false);
  });

  it("never copies the raw participant binding onto the response", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument() as never,
      now,
      resolved(OWNER_ID)
    );
    expect(response.request).not.toHaveProperty("requesterParticipantId");
    expect(JSON.stringify(response)).not.toContain(OWNER_ID);
  });
});

describe("GET /api/request/:id caller-relative ownership", () => {
  it("returns isOwnRequest for the request's own requester", async () => {
    mockFindById(requestDocument());
    const authority = mockParticipant(OWNER_ID);
    const context = routeContext({ [PARTICIPANT_AUTHORITY_HEADER]: authority });

    await getPublicRequestDetail(context.req, context.res, context.next);

    const [payload] = context.json.mock.calls[0] as [
      { request: { isOwnRequest?: boolean } }
    ];
    expect(payload.request.isOwnRequest).toBe(true);
  });

  it("states isOwnRequest: false for a different verified participant", async () => {
    mockFindById(requestDocument());
    const authority = mockParticipant(OTHER_ID);
    const context = routeContext({ [PARTICIPANT_AUTHORITY_HEADER]: authority });

    await getPublicRequestDetail(context.req, context.res, context.next);

    const [payload] = context.json.mock.calls[0] as [
      { request: { isOwnRequest?: boolean } }
    ];
    expect(payload.request.isOwnRequest).toBe(false);
  });

  // W4-R5: a credential was presented and rejected. The route refuses with the
  // shared structured error; it never answers with a request, so it cannot
  // claim the request is, or is not, theirs.
  it("refuses, with no request, when a presented credential cannot be resolved", async () => {
    mockFindById(requestDocument());
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, SECRET_TEXT);
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: "not-a-valid-authority",
    });

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(context.json).not.toHaveBeenCalledWith(
      expect.objectContaining({ request: expect.anything() })
    );
  });

  it("refuses an anonymous caller without disclosing the request or its ownership", async () => {
    mockFindById(requestDocument());
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(context.json).not.toHaveBeenCalledWith(
      expect.objectContaining({ request: expect.anything() })
    );
  });

  it("exposes no requester identity material alongside the ownership signal", async () => {
    mockFindById(requestDocument());
    const authority = mockParticipant(OWNER_ID);
    const context = routeContext({ [PARTICIPANT_AUTHORITY_HEADER]: authority });

    await getPublicRequestDetail(context.req, context.res, context.next);

    const serialized = JSON.stringify(context.json.mock.calls[0][0]);
    expect(serialized).not.toContain("requesterParticipantId");
    expect(serialized).not.toContain(OWNER_ID);
    expect(serialized).not.toContain("requester@example.edu");
    expect(serialized).not.toContain("Requester Private Name");
  });

  it("keeps the caller-relative response uncacheable", async () => {
    mockFindById(requestDocument());
    const authority = mockParticipant(OWNER_ID);
    const context = routeContext({ [PARTICIPANT_AUTHORITY_HEADER]: authority });

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.setHeaders["Cache-Control"]).toBe("private, no-store");
    expect(context.setHeaders["Vary"]).toBe(PARTICIPANT_AUTHORITY_HEADER);
  });
});
