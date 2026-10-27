import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, Request as MealRequest } from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  getOwnerRequestDetail,
  getOwnerRequestList,
} from "./requestOwnerReadRoute.js";

/**
 * U1.2 CP5 Home discovery: `GET /api/participant/requests` carries one
 * owner-only boolean, `removedNotice`, true when moderation removed one of the
 * caller's own live requests. The list itself still omits such requests.
 */

const OWNER_ID = "64c000000000000000000a01";
const OTHER_ID = "64c000000000000000000b02";
const SECRET_TEXT = "request-owner-list-removed-notice-unit-secret";
const SECRET = Buffer.from(SECRET_TEXT);
const NOW = new Date("2026-07-26T18:00:00.000Z");
const LIVE_UNTIL = new Date("2026-07-26T22:00:00.000Z");
const PAST = new Date("2026-07-26T17:00:00.000Z");

type Doc = Record<string, any>;

function doc(owner: string, overrides: Doc = {}): Doc {
  return {
    _id: new mongoose.Types.ObjectId(),
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    pickupWindowText: "1:00 PM – 2:00 PM",
    mealSwipes: 1,
    windowStart: null,
    windowEnd: null,
    status: "open",
    createdAt: new Date("2026-07-26T16:00:00.000Z"),
    expiresAt: LIVE_UNTIL,
    contentRevision: 1,
    requesterParticipantId: new mongoose.Types.ObjectId(owner),
    ...overrides,
  };
}

/** Evaluates exactly the filter operators the owner list route uses. */
function matches(document: Doc, filter: Doc): boolean {
  return Object.entries(filter).every(([key, condition]) => {
    const value = document[key];
    if (condition && typeof condition === "object" && !(condition instanceof mongoose.Types.ObjectId)) {
      if ("$in" in condition) return condition.$in.includes(value);
      if ("$gt" in condition) return value != null && value > condition.$gt;
      if ("$ne" in condition) return value !== condition.$ne;
      throw new Error(`unsupported operator in ${key}`);
    }
    return String(value) === String(condition);
  });
}

function seed(documents: Doc[]) {
  const findOne = vi.spyOn(MealRequest, "findOne").mockImplementation(((filter: Doc) => ({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue(
          documents.find((candidate) => matches(candidate, filter)) ?? null
        ),
      }),
    }),
  })) as unknown as typeof MealRequest.findOne);
  const find = vi.spyOn(MealRequest, "find").mockImplementation(((filter: Doc) => ({
    select: () => ({
      sort: () => ({
        limit: () => ({
          lean: () => ({
            exec: vi.fn().mockResolvedValue(
              documents.filter((candidate) => matches(candidate, filter))
            ),
          }),
        }),
      }),
    }),
  })) as unknown as typeof MealRequest.find);
  return { find, findOne };
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

async function list(as: string | null) {
  const headers: Record<string, string> = as
    ? { [PARTICIPANT_AUTHORITY_HEADER]: authorityFor(as) }
    : {};
  const req = { headers } as unknown as Request;
  const json = vi.fn();
  const status = vi.fn().mockReturnValue({ json });
  const setHeader = vi.fn();
  const res = { json, status, setHeader } as unknown as Response;
  await getOwnerRequestList(req, res);
  return {
    statusCode: status.mock.calls[0]?.[0] ?? 200,
    body: (json.mock.calls[0]?.[0] ?? null) as Record<string, any> | null,
    headers: setHeader.mock.calls as string[][],
  };
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

describe("owner request list removal discovery", () => {
  it("is true for an owner with a live moderation-removed request, which the list still omits", async () => {
    const removed = doc(OWNER_ID, { moderationUnavailable: true });
    const visible = doc(OWNER_ID);
    seed([removed, visible]);
    const { statusCode, body } = await list(OWNER_ID);
    expect(statusCode).toBe(200);
    expect(body?.removedNotice).toBe(true);
    expect(body?.requests.map((r: Doc) => r.id)).toEqual([String(visible._id)]);
  });

  it("is true even when the removed request is the owner's only one", async () => {
    seed([doc(OWNER_ID, { moderationUnavailable: true, status: "claimed" })]);
    const { body } = await list(OWNER_ID);
    expect(body).toEqual({ requests: [], removedNotice: true });
  });

  it("is false with no removed request", async () => {
    seed([doc(OWNER_ID)]);
    const { body } = await list(OWNER_ID);
    expect(body?.removedNotice).toBe(false);
    expect(body?.requests).toHaveLength(1);
  });

  it("is false for an owner with no requests at all", async () => {
    seed([]);
    expect((await list(OWNER_ID)).body).toEqual({ requests: [], removedNotice: false });
  });

  it.each([
    ["a helper-suspension hold (L) only", { reservationLapseHold: true }],
    ["a withdrawn request carrying the marker", { moderationUnavailable: true, status: "withdrawn" }],
    ["a placed request carrying the marker", { moderationUnavailable: true, status: "placed" }],
    ["an expired request carrying the marker", { moderationUnavailable: true, expiresAt: PAST }],
  ])("is false for %s", async (_name, overrides) => {
    seed([doc(OWNER_ID, overrides)]);
    expect((await list(OWNER_ID)).body?.removedNotice).toBe(false);
  });

  it("never lets another participant's removed request affect the caller", async () => {
    seed([doc(OTHER_ID, { moderationUnavailable: true })]);
    expect((await list(OWNER_ID)).body).toEqual({ requests: [], removedNotice: false });
    expect((await list(OTHER_ID)).body?.removedNotice).toBe(true);
  });

  it("queries only the authenticated owner's own live marked requests, bounded to one", async () => {
    const { findOne } = seed([]);
    await list(OWNER_ID);
    const filter = (findOne.mock.calls as unknown[][])[0]?.[0] as Doc;
    expect(String(filter.requesterParticipantId)).toBe(OWNER_ID);
    expect(filter).toMatchObject({
      status: { $in: ["open", "claimed"] },
      moderationUnavailable: true,
    });
    expect(filter.expiresAt.$gt).toEqual(NOW);
  });

  it("refuses an unauthenticated caller before any lookup", async () => {
    const { find, findOne } = seed([doc(OWNER_ID, { moderationUnavailable: true })]);
    const { statusCode, body } = await list(null);
    expect(statusCode).toBe(401);
    expect(body).not.toHaveProperty("removedNotice");
    expect(JSON.stringify(body)).not.toContain("removedNotice");
    expect(find).not.toHaveBeenCalled();
    expect(findOne).not.toHaveBeenCalled();
  });

  it("fails the read as unavailable rather than guessing false when the check fails", async () => {
    seed([]);
    vi.spyOn(MealRequest, "findOne").mockImplementation((() => {
      throw new Error("boom");
    }) as unknown as typeof MealRequest.findOne);
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { statusCode, body } = await list(OWNER_ID);
    expect(statusCode).toBe(503);
    expect(body).not.toHaveProperty("removedNotice");
  });

  it("adds exactly one boolean: no ids, counts, times, reporter, reason or moderation fields", async () => {
    seed([
      doc(OWNER_ID, {
        moderationUnavailable: true,
        reportId: "r1",
        reporterParticipantId: "reporter-secret",
      }),
    ]);
    const { body, headers } = await list(OWNER_ID);
    expect(Object.keys(body ?? {}).sort()).toEqual(["removedNotice", "requests"]);
    expect(typeof body?.removedNotice).toBe("boolean");
    const serialized = JSON.stringify(body).toLowerCase();
    for (const forbidden of ["moderation", "report", "reporter", "suspend", "reservationlapsehold"]) {
      expect(serialized).not.toContain(forbidden);
    }
    expect(headers).toContainEqual(["Cache-Control", "private, no-store"]);
    expect(headers).toContainEqual(["Vary", PARTICIPANT_AUTHORITY_HEADER]);
  });
});

describe("detail reads are unchanged by list discovery", () => {
  async function detail(id: string, as: string) {
    const req = {
      params: { id },
      headers: { [PARTICIPANT_AUTHORITY_HEADER]: authorityFor(as) },
    } as unknown as Request;
    const json = vi.fn();
    const status = vi.fn().mockReturnValue({ json });
    const res = { json, status, setHeader: vi.fn() } as unknown as Response;
    await getOwnerRequestDetail(req, res);
    return { statusCode: status.mock.calls[0]?.[0] ?? 200, body: json.mock.calls[0]?.[0] };
  }

  it("keeps the stranger and nonexistent 404 identical while the owner is told REQUEST_REMOVED", async () => {
    const removed = doc(OWNER_ID, { moderationUnavailable: true });
    vi.spyOn(MealRequest, "findOne").mockImplementation(((filter: Doc) => ({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue(matches(removed, filter) ? removed : null),
        }),
      }),
    })) as unknown as typeof MealRequest.findOne);
    const stranger = await detail(String(removed._id), OTHER_ID);
    const missing = await detail(String(new mongoose.Types.ObjectId()), OTHER_ID);
    expect(stranger.statusCode).toBe(404);
    expect(stranger).toEqual(missing);
    expect((await detail(String(removed._id), OWNER_ID)).body.error.code).toBe("REQUEST_REMOVED");
  });
});
