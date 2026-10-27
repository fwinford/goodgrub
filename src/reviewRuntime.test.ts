import express, { type Request, type Response } from "express";
import type { Server } from "node:http";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerHealthRoutes } from "./healthRoutes.js";
import { isPublicActionsPaused } from "./publicActionsPause.js";
import { validateProductionRuntime } from "./productionRuntimeConfig.js";
import { pauseDay4Mutation } from "./claimRoute.js";
import {
  pauseRequestAction,
  registerReviewBoundary,
  type ReviewAuthorizationAdapter,
} from "./reviewRuntime.js";

const reviewEnvironment = {
  NODE_ENV: "review",
  HOST: "127.0.0.1",
  PORT: "3001",
  BASE_URL: "https://review.example.test",
  PRODUCTION_BASE_URL: "https://example.test",
  MONGO_URI: "mongodb://127.0.0.1/commonplate_review",
  PUBLIC_ACTIONS_PAUSED: "true",
  SCHEDULER_ENABLED: "false",
  CRON_ENABLED: "false",
  EXTERNAL_PROVIDERS: "disabled",
  RESEND_API_KEY: "",
  OPENAI_API_KEY: "",
  APNS_TEAM_ID: "",
  APNS_KEY_ID: "",
  APNS_BUNDLE_ID: "",
  APNS_AUTH_KEY_P8: "",
  MONITOR_EMAILS: "",
  PARTICIPANT_SIGNING_SECRET: "",
  UNSUBSCRIBE_SIGNING_SECRET: "",
};

const servers: Server[] = [];
beforeEach(() => {
  for (const [key, value] of Object.entries(reviewEnvironment)) vi.stubEnv(key, value);
});
afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve, reject) => {
    server.closeAllConnections();
    server.close((error) => error ? reject(error) : resolve());
  })));
});

async function start(adapter?: ReviewAuthorizationAdapter) {
  const app = express();
  const boundary = registerReviewBoundary(app, adapter);
  registerHealthRoutes(app, boundary.isReady);
  const handler = vi.fn((_req: Request, res: Response) => res.json({ reached: true }));
  app.post("/api/request", pauseRequestAction("paused", "PUBLIC_ACTIONS_PAUSED"), handler);
  app.post("/api/request/0123456789abcdef01234567/claim", pauseDay4Mutation, handler);
  app.post("/api/request/0123456789abcdef01234567/fulfill", handler);
  app.all("/{*path}", handler);
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Missing test listener");
  return { url: `http://127.0.0.1:${address.port}`, handler };
}

describe("review-only action perimeter", () => {
  it("refuses every action and readiness without the REV1 adapter", async () => {
    const { url, handler } = await start();
    expect((await fetch(`${url}/health/live`)).status).toBe(200);
    expect((await fetch(`${url}/health/ready`)).status).toBe(503);
    const response = await fetch(`${url}/api/request`, {
      method: "POST", headers: { "x-review": "true", authorization: "Bearer fabricated" },
    });
    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(handler).not.toHaveBeenCalled();
  });

  it.each(["request", "request/0123456789abcdef01234567/claim", "request/0123456789abcdef01234567/fulfill"])(
    "allows %s only after server authorization, while public pause stays on",
    async (path) => {
      const authorize = vi.fn(async () => true);
      const { url, handler } = await start({ isReady: () => true, authorize });
      expect(isPublicActionsPaused()).toBe(true);
      expect((await fetch(`${url}/api/${path}`, { method: "POST" })).status).toBe(200);
      expect(authorize).toHaveBeenCalledOnce();
      expect(handler).toHaveBeenCalledOnce();
    }
  );

  it("rejects invalid sessions and does not use client flags as authority", async () => {
    const { url, handler } = await start({ isReady: () => true, authorize: async () => false });
    expect((await fetch(`${url}/api/request`, { method: "POST", headers: { "x-review": "true" } })).status).toBe(401);
    expect(handler).not.toHaveBeenCalled();
  });

  it.each([
    "/api/participant/verification", "/api/participant/verification/redeem",
    "/api/installations/push", "/api/subscribe", "/api/request/screenshot-proposal",
    "/api/future-provider", "/request/new", "/unsubscribe",
  ])("does not expose %s even to an accepted session", async (path) => {
    const { url, handler } = await start({ isReady: () => true, authorize: async () => true });
    expect((await fetch(`${url}${path}`, { method: "POST" })).status).toBe(403);
    expect(handler).not.toHaveBeenCalled();
  });

  it("keeps production pause enforcement independent of the review adapter", async () => {
    vi.stubEnv("NODE_ENV", "production");
    const authorize = vi.fn(async () => true);
    const { url, handler } = await start({ isReady: () => true, authorize });
    expect((await fetch(`${url}/api/request`, { method: "POST" })).status).toBe(503);
    expect(authorize).not.toHaveBeenCalled();
    expect(handler).not.toHaveBeenCalled();
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    expect((await fetch(`${url}/api/request`, { method: "POST" })).status).toBe(200);
  });

  it.each([
    ["BASE_URL", ""], ["BASE_URL", "http://review.example.test"],
    ["BASE_URL", "https://example.test"], ["PRODUCTION_BASE_URL", ""],
    ["BASE_URL", "https://review.example.test:8443"], ["PORT", "3000"],
    ["MONGO_URI", "mongodb://127.0.0.1/commonplate_production"],
    ["EXTERNAL_PROVIDERS", "enabled"], ["RESEND_API_KEY", "forbidden"],
    ["OPENAI_API_KEY", "forbidden"], ["APNS_AUTH_KEY_P8", "forbidden"],
    ["PARTICIPANT_SIGNING_SECRET", "forbidden"], ["SCHEDULER_ENABLED", "true"],
    ["CRON_ENABLED", "true"], ["PUBLIC_ACTIONS_PAUSED", "false"],
  ])("rejects unsafe review configuration %s", async (key, value) => {
    vi.stubEnv(key, value);
    expect(validateProductionRuntime()).not.toBeNull();
    const { url, handler } = await start({ isReady: () => true, authorize: async () => true });
    expect((await fetch(`${url}/health/ready`)).status).toBe(503);
    expect((await fetch(`${url}/api/request`, { method: "POST" })).status).toBe(503);
    expect(handler).not.toHaveBeenCalled();
  });
});
