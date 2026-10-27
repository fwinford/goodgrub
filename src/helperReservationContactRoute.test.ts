import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, Request as MealRequest } from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

const pairFence = vi.hoisted(() => vi.fn());
const eitherSuspended = vi.hoisted(() => vi.fn());
vi.mock("./participantBlocks.js", () => ({ isParticipantPairFenced: pairFence }));
vi.mock("./placedOrderRoutes.js", () => ({
  contactIsDisabledByModeration: eitherSuspended,
  placedOrderCacheIsolation: vi.fn(),
  placedOrderReadRateLimiter: vi.fn(),
}));

import {
  getHelperReservationContact,
  RESERVATION_CONTACT_NOT_FOUND_CODE,
} from "./helperReservationContactRoute.js";

const helperId = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const requesterId = new mongoose.Types.ObjectId("64e0000000000000000000c3");
const requestId = "64e000000000000000000001";
const signingSecretText = "reservation-contact-unit-signing-secret";
const authority = signParticipantAuthority(helperId, 1, Buffer.from(signingSecretText));

function mockQuery<T>(result: T) {
  const chain = {
    select: vi.fn(() => chain),
    lean: vi.fn(() => chain),
    exec: vi.fn().mockResolvedValue(result),
  };
  return chain;
}

interface Call {
  statusCode: number;
  body?: unknown;
  headers: Record<string, string>;
}

function routeContext(requestIdParam = requestId, withAuthority = true) {
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
    setHeader: vi.fn((name: string, value: string) => {
      headers[name] = value;
      return res;
    }),
  };
  const req = { params: { requestId: requestIdParam }, headers } as unknown as Request;
  return { req, res: res as unknown as Response, call };
}

function mockAuthority(): void {
  vi.spyOn(Participant, "findOne").mockReturnValue(
    mockQuery({ _id: helperId, email: "helper@nyu.edu" }) as never
  );
}

function mockReservation(
  reservation: Record<string, unknown> | null,
  requesterEmail: string | undefined = "requester@nyu.edu"
) {
  const findOne = vi.spyOn(MealRequest, "findOne").mockReturnValue(mockQuery(reservation) as never);
  const findById = vi
    .spyOn(Participant, "findById")
    .mockReturnValue(mockQuery(requesterEmail ? { email: requesterEmail } : null) as never);
  return { findOne, findById };
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-10-23T17:00:00.000Z"));
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, signingSecretText);
  pairFence.mockResolvedValue(false);
  eitherSuspended.mockResolvedValue(false);
  mockAuthority();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  pairFence.mockReset();
  eitherSuspended.mockReset();
});

describe("helper reservation contact (requester email to the reserving helper only)", () => {
  it("returns only the requester email for the caller's own live reservation", async () => {
    const { findOne } = mockReservation({ requesterParticipantId: requesterId });
    const { req, res, call } = routeContext();

    await getHelperReservationContact(req, res);

    expect(call.statusCode).toBe(200);
    expect(call.body).toEqual({ contactRequesterEmail: "requester@nyu.edu" });
    expect(findOne).toHaveBeenCalledWith({
      _id: requestId,
      helperParticipantId: helperId,
      status: "claimed",
      claimExpiresAt: { $gt: new Date("2026-10-23T17:00:00.000Z") },
      moderationUnavailable: { $ne: true },
    });
    expect(pairFence).toHaveBeenCalledWith(requesterId, helperId);
    expect(eitherSuspended).toHaveBeenCalledWith(requesterId, helperId);
  });

  it("uses one uniform 404 for no live reservation, fenced, suspended, self, missing email, failure and malformed ids", async () => {
    const outcomes: Call[] = [];
    const run = async (requestIdParam = requestId) => {
      const ctx = routeContext(requestIdParam);
      await getHelperReservationContact(ctx.req, ctx.res);
      outcomes.push(ctx.call);
    };

    mockReservation(null);
    await run();

    mockReservation({ requesterParticipantId: requesterId });
    pairFence.mockResolvedValueOnce(true);
    await run();

    mockReservation({ requesterParticipantId: requesterId });
    eitherSuspended.mockResolvedValueOnce(true);
    await run();

    mockReservation({ requesterParticipantId: helperId });
    await run();

    mockReservation({ requesterParticipantId: null });
    await run();

    mockReservation({ requesterParticipantId: requesterId }, "");
    await run();

    vi.spyOn(MealRequest, "findOne").mockReturnValue({
      select: () => ({ lean: () => ({ exec: () => Promise.reject(new Error("db down")) }) }),
    } as never);
    vi.spyOn(console, "error").mockImplementation(() => {});
    await run();

    await run("not-an-id");

    expect(outcomes).toHaveLength(8);
    for (const outcome of outcomes) {
      expect(outcome.statusCode).toBe(404);
      expect(outcome.body).toEqual(outcomes[0].body);
      expect(JSON.stringify(outcome.body)).toContain(RESERVATION_CONTACT_NOT_FOUND_CODE);
      expect(JSON.stringify(outcome.body)).not.toContain("@");
    }
  });

  it("requires participant authority and reads nothing without it", async () => {
    const { findOne } = mockReservation({ requesterParticipantId: requesterId });
    const { req, res, call } = routeContext(requestId, false);

    await getHelperReservationContact(req, res);

    expect(call.statusCode).not.toBe(200);
    expect(JSON.stringify(call.body ?? {})).not.toContain("@");
    expect(findOne).not.toHaveBeenCalled();
  });
});
