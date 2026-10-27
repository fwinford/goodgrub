import express from "express";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Installation, Participant } from "../models/db.js";
import { signParticipantAuthority } from "./participantCredentials.js";
vi.mock("./participantAccountFence.js", async (importOriginal) => ({
  ...await importOriginal<typeof import("./participantAccountFence.js")>(),
  touchParticipantAccountsInSession: vi.fn().mockResolvedValue(new Map()),
}));
import {
  PUBLIC_ACTIONS_PAUSED_ENV,
  pausePublicAction,
} from "./publicActionsPause.js";
import {
  INSTALLATION_PUSH_UNAVAILABLE_MESSAGE,
  INVALID_INSTALLATION_REQUEST_MESSAGE,
  createInstallationPushHandler,
  installationPushRateLimiter,
  isNormalizedApnsToken,
} from "./installationPushRoute.js";

function routeContext(body: unknown) {
  const req = { body, headers: { "x-commonplate-participant": authority } } as unknown as Request;
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

const validCredential = Buffer.alloc(32, 1).toString("base64url");
const validApnsToken = "b".repeat(64);
const participantId = "64d000000000000000000001";
const secret = "installation-push-test-signing-secret";
const authority = signParticipantAuthority(participantId, 1, Buffer.from(secret));

beforeEach(() => {
  vi.spyOn(mongoose, "startSession").mockResolvedValue({
    withTransaction: async (callback: () => Promise<unknown>) => callback(),
    endSession: vi.fn(),
  } as unknown as mongoose.ClientSession);
  vi.stubEnv("PARTICIPANT_SIGNING_SECRET", secret);
  vi.spyOn(Participant, "findOne").mockReturnValue(
    queryResult({ _id: participantId, email: "helper@nyu.edu" })
  );
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("installation push request validation", () => {
  it.each([0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, "2"])(
    "rejects malformed mutation version %j before persistence",
    async (mutationVersion) => {
      const update = vi.spyOn(Installation, "findOneAndUpdate");
      const context = routeContext({
        installationCredential: validCredential, mutationVersion,
        enabled: true, apnsToken: validApnsToken, environment: "development",
      });
      await createInstallationPushHandler()(context.req, context.res);
      expect(context.statusCode).toBe(400);
      expect(update).not.toHaveBeenCalled();
    }
  );

  it("requires ordering metadata for association changes", async () => {
    const update = vi.spyOn(Installation, "updateOne");
    const context = routeContext({ installationCredential: validCredential, association: "clear" });
    await createInstallationPushHandler()(context.req, context.res);
    expect(context.statusCode).toBe(400);
    expect(update).not.toHaveBeenCalled();
  });

  it.each(["missing", "stale"] as const)("refuses %s participant authority without a mutation", async (kind) => {
    const update = vi.spyOn(Installation, "findOneAndUpdate");
    const context = routeContext({
      installationCredential: validCredential, enabled: true,
      apnsToken: validApnsToken, environment: "development",
    });
    if (kind === "missing") context.req.headers = {};
    else vi.mocked(Participant.findOne).mockReturnValue(queryResult(null));
    await createInstallationPushHandler()(context.req, context.res);
    expect(context.statusCode).toBe(401);
    expect(update).not.toHaveBeenCalled();
  });

  it("writes the verified binding and version atomically with enabled state", async () => {
    const update = vi.spyOn(Installation, "findOneAndUpdate").mockReturnValue(queryResult({ pushEnabled: true }));
    const context = routeContext({
      installationCredential: validCredential, enabled: true,
      apnsToken: validApnsToken, environment: "development",
    });
    await createInstallationPushHandler()(context.req, context.res);
    expect(update).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({
      $set: expect.objectContaining({ pushEnabled: true, participantId, participantAuthorityVersion: 1 }),
    }), expect.objectContaining({ upsert: true }));
    expect(Participant.findOne).toHaveBeenCalledWith({ _id: participantId, authorityVersion: 1 });
  });

  it("disables without participant authority", async () => {
    vi.spyOn(Installation, "findOneAndUpdate").mockReturnValue(queryResult({ pushEnabled: false }));
    const context = routeContext({ installationCredential: validCredential, enabled: false });
    context.req.headers = {};
    await createInstallationPushHandler()(context.req, context.res);
    expect(context.body).toEqual({ push: { enabled: false } });
    expect(Participant.findOne).not.toHaveBeenCalled();
  });
  it("returns only push.enabled for an accepted enable request", async () => {
    vi.spyOn(Installation, "findOneAndUpdate").mockReturnValue(
      queryResult({ pushEnabled: true })
    );
    const context = routeContext({
      installationCredential: validCredential,
      enabled: true,
      apnsToken: validApnsToken,
      environment: "development",
    });

    await createInstallationPushHandler()(context.req, context.res);

    expect(context.body).toEqual({ push: { enabled: true } });
    expect(Object.keys((context.body as any).push)).toEqual(["enabled"]);
  });

  it("returns only push.enabled for an accepted disable request without a token", async () => {
    vi.spyOn(Installation, "findOneAndUpdate").mockReturnValue(
      queryResult({ pushEnabled: false })
    );
    const context = routeContext({
      installationCredential: validCredential,
      enabled: false,
    });

    await createInstallationPushHandler()(context.req, context.res);

    expect(context.body).toEqual({ push: { enabled: false } });
  });

  it.each([
    undefined,
    null,
    {},
    // missing installationCredential
    { enabled: true, apnsToken: validApnsToken, environment: "development" },
    // malformed installationCredential
    {
      installationCredential: "short",
      enabled: true,
      apnsToken: validApnsToken,
      environment: "development",
    },
    // non-boolean enabled
    {
      installationCredential: validCredential,
      enabled: "true",
      apnsToken: validApnsToken,
      environment: "development",
    },
    // enabled: true missing apnsToken
    {
      installationCredential: validCredential,
      enabled: true,
      environment: "development",
    },
    // enabled: true missing environment
    {
      installationCredential: validCredential,
      enabled: true,
      apnsToken: validApnsToken,
    },
    // invalid environment
    {
      installationCredential: validCredential,
      enabled: true,
      apnsToken: validApnsToken,
      environment: "staging",
    },
    // malformed apnsToken
    {
      installationCredential: validCredential,
      enabled: true,
      apnsToken: "not-hex",
      environment: "development",
    },
    // unexpected field on an otherwise-valid enable body
    {
      installationCredential: validCredential,
      enabled: true,
      apnsToken: validApnsToken,
      environment: "development",
      extra: true,
    },
    // unexpected field (a smuggled token) on a disable body
    {
      installationCredential: validCredential,
      enabled: false,
      apnsToken: validApnsToken,
    },
  ])("rejects an invalid body before any installation lookup: %j", async (body) => {
    const findOneAndUpdate = vi.spyOn(Installation, "findOneAndUpdate");
    const context = routeContext(body);

    await createInstallationPushHandler()(context.req, context.res);

    expect(context.statusCode).toBe(400);
    expect(context.body).toEqual({
      error: {
        code: "INVALID_INSTALLATION_REQUEST",
        message: INVALID_INSTALLATION_REQUEST_MESSAGE,
        fields: null,
      },
    });
    expect(findOneAndUpdate).not.toHaveBeenCalled();
  });

  it("never echoes a supplied credential or token in a validation error", async () => {
    const credential = "z".repeat(43);
    const token = "deadbeef".repeat(8);
    const context = routeContext({
      installationCredential: credential,
      enabled: true,
      apnsToken: token,
      environment: "not-an-environment",
    });

    await createInstallationPushHandler()(context.req, context.res);

    const serialized = JSON.stringify(context.body);
    expect(serialized).not.toContain(credential);
    expect(serialized).not.toContain(token);
  });
});

describe("isNormalizedApnsToken", () => {
  it.each([
    // Apple's current 32-byte/64-character token remains accepted, but is no
    // longer the only accepted length.
    ["b".repeat(64), true],
    ["B".repeat(64), false],
    ["<" + "b".repeat(62) + ">", false],
    ["", false],
    [undefined, false],
    // Shorter and longer even-length hex tokens are accepted: nothing here
    // assumes Apple's current byte count stays fixed.
    ["ab", true],
    ["b".repeat(2), true],
    ["b".repeat(128), true],
    ["b".repeat(200), true],
    // Odd length is never a valid sequence of hex byte-pairs, regardless of
    // whether it is shorter or longer than 64.
    ["b".repeat(63), false],
    ["b".repeat(65), false],
    ["b".repeat(1), false],
    // A bound still exists, so pathological input is still rejected.
    ["b".repeat(202), false],
  ])("evaluates %j as %s", (value, expected) => {
    expect(isNormalizedApnsToken(value)).toBe(expected);
  });
});

describe("installation push public-action pause", () => {
  it("stops synchronization before its limiter, credential hashing, and any installation lookup", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    const findOneAndUpdate = vi.spyOn(Installation, "findOneAndUpdate");
    const handler = vi.fn(createInstallationPushHandler());
    const testApp = express();
    testApp.use(express.json());
    testApp.put(
      "/api/installations/push",
      pausePublicAction(
        INSTALLATION_PUSH_UNAVAILABLE_MESSAGE,
        "PUBLIC_ACTIONS_PAUSED"
      ),
      installationPushRateLimiter,
      handler
    );
    const server = createServer(testApp);
    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", resolve);
    });

    try {
      const { port } = server.address() as AddressInfo;
      const response = await fetch(
        `http://127.0.0.1:${port}/api/installations/push`,
        {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            installationCredential: validCredential,
            enabled: true,
            apnsToken: validApnsToken,
            environment: "development",
          }),
        }
      );

      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({
        error: {
          code: "PUBLIC_ACTIONS_PAUSED",
          message: INSTALLATION_PUSH_UNAVAILABLE_MESSAGE,
        },
      });
      expect(handler).not.toHaveBeenCalled();
      expect(findOneAndUpdate).not.toHaveBeenCalled();
    } finally {
      if (server.listening) {
        await new Promise<void>((resolve, reject) => {
          server.close((error) => (error ? reject(error) : resolve()));
        });
      }
    }
  });
});
