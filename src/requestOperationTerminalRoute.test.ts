import express, { type Request, type Response } from "express";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

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
  Participant,
  Request as MealRequest,
  RequestOperation,
  RequestOperationAuthority,
} from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  OPERATION_IDENTITY_HEADER,
  terminalizeOperation,
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
import {
  buildRequestOperationTerminalMiddlewareChain,
  REQUEST_OPERATION_TERMINAL_ROUTE_PATH,
  resolveRequestOperationTerminal,
} from "./requestOperationTerminalRoute.js";

const participantId = new mongoose.Types.ObjectId("64f0000000000000000000e1");
const otherParticipantId = new mongoose.Types.ObjectId(
  "64f0000000000000000000e2"
);
const principal = "terminal-route@nyu.edu";
const participantSecretText = "request-operation-terminal-route-unit-secret";
const participantAuthority = signParticipantAuthority(
  participantId,
  1,
  Buffer.from(participantSecretText)
);
const requestId = new mongoose.Types.ObjectId("64f0000000000000000000f1");
const ledgerAuthority = "7d8f1c2a-3b4e-4f60-8a71-92b3c4d5e6f7";
const otherLedgerAuthority = "0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3";
const now = new Date("2026-09-16T16:00:00.000Z");

function routeContext(
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
    [OPERATION_IDENTITY_HEADER]: "op-terminal-1",
    [OPERATION_AUTHORITY_HEADER]: ledgerAuthority,
  },
  body: unknown = undefined
) {
  const req = { headers, body } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  const setHeader = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  res.setHeader = setHeader;
  return { req, res, status, json, setHeader };
}

function expectCacheIsolated(context: ReturnType<typeof routeContext>) {
  expect(context.setHeader).toHaveBeenCalledWith(
    "Cache-Control",
    "private, no-store"
  );
  expect(context.setHeader).toHaveBeenCalledWith(
    "Vary",
    PARTICIPANT_AUTHORITY_HEADER
  );
}

function stubVerifiedParticipant() {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({
          _id: participantId,
          email: principal,
          authorityVersion: 1,
        }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

/** This database's ledger authority row, as `requestOperationAuthority.ts` reads it. */
function stubLedgerAuthority(
  row: Record<string, unknown> | null | Error = {
    _id: "request-operation-ledger",
    authorityId: ledgerAuthority,
  }
) {
  return vi.spyOn(RequestOperationAuthority, "findById").mockReturnValue({
    lean: () => (row instanceof Error ? Promise.reject(row) : Promise.resolve(row)),
  } as unknown as ReturnType<typeof RequestOperationAuthority.findById>);
}

function stubLedgerLookups(...results: Array<Record<string, unknown> | null>) {
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

function stubRequestLookups(...results: Array<Record<string, unknown> | null>) {
  const spy = vi.spyOn(MealRequest, "findOne");
  for (const result of results) {
    spy.mockReturnValueOnce({
      select: vi.fn().mockResolvedValue(result),
    } as unknown as ReturnType<typeof MealRequest.findOne>);
  }
  return spy;
}

function createdRow(overrides: Record<string, unknown> = {}) {
  return {
    operationId: "op-terminal-1",
    participantId,
    outcome: "created",
    requestId,
    ...overrides,
  };
}

function noCreateRow(overrides: Record<string, unknown> = {}) {
  return {
    operationId: "op-terminal-1",
    participantId,
    outcome: "no-create",
    ...overrides,
  };
}

function existingRequest() {
  return {
    _id: requestId,
    vendor: "Palladium",
    food: "Vegetable rice bowl",
    pickupWindowText: "ASAP",
    menuPath: "meal-exchange",
    mealSwipes: 1,
    mealItems: ["Vegetable rice bowl"],
    status: "open",
    createdAt: now,
    visibleFrom: now,
    expiresAt: new Date("2026-09-16T19:00:00.000Z"),
    requesterParticipantId: participantId,
    email: principal,
  };
}

const duplicateKey = () =>
  Object.assign(new Error("duplicate key"), { code: 11000 });

let insertLedgerRow: ReturnType<typeof vi.spyOn>;
let createRequestDocument: ReturnType<typeof vi.spyOn>;
let countRequests: ReturnType<typeof vi.spyOn>;
let startSession: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(now);
  process.env[PARTICIPANT_SIGNING_SECRET_ENV] = participantSecretText;
  stubVerifiedParticipant();
  stubLedgerAuthority();
  resendSend.mockReset();
  notifySubscribersForRequest.mockReset();
  insertLedgerRow = vi
    .spyOn(RequestOperation, "create")
    .mockResolvedValue({} as never);
  createRequestDocument = vi.spyOn(MealRequest, "create");
  countRequests = vi.spyOn(MealRequest, "countDocuments");
  startSession = vi.spyOn(mongoose, "startSession").mockResolvedValue({
    withTransaction: vi.fn(async (work: () => Promise<void>) => {
      await work();
    }),
    endSession: vi.fn().mockResolvedValue(undefined),
  } as never);
  vi.spyOn(Participant, "findById").mockReturnValue({
    select: () => ({
      session: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue({
            _id: participantId,
            email: principal,
            authorityVersion: 1,
          }),
        }),
      }),
      lean: () => ({
        exec: vi.fn().mockResolvedValue({
          _id: participantId,
          email: principal,
          authorityVersion: 1,
        }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findById>);
  vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  delete process.env[PARTICIPANT_SIGNING_SECRET_ENV];
  vi.restoreAllMocks();
  vi.useRealTimers();
});

/** Nothing the terminal route does may count quota, create a Request, or send
 * any notification — whatever it answers. */
function expectNoCreateSideEffects() {
  expect(createRequestDocument).not.toHaveBeenCalled();
  expect(countRequests).not.toHaveBeenCalled();
  expect(resendSend).not.toHaveBeenCalled();
  expect(notifySubscribersForRequest).not.toHaveBeenCalled();
}

describe("POST /api/request-operation/terminal (W4-D2)", () => {
  it("establishes terminal NO-CREATE for an identity nothing has claimed, writing only an identity row", async () => {
    stubLedgerLookups(null);
    const context = routeContext(
      {
        [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
        [OPERATION_IDENTITY_HEADER]: "op-terminal-1",
        [OPERATION_AUTHORITY_HEADER]: ledgerAuthority,
      },
      // A body is never read: nothing here may carry request content into
      // the ledger.
      { vendor: "Palladium", mealItems: ["Should never be stored"] }
    );

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json).toHaveBeenCalledWith({ outcome: "not-created" });
    expect(insertLedgerRow).toHaveBeenCalledTimes(1);
    expect(insertLedgerRow).toHaveBeenCalledWith(
      [
        {
          operationId: "op-terminal-1",
          participantId: String(participantId),
          outcome: "no-create",
        },
      ],
      { session: expect.anything() }
    );
    expect(startSession).toHaveBeenCalledOnce();
    expectCacheIsolated(context);
    expectNoCreateSideEffects();
  });

  it("answers an already-created identity with the exact created Request and writes nothing", async () => {
    stubLedgerLookups(createdRow());
    stubRequestLookups(existingRequest());
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    const body = context.json.mock.calls[0][0] as Record<string, any>;
    expect(body.outcome).toBe("created");
    expect(body.request).toEqual(
      expect.objectContaining({ id: String(requestId), vendor: "Palladium" })
    );
    // The public projection only: no requester identity crosses the wire.
    expect(JSON.stringify(body)).not.toContain(principal);
    expect(JSON.stringify(body)).not.toContain(String(participantId));
    expect(insertLedgerRow).not.toHaveBeenCalled();
    expectCacheIsolated(context);
    expectNoCreateSideEffects();
  });

  it("treats a pre-W4-D2 ledger row with no outcome as created", async () => {
    const { outcome: _outcome, ...legacyRow } = createdRow();
    stubLedgerLookups(legacyRow);
    stubRequestLookups(existingRequest());
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json.mock.calls[0][0]).toEqual(
      expect.objectContaining({ outcome: "created" })
    );
    expect(insertLedgerRow).not.toHaveBeenCalled();
  });

  it("preserves terminal expiry once the created Request is gone, never terminalizing it as NO-CREATE", async () => {
    stubLedgerLookups(createdRow());
    stubRequestLookups(null);
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(410);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: "OPERATION_EXPIRED" }),
      })
    );
    expect(insertLedgerRow).not.toHaveBeenCalled();
    expectCacheIsolated(context);
    expectNoCreateSideEffects();
  });

  it("answers a created Request held by M or L as created-then-unavailable (410), distinct from expiry, leaking nothing", async () => {
    stubLedgerLookups(createdRow());
    stubRequestLookups({ ...existingRequest(), moderationUnavailable: true });
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(410);
    expect(context.json).toHaveBeenCalledWith({
      error: expect.objectContaining({
        code: "REQUEST_CREATED_UNAVAILABLE",
        message: "Your request was posted, but it's no longer available.",
      }),
    });
    expect(JSON.stringify(context.json.mock.calls[0][0])).not.toMatch(
      /moderation|reservationLapseHold|OPERATION_EXPIRED/
    );
    expect(insertLedgerRow).not.toHaveBeenCalled();
    expectNoCreateSideEffects();
  });

  it("repeats NO-CREATE idempotently for an already-terminalized identity without another write", async () => {
    stubLedgerLookups(noCreateRow());
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json).toHaveBeenCalledWith({ outcome: "not-created" });
    expect(insertLedgerRow).not.toHaveBeenCalled();
  });

  it.each([
    { label: "a created identity", row: () => createdRow({ participantId: otherParticipantId }) },
    { label: "a terminalized identity", row: () => noCreateRow({ participantId: otherParticipantId }) },
  ])(
    "refuses another participant's $label generically and identically, with no Request lookup",
    async ({ row }) => {
      stubLedgerLookups(row());
      const requestLookup = vi.spyOn(MealRequest, "findOne");
      const context = routeContext();

      await resolveRequestOperationTerminal(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(403);
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "OPERATION_UNAUTHORIZED",
          message:
            "This request cannot be completed with your current verification.",
          fields: null,
        },
      });
      expect(requestLookup).not.toHaveBeenCalled();
      expect(insertLedgerRow).not.toHaveBeenCalled();
      expectCacheIsolated(context);
      expectNoCreateSideEffects();
    }
  );

  it("answers the created outcome when the create transaction wins the identity between the read and the insert", async () => {
    stubLedgerLookups(null, createdRow());
    stubRequestLookups(existingRequest());
    insertLedgerRow.mockRejectedValueOnce(duplicateKey());
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json.mock.calls[0][0]).toEqual(
      expect.objectContaining({
        outcome: "created",
        request: expect.objectContaining({ id: String(requestId) }),
      })
    );
  });

  it("answers NO-CREATE when a concurrent terminalization wins the identity first", async () => {
    stubLedgerLookups(null, noCreateRow());
    insertLedgerRow.mockRejectedValueOnce(duplicateKey());
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json).toHaveBeenCalledWith({ outcome: "not-created" });
  });

  it("refuses another participant who wins the identity in that same window", async () => {
    stubLedgerLookups(null, createdRow({ participantId: otherParticipantId }));
    insertLedgerRow.mockRejectedValueOnce(duplicateKey());
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
  });

  it("never reports a terminal outcome when the ledger cannot be read or written", async () => {
    stubLedgerLookups(null);
    insertLedgerRow.mockRejectedValueOnce(new Error("connection reset"));
    const context = routeContext();

    await resolveRequestOperationTerminal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({
          code: "OPERATION_RECONCILIATION_FAILED",
        }),
      })
    );
    expectCacheIsolated(context);
  });

  it("never treats a duplicate key it cannot reconcile as terminal", async () => {
    stubLedgerLookups(null, null);
    insertLedgerRow.mockRejectedValueOnce(duplicateKey());

    await expect(
      terminalizeOperation("op-terminal-1", String(participantId))
    ).rejects.toThrow("duplicate key");
  });

  it("resolves participant authority before any ledger access", async () => {
    const ledgerLookup = vi.spyOn(RequestOperation, "findOne");
    const authorityLookup = stubLedgerAuthority();
    const unverified = routeContext({
      [OPERATION_IDENTITY_HEADER]: "op-terminal-1",
      [OPERATION_AUTHORITY_HEADER]: ledgerAuthority,
    });

    await resolveRequestOperationTerminal(unverified.req, unverified.res);

    expect(unverified.status).toHaveBeenCalledWith(401);
    expect(unverified.json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({
          code: PARTICIPANT_VERIFICATION_REQUIRED_CODE,
        }),
      })
    );
    expectCacheIsolated(unverified);

    const forged = routeContext({
      [PARTICIPANT_AUTHORITY_HEADER]: "not-a-credential",
      [OPERATION_IDENTITY_HEADER]: "op-terminal-1",
      [OPERATION_AUTHORITY_HEADER]: ledgerAuthority,
    });
    await resolveRequestOperationTerminal(forged.req, forged.res);
    expect(forged.json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({
          code: PARTICIPANT_AUTHORITY_INVALID_CODE,
        }),
      })
    );
    expectCacheIsolated(forged);

    expect(ledgerLookup).not.toHaveBeenCalled();
    expect(authorityLookup).not.toHaveBeenCalled();
    expect(insertLedgerRow).not.toHaveBeenCalled();
  });

  it.each([
    { label: "absent", value: undefined, status: 409, code: "OPERATION_AUTHORITY_MISMATCH" },
    { label: "empty", value: "", status: 409, code: "OPERATION_AUTHORITY_MISMATCH" },
    { label: "a URL rather than a ledger identity", value: "https://commonplate.example", status: 409, code: "OPERATION_AUTHORITY_MISMATCH" },
    { label: "uppercase", value: ledgerAuthority.toUpperCase(), status: 409, code: "OPERATION_AUTHORITY_MISMATCH" },
    { label: "repeated", value: [ledgerAuthority, ledgerAuthority], status: 409, code: "OPERATION_AUTHORITY_MISMATCH" },
    { label: "a different ledger", value: otherLedgerAuthority, status: 409, code: "OPERATION_AUTHORITY_MISMATCH" },
  ])(
    "refuses an $label ledger authority before any ledger access, writing nothing",
    async ({ value, status, code }) => {
      const ledgerLookup = vi.spyOn(RequestOperation, "findOne");
      const headers: Record<string, string | string[]> = {
        [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
        [OPERATION_IDENTITY_HEADER]: "op-terminal-1",
      };
      if (value !== undefined) headers[OPERATION_AUTHORITY_HEADER] = value;
      const context = routeContext(headers);

      await resolveRequestOperationTerminal(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(status);
      expect(context.json).toHaveBeenCalledWith(
        expect.objectContaining({ error: expect.objectContaining({ code }) })
      );
      expect(ledgerLookup).not.toHaveBeenCalled();
      expect(insertLedgerRow).not.toHaveBeenCalled();
      expectCacheIsolated(context);
      expectNoCreateSideEffects();
    }
  );

  it.each([
    { label: "has no ledger identity (a reset database)", row: null },
    { label: "holds a malformed ledger identity", row: { _id: "request-operation-ledger", authorityId: "not-an-id" } },
    { label: "cannot be read", row: new Error("connection reset") },
  ])(
    "refuses as unavailable, never terminal, when this database $label",
    async ({ row }) => {
      stubLedgerAuthority(row);
      const ledgerLookup = vi.spyOn(RequestOperation, "findOne");
      const context = routeContext();

      await resolveRequestOperationTerminal(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(503);
      expect(context.json).toHaveBeenCalledWith(
        expect.objectContaining({
          error: expect.objectContaining({
            code: "OPERATION_AUTHORITY_UNAVAILABLE",
          }),
        })
      );
      expect(ledgerLookup).not.toHaveBeenCalled();
      expect(insertLedgerRow).not.toHaveBeenCalled();
      expectCacheIsolated(context);
    }
  );

  it.each([
    { label: "absent", value: undefined },
    { label: "empty", value: "" },
    { label: "malformed", value: "op id with spaces" },
    { label: "over the length bound", value: "o".repeat(129) },
    { label: "repeated", value: ["op-a", "op-b"] },
  ])(
    "refuses an $label operation identity before any ledger access",
    async ({ value }) => {
      const ledgerLookup = vi.spyOn(RequestOperation, "findOne");
      const headers: Record<string, string | string[]> = {
        [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
      };
      if (value !== undefined) headers[OPERATION_IDENTITY_HEADER] = value;
      const context = routeContext(headers);

      await resolveRequestOperationTerminal(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith(
        expect.objectContaining({
          error: expect.objectContaining({ code: "INVALID_OPERATION_ID" }),
        })
      );
      expect(ledgerLookup).not.toHaveBeenCalled();
      expect(insertLedgerRow).not.toHaveBeenCalled();
      expectCacheIsolated(context);
    }
  );
});

describe("mounted request-operation terminal route", () => {
  async function withServer(
    configure: (app: express.Express) => void,
    run: (baseURL: string) => Promise<void>
  ) {
    const app = express();
    configure(app);
    const server = createServer(app);
    await new Promise<void>((resolve) =>
      server.listen(0, "127.0.0.1", resolve)
    );
    try {
      const { port } = server.address() as AddressInfo;
      await run(`http://127.0.0.1:${port}`);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  }

  const previousPause = process.env[PUBLIC_ACTIONS_PAUSED_ENV];
  afterEach(() => {
    if (previousPause === undefined) {
      delete process.env[PUBLIC_ACTIONS_PAUSED_ENV];
    } else {
      process.env[PUBLIC_ACTIONS_PAUSED_ENV] = previousPause;
    }
  });

  it("isolates a limiter-owned 429 per participant and spends its own bucket", async () => {
    process.env[PUBLIC_ACTIONS_PAUSED_ENV] = "false";
    const handler = vi.fn((_req: Request, res: Response) =>
      res.status(200).json({ outcome: "not-created" })
    );
    await withServer(
      (app) =>
        app.post(
          "/limited",
          ...buildRequestOperationTerminalMiddlewareChain(
            createDay4MutationRateLimiter(1),
            handler
          )
        ),
      async (baseURL) => {
        const first = await fetch(`${baseURL}/limited`, { method: "POST" });
        const second = await fetch(`${baseURL}/limited`, { method: "POST" });

        expect(first.status).toBe(200);
        expect(second.status).toBe(429);
        expect((await second.json()).error.code).toBe("RATE_LIMITED");
        for (const response of [first, second]) {
          expect(response.headers.get("cache-control")).toBe(
            "private, no-store"
          );
          expect(response.headers.get("vary")).toBe(
            PARTICIPANT_AUTHORITY_HEADER
          );
        }
        expect(handler).toHaveBeenCalledTimes(1);
      }
    );
  });

  it("refuses while public actions are paused, isolated, before the limiter or handler", async () => {
    process.env[PUBLIC_ACTIONS_PAUSED_ENV] = "true";
    const limiter = vi.fn((_req, _res, next) => next());
    const handler = vi.fn((_req: Request, res: Response) =>
      res.status(200).json({ outcome: "not-created" })
    );
    await withServer(
      (app) =>
        app.post(
          "/paused",
          ...buildRequestOperationTerminalMiddlewareChain(limiter, handler)
        ),
      async (baseURL) => {
        const response = await fetch(`${baseURL}/paused`, { method: "POST" });

        expect(response.status).toBe(503);
        expect((await response.json()).error.code).toBe(
          "PUBLIC_ACTIONS_PAUSED"
        );
        expect(response.headers.get("cache-control")).toBe(
          "private, no-store"
        );
        expect(response.headers.get("vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);
        expect(limiter).not.toHaveBeenCalled();
        expect(handler).not.toHaveBeenCalled();
      }
    );
  });

  it("is registered in app.ts through its single-sourced chain, separately from POST /api/request", () => {
    const appSource = readFileSync(new URL("../app.ts", import.meta.url), "utf8");
    expect(appSource).toContain("registerRequestOperationTerminalRoute(app);");
    // Ahead of every global body parser, and registered exactly once.
    expect(
      appSource.match(/registerRequestOperationTerminalRoute\(app\);/g)
    ).toHaveLength(1);
    const registration = appSource.indexOf(
      "registerRequestOperationTerminalRoute(app);"
    );
    for (const parser of [
      "app.use(express.json(",
      "app.use(express.urlencoded(",
      "app.use(express.static(",
    ]) {
      expect(appSource.indexOf(parser)).toBeGreaterThan(registration);
    }
    expect(REQUEST_OPERATION_TERMINAL_ROUTE_PATH).toBe(
      "/api/request-operation/terminal"
    );
    const routeSource = readFileSync(
      new URL("./requestOperationTerminalRoute.ts", import.meta.url),
      "utf8"
    );
    expect(routeSource).toContain(
      "requestOperationTerminalRateLimiter =\n  createDay4MutationRateLimiter(10)"
    );
    expect(routeSource).not.toContain("createRequestRateLimiter");
  });
});
