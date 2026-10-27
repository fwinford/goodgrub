import express, { type Request, type Response } from "express";
import mongoose, { type Connection } from "mongoose";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Server } from "node:http";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { REVIEW_DATABASE } from "../models/reviewDb.js";
import { ReviewAuthority } from "./reviewAuthority.js";
import { REVIEW_SESSION_HEADER } from "./reviewAuthorizationAdapter.js";
import { generateReviewSession } from "./reviewCredentials.js";
import {
  registerReviewRuntimeIntegration, type ReviewRuntimeDependencies,
} from "./reviewRuntimeIntegration.js";

// Opt-in cross-worktree proof reads INF1's actual uncommitted modules. A fresh
// clone does not require another lane's worktree and cannot claim this evidence.
const uri = process.env.MONGO_INTEGRATION_URI;
const inf1 = process.env.REV1_INF1_WORKTREE;
const describeIntegration = uri && inf1 ? describe : describe.skip;
const servers: Server[] = [];
let connection: Connection;
let runtime: {
  registerReviewBoundary: ReviewRuntimeDependencies["registerReviewBoundary"];
  pauseRequestAction(message: string, code?: string): express.RequestHandler;
};
let config: Pick<ReviewRuntimeDependencies, "validateProductionRuntime">;
let providers: { assertExternalProvidersAllowed(): void };
let jobs: { registerScheduledJob(expression: string, job: () => void, options: { enabled: boolean }): unknown };

describeIntegration("REV1 composition with the actual local INF1 boundary and replica set", () => {
  beforeAll(async () => {
    const load = (file: string) => import(/* @vite-ignore */ pathToFileURL(resolve(inf1!, "src", file)).href);
    [runtime, config, providers, jobs] = await Promise.all([
      load("reviewRuntime.ts"), load("productionRuntimeConfig.ts"),
      load("externalProviders.ts"), load("scheduledJobs.ts"),
    ]);
    connection = await mongoose.createConnection(uri!, { dbName: REVIEW_DATABASE }).asPromise();
  });
  beforeEach(() => {
    for (const [key, value] of Object.entries({
      NODE_ENV: "review", HOST: "127.0.0.1", PORT: "3001",
      BASE_URL: "https://review.example.test", PRODUCTION_BASE_URL: "https://student.example.test",
      MONGO_URI: uri!.replace(/\/commonplate_claim_test(?=\?)/, "/commonplate_review"),
      PUBLIC_ACTIONS_PAUSED: "true", SCHEDULER_ENABLED: "false", CRON_ENABLED: "false",
      EXTERNAL_PROVIDERS: "disabled", RESEND_API_KEY: "", OPENAI_API_KEY: "",
      APNS_TEAM_ID: "", APNS_KEY_ID: "", APNS_BUNDLE_ID: "", APNS_AUTH_KEY_P8: "",
      MONITOR_EMAILS: "", PARTICIPANT_SIGNING_SECRET: "", UNSUBSCRIBE_SIGNING_SECRET: "",
    })) vi.stubEnv(key, value);
  });
  afterEach(async () => {
    await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve, reject) => {
      server.closeAllConnections();
      server.close((error) => error ? reject(error) : resolve());
    })));
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });
  afterAll(async () => { await connection?.close(); });

  async function setup(database = connection) {
    const app = express();
    let startupReady = true;
    const integration = registerReviewRuntimeIntegration(app, {
      connection: database,
      ...config,
      ...runtime,
      isRuntimeReady: () => startupReady,
    });
    const handler = vi.fn((_req: Request, res: Response) => res.json({ reached: true }));
    app.get("/health/live", (_req, res) => res.send("ok"));
    app.get("/health/ready", (_req, res) => res.sendStatus(integration.isReady() ? 200 : 503));
    app.post("/api/request", runtime.pauseRequestAction("paused", "PUBLIC_ACTIONS_PAUSED"), handler);
    app.use((_req, res) => res.sendStatus(404));
    const server = app.listen(0, "127.0.0.1");
    servers.push(server);
    await new Promise<void>((resolve) => server.once("listening", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Missing test listener");
    return {
      integration, handler, url: `http://127.0.0.1:${address.port}`,
      setStartupReady(value: boolean) { startupReady = value; },
    };
  }

  it("initializes only review collections but never readies auth/lifecycle without the real actor binding", async () => {
    expect(config.validateProductionRuntime()).toBeNull();
    const { integration, url, handler, setStartupReady } = await setup();
    await Promise.all([integration.initialize(), integration.initialize()]);
    const collections = Object.keys(connection.models);
    expect(collections.sort()).toEqual(["ReviewAccount", "ReviewGeneration", "ReviewLoginLimit", "ReviewSession"]);
    const authority = new ReviewAuthority(connection);
    await authority.initialize();
    expect(authority.isReady()).toBe(true);
    expect(integration.isReady()).toBe(false);
    expect((await fetch(`${url}/health/live`)).status).toBe(200);
    expect((await fetch(`${url}/health/ready`)).status).toBe(503);
    for (const [method, path] of [
      ["POST", "/api/review/login"], ["GET", "/api/review/session"],
      ["POST", "/api/review/logout"], ["GET", "/api/requests"], ["POST", "/api/request"],
      ["POST", "/api/participant/verification"], ["POST", "/api/installations/push"],
      ["POST", "/api/request/screenshot-proposal"],
    ]) {
      const response = await fetch(`${url}${path}`, { method });
      expect(response.status).toBe(503);
      expect(response.headers.get("cache-control")).toBe("no-store");
    }
    expect(handler).not.toHaveBeenCalled();
    expect(process.env.PUBLIC_ACTIONS_PAUSED).toBe("true");
    setStartupReady(false);
    expect(integration.isReady()).toBe(false);
  });

  it("never attempts reviewer or student authentication while actor binding is absent", async () => {
    const { integration, url, handler } = await setup();
    await integration.initialize();
    const authenticate = vi.spyOn(ReviewAuthority.prototype, "authenticate");
    const login = vi.spyOn(ReviewAuthority.prototype, "login");
    const password = "fictional-integration-credential-".repeat(2);
    const credentialHeaders: Record<string, string>[] = [
      { [REVIEW_SESSION_HEADER]: generateReviewSession() },
      { "x-commonplate-participant": "ordinary-student-credential" },
    ];
    for (const headers of credentialHeaders) {
      expect((await fetch(`${url}/api/requests`, { headers })).status).toBe(503);
      expect((await fetch(`${url}/api/review/session`, { headers })).status).toBe(503);
    }
    expect((await fetch(`${url}/api/review/login`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ role: "requester", password }),
    })).status).toBe(503);
    expect(handler).not.toHaveBeenCalled();
    expect(authenticate).not.toHaveBeenCalled();
    expect(login).not.toHaveBeenCalled();
  });

  it.each([
    ["EXTERNAL_PROVIDERS", "enabled"], ["PUBLIC_ACTIONS_PAUSED", "false"],
    ["SCHEDULER_ENABLED", "true"], ["BASE_URL", ""], ["PARTICIPANT_SIGNING_SECRET", "not-a-live-secret"],
  ])("refuses unsafe %s before authority initialization", async (key, value) => {
    vi.stubEnv(key, value);
    const { integration, url } = await setup();
    await expect(integration.initialize()).rejects.toThrow("configuration is unsafe");
    expect(integration.isReady()).toBe(false);
    expect((await fetch(`${url}/api/review/login`, { method: "POST" })).status).toBe(503);
  });

  it("rejects a connected student database even when the configured URI names review", async () => {
    const student = await mongoose.createConnection(uri!, { dbName: "commonplate_claim_test" }).asPromise();
    try {
      const { integration } = await setup(student);
      await expect(integration.initialize()).rejects.toThrow("isolated review database");
      expect(student.models).toEqual({});
      expect(integration.isReady()).toBe(false);
    } finally {
      await student.close();
    }
  });

  it("loses authority on connection loss and cannot expose auth after a runtime change", async () => {
    const isolated = await mongoose.createConnection(uri!, { dbName: REVIEW_DATABASE }).asPromise();
    const { integration, url } = await setup(isolated);
    try {
      await integration.initialize();
      await isolated.close();
      expect((await fetch(`${url}/api/review/session`)).status).toBe(503);
      vi.stubEnv("NODE_ENV", "production");
      expect((await fetch(`${url}/api/review/login`, { method: "POST" })).status).toBe(404);
      expect(integration.isReady()).toBe(false);
    } finally {
      await isolated.close();
    }
  });

  it("leaves production routing and public-action pause independent of reviewer auth", async () => {
    vi.stubEnv("NODE_ENV", "production");
    const { integration, url, handler } = await setup();
    await integration.initialize();
    expect((await fetch(`${url}/api/review/login`, { method: "POST" })).status).toBe(404);
    expect(handler).not.toHaveBeenCalled();
    expect((await fetch(`${url}/api/request`, { method: "POST" })).status).toBe(503);
    expect(handler).not.toHaveBeenCalled();
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    expect((await fetch(`${url}/api/request`, { method: "POST" })).status).toBe(200);
    expect(handler).toHaveBeenCalledOnce();
  });

  it("preserves actual INF1 provider and scheduler guards without making network calls", async () => {
    const job = vi.fn();
    expect(() => providers.assertExternalProvidersAllowed()).toThrow("External providers are disabled");
    expect(jobs.registerScheduledJob("* * * * *", job, { enabled: true })).toBeUndefined();
    expect(job).not.toHaveBeenCalled();
  });
});
