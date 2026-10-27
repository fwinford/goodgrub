import { once } from "node:events";
import { randomBytes, scryptSync } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import express from "express";
import mongoose, { Types } from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => {
  process.env.RESEND_API_KEY ??= "re_cp6_integration_placeholder";
});
import { Fulfillment, Participant, ParticipantBlock, Request as MealRequest, RequestParticipation } from "../models/db.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";
import {
  ConversationMessage, MessageConversation, MessageReceipt, initializeMessagingIndexes,
} from "../models/messaging.js";
import {
  MODERATION_MODELS, ReportEvidence, ModerationReport, establishModerationIndexes,
} from "../models/moderation.js";
import { createMessagingService, type MessagingPolicy } from "./messaging.js";
import { createMessagingPolicy } from "./messagingPolicy.js";
import { installMessagingLifecycle } from "./messagingSafety.js";
import { uninstallMessagingLifecycleHooks } from "./messagingLifecycle.js";
import { isEitherParticipantSuspended, reinstateParticipant, suspendHelper, suspendRequester } from "./moderationEnforcement.js";
import { readSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";
import { runModerationTransaction } from "./safetyIdentity.js";
import { signParticipantAuthority } from "./participantCredentials.js";
import { CLAIM_ROUTE_PATH, CLAIM_RELEASE_ROUTE_PATH, claimRequest, releaseClaim } from "./claimRoute.js";
import { confirmPlacedOrderPickup } from "./placedOrderRoutes.js";
import {
  PARTICIPANT_BLOCK_ROUTE_PATH, REQUEST_BLOCK_ROUTE_PATH, createParticipantBlock, deleteParticipantBlock,
} from "./participantBlockRoute.js";
import { REPORT_SUBMISSION_ROUTE_PATH, reportBodyParser, submitParticipantReport } from "./reportRoutes.js";
import { REQUEST_WITHDRAW_ROUTE_PATH } from "./requestUpdateRoute.js";
import * as requestUpdate from "./requestUpdateRoute.js";
import { REPORT_REASONS } from "./moderationConstants.js";
import { mintReportAuthorization } from "./reportAuthorization.js";
import { sweepMessageCleanup } from "./messaging.js";
import { recomputeCaseClocks } from "./moderationClocks.js";
import { ReportSubmissionLedger } from "../models/moderation.js";

const uri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = uri ? describe : describe.skip;
const secret = "messaging-integration-signing-secret";
const credential = (id: Types.ObjectId) => signParticipantAuthority(id, 1, Buffer.from(secret));
const keyringJson = JSON.stringify({
  current: "k1", keys: { k1: Buffer.alloc(32, 0x72).toString("base64url") },
});
const salt = Buffer.alloc(16, 0x42);
const passphraseHash = scryptSync("cp6-integration-passphrase", salt, 32, { N: 16_384, r: 8, p: 1 });

function stubEnvironment(): void {
  vi.stubEnv("PARTICIPANT_SIGNING_SECRET", secret);
  vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "claim-token-test-secret-material-32b");
  vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
  vi.stubEnv("MODERATOR_ORIGIN", "https://moderator.example");
  vi.stubEnv("MODERATOR_PASSPHRASE_HASH", [
    "scrypt-v1", 16_384, 8, 1, salt.toString("base64url"), passphraseHash.toString("base64url"),
  ].join("$"));
  vi.stubEnv("MODERATOR_TOTP_SECRET", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ");
  vi.stubEnv("REPORT_ALERT_RECIPIENT", "moderator@example.org");
  vi.stubEnv("SUPPORT_EMAIL", "support@example.org");
  vi.stubEnv("SAFETY_IDENTITY_KEYRING", keyringJson);
}

describeMongo("MSG1 CP6 messaging integration with real Report, Block, suspension and lifecycle writers", () => {
  const owner = new Types.ObjectId();
  const helper = new Types.ObjectId();
  const replacement = new Types.ObjectId();
  const stranger = new Types.ObjectId();
  const policy = createMessagingPolicy(async () => "none", isEitherParticipantSuspended);
  const service = createMessagingService(policy);
  let server: Server;
  let base: string;
  let requestId: string;

  const call = async (method: string, path: string, actor: Types.ObjectId, body: unknown = {}) => {
    const response = await fetch(`${base}${path}`, {
      method,
      headers: { "x-commonplate-participant": credential(actor), "Content-Type": "application/json" },
      ...(method === "GET" || method === "DELETE" ? {} : { body: JSON.stringify(body) }),
    });
    return { status: response.status, body: (await response.json().catch(() => ({}))) as Record<string, unknown> };
  };
  const claim = (actor = helper) => call("POST", `/api/request/${requestId}/claim`, actor);
  const release = (actor = helper) => call("POST", `/api/request/${requestId}/claim/release`, actor);
  const pickup = () => call("POST", `/api/participant/placed-orders/${requestId}/pickup-confirmation`, owner);
  const block = (actor: Types.ObjectId, body: unknown = {}) => call("POST", `/api/request/${requestId}/block`, actor, body);
  const report = (actor: Types.ObjectId, extra: Record<string, unknown> = {}, id = requestId) =>
    call("POST", `/api/request/${id}/report`, actor, {
      operationId: `rp1.${Date.now()}.${randomBytes(18).toString("base64url")}`,
      reason: REPORT_REASONS[0],
      ...extra,
    });
  const send = (actor: Types.ObjectId, helperId: Types.ObjectId, text: string) =>
    service.send(credential(actor), requestId, String(helperId), crypto.randomUUID(), text);
  const open = (actor: Types.ObjectId) => service.open(credential(actor), requestId);
  const seed = async (count: number, helperId = helper) => {
    for (let i = 1; i <= count; i++) await send(i % 2 ? helperId : owner, helperId, `m${i}`);
  };
  const conversation = () => MessageConversation.findOne({ requestId, helperParticipantId: helper }).lean();
  const messageContext = () => ReportEvidence.findOne({ kind: "message-context" }).lean();
  const toPlaced = async () => {
    await Fulfillment.updateOne(
      { requestId: new Types.ObjectId(requestId) },
      { $setOnInsert: { orderNumber: "123", etaText: "15 minutes", placedAt: new Date() } },
      { upsert: true }
    );
    await MealRequest.collection.updateOne(
      { _id: new Types.ObjectId(requestId) }, { $set: { status: "placed" } }
    );
  };
  const chatDenied = async () => {
    for (const actor of [owner, helper]) {
      await expect(send(actor, helper, "after")).rejects.toThrow("unavailable");
      await expect(service.read(credential(actor), requestId, String(helper))).rejects.toThrow("unavailable");
    }
  };

  beforeAll(async () => {
    stubEnvironment();
    const isolated = new URL(uri!);
    isolated.pathname = "/commonplate_msg1_cp6_integration";
    await mongoose.connect(isolated.toString());
    await Participant.createIndexes();
    await ParticipantBlock.createIndexes();
    await MealRequest.createIndexes();
    await RequestParticipation.createIndexes();
    await Fulfillment.createIndexes();
    await initializeMessagingIndexes();
    await establishModerationIndexes();
    const app = express();
    app.use(express.json({ limit: "16kb" }));
    const wrap = (handler: (req: express.Request, res: express.Response) => unknown) =>
      (req: express.Request, res: express.Response, next: express.NextFunction) => {
        Promise.resolve(handler(req, res)).catch(next);
      };
    app.post(CLAIM_ROUTE_PATH, wrap(claimRequest));
    app.post(CLAIM_RELEASE_ROUTE_PATH, wrap(releaseClaim));
    app.post("/api/participant/placed-orders/:requestId/pickup-confirmation", wrap(confirmPlacedOrderPickup));
    app.post(REQUEST_BLOCK_ROUTE_PATH, wrap(createParticipantBlock));
    app.delete(PARTICIPANT_BLOCK_ROUTE_PATH, wrap(deleteParticipantBlock));
    app.post(REPORT_SUBMISSION_ROUTE_PATH, reportBodyParser, wrap((req, res) =>
      submitParticipantReport(req, res, async () => {})));
    app.post(REQUEST_WITHDRAW_ROUTE_PATH, wrap(requestUpdate.withdrawRequest));
    server = createServer(app);
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test HTTP server missing");
    base = `http://127.0.0.1:${address.port}`;
  });
  afterAll(async () => {
    uninstallMessagingLifecycleHooks();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });
  beforeEach(async () => {
    stubEnvironment();
    installMessagingLifecycle(policy);
    const models: Array<mongoose.Model<any>> = [ConversationMessage, MessageReceipt, MessageConversation,
      RequestParticipation, ParticipantBlock, MealRequest, Fulfillment, Participant, ...MODERATION_MODELS];
    for (const model of models) {
      await model.deleteMany({});
    }
    await prepareParticipantIdentityMongoTestState();
    for (const id of [owner, helper, replacement, stranger]) {
      await Participant.create({ _id: id, email: `${id}@nyu.edu`, verifiedAt: new Date(), authorityVersion: 1 });
    }
    const future = new Date(Date.now() + 3600_000);
    const request = await MealRequest.create({
      vendor: "Palladium", food: "Rice bowl", pickupWindowText: "ASAP",
      email: `${owner}@nyu.edu`, requesterParticipantId: owner,
      status: "open", visibleFrom: new Date(Date.now() - 60_000),
      expiresAt: future, deleteAt: new Date(Date.now() + 90 * 86_400_000),
    });
    requestId = String(request._id);
    expect((await claim()).status).toBe(200);
  });
  afterEach(() => { vi.restoreAllMocks(); });

  describe("U1.2 report authorization windows", () => {
    it("lets the requester report the bound helper from the start of a live reservation", async () => {
      expect((await report(owner)).status).toBe(200);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect((await messageContext())?.messageContext).toEqual({
        captureStatus: "complete",
        messages: [],
      });
    });

    it("refuses requester reporting after the reservation lapses, and strangers throughout", async () => {
      expect((await report(stranger)).status).toBe(404);
      await MealRequest.collection.updateOne(
        { _id: new Types.ObjectId(requestId) }, { $set: { claimExpiresAt: new Date(Date.now() - 1000) } }
      );
      expect((await report(owner)).status).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(0);
    });

    it("preserves U1.2 reports of an available requester without chat evidence", async () => {
      expect((await release()).status).toBe(200);
      expect((await report(stranger)).status).toBe(200);
      expect((await messageContext())?.messageContext).toMatchObject({
        captureStatus: "incomplete",
        captureReason: "chat-not-authorized",
        messages: [],
      });
    });

    it("lets the placed helper and requester report until pickup, never after (Option A)", async () => {
      await toPlaced();
      expect((await report(helper)).status).toBe(200);
      expect((await report(owner)).status).toBe(200);
      expect((await report(stranger)).status).toBe(404);
      expect((await pickup()).status).toBe(200);
      expect((await report(helper)).status).toBe(404);
      expect((await report(owner)).status).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(2);
    });
  });

  describe("U1.2 transactional message-evidence capture", () => {
    it("captures exactly the ten newest committed messages by role, with no identifiers", async () => {
      await seed(12);
      expect((await report(helper)).status).toBe(200);
      const evidence = await messageContext();
      const messages = evidence!.messageContext!.messages;
      expect(evidence!.messageContext!.captureStatus).toBe("complete");
      expect(messages.map(m => m.text)).toEqual(Array.from({ length: 10 }, (_, i) => `m${i + 3}`));
      expect(messages.map(m => m.sender)).toEqual(["reporter", "reported", "reporter", "reported", "reporter",
        "reported", "reporter", "reported", "reporter", "reported"]);
      const serialized = JSON.stringify(evidence);
      for (const id of [owner, helper]) expect(serialized).not.toContain(String(id));
      expect(serialized).not.toContain("clientMessageId");
      expect(evidence!.deleteAt).toBeUndefined();
      // Chat evidence is capture-only: the live conversation is untouched.
      expect(await ConversationMessage.countDocuments({})).toBe(12);
    });

    it("captures for the requester and records a genuinely empty opened conversation", async () => {
      await seed(3);
      expect((await report(owner)).status).toBe(200);
      expect((await messageContext())!.messageContext).toMatchObject({
        captureStatus: "complete",
        messages: expect.arrayContaining([expect.objectContaining({ text: "m1" })]),
      });
    });

    it("records a successful empty capture for an opened conversation with no committed messages", async () => {
      await open(owner);
      expect(await ConversationMessage.countDocuments({})).toBe(0);
      expect((await report(helper)).status).toBe(200);
      expect((await messageContext())?.messageContext).toEqual({
        captureStatus: "complete",
        messages: [],
      });
    });

    it("never captures a previous helper's conversation for a replacement helper", async () => {
      await seed(4);
      expect((await release()).status).toBe(200);
      expect((await claim(replacement)).status).toBe(200);
      expect((await report(owner)).status).toBe(200);
      expect((await messageContext())?.messageContext).toEqual({
        captureStatus: "complete",
        messages: [],
      });
    });

    it("is not captured when the conversation is closed and no handoff lease exists", async () => {
      await seed(3);
      await toPlaced();
      expect((await pickup()).status).toBe(200);
      await expect(send(helper, helper, "after")).rejects.toThrow("unavailable");
      // Test-only reopening of the report window; the closed chat grants no read.
      await MealRequest.collection.updateOne(
        { _id: new Types.ObjectId(requestId) }, { $unset: { requesterPickupConfirmedAt: "" } }
      );
      expect((await report(helper)).status).toBe(200);
      expect((await messageContext())?.messageContext).toMatchObject({
        captureStatus: "incomplete",
        captureReason: "conversation-closed",
        messages: [],
      });
    });

    it("persists an incomplete status and only safely available messages when history has a gap", async () => {
      await seed(3);
      const activeConversation = await conversation();
      await ConversationMessage.deleteOne({
        conversationId: activeConversation!._id,
        sequence: 2,
      });
      expect((await report(helper)).status).toBe(200);
      expect((await messageContext())?.messageContext).toMatchObject({
        captureStatus: "incomplete",
        captureReason: "message-history-incomplete",
        messages: [
          { text: "m1" },
          { text: "m3" },
        ],
      });
    });

    it("keeps an authorized Report available after capture lookup failure", async () => {
      await seed(2);
      const handoff = (await block(owner)).body.reportAuthorization as string;
      vi.spyOn(ConversationMessage, "find").mockImplementationOnce((() => {
        throw new Error("injected capture lookup failure");
      }) as never);
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect(await ReportSubmissionLedger.countDocuments({})).toBe(1);
      expect((await messageContext())?.messageContext).toMatchObject({
        captureStatus: "incomplete",
        captureReason: "capture-failed",
        messages: [],
      });
      expect((await conversation())?.reportLeaseConsumedAt).toBeFalsy();
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(1);
    });

    it("an idempotent replay and a failed report never consume or double-capture", async () => {
      await seed(2);
      const operationId = `rp1.${Date.now()}.${randomBytes(18).toString("base64url")}`;
      const first = await call("POST", `/api/request/${requestId}/report`, helper, { operationId, reason: REPORT_REASONS[0] });
      const replay = await call("POST", `/api/request/${requestId}/report`, helper, { operationId, reason: REPORT_REASONS[0] });
      expect(first.status).toBe(200);
      expect(replay.status).toBe(200);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect(await ReportEvidence.countDocuments({ kind: "message-context" })).toBe(1);
    });
  });

  describe("U1.3 reservation-start Block, permanent closure and report-only handoff", () => {
    it("the real Block writer persists closure before any chat is opened; real Unblock never removes it", async () => {
      const raw = () => MessageConversation.collection.findOne({ requestId: new Types.ObjectId(requestId) });
      expect(await raw()).toBeNull();
      const blocked = await block(owner);
      expect(blocked.status).toBe(200);
      expect(typeof blocked.body.reportAuthorization).toBe("string");
      // Observed directly, before any messaging call that could create a tombstone.
      const closed = await raw();
      expect(closed!.closedAt).toBeTruthy();
      expect(String(closed!.helperParticipantId)).toBe(String(helper));
      const row = await ParticipantBlock.findOne().lean();
      expect((await call("DELETE", `/api/participant/blocks/${row!._id}`, owner)).status).toBe(200);
      expect(await ParticipantBlock.countDocuments({})).toBe(0);
      expect((await raw())!.closedAt).toBeTruthy();
      expect(String((await raw())!._id)).toBe(String(closed!._id));
      expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
      await chatDenied();
      await expect(open(owner)).rejects.toThrow("unavailable");
      await expect(open(helper)).rejects.toThrow("unavailable");
    });

    it("closure survives Unblock and the request reopening; replacement helpers get a fresh chat", async () => {
      await seed(3);
      expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(2);
      expect((await block(owner)).status).toBe(200);
      expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
      expect(await ConversationMessage.countDocuments({ conversationId: (await conversation())!._id })).toBe(3);
      await chatDenied();
      const row = await ParticipantBlock.findOne().lean();
      expect((await call("DELETE", `/api/participant/blocks/${row!._id}`, owner)).status).toBe(200);
      await chatDenied();
      expect((await conversation())?.closedAt).toBeTruthy();
      expect((await release()).status).toBe(200);
      expect((await claim(replacement)).status).toBe(200);
      const fresh = await open(replacement);
      expect(fresh.conversationId).not.toBe(String((await conversation())!._id));
      await chatDenied();
    });

    it("post-Block handoff report captures ten messages once, restores no chat access", async () => {
      await seed(12);
      const blocked = await block(owner);
      const handoff = blocked.body.reportAuthorization as string;
      expect((await conversation())!.reportLeaseUntil).toBeTruthy();
      await chatDenied();
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect((await messageContext())!.messageContext).toMatchObject({
        captureStatus: "complete",
        messages: expect.any(Array),
      });
      expect((await messageContext())!.messageContext!.messages).toHaveLength(10);
      expect((await conversation())!.reportLeaseConsumedAt).toBeTruthy();
      // The same handoff cannot be used again: no second report or capture.
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect(await ReportEvidence.countDocuments({ kind: "message-context" })).toBe(1);
      await chatDenied();
    });

    it("an expired lease still lets the handoff report proceed, without message context", async () => {
      await seed(3);
      const handoff = (await block(owner)).body.reportAuthorization as string;
      await MessageConversation.collection.updateOne(
        { requestId: new Types.ObjectId(requestId) }, { $set: { reportLeaseUntil: new Date(Date.now() - 1000) } }
      );
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect((await messageContext())?.messageContext).toMatchObject({
        captureStatus: "incomplete",
        captureReason: "handoff-unavailable",
        messages: [],
      });
    });

    it("records unavailable evidence when the authorized handoff conversation source is missing", async () => {
      const handoff = (await block(owner)).body.reportAuthorization as string;
      await MessageConversation.deleteOne({
        requestId: new Types.ObjectId(requestId),
        helperParticipantId: helper,
      });
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect((await messageContext())?.messageContext).toMatchObject({
        captureStatus: "incomplete",
        captureReason: "conversation-unavailable",
        messages: [],
      });
    });

    it("helper Block with a confirmed No releases the reservation yet keeps the handoff capture", async () => {
      await seed(4);
      const blocked = await block(helper, { externalOrderPlaced: false });
      expect(blocked.status).toBe(200);
      expect((await MealRequest.findById(requestId).lean())!.status).toBe("open");
      await chatDenied();
      const handoff = blocked.body.reportAuthorization as string;
      expect((await report(helper, { reportAuthorization: handoff })).status).toBe(200);
      expect((await messageContext())!.messageContext!.messages).toHaveLength(4);
    });

    it("Block racing an in-flight send: no message commits after the Block", async () => {
      await open(owner);
      let enter!: () => void;
      let resume!: () => void;
      const entered = new Promise<void>(r => { enter = r; });
      const released = new Promise<void>(r => { resume = r; });
      let first = true;
      const paused: MessagingPolicy = {
        async authorize(request, session, now) {
          const result = await policy.authorize(request, session, now);
          if (first) { first = false; enter(); await released; }
          return result;
        },
      };
      const racing = createMessagingService(paused)
        .send(credential(helper), requestId, String(helper), crypto.randomUUID(), "late")
        .then(() => "sent", () => "denied");
      await entered;
      expect((await block(owner)).status).toBe(200);
      resume();
      expect(await racing).toBe("denied");
      expect(await ConversationMessage.countDocuments({})).toBe(0);
    });
  });

  describe("report-only handoff identity, cutoff and transactional safety", () => {
    const reportedIdentity = async (id: Types.ObjectId) =>
      (await Participant.findById(id).select("+safetyIdentityRef").lean())!.safetyIdentityRef;
    const handoffFor = async (actor: Types.ObjectId, extra: Record<string, unknown> = {}) => {
      const blocked = await block(actor, extra);
      expect(blocked.status).toBe(200);
      return blocked.body.reportAuthorization as string;
    };

    it("Block → helper release → original-helper report within ten minutes reaches the original helper", async () => {
      await seed(4);
      const handoff = await handoffFor(owner);
      expect((await release()).status).toBe(200);
      expect((await MealRequest.findById(requestId).lean())!.status).toBe("open");
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect(await reportedIdentity(helper)).toBeTruthy();
      expect(await reportedIdentity(replacement)).toBeUndefined();
      expect((await messageContext())!.messageContext!.messages.map(m => m.text)).toEqual(["m1", "m2", "m3", "m4"]);
      await chatDenied();
    });

    it("Block → release → replacement → report never redirects and never leaks replacement messages", async () => {
      await seed(3);
      const handoff = await handoffFor(owner);
      expect((await release()).status).toBe(200);
      expect((await claim(replacement)).status).toBe(200);
      await send(owner, replacement, "replacement-only-secret");
      await send(replacement, replacement, "replacement-reply");
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect(await reportedIdentity(helper)).toBeTruthy();
      expect(await reportedIdentity(replacement)).toBeUndefined();
      const capture = (await messageContext())!.messageContext!;
      expect(capture.captureStatus).toBe("complete");
      const evidence = JSON.stringify(capture);
      expect(evidence).toContain("m3");
      expect(evidence).not.toContain("replacement");
      // The replacement relationship stays private and live.
      expect((await service.read(credential(replacement), requestId, String(replacement))).messages).toHaveLength(2);
    });

    it("refuses foreign, forged-counterpart, expired and already-consumed authority", async () => {
      await seed(2);
      const handoff = await handoffFor(owner);
      expect((await report(stranger, { reportAuthorization: handoff })).status).toBe(404);
      expect((await report(helper, { reportAuthorization: handoff })).status).toBe(404);
      const keyring = readSafetyIdentityKeyring();
      const expired = mintReportAuthorization(
        keyring, String(owner), requestId, new Date(Date.now() - 11 * 60_000), undefined, String(helper)
      );
      expect((await report(owner, { reportAuthorization: expired })).status).toBe(404);
      const wrongCounterpart = mintReportAuthorization(
        keyring, String(owner), requestId, new Date(), undefined, String(replacement)
      );
      expect((await report(owner, { reportAuthorization: wrongCounterpart })).status).toBe(404);
      const unbound = mintReportAuthorization(keyring, String(owner), requestId, new Date());
      expect((await report(owner, { reportAuthorization: unbound })).status).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(0);
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect(await ReportEvidence.countDocuments({ kind: "message-context" })).toBe(1);
    });

    it("concurrent duplicate submissions create exactly one report and one capture", async () => {
      await seed(3);
      const handoff = await handoffFor(owner);
      const sameOperation = `rp1.${Date.now()}.${randomBytes(18).toString("base64url")}`;
      const duplicates = await Promise.all([1, 2, 3].map(() =>
        call("POST", `/api/request/${requestId}/report`, owner,
          { operationId: sameOperation, reason: REPORT_REASONS[0], reportAuthorization: handoff })));
      const distinct = await Promise.all([1, 2].map(() => report(owner, { reportAuthorization: handoff })));
      for (const outcome of [...duplicates, ...distinct]) expect([200, 404]).toContain(outcome.status);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect(await ReportEvidence.countDocuments({ kind: "message-context" })).toBe(1);
      expect(await ReportSubmissionLedger.countDocuments({})).toBe(1);
    });

    it("pickup then Report: the cutoff denies, and no report, evidence or consumption exists", async () => {
      await seed(3);
      await toPlaced();
      const handoff = await handoffFor(owner);
      expect((await pickup()).status).toBe(200);
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(404);
      expect((await report(helper)).status).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(0);
      expect(await ReportEvidence.countDocuments({})).toBe(0);
      expect((await conversation())!.reportLeaseConsumedAt).toBeFalsy();
    });

    it("Report then pickup: the report commits with its evidence and pickup still succeeds", async () => {
      await seed(3);
      await toPlaced();
      expect((await report(helper)).status).toBe(200);
      expect((await pickup()).status).toBe(200);
      expect(await ModerationReport.countDocuments({})).toBe(1);
      expect((await messageContext())!.messageContext!.messages).toHaveLength(3);
    });

    it("concurrent pickup and Report never produces an inconsistent or failed outcome", async () => {
      await seed(3);
      await toPlaced();
      const [picked, reported] = await Promise.all([pickup(), report(helper)]);
      expect(picked.status).toBe(200);
      expect([200, 404]).toContain(reported.status);
      expect(await ModerationReport.countDocuments({})).toBe(reported.status === 200 ? 1 : 0);
      expect(await ReportEvidence.countDocuments({ kind: "message-context" })).toBe(reported.status === 200 ? 1 : 0);
    });

    it("helper Block after pickup closes chat but mints no authority and captures nothing", async () => {
      await seed(3);
      await toPlaced();
      expect((await pickup()).status).toBe(200);
      const blocked = await block(helper);
      expect(blocked.status).toBe(200);
      expect(blocked.body.reportAuthorization).toBeUndefined();
      expect((await conversation())!.reportLeaseUntil).toBeFalsy();
      expect((await report(helper)).status).toBe(404);
      expect(await ModerationReport.countDocuments({})).toBe(0);
      expect(await ReportEvidence.countDocuments({})).toBe(0);
      await chatDenied();
    });

    it("a stranger helper's Block of a placed request mints no authority", async () => {
      await toPlaced();
      const blocked = await block(stranger);
      expect(blocked.body.reportAuthorization).toBeUndefined();
    });

    it("a failure after capture rolls back the report, evidence, ledger row and lease consumption", async () => {
      await seed(3);
      const handoff = await handoffFor(owner);
      const original = Participant.updateOne.bind(Participant);
      vi.spyOn(Participant, "updateOne").mockImplementation(((filter: unknown, update: any, ...rest: unknown[]) => {
        if (update?.$set?.safetyIdentityRef) throw new Error("injected failure after capture");
        return (original as any)(filter, update, ...rest);
      }) as never);
      const failed = await report(owner, { reportAuthorization: handoff });
      expect(failed.status).not.toBe(200);
      vi.restoreAllMocks();
      expect(await ModerationReport.countDocuments({})).toBe(0);
      expect(await ReportEvidence.countDocuments({})).toBe(0);
      expect(await ReportSubmissionLedger.countDocuments({})).toBe(0);
      expect((await conversation())!.reportLeaseConsumedAt).toBeFalsy();
      // Nothing was consumed, so the same handoff still works exactly once.
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect(await ReportEvidence.countDocuments({ kind: "message-context" })).toBe(1);
    });

    it("a repeated Block neither re-grants nor extends the lease and mints no extra capture", async () => {
      await seed(3);
      await handoffFor(owner);
      const firstLease = (await conversation())!.reportLeaseUntil!.getTime();
      const row = await ParticipantBlock.findOne().lean();
      expect((await call("DELETE", `/api/participant/blocks/${row!._id}`, owner)).status).toBe(200);
      const second = await handoffFor(owner);
      expect((await conversation())!.reportLeaseUntil!.getTime()).toBe(firstLease);
      expect((await report(owner, { reportAuthorization: second })).status).toBe(200);
      expect((await messageContext())!.messageContext!.messages).toHaveLength(3);
      expect((await conversation())!.reportLeaseConsumedAt).toBeTruthy();
      await chatDenied();
    });

    it("cleanup honors an active lease, then erases; later handoff reports carry no context", async () => {
      await seed(3);
      const handoff = await handoffFor(owner);
      const due = { cleanupDueAt: new Date(Date.now() + 5 * 60_000) };
      await MessageConversation.collection.updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: due });
      await sweepMessageCleanup(policy);
      expect(await ConversationMessage.countDocuments({})).toBe(3);
      await MessageConversation.collection.updateOne(
        { requestId: new Types.ObjectId(requestId) },
        { $set: { reportLeaseUntil: new Date(Date.now() - 1000), cleanupDueAt: new Date(Date.now() - 500) } }
      );
      await sweepMessageCleanup(policy);
      expect(await ConversationMessage.countDocuments({})).toBe(0);
      expect((await report(owner, { reportAuthorization: handoff })).status).toBe(200);
      expect((await messageContext())?.messageContext).toMatchObject({
        captureStatus: "incomplete",
        captureReason: "conversation-erased",
        messages: [],
      });
    });

    it("captured message context follows the existing evidence retention clock", async () => {
      await seed(3);
      expect((await report(helper)).status).toBe(200);
      const created = (await ModerationReport.findOne().lean())!;
      expect((await messageContext())!.deleteAt).toBeUndefined();
      const closedAt = new Date();
      await ModerationReport.updateOne({ _id: created._id }, { $set: { state: "closed", closedAt } });
      await runModerationTransaction(session => recomputeCaseClocks(session, created._id as Types.ObjectId, closedAt));
      const evidence = await ReportEvidence.find({ reportId: created._id }).lean();
      expect(evidence.length).toBeGreaterThanOrEqual(2);
      const deleteAts = new Set(evidence.map(item => item.deleteAt?.getTime()));
      expect(deleteAts.size).toBe(1);
      expect([...deleteAts][0]).toBeGreaterThan(closedAt.getTime());
    });
  });

  describe("U1.2 suspension and removal closure", () => {
    const suspend = (fn: typeof suspendHelper, id: Types.ObjectId) =>
      runModerationTransaction(session => fn({
        session, now: new Date(), keyring: readSafetyIdentityKeyring(), participantId: id,
        email: `${id}@nyu.edu`, origin: "manual", rationale: "integration",
      }));

    const rawConversation = () =>
      MessageConversation.collection.findOne({ requestId: new Types.ObjectId(requestId) });
    const reinstate = (suspensionId: Types.ObjectId, id: Types.ObjectId) =>
      runModerationTransaction(session => reinstateParticipant({
        session, now: new Date(), keyring: readSafetyIdentityKeyring(), suspensionId, participantId: id,
      }));

    it.each([
      ["helper", suspendHelper, helper],
      ["requester", suspendRequester, owner],
    ] as const)("the real %s suspension writer closes a placed relationship; real reinstatement never reopens it", async (_role, fn, id) => {
      await seed(3);
      await toPlaced();
      // Control: the placed relationship is genuinely usable, so only the
      // suspension writer can be responsible for the closure below.
      await send(owner, helper, "placed-ok");
      expect((await rawConversation())!.closedAt ?? null).toBeNull();

      const { suspensionId } = await suspend(fn, id);
      // Persisted closure observed directly, before any messaging call that
      // could itself tombstone the conversation.
      expect((await rawConversation())!.closedAt).toBeTruthy();
      expect(await Participant.exists({ _id: id, suspended: true })).toBeTruthy();
      expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);

      await reinstate(suspensionId, id);
      expect(await Participant.exists({ _id: id, suspended: true })).toBeNull();
      expect((await rawConversation())!.closedAt).toBeTruthy();
      await chatDenied();
    });

    it("the real suspension writer closes a relationship whose chat was never opened", async () => {
      await toPlaced();
      expect(await rawConversation()).toBeNull();
      const { suspensionId } = await suspend(suspendHelper, helper);
      expect((await rawConversation())!.closedAt).toBeTruthy();
      await reinstate(suspensionId, helper);
      expect((await rawConversation())!.closedAt).toBeTruthy();
      await chatDenied();
    });
  });

  describe("R3/R5 lifecycle: policy enforcement is sufficient, no writer tombstone needed", () => {
    it("pickup, release/replacement and lapse close via real writers without any closure call", async () => {
      await seed(2);
      expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(1);
      await toPlaced();
      expect((await pickup()).status).toBe(200);
      expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
      await chatDenied();
      // No lifecycle writer calls a closure hook: the monotonic facts alone deny.
      expect((await conversation())?.closedAt).toBeTruthy();
      expect(await ConversationMessage.countDocuments({})).toBe(2);
    });

    it("final participant loss immediately removes the relationship from unread projection", async () => {
      await seed(3);
      expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(2);
      await Participant.deleteOne({ _id: helper });

      expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
      await chatDenied();
      expect((await conversation())?.closedAt).toBeTruthy();
      expect(await ConversationMessage.countDocuments({})).toBe(3);
    });

    it("withdraw cannot target a reserved request, so no live chat can be withdrawn under", async () => {
      await seed(1);
      const withdrawn = await call("POST", `/api/request/${requestId}/withdraw`, owner, {});
      expect(withdrawn.status).not.toBe(200);
      expect((await MealRequest.findById(requestId).lean())!.status).toBe("claimed");
      expect(await send(helper, helper, "still allowed")).toBeDefined();
    });
  });

  describe("dormancy", () => {
    it("without installed hooks Block, Report and suspension create no messaging state", async () => {
      uninstallMessagingLifecycleHooks();
      await MessageConversation.deleteMany({});
      expect((await report(owner)).status).toBe(200);
      expect((await block(owner)).status).toBe(200);
      expect(await MessageConversation.countDocuments({})).toBe(0);
      expect((await messageContext())?.messageContext).toMatchObject({
        captureStatus: "incomplete",
        captureReason: "lifecycle-unavailable",
        messages: [],
      });
    });

    it("writer modules import only the neutral registry, never messaging models or services", () => {
      for (const file of ["src/reportRoutes.ts", "src/participantBlockRoute.ts", "src/moderationEnforcement.ts",
        "src/moderationRoutes.ts", "src/moderationRecords.ts"]) {
        const source = readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
        expect(source, file).not.toMatch(/from\s+"(\.\.\/models\/messaging|\.\/messaging(Safety|Policy)?)\.js"/);
      }
    });
  });
});
