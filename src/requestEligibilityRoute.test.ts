import express, { type Request, type Response } from "express";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, Request as MealRequest } from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_AUTHORITY_INVALID_CODE,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  buildRequestEligibilityMiddlewareChain,
  getRequestEligibility,
} from "./requestEligibilityRoute.js";

const participantIdA = new mongoose.Types.ObjectId("64f0000000000000000000d1");
const participantIdB = new mongoose.Types.ObjectId("64f0000000000000000000d2");
const principalA = "eligibility-route-a@nyu.edu";
const principalB = "eligibility-route-b@nyu.edu";
const participantSecretText = "request-eligibility-route-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthorityA = signParticipantAuthority(
  participantIdA,
  1,
  participantSecret
);
const participantAuthorityB = signParticipantAuthority(
  participantIdB,
  1,
  participantSecret
);

function routeContext(
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthorityA,
  }
) {
  const req = { headers } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  const setHeader = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  res.setHeader = setHeader;
  return { req, res, status, json, setHeader };
}

function headerValue(
  context: ReturnType<typeof routeContext>,
  name: string
): unknown {
  const call = context.setHeader.mock.calls.find(
    ([field]) => (field as string).toLowerCase() === name.toLowerCase()
  );
  return call?.[1];
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

function stubVerifiedParticipant(
  id: mongoose.Types.ObjectId,
  email: string
) {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({ _id: id, email }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

function mockCount(value: number) {
  return vi
    .spyOn(MealRequest, "countDocuments")
    .mockResolvedValue(value as never);
}

beforeEach(() => {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("GET /api/participant/request-eligibility", () => {
  it("requires usable participant authority before any count read", async () => {
    const count = vi.spyOn(MealRequest, "countDocuments");
    const context = routeContext({});

    await getRequestEligibility(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_VERIFICATION_REQUIRED_CODE
    );
    expect(count).not.toHaveBeenCalled();
  });

  it("refuses an invalid/unusable credential without exposing quota truth", async () => {
    const count = vi.spyOn(MealRequest, "countDocuments");
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential",
    });

    await getRequestEligibility(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_AUTHORITY_INVALID_CODE
    );
    expect(count).not.toHaveBeenCalled();
  });

  it("reports eligible when the current-day count is below three", async () => {
    stubVerifiedParticipant(participantIdA, principalA);
    mockCount(2);
    const context = routeContext();

    await getRequestEligibility(context.req, context.res);

    expect(responseBody(context)).toEqual({ eligibility: "eligible" });
  });

  it("reports exhausted when the current-day count is three or more", async () => {
    stubVerifiedParticipant(participantIdA, principalA);
    mockCount(3);
    const context = routeContext();

    await getRequestEligibility(context.req, context.res);

    expect(responseBody(context)).toEqual({ eligibility: "exhausted" });
  });

  it("derives the counted principal only from resolved participant authority, never a caller-supplied value", async () => {
    stubVerifiedParticipant(participantIdA, principalA);
    const count = mockCount(0);
    const context = routeContext();
    (context.req as unknown as { query: unknown }).query = {
      email: "someone-else@nyu.edu",
    };

    await getRequestEligibility(context.req, context.res);

    expect(count).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({ email: principalA })
    );
  });

  it("isolates one verified participant's result from another's authority", async () => {
    stubVerifiedParticipant(participantIdA, principalA);
    mockCount(3);
    const contextA = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: participantAuthorityA,
    });
    await getRequestEligibility(contextA.req, contextA.res);
    expect(responseBody(contextA)).toEqual({ eligibility: "exhausted" });

    vi.restoreAllMocks();
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    stubVerifiedParticipant(participantIdB, principalB);
    const countB = mockCount(0);
    const contextB = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: participantAuthorityB,
    });
    await getRequestEligibility(contextB.req, contextB.res);

    expect(responseBody(contextB)).toEqual({ eligibility: "eligible" });
    expect(countB).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({ email: principalB })
    );
  });

  it("never exposes count, remaining, reset time, identity, or credential data", async () => {
    stubVerifiedParticipant(participantIdA, principalA);
    mockCount(1);
    const context = routeContext();

    await getRequestEligibility(context.req, context.res);

    const body = responseBody(context);
    expect(Object.keys(body)).toEqual(["eligibility"]);
    expect(JSON.stringify(body)).not.toMatch(
      /count|remaining|reset|participantId|email|credential/i
    );
  });

  it("answers 503 without leaking detail and does not report eligible or exhausted when the read fails", async () => {
    stubVerifiedParticipant(participantIdA, principalA);
    vi.spyOn(MealRequest, "countDocuments").mockRejectedValue(
      new Error("connection reset")
    );
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    const context = routeContext();

    await getRequestEligibility(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(
      /connection reset/
    );
  });

  it("performs no Request, RequestOperation, or other mutation on any path", async () => {
    stubVerifiedParticipant(participantIdA, principalA);
    mockCount(0);
    const create = vi.spyOn(MealRequest, "create");
    const context = routeContext();

    await getRequestEligibility(context.req, context.res);

    expect(create).not.toHaveBeenCalled();
  });

  describe("participant-specific cache isolation", () => {
    it("marks a successful read private/no-store and Vary'd on the participant credential", async () => {
      stubVerifiedParticipant(participantIdA, principalA);
      mockCount(0);
      const context = routeContext();

      await getRequestEligibility(context.req, context.res);

      expect(headerValue(context, "Cache-Control")).toBe("private, no-store");
      expect(headerValue(context, "Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
    });

    it("isolates a missing-authority refusal the same way", async () => {
      const context = routeContext({});

      await getRequestEligibility(context.req, context.res);

      expect(headerValue(context, "Cache-Control")).toBe("private, no-store");
      expect(headerValue(context, "Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
    });

    it("isolates an invalid-authority refusal the same way", async () => {
      const context = routeContext({
        [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential",
      });

      await getRequestEligibility(context.req, context.res);

      expect(headerValue(context, "Cache-Control")).toBe("private, no-store");
      expect(headerValue(context, "Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
    });

    it("isolates a lookup-failure response the same way", async () => {
      stubVerifiedParticipant(participantIdA, principalA);
      vi.spyOn(MealRequest, "countDocuments").mockRejectedValue(
        new Error("connection reset")
      );
      vi.spyOn(console, "error").mockImplementation(() => {});
      const context = routeContext();

      await getRequestEligibility(context.req, context.res);

      expect(headerValue(context, "Cache-Control")).toBe("private, no-store");
      expect(headerValue(context, "Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
    });

    // Finding 1 (MUST FIX, W4-Q1 review, structurally hardened by the
    // rereview's finding 1): the rate limiter runs before
    // `getRequestEligibility` ever executes, so a mounted request that trips
    // it answers straight from the shared limiter handler, which never sets
    // these headers on its own. This mounts the real middleware chain — not
    // a direct handler call — so it is the one case above that could not be
    // proved by calling `getRequestEligibility` alone; it matches the
    // mounted-server pattern already used for the shared rate limiter itself
    // in `claimRoute.test.ts`'s "rate limits with a structured Day 4 error".
    // Built from `buildRequestEligibilityMiddlewareChain` — the same function
    // `app.ts`'s own registration uses — rather than restating the ordering
    // by hand, so this proof and production cannot silently drift apart; a
    // cheap 1-request limiter and a trivial final handler are substituted in
    // place of the real limiter/handler purely to keep the test fast and
    // independent of participant/database setup.
    it("isolates a mounted rate-limited 429 the same way, even though it never reaches the handler", async () => {
      const testApp = express();
      testApp.get(
        "/limited",
        ...buildRequestEligibilityMiddlewareChain(
          createDay4MutationRateLimiter(1),
          (_req: Request, res: Response) => res.json({ eligibility: "eligible" })
        )
      );
      const server = createServer(testApp);
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));

      try {
        const { port } = server.address() as AddressInfo;
        const first = await fetch(`http://127.0.0.1:${port}/limited`);
        const second = await fetch(`http://127.0.0.1:${port}/limited`);

        expect(first.status).toBe(200);
        expect(second.status).toBe(429);
        expect(second.headers.get("Cache-Control")).toBe("private, no-store");
        expect(second.headers.get("Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
      } finally {
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve()))
        );
      }
    });
  });
});
