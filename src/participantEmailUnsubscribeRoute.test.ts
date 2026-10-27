import mongoose, { type ClientSession } from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Request, Response } from "express";
import { Participant, Subscriber } from "../models/db.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_AUTHORITY_INVALID_CODE,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { createParticipantEmailUnsubscribeHandler } from "./participantEmailUnsubscribeRoute.js";

/**
 * The route handler's own contract: participant-authority resolution runs
 * ahead of any mutation, no request body is ever consulted, and the mutation
 * always acts on the backend-resolved principal — never anything a caller
 * could supply. `participantEmailUnsubscribe.test.ts` proves the primitive's
 * database shape; `unsubscribeSubscriber.mongo.test.ts`-style real-Mongo
 * convergence is out of scope here for the same reason `claimRoute.test.ts`
 * stubs `Participant` rather than standing up a real one.
 */
const principal = "helper@nyu.edu";
const participantId = new mongoose.Types.ObjectId("64b000000000000000000001");
const secretText = "participant-email-unsubscribe-route-secret";
const secret = Buffer.from(secretText);
const authority = signParticipantAuthority(participantId, 1, secret);
const {
  touchParticipantAccountsInSession,
} = vi.hoisted(() => ({
  touchParticipantAccountsInSession: vi.fn(),
}));

vi.mock("./participantAccountFence.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./participantAccountFence.js")>();
  return { ...actual, touchParticipantAccountsInSession };
});

function routeContext(headers: Record<string, string> = {}) {
  const req = { headers, body: {} } as unknown as Request;
  const res = {} as Response;
  let statusCode = 200;
  let bodyValue: unknown;
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    bodyValue = value;
    return res;
  }) as any;
  return {
    req,
    res,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return bodyValue;
    },
  };
}

function stubVerifiedParticipant(email: string = principal) {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({ _id: participantId, email }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

function mockUpdate(matchedCount = 1) {
  return vi.spyOn(Subscriber, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ acknowledged: true, matchedCount }),
  } as never);
}

beforeEach(() => {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, secretText);
  touchParticipantAccountsInSession.mockImplementation(async (ids: Array<string | mongoose.Types.ObjectId>) => {
    const id = String(ids[0]);
    return new Map([[id, { participantId: id, authorityVersion: 1, principal }]]);
  });
  const session = {
    withTransaction: vi.fn(async (callback: () => Promise<unknown>) => callback()),
    endSession: vi.fn().mockResolvedValue(undefined),
  } as unknown as ClientSession;
  vi.spyOn(mongoose, "startSession").mockResolvedValue(session);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("unsubscribeParticipantEmailAlerts", () => {
  it("refuses a request with no participant credential and mutates nothing", async () => {
    const update = mockUpdate();
    const context = routeContext();

    await createParticipantEmailUnsubscribeHandler()(context.req, context.res);

    expect(context.statusCode).toBe(401);
    expect((context.body as { error: { code: string } }).error.code).toBe(
      PARTICIPANT_VERIFICATION_REQUIRED_CODE
    );
    expect(update).not.toHaveBeenCalled();
  });

  it("refuses a forged credential and mutates nothing", async () => {
    stubVerifiedParticipant();
    const update = mockUpdate();
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: `${authority}x`,
    });

    await createParticipantEmailUnsubscribeHandler()(context.req, context.res);

    expect(context.statusCode).toBe(401);
    expect((context.body as { error: { code: string } }).error.code).toBe(
      PARTICIPANT_AUTHORITY_INVALID_CODE
    );
    expect(update).not.toHaveBeenCalled();
  });

  it("refuses a credential signed at a revoked authority version", async () => {
    // The stub answers only for version 1, so a version-2 credential fails
    // the database check even though its signature is genuine.
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
    } as unknown as ReturnType<typeof Participant.findOne>);
    const update = mockUpdate();
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
        participantId,
        2,
        secret
      ),
    });

    await createParticipantEmailUnsubscribeHandler()(context.req, context.res);

    expect(context.statusCode).toBe(401);
    expect((context.body as { error: { code: string } }).error.code).toBe(
      PARTICIPANT_AUTHORITY_INVALID_CODE
    );
    expect(update).not.toHaveBeenCalled();
  });

  it("refuses a credential naming a participant that no longer exists", async () => {
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
    } as unknown as ReturnType<typeof Participant.findOne>);
    const update = mockUpdate();
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: authority,
    });

    await createParticipantEmailUnsubscribeHandler()(context.req, context.res);

    expect(context.statusCode).toBe(401);
    expect(update).not.toHaveBeenCalled();
  });

  it("mutates only the backend-resolved principal, never a client-supplied one", async () => {
    stubVerifiedParticipant(principal);
    const update = mockUpdate();
    // A caller-supplied email/id in the body must have no effect: the handler
    // never reads req.body at all.
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: authority,
    });
    context.req.body = { email: "attacker@nyu.edu", subscriberId: "x" };

    await createParticipantEmailUnsubscribeHandler()(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(update).toHaveBeenCalledOnce();
    expect(update.mock.calls[0][0]).toEqual({ email: principal });
    expect((update.mock.calls[0] as unknown[])[2]).toMatchObject({
      session: expect.any(Object),
    });
    expect(touchParticipantAccountsInSession).toHaveBeenCalledWith(
      [String(participantId)],
      expect.any(Object),
      new Map([[String(participantId), 1]])
    );
    expect(context.body).toEqual({ email: { unsubscribed: true } });
  });

  it("refuses without changing Subscriber state when the fenced principal no longer matches", async () => {
    stubVerifiedParticipant();
    const update = mockUpdate();
    touchParticipantAccountsInSession.mockResolvedValue(
      new Map([[String(participantId), {
        participantId: String(participantId),
        authorityVersion: 1,
        principal: "rebound@nyu.edu",
      }]])
    );
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: authority,
    });

    await createParticipantEmailUnsubscribeHandler()(context.req, context.res);

    expect(context.statusCode).toBe(401);
    expect(update).not.toHaveBeenCalled();
  });

  it("reports the same success shape whether or not a Subscriber existed", async () => {
    stubVerifiedParticipant();
    mockUpdate(0);
    const context = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: authority,
    });

    await createParticipantEmailUnsubscribeHandler()(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body).toEqual({ email: { unsubscribed: true } });
  });

  it("is idempotent: repeated calls with the same credential converge on the same result", async () => {
    stubVerifiedParticipant();
    const update = mockUpdate();
    const handler = createParticipantEmailUnsubscribeHandler();

    for (let i = 0; i < 3; i++) {
      const context = routeContext({
        [PARTICIPANT_AUTHORITY_HEADER]: authority,
      });
      await handler(context.req, context.res);
      expect(context.statusCode).toBe(200);
      expect(context.body).toEqual({ email: { unsubscribed: true } });
    }
    expect(update).toHaveBeenCalledTimes(3);
  });
});
