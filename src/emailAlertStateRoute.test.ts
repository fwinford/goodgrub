import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, Subscriber } from "../models/db.js";
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
import { getEmailAlertState } from "./emailAlertStateRoute.js";

const participantId = new mongoose.Types.ObjectId("64f0000000000000000000b1");
const principal = "email-state-unit@nyu.edu";
const participantSecretText = "email-alert-state-route-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthority = signParticipantAuthority(
  participantId,
  1,
  participantSecret
);

function routeContext(
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
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

function stubVerifiedParticipant(email = principal) {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({ _id: participantId, email }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

function mockExists(value: unknown) {
  return vi.spyOn(Subscriber, "exists").mockResolvedValue(value as never);
}

beforeEach(() => {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("GET /api/participant/email-alerts/state", () => {
  it("requires usable participant authority before any Subscriber read", async () => {
    const exists = vi.spyOn(Subscriber, "exists");
    const context = routeContext({});

    await getEmailAlertState(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_VERIFICATION_REQUIRED_CODE
    );
    expect(exists).not.toHaveBeenCalled();
  });

  it("refuses an invalid/unusable credential without exposing Subscriber truth", async () => {
    const exists = vi.spyOn(Subscriber, "exists");
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential",
    });

    await getEmailAlertState(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_AUTHORITY_INVALID_CODE
    );
    expect(exists).not.toHaveBeenCalled();
  });

  it("reports active for an active/confirmed Subscriber on the caller's own current verified email", async () => {
    stubVerifiedParticipant();
    mockExists({ _id: "64f0000000000000000000c1" });
    const context = routeContext();

    await getEmailAlertState(context.req, context.res);

    expect(responseBody(context)).toEqual({ email: { active: true } });
  });

  it("reports inactive when no active/confirmed Subscriber exists for the current verified email", async () => {
    stubVerifiedParticipant();
    mockExists(null);
    const context = routeContext();

    await getEmailAlertState(context.req, context.res);

    expect(responseBody(context)).toEqual({ email: { active: false } });
  });

  it("derives the lookup email only from resolved participant authority, never from a caller-supplied value", async () => {
    stubVerifiedParticipant();
    const exists = mockExists(null);
    const context = routeContext();
    // No email, address, or Subscriber-selecting field exists on this
    // request at all — the route accepts no body and no query string.
    (context.req as unknown as { query: unknown }).query = {
      email: "someone-else@nyu.edu",
    };

    await getEmailAlertState(context.req, context.res);

    expect(exists).toHaveBeenCalledExactlyOnceWith({
      email: principal,
      status: "confirmed",
    });
  });

  it("cannot expose another participant's Subscriber state through this caller's authority", async () => {
    stubVerifiedParticipant("this-caller@nyu.edu");
    const exists = mockExists(null);
    const context = routeContext();

    await getEmailAlertState(context.req, context.res);

    expect(exists).toHaveBeenCalledExactlyOnceWith({
      email: "this-caller@nyu.edu",
      status: "confirmed",
    });
  });

  it("never exposes Subscriber id, credentials, or lifecycle fields beyond the minimal boolean", async () => {
    stubVerifiedParticipant();
    mockExists({ _id: "64f0000000000000000000c2" });
    const context = routeContext();

    await getEmailAlertState(context.req, context.res);

    const body = responseBody(context);
    expect(Object.keys(body)).toEqual(["email"]);
    expect(Object.keys(body.email)).toEqual(["active"]);
    expect(JSON.stringify(body)).not.toMatch(
      /subscriberId|confirmationToken|unsubscribeCredential|dailyCount|bounced/i
    );
  });

  it("answers 503 without leaking detail and does not report inactive when the read fails", async () => {
    stubVerifiedParticipant();
    vi.spyOn(Subscriber, "exists").mockRejectedValue(
      new Error("connection reset")
    );
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext();

    await getEmailAlertState(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(
      /connection reset/
    );
  });

  it("performs no Subscriber mutation on any path", async () => {
    stubVerifiedParticipant();
    mockExists(null);
    const updateOne = vi.spyOn(Subscriber, "updateOne");
    const deleteOne = vi.spyOn(Subscriber, "deleteOne");
    const context = routeContext();

    await getEmailAlertState(context.req, context.res);

    expect(updateOne).not.toHaveBeenCalled();
    expect(deleteOne).not.toHaveBeenCalled();
  });

  describe("participant-specific cache isolation", () => {
    it("marks a successful read private/no-store and Vary'd on the participant credential", async () => {
      stubVerifiedParticipant();
      mockExists({ _id: "64f0000000000000000000c3" });
      const context = routeContext();

      await getEmailAlertState(context.req, context.res);

      expect(headerValue(context, "Cache-Control")).toBe("private, no-store");
      expect(headerValue(context, "Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
    });

    it("isolates a missing-authority refusal the same way", async () => {
      const context = routeContext({});

      await getEmailAlertState(context.req, context.res);

      expect(headerValue(context, "Cache-Control")).toBe("private, no-store");
      expect(headerValue(context, "Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
    });

    it("isolates an invalid-authority refusal the same way", async () => {
      const context = routeContext({
        [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential",
      });

      await getEmailAlertState(context.req, context.res);

      expect(headerValue(context, "Cache-Control")).toBe("private, no-store");
      expect(headerValue(context, "Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
    });

    it("isolates a lookup-failure response the same way", async () => {
      stubVerifiedParticipant();
      vi.spyOn(Subscriber, "exists").mockRejectedValue(
        new Error("connection reset")
      );
      vi.spyOn(console, "error").mockImplementation(() => {});
      const context = routeContext();

      await getEmailAlertState(context.req, context.res);

      expect(headerValue(context, "Cache-Control")).toBe("private, no-store");
      expect(headerValue(context, "Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
    });
  });
});
