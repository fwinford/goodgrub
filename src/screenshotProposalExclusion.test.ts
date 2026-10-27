import express, { type Request, type Response } from "express";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { providerCall, limiterWork } = vi.hoisted(() => ({
  providerCall: vi.fn(),
  limiterWork: vi.fn(),
}));
vi.mock("./screenshotProposalProvider.js", async (importOriginal) => ({
  ...await importOriginal<typeof import("./screenshotProposalProvider.js")>(),
  callScreenshotProvider: providerCall,
}));
vi.mock("./claimRoute.js", async (importOriginal) => ({
  ...await importOriginal<typeof import("./claimRoute.js")>(),
  createDay4MutationRateLimiter: () => (
    _req: Request, _res: Response, next: () => void
  ) => {
    limiterWork();
    next();
  },
}));

import { Participant } from "../models/db.js";
import {
  handleScreenshotProposal,
  registerScreenshotProposalRoute,
  SCREENSHOT_PROPOSAL_ROUTE_PATH,
  SCREENSHOT_ASSISTANCE_UNAVAILABLE_CODE,
  SCREENSHOT_ASSISTANCE_UNAVAILABLE_MESSAGE,
} from "./screenshotProposalRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import { signParticipantAuthority } from "./participantCredentials.js";

const refusal = {
  error: {
    code: SCREENSHOT_ASSISTANCE_UNAVAILABLE_CODE,
    message: SCREENSHOT_ASSISTANCE_UNAVAILABLE_MESSAGE,
    fields: null,
  },
};
const authority = signParticipantAuthority(
  new mongoose.Types.ObjectId("64f0000000000000000000c1"),
  1,
  Buffer.from("ios1-exclusion-synthetic-signing-secret")
);
let server: Server | undefined;
let origin: string;
let parserWork = vi.fn<() => void>();
let participantLookup: ReturnType<typeof vi.spyOn>;

beforeEach(async () => {
  vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
  vi.stubEnv("PARTICIPANT_SIGNING_SECRET", "ios1-exclusion-synthetic-signing-secret");
  vi.stubEnv("OPENAI_API_KEY", "synthetic-unused-provider-key");
  providerCall.mockReset();
  limiterWork.mockReset();
  parserWork = vi.fn();
  participantLookup = vi.spyOn(Participant, "findOne");
  const json = express.json;
  vi.spyOn(express, "json").mockImplementation((options) => {
    const parse = json(options);
    return (req, res, next) => {
      parserWork();
      parse(req, res, next);
    };
  });
  const app = express();
  // This is the same default registration app.ts uses: no test injection.
  registerScreenshotProposalRoute(app);
  server = createServer(app);
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

afterEach(async () => {
  if (server) {
    await new Promise<void>((resolve, reject) =>
      server!.close((error) => error ? reject(error) : resolve())
    );
  }
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

function expectNoFeatureWork() {
  expect(parserWork).not.toHaveBeenCalled();
  expect(limiterWork).not.toHaveBeenCalled();
  expect(participantLookup).not.toHaveBeenCalled();
  expect(providerCall).not.toHaveBeenCalled();
}

describe("V1 requester Screenshot Assistance exclusion", () => {
  it.each([true, false])("refuses direct HTTP invocation (authenticated=%s)", async (authenticated) => {
    const response = await fetch(origin + SCREENSHOT_PROPOSAL_ROUTE_PATH, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(authenticated ? { [PARTICIPANT_AUTHORITY_HEADER]: authority } : {}),
      },
      body: JSON.stringify({ images: [] }),
    });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual(refusal);
    expectNoFeatureWork();
  });

  it.each(["true", "false", "", "unrecognized"])("cannot be overridden by pause configuration %j", async (pause) => {
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", pause);
    vi.stubEnv("SCREENSHOT_ASSISTANCE_ENABLED", "true");
    vi.stubEnv("NODE_ENV", "test");
    const response = await fetch(origin + SCREENSHOT_PROPOSAL_ROUTE_PATH, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        [PARTICIPANT_AUTHORITY_HEADER]: authority,
        "X-Screenshot-Assistance-Enabled": "true",
        "X-App-Review": "true",
      },
      body: JSON.stringify({ enableForTests: true, enabled: true, images: [] }),
    });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual(refusal);
    expectNoFeatureWork();
  });

  it("refuses malformed, oversized and invalid compressed bodies before parsing", async () => {
    for (const request of [
      { body: "{malformed", encoding: undefined },
      { body: "A".repeat(35_000_000), encoding: undefined },
      { body: "not-gzip", encoding: "gzip" },
    ]) {
      const response = await fetch(origin + SCREENSHOT_PROPOSAL_ROUTE_PATH, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          [PARTICIPANT_AUTHORITY_HEADER]: authority,
          ...(request.encoding ? { "Content-Encoding": request.encoding } : {}),
        },
        body: request.body,
      });
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual(refusal);
    }
    expectNoFeatureWork();
  });

  it("refuses path variants and repeated attempts without rate-limit work", async () => {
    for (let index = 0; index < 12; index++) {
      const path = [
        SCREENSHOT_PROPOSAL_ROUTE_PATH,
        SCREENSHOT_PROPOSAL_ROUTE_PATH + "/",
        SCREENSHOT_PROPOSAL_ROUTE_PATH + "?enableForTests=true",
        SCREENSHOT_PROPOSAL_ROUTE_PATH.toUpperCase(),
      ][index % 4]!;
      const response = await fetch(origin + path, { method: "POST" });
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual(refusal);
    }
    expectNoFeatureWork();
  });

  it("also refuses a direct handler call without a test-only injection", async () => {
    const req = Object.assign(Object.create(express.request) as Request, {
      headers: { [PARTICIPANT_AUTHORITY_HEADER]: authority },
    });
    const res = {} as Response;
    res.status = vi.fn().mockReturnValue(res);
    res.json = vi.fn().mockReturnValue(res);
    await handleScreenshotProposal(req, res);
    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith(refusal);
    expectNoFeatureWork();
  });
});
