import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import express from "express";
import type { Server } from "node:http";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Participant } from "../models/db.js";
import { resolveParticipantAuthority } from "./participantAuthorityGate.js";
import { generateReviewSession } from "./reviewCredentials.js";

let server: Server | undefined;
afterEach(async () => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  if (server) {
    const running = server;
    running.closeAllConnections();
    await new Promise<void>((resolve, reject) =>
      running.close((error) => error ? reject(error) : resolve()));
    server = undefined;
  }
});

describe("independent REV1 isolation boundary", () => {
  it("rejects a review session at the real production participant gate before a student lookup", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("PARTICIPANT_SIGNING_SECRET", "fictional-unit-test-signing-secret-32-bytes");
    const lookup = vi.spyOn(Participant, "findOne");
    const app = express();
    app.get("/student-authority", async (req, res) =>
      res.json(await resolveParticipantAuthority(req)));
    server = app.listen(0, "127.0.0.1");
    await new Promise<void>((resolve) => server!.once("listening", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Missing test listener");
    const response = await fetch(`http://127.0.0.1:${address.port}/student-authority`, {
      headers: { "x-commonplate-participant": generateReviewSession() },
    });
    expect(await response.json()).toEqual({ ok: false, refusal: "invalid" });
    expect(lookup).not.toHaveBeenCalled();
  });

  it("has no provider, scheduler, student-model or administrative operation dependencies", () => {
    // Source evidence only. Integrated transport/egress and database privilege
    // proof still belong to the INF1 + REV1 candidate.
    const files = [
      "../models/reviewDb.ts", "./reviewCredentials.ts", "./reviewAuthority.ts",
      "./reviewAuthRoutes.ts", "./reviewAuthorizationAdapter.ts",
    ];
    for (const file of files) {
      const source = readFileSync(fileURLToPath(new URL(file, import.meta.url)), "utf8");
      expect(source).not.toMatch(/from ["'][^"']*(?:models\/db|resend|apns|screenshotProposal|notifySubscribers|node-cron|child_process)/i);
      expect(source).not.toMatch(/\b(?:fetch|dropDatabase|dropCollection|spawn|schedule)\s*\(/);
      expect(source).not.toMatch(/process\.env\.PUBLIC_ACTIONS_PAUSED\s*=/);
    }
  });
});
