import express, { type Express, type NextFunction, type Request, type Response } from "express";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * The two verification endpoints over real HTTP, with real Express middleware.
 *
 * `participantVerificationRoute.test.ts` proves the handler contract against
 * stubbed persistence. It cannot prove anything about *parsing*, because it
 * hands the handler an already-decoded `req.body` — and the one risk this file
 * exists for lives entirely before the handler is reached: a raw six-digit
 * verification code arriving inside a body that no parser can decode.
 *
 * Every case below sends real bytes to a real listening server and asserts on
 * what came back and what was logged.
 */
const { issueChallenge, redeemCode } = vi.hoisted(() => ({
  issueChallenge: vi.fn(),
  redeemCode: vi.fn(),
}));

vi.mock("./emailHelpers.js", () => ({
  sendParticipantVerificationEmail: vi.fn(),
}));

vi.mock("./participantVerification.js", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./participantVerification.js")>();
  return {
    ...actual,
    issueParticipantVerificationChallenge: issueChallenge,
    redeemParticipantVerificationCode: redeemCode,
  };
});

import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES,
} from "./participantCredentials.js";
import {
  PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
  PARTICIPANT_VERIFICATION_ROUTE_PATH,
} from "./participantVerificationRoute.js";
import { registerParticipantVerificationRoutes } from "./participantVerificationRoutes.js";

const principal = "student@nyu.edu";
/** The value that must never reach a log, whatever the body around it does. */
const code = "424242";
const secret = Buffer.from("p".repeat(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES));

let baseUrl = "";
let close: () => Promise<void>;
const globalErrorHandler = vi.fn<(error: Error) => void>();
let consoleError: ReturnType<typeof vi.spyOn>;
let consoleLog: ReturnType<typeof vi.spyOn>;

/**
 * Uses the exact production registration function that `app.ts` calls, then
 * installs the same global parser/error shape after it. A route registered
 * after the global parser would have malformed bodies rejected by a parser
 * whose failures land in the logging handler below.
 */
function buildApp(): Express {
  const app = express();
  registerParticipantVerificationRoutes(app);

  app.use(express.json({ limit: "100kb" }));
  app.use(express.urlencoded({ extended: true, limit: "100kb" }));

  app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
    globalErrorHandler(err);
    console.error("Error:", err);
    res.status(500).json({ error: "Internal server error" });
  });

  return app;
}

async function post(
  path: string,
  body: string,
  contentType = "application/json"
) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers: { "Content-Type": contentType },
    body,
  });
  return { status: response.status, body: await response.text() };
}

function loggedText(): string {
  return JSON.stringify([
    ...consoleError.mock.calls,
    ...consoleLog.mock.calls,
  ]);
}

beforeAll(async () => {
  const server = createServer(buildApp());
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address() as AddressInfo;
  baseUrl = `http://127.0.0.1:${address.port}`;
  close = () =>
    new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve()))
    );
});

afterAll(async () => {
  await close();
});

beforeEach(() => {
  globalErrorHandler.mockReset();
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
  consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
  issueChallenge.mockResolvedValue({
    outcome: "issued",
    expiresAt: new Date("2026-08-05T15:10:00.000Z"),
    resendAvailableAt: new Date("2026-08-05T15:01:00.000Z"),
  });
  redeemCode.mockResolvedValue({ outcome: "invalidCode" });
  vi.stubEnv("PARTICIPANT_SIGNING_SECRET", secret.toString("utf8"));
  // Public actions fail closed by default, so an unpaused deployment has to be
  // stated. The paused case states the opposite for itself.
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  issueChallenge.mockReset();
  redeemCode.mockReset();
});

describe("participant verification route-local body parsing", () => {
  it("parses its own body even though the global parser is registered after it", async () => {
    const response = await post(
      PARTICIPANT_VERIFICATION_ROUTE_PATH,
      JSON.stringify({ email: "  STUDENT@NYU.EDU  " })
    );

    expect(response.status).toBe(202);
    // Reached the handler with a decoded body, which is only possible if the
    // route's own parser ran.
    expect(issueChallenge).toHaveBeenCalledWith(principal, expect.anything());
  });

  it.each([
    [
      "truncated JSON",
      `{"email":"${principal}","code":"${code}"`,
    ],
    [
      "trailing garbage after valid JSON",
      `{"email":"${principal}","code":"${code}"}<<<`,
    ],
    ["a bare fragment", `code=${code}`],
  ])(
    "answers %s carrying a raw code from inside the route, logging nothing",
    async (_label, body) => {
      const response = await post(
        PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
        body
      );

      expect(response.status).toBe(400);
      expect(JSON.parse(response.body).error.code).toBe("INVALID_REQUEST");
      // The whole point: the global handler, which logs the parser error, is
      // never reached — so the code inside the unparseable body is never
      // printed.
      expect(globalErrorHandler).not.toHaveBeenCalled();
      expect(loggedText()).not.toContain(code);
      expect(loggedText()).not.toContain(principal);
      // A body that could not be parsed is never redeemed.
      expect(redeemCode).not.toHaveBeenCalled();
    }
  );

  it("answers an oversized body from inside the route, logging nothing", async () => {
    const oversized = JSON.stringify({
      email: principal,
      code,
      padding: "x".repeat(8 * 1024),
    });

    const response = await post(
      PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
      oversized
    );

    expect(response.status).toBe(400);
    expect(JSON.parse(response.body).error.code).toBe("INVALID_REQUEST");
    expect(globalErrorHandler).not.toHaveBeenCalled();
    expect(loggedText()).not.toContain(code);
    expect(redeemCode).not.toHaveBeenCalled();
  });

  it("leaves a non-JSON content type unparsed and refuses it as a shape failure", async () => {
    // Not a parser error — nothing to reject — so it reaches the handler with
    // no usable body and is refused by the schema, still without logging.
    const response = await post(
      PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
      `email=${principal}&code=${code}`,
      "application/x-www-form-urlencoded"
    );

    expect(response.status).toBe(400);
    expect(JSON.parse(response.body).error.code).toBe("INVALID_EMAIL");
    expect(globalErrorHandler).not.toHaveBeenCalled();
    expect(loggedText()).not.toContain(code);
    expect(redeemCode).not.toHaveBeenCalled();
  });

  it("refuses a well-formed body naming an ineligible address without redeeming", async () => {
    const response = await post(
      PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
      JSON.stringify({ email: "student@gmail.com", code })
    );

    expect(response.status).toBe(400);
    expect(JSON.parse(response.body).error.code).toBe("INVALID_EMAIL");
    expect(redeemCode).not.toHaveBeenCalled();
    expect(loggedText()).not.toContain(code);
  });

  it("never echoes the submitted code back in a refusal", async () => {
    const response = await post(
      PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
      JSON.stringify({ email: principal, code })
    );

    expect(response.status).toBe(400);
    expect(response.body).not.toContain(code);
  });

  it("pauses before parsing, so a paused deployment reads no body at all", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");

    const response = await post(
      PARTICIPANT_VERIFICATION_REDEEM_ROUTE_PATH,
      `{"email":"${principal}","code":"${code}"`
    );

    // The pause answer, not the parser's — the malformed body was never read.
    expect(response.status).toBe(503);
    expect(JSON.parse(response.body).error.code).toBe("PUBLIC_ACTIONS_PAUSED");
    expect(globalErrorHandler).not.toHaveBeenCalled();
    expect(loggedText()).not.toContain(code);
    expect(redeemCode).not.toHaveBeenCalled();
  });
});

/**
 * The behavioral cases above execute production registration. These structural
 * assertions pin the one remaining app-level responsibility: calling it before
 * the global parsers.
 */
describe("app.ts registers participant verification ahead of the global parsers", () => {
  const appSource = readFileSync(
    new URL("../app.ts", import.meta.url),
    "utf8"
  );

  function indexIn(needle: string): number {
    const index = appSource.indexOf(needle);
    expect(index, `app.ts must contain ${needle}`).toBeGreaterThan(-1);
    return index;
  }

  it("calls the production registration function before express.json", () => {
    const globalParser = indexIn("app.use(express.json({ limit: '100kb' }));");
    const registration = indexIn("registerParticipantVerificationRoutes(app);");

    expect(registration).toBeLessThan(globalParser);
    expect(appSource).toContain(
      'from "./src/participantVerificationRoutes.js"'
    );
  });

  it("keeps both complete ordered chains in the production registration module", () => {
    const registrationSource = readFileSync(
      new URL("./participantVerificationRoutes.ts", import.meta.url),
      "utf8"
    );
    const registrations = registrationSource
      .split("app.post(")
      .slice(1)
      .map((block) => block.slice(0, block.indexOf(");")))
      .filter((block) => block.includes("PARTICIPANT_VERIFICATION"));

    expect(registrations).toHaveLength(2);
    for (const body of registrations) {
      expect(body).toContain("participantVerificationBodyParser");
      expect(body).toContain("participantVerificationParserError");
      // The pause guard stays ahead of the limiter, and both stay ahead of the
      // parser: a paused or throttled caller has no body read at all.
      expect(body).toMatch(/RateLimiter/);
      expect(body.indexOf("pausePublicAction")).toBeLessThan(
        body.search(/RateLimiter/)
      );
      expect(body.search(/RateLimiter/)).toBeLessThan(
        body.indexOf("participantVerificationBodyParser")
      );
      // The error boundary is last, so it can answer anything the parser or the
      // handler above it rejected.
      expect(body.indexOf("participantVerificationBodyParser")).toBeLessThan(
        body.indexOf("participantVerificationParserError")
      );
    }
  });
});
