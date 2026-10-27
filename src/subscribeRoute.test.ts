import { readFileSync } from "node:fs";
import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Subscriber } from "../models/db.js";
import { NYU_EMAIL_REQUIRED_MESSAGE } from "./allowedEmailDomains.js";
vi.mock("./requestAlertEmailDelivery.js", () => ({ isRequestAlertEmailDeliveryActive: () => true }));

vi.mock("./emailHelpers.js", () => ({
  CONFIRMATION_EMAIL_TIMEOUT_MS: 30_000,
  sendSubscriptionConfirmationEmail: vi.fn(),
}));

import { CONFIRMATION_EMAIL_TIMEOUT_MS } from "./emailHelpers.js";
import {
  CONFIRMATION_SEND_LEASE_MS,
  CONFIRMATION_TOKEN_BYTES,
  SUBSCRIBE_ACCEPTED_RESPONSE,
  createSubscribeHandler,
  digestConfirmationToken,
  generateConfirmationToken,
} from "./subscribeRoute.js";

function routeContext(body: unknown) {
  const req = {
    body,
    protocol: "https",
    get: () => "commonplate.test",
  } as unknown as Request;
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

function queryResult(value: unknown) {
  const query = {
    select: vi.fn(),
    lean: vi.fn(),
    exec: vi.fn().mockResolvedValue(value),
  };
  query.select.mockReturnValue(query);
  query.lean.mockReturnValue(query);
  return query as any;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("subscribe request validation", () => {
  it.each([
    undefined,
    null,
    {},
    { email: "" },
    { email: "not-an-email" },
    { email: "helper@nyu.edu", extra: true },
  ])("rejects an invalid or non-strict body before database work", async (body) => {
    const find = vi.spyOn(Subscriber, "findOne");
    const sendConfirmationEmail = vi.fn();
    const context = routeContext(body);

    await createSubscribeHandler({ sendConfirmationEmail })(
      context.req,
      context.res
    );

    expect(context.statusCode).toBe(400);
    expect(context.body).toEqual({
      error: {
        code: "INVALID_EMAIL",
        message: NYU_EMAIL_REQUIRED_MESSAGE,
        fields: null,
      },
    });
    expect(find).not.toHaveBeenCalled();
    expect(sendConfirmationEmail).not.toHaveBeenCalled();
  });

  it.each([
    "helper@gmail.com",
    "helper@law.nyu.edu",
    "helper@nyu.edu.fake",
    "helper@fake-nyu.edu",
    "helper@nyu.edu.example.com",
    "helper@notnyu.edu",
  ])(
    "refuses %s with the same code before any Subscriber lookup or mutation",
    async (email) => {
      const find = vi.spyOn(Subscriber, "findOne");
      const create = vi.spyOn(Subscriber, "create");
      const update = vi.spyOn(Subscriber, "findOneAndUpdate");
      const sendConfirmationEmail = vi.fn();
      const generateRawToken = vi.fn();
      const context = routeContext({ email });

      await createSubscribeHandler({ sendConfirmationEmail, generateRawToken })(
        context.req,
        context.res
      );

      expect(context.statusCode).toBe(400);
      expect(context.body).toEqual({
        error: {
          code: "INVALID_EMAIL",
          message: NYU_EMAIL_REQUIRED_MESSAGE,
          fields: null,
        },
      });
      expect(find).not.toHaveBeenCalled();
      expect(create).not.toHaveBeenCalled();
      expect(update).not.toHaveBeenCalled();
      expect(generateRawToken).not.toHaveBeenCalled();
      expect(sendConfirmationEmail).not.toHaveBeenCalled();
    }
  );

  it.each([
    ["  Helper@NYU.EDU  ", "helper@nyu.edu"],
    ["student@stern.nyu.edu", "student@stern.nyu.edu"],
    ["Helper+alerts@NYU.edu", "helper+alerts@nyu.edu"],
  ])("accepts %s and looks it up normalized", async (submitted, stored) => {
    const find = vi
      .spyOn(Subscriber, "findOne")
      .mockReturnValue(
        queryResult({
          _id: new mongoose.Types.ObjectId(),
          email: stored,
          status: "confirmed",
        })
      );
    const context = routeContext({ email: submitted });

    await createSubscribeHandler({ sendConfirmationEmail: vi.fn() })(
      context.req,
      context.res
    );

    expect(find).toHaveBeenCalledWith({ email: stored });
    expect(context.statusCode).toBe(202);
    expect(context.body).toEqual(SUBSCRIBE_ACCEPTED_RESPONSE);
  });

  it("trims and lowercases before the lookup", async () => {
    const id = new mongoose.Types.ObjectId();
    const find = vi
      .spyOn(Subscriber, "findOne")
      .mockReturnValue(
        queryResult({
          _id: id,
          email: "helper@nyu.edu",
          status: "confirmed",
        })
      );
    const sendConfirmationEmail = vi.fn();
    const context = routeContext({ email: "  Helper@NYU.EDU  " });

    await createSubscribeHandler({ sendConfirmationEmail })(
      context.req,
      context.res
    );

    expect(find).toHaveBeenCalledWith({ email: "helper@nyu.edu" });
    expect(context.statusCode).toBe(202);
    expect(context.body).toEqual(SUBSCRIBE_ACCEPTED_RESPONSE);
    expect(sendConfirmationEmail).not.toHaveBeenCalled();
  });
});

describe("confirmation token generation", () => {
  it("generates cryptographically random-shaped 32-byte base64url tokens", () => {
    const tokens = Array.from({ length: 20 }, generateConfirmationToken);

    expect(new Set(tokens)).toHaveLength(tokens.length);
    for (const token of tokens) {
      expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(Buffer.from(token, "base64url")).toHaveLength(
        CONFIRMATION_TOKEN_BYTES
      );
    }
  });
});

describe("provider-failure public response", () => {
  it("returns generic acceptance after conditional new-record cleanup without leaking the raw credential", async () => {
    const id = new mongoose.Types.ObjectId();
    const rawToken = "provider-failure-raw-token";
    vi.spyOn(Subscriber, "findOne").mockReturnValue(queryResult(null));
    vi.spyOn(Subscriber, "create").mockResolvedValue({ _id: id } as never);
    vi.spyOn(Subscriber, "exists").mockResolvedValue({ _id: id } as never);
    const cleanup = vi.spyOn(Subscriber, "deleteOne").mockResolvedValue(null as never);
    const context = routeContext({ email: "provider-failure@nyu.edu" });

    await createSubscribeHandler({
      generateRawToken: () => rawToken,
      generateAttemptId: () => "provider-failure-attempt",
      sendConfirmationEmail: vi.fn().mockRejectedValue(new Error("offline")),
    })(context.req, context.res);

    expect(context.statusCode).toBe(202);
    expect(context.body).toEqual(SUBSCRIBE_ACCEPTED_RESPONSE);
    expect(JSON.stringify(context.body)).not.toContain(rawToken);
    expect(cleanup).toHaveBeenCalledWith({
      _id: id,
      confirmationTokenDigest: digestConfirmationToken(rawToken),
      confirmationSendAttemptId: "provider-failure-attempt",
    });
  });
});

describe("re-signup credential and history preservation", () => {
  const backendNow = new Date("2026-08-03T18:30:00.000Z");
  // Every field a signup attempt must leave exactly as it found it.
  const PRESERVED_FIELDS = [
    "unsubscribeCredentialVersion",
    "dailyCount",
    "lastSentAt",
    "bounced",
    "unsubscribedAt",
    "unsubToken",
  ];

  it("rotates an existing lifecycle without touching the credential version, counters, or history", async () => {
    const existing = {
      _id: new mongoose.Types.ObjectId(),
      email: "helper@nyu.edu",
      status: "unsubscribed" as const,
    };
    vi.spyOn(Subscriber, "findOne").mockReturnValue(queryResult(existing));
    const update = vi
      .spyOn(Subscriber, "findOneAndUpdate")
      .mockReturnValue(queryResult({ _id: existing._id }));
    vi.spyOn(Subscriber, "exists").mockResolvedValue(existing as never);
    vi.spyOn(Subscriber, "updateOne").mockResolvedValue(null as never);
    const context = routeContext({ email: existing.email });

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => "raw-token",
      generateAttemptId: () => "resignup-attempt",
      sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
    })(context.req, context.res);

    expect(update).toHaveBeenCalledOnce();
    const rotation = JSON.stringify((update.mock.calls[0] as unknown[])[1]);
    for (const field of PRESERVED_FIELDS) {
      // A rotated unsubscribe credential version would silently break every
      // unsubscribe link this address was ever emailed.
      expect(rotation).not.toContain(field);
    }
    expect(context.statusCode).toBe(202);
  });

  it("creates a brand-new subscriber without dictating any of them", async () => {
    vi.spyOn(Subscriber, "findOne").mockReturnValue(queryResult(null));
    const created = { _id: new mongoose.Types.ObjectId() };
    const create = vi
      .spyOn(Subscriber, "create")
      .mockResolvedValue(created as never);
    vi.spyOn(Subscriber, "exists").mockResolvedValue(created as never);
    vi.spyOn(Subscriber, "updateOne").mockResolvedValue(null as never);
    const context = routeContext({ email: "new@nyu.edu" });

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken: () => "raw-token",
      generateAttemptId: () => "new-attempt",
      sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
    })(context.req, context.res);

    // The schema default supplies the initial version; signup names none of
    // these fields, so it can neither seed nor reset them.
    const document = JSON.stringify(create.mock.calls[0]);
    for (const field of PRESERVED_FIELDS) {
      expect(document).not.toContain(field);
    }
    expect(context.statusCode).toBe(202);
  });
});

describe("send ownership losers", () => {
  const backendNow = new Date("2026-08-03T18:30:00.000Z");

  function owned(overrides: Record<string, unknown>) {
    return {
      _id: new mongoose.Types.ObjectId(),
      email: "helper@nyu.edu",
      status: "pending",
      confirmationTokenDigest: "a".repeat(64),
      confirmationSendAttemptId: "winner-attempt",
      ...overrides,
    };
  }

  it("re-reads a leased lifecycle without generating or sending a token", async () => {
    const record = owned({ confirmationSendAttemptAt: backendNow });
    const find = vi
      .spyOn(Subscriber, "findOne")
      .mockReturnValue(queryResult(record));
    const generateRawToken = vi.fn();
    const sendConfirmationEmail = vi.fn();
    const context = routeContext({ email: record.email });

    await createSubscribeHandler({
      now: () => backendNow,
      generateRawToken,
      sendConfirmationEmail,
    })(context.req, context.res);

    expect(find).toHaveBeenCalledTimes(2);
    expect(generateRawToken).not.toHaveBeenCalled();
    expect(sendConfirmationEmail).not.toHaveBeenCalled();
    expect(context.statusCode).toBe(202);
    expect(context.body).toEqual(SUBSCRIBE_ACCEPTED_RESPONSE);
  });

  it.each([
    [
      "an owner exactly at the lease boundary",
      new Date(backendNow.getTime() - CONFIRMATION_SEND_LEASE_MS),
    ],
    [
      "an owner past the lease boundary",
      new Date(backendNow.getTime() - CONFIRMATION_SEND_LEASE_MS - 1),
    ],
    ["an owner with no lease timestamp at all", undefined],
  ])("treats %s as stale and attempts takeover", async (_label, attemptAt) => {
    const record = owned(
      attemptAt === undefined ? {} : { confirmationSendAttemptAt: attemptAt }
    );
    vi.spyOn(Subscriber, "findOne").mockReturnValue(queryResult(record));
    // The takeover CAS loses here, which is what keeps the response generic;
    // the point is that a stale owner no longer short-circuits before it.
    const update = vi
      .spyOn(Subscriber, "findOneAndUpdate")
      .mockReturnValue(queryResult(null));
    const sendConfirmationEmail = vi.fn();
    const context = routeContext({ email: record.email });

    await createSubscribeHandler({
      now: () => backendNow,
      sendConfirmationEmail,
    })(context.req, context.res);

    expect(update).toHaveBeenCalledOnce();
    expect(context.statusCode).toBe(202);
    expect(context.body).toEqual(SUBSCRIBE_ACCEPTED_RESPONSE);
  });

  it("bounds provider submission well inside the send lease", () => {
    expect(CONFIRMATION_EMAIL_TIMEOUT_MS).toBeLessThanOrEqual(30_000);
    expect(CONFIRMATION_EMAIL_TIMEOUT_MS).toBeLessThan(CONFIRMATION_SEND_LEASE_MS);
  });
});

describe("confirmation link origin", () => {
  it("submits no request-derived base URL even under hostile headers", async () => {
    const sendConfirmationEmail = vi.fn().mockResolvedValue(undefined);
    vi.spyOn(Subscriber, "findOne").mockReturnValue(queryResult(null));
    const created = { _id: new mongoose.Types.ObjectId() };
    vi.spyOn(Subscriber, "create").mockResolvedValue(created as never);
    vi.spyOn(Subscriber, "exists").mockResolvedValue(created as never);
    vi.spyOn(Subscriber, "updateOne").mockResolvedValue(null as never);

    const req = {
      body: { email: "helper@nyu.edu" },
      protocol: "http",
      get: () => "evil.test",
    } as unknown as Request;
    const res = {} as Response;
    res.status = vi.fn(() => res) as never;
    res.json = vi.fn(() => res) as never;

    await createSubscribeHandler({
      generateRawToken: () => "raw-token",
      sendConfirmationEmail,
    })(req, res);

    expect(sendConfirmationEmail).toHaveBeenCalledOnce();
    const submitted = sendConfirmationEmail.mock.calls[0] as unknown[];
    expect(submitted).toEqual(["helper@nyu.edu", "raw-token"]);
    expect(JSON.stringify(submitted)).not.toContain("evil.test");
  });

  it("reads no request host or protocol anywhere in the route", () => {
    const source = readFileSync(
      new URL("./subscribeRoute.ts", import.meta.url),
      "utf8"
    );

    expect(source).not.toContain("req.protocol");
    expect(source).not.toMatch(/req\.get\(/);
    expect(source).not.toMatch(/x-forwarded/i);
  });
});
