import express from "express";
import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it } from "vitest";
import type { Server } from "node:http";
import { fileURLToPath } from "node:url";
import { registerHealthRoutes } from "./healthRoutes.js";

let server: Server | undefined;

afterEach(async () => {
  if (!server) return;
  const currentServer = server;
  server = undefined;
  await new Promise<void>((resolve, reject) => {
    currentServer.close((error) => (error ? reject(error) : resolve()));
  });
});

async function startHealthServer(isReady: () => boolean): Promise<string> {
  const app = express();
  registerHealthRoutes(app, isReady);
  server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolve, reject) => {
    server?.once("listening", resolve);
    server?.once("error", reject);
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("health test server did not bind a TCP port");
  }
  return `http://127.0.0.1:${address.port}`;
}

describe("health routes", () => {
  it("keeps liveness separate from readiness and refuses readiness before startup gates", async () => {
    const baseUrl = await startHealthServer(() => false);

    const live = await fetch(`${baseUrl}/health/live`);
    expect(live.status).toBe(200);
    expect(await live.text()).toBe("ok");

    const ready = await fetch(`${baseUrl}/health/ready`);
    expect(ready.status).toBe(503);
    expect(await ready.json()).toEqual({ status: "not-ready" });

    const legacy = await fetch(`${baseUrl}/health`);
    expect(legacy.status).toBe(200);
    expect(await legacy.text()).toBe("ok");
  });

  it("reports ready only after the startup predicate passes", async () => {
    let startupGatesPassed = false;
    const baseUrl = await startHealthServer(() => startupGatesPassed);

    expect((await fetch(`${baseUrl}/health/ready`)).status).toBe(503);
    startupGatesPassed = true;
    const response = await fetch(`${baseUrl}/health/ready`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ready" });
  });

  it("connects application readiness to completed startup and the live Mongo connection", () => {
    const appSource = readFileSync(
      fileURLToPath(new URL("../app.ts", import.meta.url)),
      "utf8"
    );

    expect(appSource).toContain("registerHealthRoutes(");
    expect(appSource).toContain(
      "() => runtimeReady && mongoose.connection.readyState === 1"
    );
    expect(appSource).toContain("runtimeReady = true;");
    expect(appSource.indexOf("runtimeReady = true;")).toBeGreaterThan(
      appSource.indexOf("await mongoose.connect(MONGO_URI, mongoOptions.options);")
    );
    expect(appSource.indexOf("runtimeReady = true;")).toBeGreaterThan(
      appSource.indexOf("await establishRequestOperationLedger();")
    );
  });
});
