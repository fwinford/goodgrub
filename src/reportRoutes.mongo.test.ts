import type { Request, Response } from "express";
import { randomBytes, scryptSync } from "node:crypto";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => {
  process.env.RESEND_API_KEY ??= "re_cp3_mongo_test_placeholder";
});
import { Participant, Request as MealRequest } from "../models/db.js";
import {
  MODERATION_MODELS,
  ModerationReport,
  ReportEvidence,
  ReportSubmissionLedger,
  establishModerationIndexes,
} from "../models/moderation.js";
import { REPORT_REASONS } from "./moderationConstants.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { submitParticipantReport, reconcileParticipantReportOperation } from "./reportRoutes.js";
import { mintReportAuthorization } from "./reportAuthorization.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_participant_reports`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;
const signingSecretText = "cp3-report-participant-signing-secret";
const signingSecret = Buffer.from(signingSecretText);
const requesterId = new mongoose.Types.ObjectId("64e0000000000000000000a1");
const helperId = new mongoose.Types.ObjectId("64e0000000000000000000b2");
const unrelatedId = new mongoose.Types.ObjectId("64e0000000000000000000c3");
const testKeyringJson = JSON.stringify({
  current: "k1",
  keys: { k1: Buffer.alloc(32, 0x71).toString("base64url") },
});
const passphraseHash = scryptSync("cp3-report-test-passphrase", Buffer.alloc(16, 0x41), 32, {
  N: 16_384,
  r: 8,
  p: 1,
});

function setEnvironment(): void {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, signingSecretText);
  vi.stubEnv("MODERATOR_ORIGIN", "https://moderator.example");
  vi.stubEnv(
    "MODERATOR_PASSPHRASE_HASH",
    [
      "scrypt-v1",
      16_384,
      8,
      1,
      Buffer.alloc(16, 0x41).toString("base64url"),
      passphraseHash.toString("base64url"),
    ].join("$")
  );
  vi.stubEnv("MODERATOR_TOTP_SECRET", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ");
  vi.stubEnv("REPORT_ALERT_RECIPIENT", "moderator@example.org");
  vi.stubEnv("SUPPORT_EMAIL", "support@example.org");
  vi.stubEnv("SAFETY_IDENTITY_KEYRING", testKeyringJson);
}

interface Call {
  statusCode: number;
  body: unknown;
  headers: Map<string, unknown>;
}

function makeCall(
  requestId: string,
  participantId?: mongoose.Types.ObjectId,
  body?: unknown
): { req: Request; res: Response; call: Call } {
  const call: Call = { statusCode: 200, body: undefined, headers: new Map() };
  const res = {} as Response;
  res.status = vi.fn((status: number) => {
    call.statusCode = status;
    return res;
  }) as never;
  res.json = vi.fn((value: unknown) => {
    call.body = value;
    return res;
  }) as never;
  res.setHeader = vi.fn((name: string, value: unknown) => {
    call.headers.set(name.toLowerCase(), value);
    return res;
  }) as never;
  const req = {
    params: { id: requestId },
    headers: participantId
      ? {
          [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
            participantId,
            1,
            signingSecret
          ),
        }
      : {},
    body,
  } as unknown as Request;
  return { req, res, call };
}

function operationId(): string {
  return `rp1.${Date.now()}.${randomBytes(18).toString("base64url")}`;
}

async function createRequest(overrides: Record<string, unknown> = {}) {
  const now = new Date();
  return MealRequest.create({
    vendor: "Jasper Kane Cafe",
    food: "Rice bowl",
    pickupWindowText: "ASAP",
    email: "report-requester@nyu.edu",
    status: "open",
    visibleFrom: new Date(now.getTime() - 60_000),
    expiresAt: new Date(now.getTime() + 60 * 60_000),
    deleteAt: new Date(now.getTime() + 90 * 24 * 60 * 60_000),
    requesterParticipantId: requesterId,
    ...overrides,
  });
}

describeMongo(
  "real MongoDB participant report submission and recovery",
  { timeout: 60_000 },
  () => {
    beforeAll(async () => {
      setEnvironment();
      await mongoose.connect(mongoUri!);
      await Participant.createIndexes();
      await MealRequest.syncIndexes();
      await establishModerationIndexes();
    });

    beforeEach(async () => {
      setEnvironment();
      await MealRequest.deleteMany({});
      for (const model of MODERATION_MODELS) await model.deleteMany({});
      await Participant.deleteMany({});
      for (const [id, email] of [
        [requesterId, "requester-report@nyu.edu"],
        [helperId, "helper-report@nyu.edu"],
        [unrelatedId, "other-report@nyu.edu"],
      ] as const) {
        await Participant.create({
          _id: id,
          email,
          verifiedAt: new Date(),
          authorityVersion: 1,
        });
      }
    });

    afterEach(() => {
      vi.restoreAllMocks();
    });

    afterAll(async () => {
      await mongoose.disconnect();
      vi.unstubAllEnvs();
    });

    it("derives the reported participant from a live interaction and keeps reporter data out of case records", async () => {
      const request = await createRequest();
      const operation = operationId();
      const sender = vi.fn(async () => {});
      const spoofed = makeCall(String(request._id), helperId, {
        operationId: operationId(),
        reason: REPORT_REASONS[0],
        reportedParticipantId: unrelatedId,
        reportedEmail: "attacker@example.org",
      });
      await submitParticipantReport(spoofed.req, spoofed.res, sender);
      expect(spoofed.call.statusCode).toBe(400);
      expect(await ModerationReport.countDocuments({})).toBe(0);

      const { req, res, call } = makeCall(String(request._id), helperId, {
        operationId: operation,
        reason: REPORT_REASONS[0],
        explanation: "<script>private explanation</script>",
      });

      await submitParticipantReport(req, res, sender);
      expect(call.statusCode).toBe(200);
      expect(call.body).toEqual({ outcome: "reported" });
      expect(call.headers.get("cache-control")).toBe("private, no-store");
      expect(sender).toHaveBeenCalledTimes(1);

      const report = await ModerationReport.findOne().lean();
      const evidence = await ReportEvidence.find().lean();
      const ledger = await ReportSubmissionLedger.findOne().lean();
      expect(report).not.toBeNull();
      expect(report).not.toHaveProperty("reporter");
      expect(report).not.toHaveProperty("reporterId");
      expect(report).not.toHaveProperty("reportedEmail");
      expect(report).not.toHaveProperty("reportedParticipantId");
      expect(evidence.map((entry) => entry.text)).toContain(
        "<script>private explanation</script>"
      );
      expect(JSON.stringify(ledger)).not.toContain(String(helperId));
      expect(JSON.stringify(ledger)).not.toContain(String(request._id));
      expect(JSON.stringify(ledger)).not.toContain(String(report!._id));
      expect(ledger).not.toHaveProperty("caseId");
      expect(ledger).not.toHaveProperty("requestId");
    });

    it("requires details for Other concern and refuses a repeat report for the same request", async () => {
      const request = await createRequest();
      const sender = vi.fn(async () => {});
      for (const explanation of [undefined, "", "   "]) {
        const missing = makeCall(String(request._id), helperId, {
          operationId: operationId(),
          reason: "Other concern",
          ...(explanation === undefined ? {} : { explanation }),
        });
        await submitParticipantReport(missing.req, missing.res, sender);
        expect(missing.call.statusCode).toBe(400);
      }
      expect(await ModerationReport.countDocuments({})).toBe(0);

      const first = makeCall(String(request._id), helperId, {
        operationId: operationId(),
        reason: "Other concern",
        explanation: "Details",
      });
      await submitParticipantReport(first.req, first.res, sender);
      expect(first.call.statusCode).toBe(200);

      const repeat = makeCall(String(request._id), helperId, {
        operationId: operationId(),
        reason: REPORT_REASONS[0],
      });
      await submitParticipantReport(repeat.req, repeat.res, sender);
      expect(repeat.call.statusCode).toBe(429);
      expect(await ModerationReport.countDocuments({})).toBe(1);
    });

    it("replays one operation without a duplicate report or alert and reconciles its created outcome", async () => {
      const request = await createRequest();
      const body = {
        operationId: operationId(),
        reason: REPORT_REASONS[1],
      };
      const sender = vi.fn(async () => {});
      const first = makeCall(String(request._id), helperId, body);
      await submitParticipantReport(first.req, first.res, sender);
      const replay = makeCall(String(request._id), helperId, body);
      await submitParticipantReport(replay.req, replay.res, sender);

      expect(first.call.body).toEqual({ outcome: "reported" });
      expect(replay.call.body).toEqual({ outcome: "reported" });
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect(sender).toHaveBeenCalledTimes(1);

      const reconcile = makeCall("", helperId);
      reconcile.req.params = { operationId: body.operationId } as never;
      await reconcileParticipantReportOperation(reconcile.req, reconcile.res);
      expect(reconcile.call.body).toEqual({ outcome: "created" });
    });

    it("consumes a post-Block handoff only with the first committed report", async () => {
      const request = await createRequest();
      const keyring = JSON.parse(testKeyringJson);
      const parsedKeyring = {
        currentKeyId: keyring.current as string,
        keys: new Map([[keyring.current as string, Buffer.from(keyring.keys.k1, "base64url")]]),
      };
      const handoff = mintReportAuthorization(
        parsedKeyring,
        String(helperId),
        String(request._id),
        new Date(),
        undefined,
        String(requesterId)
      );
      const sender = vi.fn(async () => {});
      const first = makeCall(String(request._id), helperId, {
        operationId: operationId(),
        reason: REPORT_REASONS[2],
        reportAuthorization: handoff,
      });
      await submitParticipantReport(first.req, first.res, sender);
      expect(first.call.body).toEqual({ outcome: "reported" });

      const second = makeCall(String(request._id), helperId, {
        operationId: operationId(),
        reason: REPORT_REASONS[2],
        reportAuthorization: handoff,
      });
      await submitParticipantReport(second.req, second.res, sender);
      expect(second.call.statusCode).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect(sender).toHaveBeenCalledTimes(1);
    });

    it("returns a generic missing-target refusal for unauthorized contexts and unavailable reporting config", async () => {
      const request = await createRequest();
      const unauthorized = makeCall(String(request._id), requesterId, {
        operationId: operationId(),
        reason: REPORT_REASONS[3],
      });
      await submitParticipantReport(unauthorized.req, unauthorized.res);
      expect(unauthorized.call.statusCode).toBe(404);
      expect(JSON.stringify(unauthorized.call.body)).not.toMatch(/reporter|suspend|moderation/i);
      expect(await ModerationReport.countDocuments({})).toBe(0);

      const available = makeCall(String(request._id), helperId, {
        operationId: operationId(),
        reason: REPORT_REASONS[4],
        explanation: "Details",
      });
      vi.stubEnv("MODERATOR_ORIGIN", "");
      await submitParticipantReport(available.req, available.res);
      expect(available.call.statusCode).toBe(503);
      expect(await ModerationReport.countDocuments({})).toBe(0);
      expect(await ReportSubmissionLedger.countDocuments({})).toBe(0);
    });

    it("lets the requester report the helper only while pickup is unconfirmed, and refuses afterwards", async () => {
      const request = await createRequest({
        status: "placed",
        helperParticipantId: helperId,
      });
      const sender = vi.fn(async () => {});
      const eligible = makeCall(String(request._id), requesterId, {
        operationId: operationId(),
        reason: REPORT_REASONS[0],
      });
      await submitParticipantReport(eligible.req, eligible.res, sender);
      expect(eligible.call.statusCode).toBe(200);
      expect(eligible.call.body).toEqual({ outcome: "reported" });
      expect(await ModerationReport.countDocuments({})).toBe(1);

      await MealRequest.updateOne(
        { _id: request._id },
        { $set: { requesterPickupConfirmedAt: new Date() } }
      );
      const after = makeCall(String(request._id), requesterId, {
        operationId: operationId(),
        reason: REPORT_REASONS[1],
      });
      await submitParticipantReport(after.req, after.res, sender);
      expect(after.call.statusCode).toBe(404);
      expect(JSON.stringify(after.call.body)).not.toMatch(/helper|pickup|block|suspend/i);
      expect(await ModerationReport.countDocuments({})).toBe(1);
    });

    it("refuses requester reports to non-participants, unplaced requests and revoked authority", async () => {
      const placed = await createRequest({ status: "placed", helperParticipantId: helperId });
      const stranger = makeCall(String(placed._id), unrelatedId, {
        operationId: operationId(),
        reason: REPORT_REASONS[0],
      });
      await submitParticipantReport(stranger.req, stranger.res);
      expect(stranger.call.statusCode).toBe(404);

      const unplaced = await createRequest({ status: "claimed", helperParticipantId: helperId });
      const early = makeCall(String(unplaced._id), requesterId, {
        operationId: operationId(),
        reason: REPORT_REASONS[0],
      });
      await submitParticipantReport(early.req, early.res);
      expect(early.call.statusCode).toBe(404);

      await Participant.updateOne({ _id: requesterId }, { $set: { authorityVersion: 2 } });
      const revoked = makeCall(String(placed._id), requesterId, {
        operationId: operationId(),
        reason: REPORT_REASONS[0],
      });
      await submitParticipantReport(revoked.req, revoked.res);
      expect(revoked.call.statusCode).not.toBe(200);
      expect(await ModerationReport.countDocuments({})).toBe(0);
    });

    it("does not commit a successful operation when the reported Participant is missing", async () => {
      const request = await createRequest({ requesterParticipantId: unrelatedId });
      await Participant.deleteOne({ _id: unrelatedId });
      const submission = makeCall(String(request._id), helperId, {
        operationId: operationId(),
        reason: REPORT_REASONS[0],
      });
      await submitParticipantReport(submission.req, submission.res);
      expect(submission.call.statusCode).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(0);
      expect(await ReportSubmissionLedger.countDocuments({})).toBe(0);
    });
  }
);
