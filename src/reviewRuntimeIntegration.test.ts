import express from "express";
import mongoose from "mongoose";
import type { Server } from "node:http";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  registerReviewRuntimeIntegration, type ReviewRuntimeDependencies,
} from "./reviewRuntimeIntegration.js";

const servers: Server[] = [];
afterEach(async () => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve, reject) => {
    server.closeAllConnections();
    server.close((error) => error ? reject(error) : resolve());
  })));
});

async function setup(runtime = "review") {
  vi.stubEnv("NODE_ENV", runtime);
  const app = express();
  const connection = mongoose.createConnection();
  const dependencies = {
    connection,
    validateProductionRuntime: vi.fn((): string | null => null),
    isRuntimeReady: vi.fn(() => true),
    registerReviewBoundary: vi.fn<ReviewRuntimeDependencies["registerReviewBoundary"]>(
      (target, adapter) => {
        target.use((_req, res) => res.status(418).end());
        return { isReady: () => adapter?.isReady() ?? true };
      }
    ),
  };
  const integration = registerReviewRuntimeIntegration(app, dependencies);
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Missing test listener");
  return { integration, dependencies, connection, url: `http://127.0.0.1:${address.port}` };
}

describe("REV1 composition before INF1 incorporation", () => {
  it.each(["production", "development"])("does not register auth or initialize models in %s", async (runtime) => {
    const { integration, dependencies, connection, url } = await setup(runtime);
    await integration.initialize();
    for (const [method, path] of [
      ["POST", "login"], ["GET", "session"], ["POST", "logout"],
    ]) {
      expect((await fetch(`${url}/api/review/${path}`, { method })).status).toBe(418);
    }
    expect(dependencies.registerReviewBoundary.mock.calls[0][1]).toBeUndefined();
    expect(dependencies.validateProductionRuntime).not.toHaveBeenCalled();
    expect(connection.models).toEqual({});
  });

  it("registers bounded auth before the perimeter but refuses it without startup/binding", async () => {
    const { integration, dependencies, url } = await setup();
    const adapter = dependencies.registerReviewBoundary.mock.calls[0][1];
    expect(adapter).toBeDefined();
    expect(adapter?.isReady()).toBe(false);
    for (const [method, path] of [
      ["POST", "login"], ["GET", "session"], ["POST", "logout"],
    ]) {
      const response = await fetch(`${url}/api/review/${path}`, { method });
      expect(response.status).toBe(503);
      expect(response.headers.get("cache-control")).toBe("no-store");
    }
    expect(integration.isReady()).toBe(false);
  });

  it("rejects unsafe configuration before touching the connection", async () => {
    const { integration, dependencies, connection } = await setup();
    dependencies.validateProductionRuntime.mockReturnValue("unsafe");
    await expect(integration.initialize()).rejects.toThrow("configuration is unsafe");
    expect(connection.models).toEqual({});
    expect(integration.isReady()).toBe(false);
  });

  it("does not initialize or become ready with a disconnected database", async () => {
    const { integration, connection } = await setup();
    await expect(integration.initialize()).rejects.toThrow("isolated review database");
    expect(connection.models).toEqual({});
    expect(integration.isReady()).toBe(false);
  });

  it("reports readiness callback failures without leaking configuration", async () => {
    const { integration, dependencies } = await setup();
    dependencies.isRuntimeReady.mockImplementation(() => { throw new Error("private-value"); });
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(integration.isReady()).toBe(false);
    expect(log).toHaveBeenCalledExactlyOnceWith("[review] runtime integration readiness failed");
  });
});
