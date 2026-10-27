import express from "express";
import { request as httpRequest } from "node:http";
import type { Request, Response } from "express";
import { describe, expect, it, vi } from "vitest";
import { createProductionLegacyWebPageGuard } from "./legacyWebPageGuard.js";

function invokeGuard(path: string, nodeEnv: string) {
  const response = { sendStatus: vi.fn() } as unknown as Response;
  const next = vi.fn();
  const request = { path } as Request;

  createProductionLegacyWebPageGuard({ NODE_ENV: nodeEnv })(
    request,
    response,
    next
  );

  return { response, next };
}

function getPath(
  port: number,
  path: string
): Promise<{ statusCode?: number; body: string }> {
  return new Promise((resolve, reject) => {
    const request = httpRequest(
      { hostname: "127.0.0.1", port, path, method: "GET" },
      (response) => {
        let body = "";
        response.setEncoding("utf8");
        response.on("data", (chunk: string) => {
          body += chunk;
        });
        response.on("end", () => {
          resolve({ statusCode: response.statusCode, body });
        });
      }
    );
    request.on("error", reject);
    request.end();
  });
}

describe("production legacy web page guard", () => {
  it.each([
    "/",
    "/home.html",
    "/request/new",
    "/request/new/",
    "/new-request.html",
    "/fulfill.html",
    "/request/abc123/fulfill",
    "/request/abc123/fulfill/",
  ])("returns 404 for obsolete production page %s", (path) => {
    const { response, next } = invokeGuard(path, "production");

    expect(response.sendStatus).toHaveBeenCalledWith(404);
    expect(next).not.toHaveBeenCalled();
  });

  it.each([
    "/api/request/new",
    "/api/requests",
    "/api/subscribe/confirm",
    "/unsubscribe",
    "/health/ready",
  ])(
    "passes non-page production route %s through",
    (path) => {
      const { response, next } = invokeGuard(path, "production");

      expect(response.sendStatus).not.toHaveBeenCalled();
      expect(next).toHaveBeenCalledOnce();
    }
  );

  it("leaves legacy pages available outside production", () => {
    const { response, next } = invokeGuard("/", "development");

    expect(response.sendStatus).not.toHaveBeenCalled();
    expect(next).toHaveBeenCalledOnce();
  });

  it.each([
    "/request/%2f/fulfill",
    "/request/a%2fb/fulfill",
    "/request/./fulfill",
    "/request/../fulfill",
  ])(
    "blocks legacy fulfillment path variants at the HTTP boundary: %s",
    async (path) => {
      const app = express();
      app.use(createProductionLegacyWebPageGuard({ NODE_ENV: "production" }));
      app.get("/request/:id/fulfill", (_request, response) =>
        response.status(200).send("legacy fulfillment page")
      );
      const server = app.listen(0, "127.0.0.1");
      await new Promise<void>((resolve) => server.once("listening", resolve));
      const address = server.address();
      if (!address || typeof address === "string") {
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve()))
        );
        throw new Error("test server did not bind a TCP port");
      }

      try {
        const response = await getPath(address.port, path);
        expect(response.statusCode).toBe(404);
        expect(response.body).not.toContain("legacy fulfillment page");
      } finally {
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve()))
        );
      }
    }
  );
});
