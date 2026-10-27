import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, Request as MealRequest } from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { getOwnerRequestDetail } from "./requestOwnerReadRoute.js";

/**
 * U1.2 CP5 requester removal notice: the requester's own detail read answers
 * `REQUEST_REMOVED` for a live request moderation removed (M), and every other
 * caller or state keeps the single indistinguishable `404`.
 */

const OWNER_ID = "64c000000000000000000a01";
const OTHER_ID = "64c000000000000000000b02";
const REQUEST_ID = "64b000000000000000000001";
const MISSING_ID = "64b0000000000000000000ff";

const SECRET_TEXT = "request-owner-removed-notice-unit-secret";
const SECRET = Buffer.from(SECRET_TEXT);

const NOW = new Date("2026-07-26T18:00:00.000Z");

function requestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: new mongoose.Types.ObjectId(REQUEST_ID),
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    pickupWindowText: "1:00 PM – 2:00 PM",
    mealSwipes: 1,
    windowStart: new Date("2026-07-26T20:00:00.000Z"),
    windowEnd: new Date("2026-07-26T21:00:00.000Z"),
    status: "open",
    createdAt: new Date("2026-07-26T16:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    contentRevision: 1,
    requesterParticipantId: new mongoose.Types.ObjectId(OWNER_ID),
    ...overrides,
  };
}

/** Stores the one document and answers `findOne` only for a filter that
 * matches its id and requester binding, like the real keyed query. */
function seed(document: ReturnType<typeof requestDocument>): void {
  vi.spyOn(MealRequest, "findOne").mockImplementation(((
    filter: { _id: string; requesterParticipantId: string }
  ) => {
    const matches =
      String(filter._id) === String(document._id) &&
      String(filter.requesterParticipantId) ===
        String(document.requesterParticipantId);
    return {
      select: () => ({
        lean: () => ({ exec: vi.fn().mockResolvedValue(matches ? document : null) }),
      }),
    };
  }) as unknown as typeof MealRequest.findOne);
}

function authorityFor(participantId: string): string {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, SECRET_TEXT);
  const objectId = new mongoose.Types.ObjectId(participantId);
  vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({ _id: objectId, email: "owner@nyu.edu" }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
  return signParticipantAuthority(objectId, 1, SECRET);
}

async function detail(id: string, as: string | null) {
  const headers: Record<string, string> = as
    ? { [PARTICIPANT_AUTHORITY_HEADER]: authorityFor(as) }
    : {};
  const req = { params: { id }, headers } as unknown as Request;
  const json = vi.fn();
  const status = vi.fn().mockReturnValue({ json });
  const res = { json, status, setHeader: vi.fn() } as unknown as Response;
  await getOwnerRequestDetail(req, res);
  const statusCode = status.mock.calls[0]?.[0] ?? 200;
  const body = (json.mock.calls[0]?.[0] ?? null) as Record<string, any> | null;
  return { statusCode, body };
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(NOW);
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("owner request detail removal notice", () => {
  it("answers the owner of a moderation-removed live request with REQUEST_REMOVED", async () => {
    seed(requestDocument({ moderationUnavailable: true }));
    const { statusCode, body } = await detail(REQUEST_ID, OWNER_ID);
    expect(statusCode).toBe(410);
    expect(body?.error?.code).toBe("REQUEST_REMOVED");
    expect(body?.error?.message).toBe("This request is no longer available.");
  });

  it("applies to a removed claimed request too", async () => {
    seed(requestDocument({ moderationUnavailable: true, status: "claimed" }));
    const { body } = await detail(REQUEST_ID, OWNER_ID);
    expect(body?.error?.code).toBe("REQUEST_REMOVED");
  });

  it("answers a non-owner of a removed request with the exact uniform 404 of a nonexistent id", async () => {
    seed(requestDocument({ moderationUnavailable: true }));
    const nonOwner = await detail(REQUEST_ID, OTHER_ID);
    const nonexistent = await detail(MISSING_ID, OTHER_ID);
    const malformed = await detail("not-an-id", OTHER_ID);
    expect(nonOwner.statusCode).toBe(404);
    expect(nonOwner.body?.error?.code).toBe("REQUEST_NOT_FOUND");
    expect(nonOwner).toEqual(nonexistent);
    expect(nonOwner).toEqual(malformed);
  });

  it("is identical for a non-owner whether or not the request is removed", async () => {
    seed(requestDocument({ moderationUnavailable: true }));
    const removed = await detail(REQUEST_ID, OTHER_ID);
    vi.restoreAllMocks();
    seed(requestDocument());
    const live = await detail(REQUEST_ID, OTHER_ID);
    expect(removed).toEqual(live);
  });

  it("returns no code before authorization: missing or invalid credentials are refused", async () => {
    seed(requestDocument({ moderationUnavailable: true }));
    const anonymous = await detail(REQUEST_ID, null);
    expect(anonymous.statusCode).toBe(401);
    expect(anonymous.body?.error?.code).not.toBe("REQUEST_REMOVED");
  });

  it("leaves the owner's non-removed request unchanged", async () => {
    seed(requestDocument());
    const { statusCode, body } = await detail(REQUEST_ID, OWNER_ID);
    expect(statusCode).toBe(200);
    expect(body?.request?.phase).toBe("available");
  });

  it.each([
    ["withdrawn", { status: "withdrawn" }, 410, "REQUEST_WITHDRAWN"],
    ["placed", { status: "placed" }, 409, "REQUEST_ALREADY_PLACED"],
    [
      "expired",
      { expiresAt: new Date("2026-07-26T17:00:00.000Z") },
      410,
      "REQUEST_EXPIRED",
    ],
  ])("keeps the %s terminal code when not removed", async (_n, overrides, code, errorCode) => {
    seed(requestDocument(overrides));
    const { statusCode, body } = await detail(REQUEST_ID, OWNER_ID);
    expect(statusCode).toBe(code);
    expect(body?.error?.code).toBe(errorCode);
  });

  it("keeps the owner's uniform 404 for a live helper-suspension reservation hold (L)", async () => {
    seed(requestDocument({ reservationLapseHold: true }));
    const { statusCode, body } = await detail(REQUEST_ID, OWNER_ID);
    expect(statusCode).toBe(404);
    expect(body?.error?.code).toBe("REQUEST_NOT_FOUND");
  });

  it.each([
    [
      "withdrawn",
      { status: "withdrawn" },
      410,
      "REQUEST_WITHDRAWN",
    ],
    [
      "expired",
      { expiresAt: new Date("2026-07-26T17:00:00.000Z") },
      410,
      "REQUEST_EXPIRED",
    ],
  ])(
    "answers a held %s request with the same terminal answer as an unheld one, never REQUEST_REMOVED",
    async (_n, overrides, code, errorCode) => {
      seed(requestDocument({ ...overrides }));
      const plain = await detail(REQUEST_ID, OWNER_ID);
      for (const hold of [
        { moderationUnavailable: true },
        { reservationLapseHold: true },
        { moderationUnavailable: true, reservationLapseHold: true },
      ]) {
        seed(requestDocument({ ...overrides, ...hold }));
        const held = await detail(REQUEST_ID, OWNER_ID);
        expect(held.statusCode).toBe(code);
        expect(held.body?.error?.code).toBe(errorCode);
        expect(held.statusCode).toBe(plain.statusCode);
        expect(JSON.stringify(held.body)).toBe(JSON.stringify(plain.body));
      }
    }
  );

  it("still gives a non-owner the uniform 404 for a held terminal request", async () => {
    seed(requestDocument({ moderationUnavailable: true, status: "withdrawn" }));
    const nonOwner = await detail(REQUEST_ID, OTHER_ID);
    expect(nonOwner.statusCode).toBe(404);
    expect(nonOwner.body?.error?.code).toBe("REQUEST_NOT_FOUND");
  });

  it("keeps a placed order reachable even if it carries a marker", async () => {
    seed(requestDocument({ moderationUnavailable: true, status: "placed" }));
    const { statusCode, body } = await detail(REQUEST_ID, OWNER_ID);
    expect(statusCode).toBe(409);
    expect(body?.error?.code).toBe("REQUEST_ALREADY_PLACED");
  });

  it("carries no moderation, report, reporter, or requester data in the removed response", async () => {
    seed(
      requestDocument({
        moderationUnavailable: true,
        reportId: "r1",
        reporterParticipantId: "reporter-secret",
      })
    );
    const { body } = await detail(REQUEST_ID, OWNER_ID);
    expect(Object.keys(body ?? {})).toEqual(["error"]);
    const serialized = JSON.stringify(body);
    for (const forbidden of [
      "moderation",
      "report",
      "reporter",
      "suspend",
      "reservationLapseHold",
      "Requester Private Name",
      "Campus Market",
      OWNER_ID,
    ]) {
      expect(serialized.toLowerCase()).not.toContain(forbidden.toLowerCase());
    }
    expect(body?.error?.fields).toBeNull();
    expect(Object.keys(body?.error ?? {}).sort()).toEqual([
      "code",
      "fields",
      "message",
    ]);
  });
});
