import express from "express";
import type { Server } from "node:http";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerReviewAuthRoutes } from "./reviewAuthRoutes.js";
import type { ReviewAuthority } from "./reviewAuthority.js";
import { REVIEW_SESSION_HEADER } from "./reviewAuthorizationAdapter.js";
import { generateReviewSession } from "./reviewCredentials.js";

const servers: Server[] = [];
const token = generateReviewSession();
const password = "fictional-not-live-credential-".repeat(2);
beforeEach(() => vi.stubEnv("NODE_ENV", "review"));
afterEach(async () => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve, reject) => {
    server.closeAllConnections();
    server.close((error) => error ? reject(error) : resolve());
  })));
});

async function setup(ready = true) {
  const authority = {
    isReady: () => true,
    login: vi.fn<ReviewAuthority["login"]>().mockResolvedValue({
      outcome: "authenticated", token, expiresAt: new Date("2030-01-01"),
      actor: { role: "requester", actorId: "private-id", principal: "requester@review.invalid", generation: "generation" },
    }),
    authenticate: vi.fn<ReviewAuthority["authenticate"]>().mockResolvedValue(null),
    logout: vi.fn<ReviewAuthority["logout"]>().mockResolvedValue(undefined),
  };
  const app = express();
  registerReviewAuthRoutes(app, authority, () => ready);
  const server = app.listen(0, "127.0.0.1");
  servers.push(server);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Missing test listener");
  return { url: `http://127.0.0.1:${address.port}/api/review`, authority };
}

describe("review authentication routes for owner registration", () => {
  it("returns a bounded session with no private actor/database fields", async () => {
    const { url, authority } = await setup();
    const response = await fetch(`${url}/login`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ role: "requester", password }),
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      token, role: "requester", generation: "generation", expiresAt: "2030-01-01T00:00:00.000Z",
    });
    expect(authority.login).toHaveBeenCalledWith("requester", password);
  });

  it.each(["production", "development"])("does not expose login in %s", async (runtime) => {
    const { url, authority } = await setup();
    vi.stubEnv("NODE_ENV", runtime);
    expect((await fetch(`${url}/login`, { method: "POST" })).status).toBe(404);
    expect(authority.login).not.toHaveBeenCalled();
  });

  it("refuses login with 503 until runtime/adapter integration is ready", async () => {
    const { url, authority } = await setup(false);
    expect((await fetch(`${url}/login`, { method: "POST" })).status).toBe(503);
    expect(authority.login).not.toHaveBeenCalled();
  });

  it("limits source-IP guesses before password derivation", async () => {
    const { url, authority } = await setup();
    authority.login.mockResolvedValue({ outcome: "invalid" });
    for (let attempt = 0; attempt < 6; attempt++) {
      const response = await fetch(`${url}/login`, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ role: "requester", password }),
      });
      expect(response.status).toBe(attempt < 5 ? 401 : 429);
    }
    expect(authority.login).toHaveBeenCalledTimes(5);
  });

  it("rejects malformed, oversized and additional input without echoing it", async () => {
    const { url, authority } = await setup();
    for (const body of [
      '{"password":', JSON.stringify({ role: "requester", password: password.repeat(100) }),
      JSON.stringify({ role: "requester", password, admin: true }),
    ]) {
      const response = await fetch(`${url}/login`, {
        method: "POST", headers: { "content-type": "application/json" }, body,
      });
      expect([400, 401]).toContain(response.status);
      expect(await response.text()).not.toContain(password);
    }
    expect(authority.login).not.toHaveBeenCalled();
  });

  it("reports infrastructure failures explicitly without exposing credentials", async () => {
    const { url, authority } = await setup();
    authority.login.mockRejectedValue(new Error(password));
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await fetch(`${url}/login`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ role: "requester", password }),
    });
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain(password);
    expect(log.mock.calls.flat().join(" ")).not.toContain(password);
    expect(log).toHaveBeenCalledOnce();
  });

  it("does not treat student credentials as a review session", async () => {
    const { url, authority } = await setup();
    expect((await fetch(`${url}/session`, {
      headers: { "x-commonplate-participant": "student-credential" },
    })).status).toBe(401);
    expect(authority.authenticate).toHaveBeenCalledWith(undefined);
  });

  it("revokes the presented session on logout without exposing it", async () => {
    const { url, authority } = await setup();
    const response = await fetch(`${url}/logout`, {
      method: "POST", headers: { [REVIEW_SESSION_HEADER]: token },
    });
    expect(await response.json()).toEqual({ signedOut: true });
    expect(authority.logout).toHaveBeenCalledWith(token);
  });
});
