import express from "express";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CREATE_UNAVAILABLE_MESSAGE,
  PUBLIC_ACTIONS_PAUSED_ENV,
  SUBSCRIBE_UNAVAILABLE_MESSAGE,
  isPublicActionsPaused,
  pausePublicAction,
} from "./publicActionsPause.js";

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("public actions pause configuration", () => {
  it("stays paused when the variable is missing, empty, or unrecognized", () => {
    expect(isPublicActionsPaused({})).toBe(true);
    expect(isPublicActionsPaused({ [PUBLIC_ACTIONS_PAUSED_ENV]: "" })).toBe(
      true
    );
    expect(
      isPublicActionsPaused({ [PUBLIC_ACTIONS_PAUSED_ENV]: "maybe" })
    ).toBe(true);
    expect(
      isPublicActionsPaused({ [PUBLIC_ACTIONS_PAUSED_ENV]: "off" })
    ).toBe(true);
  });

  it("stays paused for explicit true values", () => {
    expect(isPublicActionsPaused({ [PUBLIC_ACTIONS_PAUSED_ENV]: "true" })).toBe(
      true
    );
    expect(isPublicActionsPaused({ [PUBLIC_ACTIONS_PAUSED_ENV]: "TRUE" })).toBe(
      true
    );
    expect(isPublicActionsPaused({ [PUBLIC_ACTIONS_PAUSED_ENV]: "1" })).toBe(
      true
    );
  });

  it("resumes only for explicit false values, tolerating case and padding", () => {
    for (const value of ["false", "FALSE", " false ", "False", "0"]) {
      expect(
        isPublicActionsPaused({ [PUBLIC_ACTIONS_PAUSED_ENV]: value })
      ).toBe(false);
    }
  });

  it("reads the current environment at call time", () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    expect(isPublicActionsPaused()).toBe(false);

    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    expect(isPublicActionsPaused()).toBe(true);
  });
});

async function callGuardedRoute(message: string, errorCode?: string): Promise<{
  status: number;
  body: unknown;
  handler: ReturnType<typeof vi.fn>;
}> {
  const testApp = express();
  testApp.use(express.json());

  const handler = vi.fn((_req, res) => res.status(201).json({ created: true }));
  testApp.post("/guarded", pausePublicAction(message, errorCode), handler);

  const server = createServer(testApp);
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });

  try {
    const { port } = server.address() as AddressInfo;
    const response = await fetch(`http://127.0.0.1:${port}/guarded`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ any: "payload" }),
    });
    return { status: response.status, body: await response.json(), handler };
  } finally {
    if (server.listening) {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    }
  }
}

describe("pausePublicAction middleware", () => {
  it("refuses create with the Day 3 envelope and never reaches the handler while paused", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");

    const result = await callGuardedRoute(
      CREATE_UNAVAILABLE_MESSAGE,
      "PUBLIC_ACTIONS_PAUSED"
    );

    expect(result.status).toBe(503);
    expect(result.body).toEqual({
      error: {
        code: "PUBLIC_ACTIONS_PAUSED",
        message: CREATE_UNAVAILABLE_MESSAGE,
      },
    });
    expect(result.handler).not.toHaveBeenCalled();
  });

  it("carries the caller's message", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");

    const result = await callGuardedRoute(SUBSCRIBE_UNAVAILABLE_MESSAGE);

    expect(result.body).toEqual({ error: SUBSCRIBE_UNAVAILABLE_MESSAGE });
  });

  it("passes through to the handler when explicitly resumed", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");

    const result = await callGuardedRoute(CREATE_UNAVAILABLE_MESSAGE);

    expect(result.status).toBe(201);
    expect(result.body).toEqual({ created: true });
    expect(result.handler).toHaveBeenCalledOnce();
  });

  it("stops signup before its limiter and all handler-owned work", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    const testApp = express();
    testApp.use(express.json());
    const limiter = vi.fn((_req, _res, next) => next());
    const subscribe = vi.fn((_req, res) => res.status(202).json({ ok: true }));
    testApp.post(
      "/api/subscribe",
      pausePublicAction(SUBSCRIBE_UNAVAILABLE_MESSAGE),
      limiter,
      subscribe
    );
    const server = createServer(testApp);
    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", resolve);
    });

    try {
      const { port } = server.address() as AddressInfo;
      const response = await fetch(`http://127.0.0.1:${port}/api/subscribe`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: "not-valid" }),
      });

      expect(response.status).toBe(503);
      expect(limiter).not.toHaveBeenCalled();
      expect(subscribe).not.toHaveBeenCalled();
    } finally {
      if (server.listening) {
        await new Promise<void>((resolve, reject) => {
          server.close((error) => (error ? reject(error) : resolve()));
        });
      }
    }
  });
});
