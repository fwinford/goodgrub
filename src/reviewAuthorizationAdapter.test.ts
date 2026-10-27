import express, { type Request } from "express";
import type { Server } from "node:http";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createReviewAuthorizationAdapter, REVIEW_SESSION_HEADER } from "./reviewAuthorizationAdapter.js";
import { generateReviewSession } from "./reviewCredentials.js";
import type { ReviewActor } from "./reviewAuthority.js";

const id = "0123456789abcdef01234567";
const token = generateReviewSession();
const servers: Server[] = [];

beforeEach(() => vi.stubEnv("NODE_ENV", "review"));
afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve, reject) => {
    server.closeAllConnections();
    server.close((error) => error ? reject(error) : resolve());
  })));
});

async function setup(role: ReviewActor["role"], bound = true) {
  const actor: ReviewActor = { role, actorId: id, principal: `${role}@review.invalid`, generation: "generation" };
  const authenticate = vi.fn(async (submitted: unknown) => submitted === token ? actor : null);
  const bind = vi.fn(async () => true);
  const adapter = createReviewAuthorizationAdapter(
    { isReady: () => true, authenticate },
    bound ? { isReady: () => true, authorize: bind } : undefined
  );
  let last: Request | undefined;
  const app = express();
  app.all("/{*path}", async (req, res) => {
    last = req;
    const authorized = await adapter.authorize(req);
    res.status(authorized ? 200 : 401).json({ authorized });
  });
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Missing test listener");
  return { url: `http://127.0.0.1:${address.port}`, adapter, authenticate, bind, last: () => last };
}

describe("INF1-compatible review authority adapter", () => {
  it("is default closed without the real lifecycle binding", async () => {
    const { url, adapter, authenticate } = await setup("requester", false);
    expect(adapter.isReady()).toBe(false);
    expect((await fetch(`${url}/api/request`, { method: "POST", headers: { [REVIEW_SESSION_HEADER]: token } })).status).toBe(401);
    expect(authenticate).not.toHaveBeenCalled();
  });

  it.each(["production", "test", "development"])("cannot activate in %s", async (runtime) => {
    const { url, adapter, authenticate } = await setup("requester");
    vi.stubEnv("NODE_ENV", runtime);
    expect(adapter.isReady()).toBe(false);
    expect((await fetch(`${url}/api/request`, { method: "POST", headers: { [REVIEW_SESSION_HEADER]: token } })).status).toBe(401);
    expect(authenticate).not.toHaveBeenCalled();
  });

  it.each([
    ["requester", "POST", "/api/request", 200],
    ["helper", "POST", "/api/request", 401],
    ["requester", "POST", `/api/request/${id}/claim`, 401],
    ["helper", "POST", `/api/request/${id}/claim`, 200],
    ["requester", "POST", `/api/request/${id}/fulfill`, 401],
    ["helper", "POST", `/api/request/${id}/fulfill`, 200],
    ["helper", "POST", `/api/request/${id}/edit`, 401],
    ["requester", "POST", `/api/request/${id}/withdraw`, 200],
    ["helper", "GET", `/api/request/${id}`, 200],
    ["requester", "POST", "/api/participant/verification", 401],
    ["helper", "POST", "/api/installations/push", 401],
    ["requester", "POST", "/api/request/screenshot-proposal", 401],
    ["helper", "GET", `/api/request/${id}/messages`, 401],
    ["requester", "POST", "/api/admin/reset", 401],
  ] as const)("enforces %s %s %s", async (role, method, path, expected) => {
    const { url, adapter, last } = await setup(role);
    expect((await fetch(`${url}${path}`, { method, headers: { [REVIEW_SESSION_HEADER]: token } })).status).toBe(expected);
    const req = last();
    if (!req) throw new Error("Missing captured request");
    expect(adapter.actorForRequest(req)?.role).toBe(expected === 200 ? role : undefined);
    expect(Object.isFrozen(adapter.actorForRequest(req))).toBe(true);
  });

  it("does not trust reviewer flags or student authority", async () => {
    const { url, bind } = await setup("requester");
    const cases: Record<string, string>[] = [
      { "x-review": "true" },
      { "x-commonplate-participant": "student-authority" },
      { [REVIEW_SESSION_HEADER]: token, "x-commonplate-participant": "student-authority" },
    ];
    for (const headers of cases) {
      expect((await fetch(`${url}/api/request`, { method: "POST", headers })).status).toBe(401);
    }
    expect(bind).not.toHaveBeenCalled();
  });

  it("retains no actor if ownership binding denies the request", async () => {
    const { url, adapter, bind, last } = await setup("helper");
    bind.mockResolvedValue(false);
    expect((await fetch(`${url}/api/request/${id}`, { headers: { [REVIEW_SESSION_HEADER]: token } })).status).toBe(401);
    const req = last();
    if (!req) throw new Error("Missing captured request");
    expect(adapter.actorForRequest(req)).toBeUndefined();
  });
});
