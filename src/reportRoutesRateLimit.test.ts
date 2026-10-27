import express from "express";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.hoisted(() => {
  process.env.RESEND_API_KEY ??= "re_cp3_rate_limit_test_placeholder";
});

import { registerReportRoutes } from "./reportRoutes.js";

describe("report-operation reconciliation rate limit", () => {
  let baseUrl = "";
  let server: ReturnType<typeof createServer>;

  beforeAll(async () => {
    const app = express();
    registerReportRoutes(app);
    server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  afterAll(async () => {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve()))
    );
  });

  it("limits fresh reconciliation operations before they can write terminal ledger rows", async () => {
    const statuses: number[] = [];
    for (let attempt = 0; attempt < 11; attempt += 1) {
      const operationId = `rp1.${Date.now()}.${Buffer.alloc(18, attempt).toString("base64url")}`;
      const response = await fetch(
        `${baseUrl}/api/participant/report-operations/${operationId}/reconcile`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{}",
        }
      );
      statuses.push(response.status);
    }

    expect(statuses.slice(0, 10)).toEqual(Array(10).fill(401));
    expect(statuses[10]).toBe(429);
  });
});
