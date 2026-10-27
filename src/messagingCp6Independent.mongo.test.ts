import { once } from "node:events";
import { createServer, type Server } from "node:http";
import express from "express";
import mongoose, { Types, type ClientSession } from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { Fulfillment, Participant, ParticipantBlock, Request as MealRequest, RequestParticipation } from "../models/db.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";
import {
  ConversationMessage, MessageConversation, MessageReceipt, initializeMessagingIndexes,
} from "../models/messaging.js";
import {
  MESSAGE_CLEANUP_DEADLINE_MS, closeMessagingRelationship, createMessagingService, sweepMessageCleanup,
  type MessagingPolicy,
} from "./messaging.js";
import { isEitherParticipantSuspended } from "./moderationEnforcement.js";
import { createMessagingPolicy, type DeletionAccess } from "./messagingPolicy.js";
import {
  REPORT_CONTEXT_MAX_MESSAGES, REPORT_LEASE_MS, captureReportContext, closeMessagingForPair,
  closeMessagingForParticipant, grantReportCaptureLease,
} from "./messagingSafety.js";
import { claimRequest, extendClaim, releaseClaim, CLAIM_ROUTE_PATH, CLAIM_RELEASE_ROUTE_PATH, CLAIM_EXTENSION_ROUTE_PATH } from "./claimRoute.js";
import { confirmPlacedOrderPickup } from "./placedOrderRoutes.js";
import { signParticipantAuthority } from "./participantCredentials.js";

const uri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = uri ? describe : describe.skip;
const secret = "messaging-test-signing-secret-32-bytes";
const credential = (id: Types.ObjectId) => signParticipantAuthority(id, 1, Buffer.from(secret));

describeMongo("MSG1 CP6 bounded package: policy, closure, report context, cleanup lease", () => {
  const owner = new Types.ObjectId();
  const helper = new Types.ObjectId();
  const replacement = new Types.ObjectId();
  const stranger = new Types.ObjectId();
  let deletion: DeletionAccess | "unknown" | Error = "none";
  const policy = createMessagingPolicy(async () => {
    if (deletion instanceof Error) throw deletion;
    return deletion as DeletionAccess;
  }, isEitherParticipantSuspended);
  const service = createMessagingService(policy);
  let server: Server;
  let base: string;
  let requestId: string;

  const http = async (url: string, actor: Types.ObjectId, method = "POST") => {
    const response = await fetch(`${base}${url}`, {
      method,
      headers: { "x-commonplate-participant": credential(actor), "Content-Type": "application/json" },
      ...(method === "POST" ? { body: "{}" } : {}),
    });
    return response.status;
  };
  const claim = (actor = helper) => http(`/api/request/${requestId}/claim`, actor);
  const pickup = () => http(`/api/participant/placed-orders/${requestId}/pickup-confirmation`, owner);
  const withTxn = async <T>(work: (session: ClientSession) => Promise<T>): Promise<T> => {
    const session = await mongoose.startSession();
    try {
      let value!: T;
      await session.withTransaction(async () => { value = await work(session); });
      return value;
    } finally {
      await session.endSession();
    }
  };
  const open = (actor: Types.ObjectId) => service.open(credential(actor), requestId);
  const send = (actor: Types.ObjectId, helperId: Types.ObjectId, text = "hello") =>
    service.send(credential(actor), requestId, String(helperId), crypto.randomUUID(), text);
  const read = (actor: Types.ObjectId, helperId: Types.ObjectId) =>
    service.read(credential(actor), requestId, String(helperId));
  const conversationOf = (helperId: Types.ObjectId, id = requestId) =>
    MessageConversation.findOne({ requestId: id, helperParticipantId: helperId }).lean();
  const messageCount = () => ConversationMessage.countDocuments({});
  const seedMessages = async (helperId: Types.ObjectId, count: number) => {
    for (let i = 1; i <= count; i++) await send(i % 2 ? helperId : owner, helperId, `m${i}`);
  };
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

  beforeAll(async () => {
    vi.stubEnv("PARTICIPANT_SIGNING_SECRET", secret);
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "claim-token-test-secret-material-32b");
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    const isolated = new URL(uri!);
    isolated.pathname = "/commonplate_msg1_cp6_p0";
    await mongoose.connect(isolated.toString());
    await Participant.createIndexes();
    await ParticipantBlock.createIndexes();
    await MealRequest.createIndexes();
    await RequestParticipation.createIndexes();
    await Fulfillment.createIndexes();
    await initializeMessagingIndexes();
    const app = express();
    app.use(express.json({ limit: "16kb" }));
    app.post(CLAIM_ROUTE_PATH, (req, res, next) => { void claimRequest(req, res).catch(next); });
    app.post(CLAIM_RELEASE_ROUTE_PATH, (req, res, next) => { void releaseClaim(req, res).catch(next); });
    app.post(CLAIM_EXTENSION_ROUTE_PATH, (req, res, next) => { void extendClaim(req, res).catch(next); });
    app.post("/api/participant/placed-orders/:requestId/pickup-confirmation", (req, res, next) => {
      void confirmPlacedOrderPickup(req, res).catch(next);
    });
    server = createServer(app);
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test HTTP server missing");
    base = `http://127.0.0.1:${address.port}`;
  });
  afterAll(async () => {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });
  beforeEach(async () => {
    deletion = "none";
    for (const model of [ConversationMessage, MessageReceipt, MessageConversation, RequestParticipation, MealRequest, Fulfillment, Participant]) {
      await model.collection.deleteMany({});
    }
    await prepareParticipantIdentityMongoTestState();
    for (const id of [owner, helper, replacement, stranger]) {
      await Participant.create({ _id: id, email: `${id}@nyu.edu`, verifiedAt: new Date() });
    }
    const future = new Date(Date.now() + 3600_000);
    const request = await MealRequest.create({
      vendor: "Palladium", food: "Rice bowl", pickupWindowText: "ASAP",
      email: `${owner}@nyu.edu`, requesterParticipantId: owner,
      status: "open", expiresAt: future, deleteAt: future,
    });
    requestId = String(request._id);
    expect(await claim()).toBe(200);
  });
  afterEach(() => { vi.restoreAllMocks(); });

  // Pauses the first policy decision of one operation until released.
  function pausedPolicy() {
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
    return { service: createMessagingService(paused), entered, resume };
  }

  describe("policy", () => {
    it("isolates the requester/helper pair and denies others", async () => {
      const { conversationId } = await open(owner);
      expect((await open(helper)).conversationId).toBe(conversationId);
      await send(helper, helper, "from helper");
      expect((await read(owner, helper)).messages.map(m => m.text)).toEqual(["from helper"]);
      await expect(open(stranger)).rejects.toThrow("unavailable");
      await expect(read(stranger, helper)).rejects.toThrow("unavailable");
      await expect(send(stranger, helper)).rejects.toThrow("unavailable");
    });

    it("denies after pickup for both sides and closes permanently", async () => {
      await send(helper, helper);
      await toPlaced();
      await send(owner, helper, "placed chat continues");
      expect(await pickup()).toBe(200);
      for (const actor of [owner, helper]) {
        await expect(read(actor, helper)).rejects.toThrow("unavailable");
        await expect(send(actor, helper)).rejects.toThrow("unavailable");
      }
      await expect(open(owner)).rejects.toThrow("unavailable");
      expect((await conversationOf(helper))?.closedAt).toBeTruthy();
      expect(await messageCount()).toBe(2);
    });

    it("pickup/send race: no message commits after pickup (barrier race), plus the sequential before-pickup boundary", async () => {
      await toPlaced();
      await open(owner);
      const before = await messageCount();
      const gate = pausedPolicy();
      const racing = gate.service.send(credential(helper), requestId, String(helper), crypto.randomUUID(), "late");
      const outcome = racing.then(() => "sent", () => "denied");
      await gate.entered;
      expect(await pickup()).toBe(200);
      gate.resume();
      expect(await outcome).toBe("denied");
      expect(await messageCount()).toBe(before);

      // Sequential boundary (not a concurrent race): a send that committed before pickup is legitimate.
      await Promise.all([
        MealRequest.collection.updateOne({ _id: new Types.ObjectId(requestId) }, { $unset: { requesterPickupConfirmedAt: "" } }),
        MessageConversation.collection.updateOne({ requestId: new Types.ObjectId(requestId) }, { $unset: { closedAt: "", cleanupDueAt: "" } }),
      ]);
      await send(helper, helper, "first");
      expect(await pickup()).toBe(200);
      await expect(send(helper, helper, "after")).rejects.toThrow("unavailable");
      expect(await messageCount()).toBe(before + 1);
    });

    it("release/send race and replacement history isolation", async () => {
      await send(helper, helper, "private to first helper");
      const gate = pausedPolicy();
      const racing = gate.service.send(credential(helper), requestId, String(helper), crypto.randomUUID(), "late");
      const outcome = racing.then(() => "sent", () => "denied");
      await gate.entered;
      expect(await http(`/api/request/${requestId}/claim/release`, helper)).toBe(200);
      gate.resume();
      expect(await outcome).toBe("denied");
      expect(await messageCount()).toBe(1);

      expect(await claim(replacement)).toBe(200);
      const fresh = await open(replacement);
      const old = await conversationOf(helper);
      expect(fresh.conversationId).not.toBe(String(old!._id));
      expect((await read(replacement, replacement)).messages).toEqual([]);
      await expect(
        service.read(credential(replacement), requestId, { conversationId: String(old!._id) })
      ).rejects.toThrow("unavailable");
      await expect(read(helper, helper)).rejects.toThrow("unavailable");
      await expect(read(owner, helper)).rejects.toThrow("unavailable");
      expect((await conversationOf(helper))?.closedAt).toBeTruthy();
    });

    it("passive lapse denies, and a late extension cannot revive it", async () => {
      await send(helper, helper);
      await MealRequest.collection.updateOne(
        { _id: new Types.ObjectId(requestId) }, { $set: { claimExpiresAt: new Date(Date.now() - 1000) } }
      );
      await expect(send(helper, helper)).rejects.toThrow("unavailable");
      expect(await http(`/api/request/${requestId}/claim/extend`, helper)).not.toBe(200);
      await expect(read(helper, helper)).rejects.toThrow("unavailable");
      expect((await MealRequest.findById(requestId).select("claimExpiresAt").lean())!.claimExpiresAt!.getTime())
        .toBeLessThan(Date.now());
    });

    it("denies suspension, moderation removal and unknown or unavailable deletion state", async () => {
      await send(helper, helper);
      await Participant.updateOne({ _id: helper }, { $set: { suspended: true } });
      await expect(read(owner, helper)).rejects.toThrow("unavailable");
      await Participant.updateOne({ _id: helper }, { $set: { suspended: false } });
      // The denial above already closed it permanently, even though the cause is reversible.
      await expect(read(owner, helper)).rejects.toThrow("unavailable");
    });

    it.each([
      ["moderationUnavailable", () => MealRequest.collection.updateOne({ _id: new Types.ObjectId(requestId) }, { $set: { moderationUnavailable: true } })],
    ])("denies on %s", async (_name, mutate) => {
      await mutate();
      await expect(send(helper, helper)).rejects.toThrow("unavailable");
    });

    it("allows pending deletion; denies final, unknown values and unavailable adapters", async () => {
      deletion = "pending";
      await send(helper, helper, "allowed while pending");
      deletion = "unknown";
      await expect(send(helper, helper)).rejects.toThrow("unavailable");
      expect((await conversationOf(helper))?.closedAt).toBeTruthy();
      await MessageConversation.updateOne({ requestId }, { $unset: { closedAt: "" } });
      deletion = "final";
      await expect(read(owner, helper)).rejects.toThrow("unavailable");
      await MessageConversation.updateOne({ requestId }, { $unset: { closedAt: "" } });
      deletion = new Error("P2 unavailable");
      await expect(read(owner, helper)).rejects.toThrow("P2 unavailable");
      expect((await MessageConversation.findOne({ requestId }).lean())?.closedAt).toBeFalsy();
    });

    it("sweeper closes and cleans a conversation the policy no longer allows", async () => {
      await send(helper, helper);
      await toPlaced();
      await pickup();
      const result = await sweepMessageCleanup(policy);
      expect(result.failed).toBe(0);
      expect(await messageCount()).toBe(0);
    });
  });

  describe("permanent closure primitives", () => {
    it("closes before first open, is idempotent and cannot be reopened", async () => {
      const id = new Types.ObjectId(requestId);
      await withTxn(session => closeMessagingRelationship(id, helper, session));
      const first = await conversationOf(helper);
      expect(first?.closedAt).toBeTruthy();
      await withTxn(session => closeMessagingRelationship(id, helper, session));
      expect((await conversationOf(helper))?.closedAt).toEqual(first?.closedAt);
      expect(await MessageConversation.countDocuments({ requestId })).toBe(1);
      for (const actor of [owner, helper]) await expect(open(actor)).rejects.toThrow("unavailable");
    });

    it("pair closure covers both directions, opened or never opened, and spares others", async () => {
      await send(helper, helper);
      const second = await MealRequest.create({
        vendor: "Palladium", food: "Soup", pickupWindowText: "ASAP", email: `${helper}@nyu.edu`,
        requesterParticipantId: helper, status: "open",
        expiresAt: new Date(Date.now() + 3600_000), deleteAt: new Date(Date.now() + 3600_000),
      });
      await RequestParticipation.create({ requestId: second._id, participantId: owner });
      const third = await MealRequest.create({
        vendor: "Palladium", food: "Salad", pickupWindowText: "ASAP", email: `${owner}@nyu.edu`,
        requesterParticipantId: owner, status: "open",
        expiresAt: new Date(Date.now() + 3600_000), deleteAt: new Date(Date.now() + 3600_000),
      });
      await RequestParticipation.create({ requestId: third._id, participantId: stranger });

      await expect(closeMessagingForPair(owner, helper, await mongoose.startSession())).rejects.toThrow("unavailable");
      await withTxn(session => closeMessagingForPair(owner, helper, session));
      await withTxn(session => closeMessagingForPair(helper, owner, session));
      expect((await conversationOf(helper))?.closedAt).toBeTruthy();
      expect((await MessageConversation.findOne({ requestId: second._id, helperParticipantId: owner }).lean())?.closedAt).toBeTruthy();
      expect((await MessageConversation.findOne({ requestId: third._id, helperParticipantId: stranger }).lean())?.closedAt).toBeFalsy();
      await expect(read(owner, helper)).rejects.toThrow("unavailable");
    });

    it("participant closure covers helper and requester roles; rolls back with its transaction", async () => {
      await send(helper, helper);
      const session = await mongoose.startSession();
      try {
        await expect(session.withTransaction(async () => {
          await closeMessagingForParticipant(helper, session);
          throw new Error("owner transaction aborted");
        })).rejects.toThrow("owner transaction aborted");
      } finally { await session.endSession(); }
      expect((await conversationOf(helper))?.closedAt).toBeFalsy();
      await send(owner, helper, "still open after abort");

      await withTxn(s => closeMessagingForParticipant(owner, s));
      expect((await conversationOf(helper))?.closedAt).toBeTruthy();
      await expect(send(helper, helper)).rejects.toThrow("unavailable");
      await withTxn(s => closeMessagingForParticipant(owner, s));
    });

    it("never gives a replacement helper previous history after closure", async () => {
      await send(helper, helper, "secret");
      await withTxn(s => closeMessagingForParticipant(helper, s));
      await http(`/api/request/${requestId}/claim/release`, helper);
      expect(await claim(replacement)).toBe(200);
      expect((await read(replacement, replacement)).messages).toEqual([]);
    });
  });

  describe("report context capture", () => {
    const capture = (basis: "live" | "post-block-handoff", reporter = owner, reported = helper) =>
      withTxn(session => captureReportContext(
        session, { basis, requestId: new Types.ObjectId(requestId), reporterId: reporter, reportedId: reported, }, policy
      ));

    it.each([0, 1, 10, 11, 25])("captures the newest committed messages for %i", async count => {
      await seedMessages(helper, count);
      const context = await capture("live");
      const expected = Math.min(count, REPORT_CONTEXT_MAX_MESSAGES);
      expect(context.messages).toHaveLength(expected);
      expect(context.messages.map(m => m.sequence)).toEqual(
        Array.from({ length: expected }, (_, i) => count - expected + 1 + i)
      );
      expect(context.newestSequence).toBe(count);
      for (const message of context.messages) {
        expect(Object.keys(message).sort()).toEqual(["createdAt", "sender", "sequence", "text"]);
        expect(message.sender).toBe(message.sequence % 2 ? "reported" : "reporter");
      }
    });

    it("denies unauthorized, stale and wrong-relationship capture", async () => {
      await seedMessages(helper, 3);
      await expect(capture("live", stranger, helper)).rejects.toThrow("unavailable");
      await expect(capture("live", owner, stranger)).rejects.toThrow("unavailable");
      await expect(capture("live", owner, owner)).rejects.toThrow("unavailable");
      await expect(capture("post-block-handoff")).rejects.toThrow("unavailable");
      await withTxn(s => closeMessagingForParticipant(helper, s));
      await expect(capture("live")).rejects.toThrow("unavailable");
      await expect(capture("live", helper, owner)).rejects.toThrow("unavailable");
      await expect(
        withTxn(session => captureReportContext(session, {
          basis: "live", requestId: new Types.ObjectId(requestId), reporterId: owner, reportedId: helper,
        }))
      ).rejects.toThrow("unavailable");
    });

    it("never captures a previous helper's messages for the replacement", async () => {
      await seedMessages(helper, 4);
      await http(`/api/request/${requestId}/claim/release`, helper);
      expect(await claim(replacement)).toBe(200);
      await send(replacement, replacement, "new helper only");
      const context = await capture("live", owner, replacement);
      expect(context.messages.map(m => m.text)).toEqual(["new helper only"]);
      await expect(capture("live", owner, helper)).rejects.toThrow("unavailable");
    });

    it("ignores a caller-supplied future instant: the lease stays within ten real minutes", async () => {
      await seedMessages(helper, 1);
      const id = new Types.ObjectId(requestId);
      await withTxn(s => closeMessagingForPair(owner, helper, s));
      const forged = { requestId: id, helperId: helper, holderId: owner, now: new Date(Date.now() + 86_400_000) };
      expect(await withTxn(s => grantReportCaptureLease(s, forged))).toBe(true);
      expect((await conversationOf(helper))!.reportLeaseUntil!.getTime() - Date.now()).toBeLessThanOrEqual(REPORT_LEASE_MS);
    });

    it("post-block handoff: bound to holder and relationship, single use, expiring, no chat access", async () => {
      await seedMessages(helper, 3);
      const id = new Types.ObjectId(requestId);
      expect(await withTxn(s => grantReportCaptureLease(s, { requestId: id, helperId: helper, holderId: owner, }))).toBe(false);
      await withTxn(s => closeMessagingForPair(owner, helper, s));
      expect(await withTxn(s => grantReportCaptureLease(s, { requestId: id, helperId: helper, holderId: stranger, }))).toBe(false);
      expect(await withTxn(s => grantReportCaptureLease(s, { requestId: id, helperId: helper, holderId: owner, }))).toBe(true);
      expect(await withTxn(s => grantReportCaptureLease(s, { requestId: id, helperId: helper, holderId: owner, }))).toBe(false);
      const lease = await conversationOf(helper);
      expect(lease!.reportLeaseUntil!.getTime() - Date.now()).toBeLessThanOrEqual(REPORT_LEASE_MS);

      await expect(read(owner, helper)).rejects.toThrow("unavailable");
      await expect(capture("post-block-handoff", helper, owner)).rejects.toThrow("unavailable");
      await expect(capture("live")).rejects.toThrow("unavailable");
      const context = await capture("post-block-handoff");
      expect(context.messages).toHaveLength(3);
      await expect(capture("post-block-handoff")).rejects.toThrow("unavailable");
      await expect(read(owner, helper)).rejects.toThrow("unavailable");
    });

    it("an aborted report transaction does not consume the lease", async () => {
      await seedMessages(helper, 2);
      const id = new Types.ObjectId(requestId);
      await withTxn(async s => {
        await closeMessagingForPair(owner, helper, s);
        await grantReportCaptureLease(s, { requestId: id, helperId: helper, holderId: owner, });
      });
      const session = await mongoose.startSession();
      try {
        await expect(session.withTransaction(async () => {
          await captureReportContext(session, {
            basis: "post-block-handoff", requestId: id, reporterId: owner, reportedId: helper,
          });
          throw new Error("report transaction aborted");
        })).rejects.toThrow("report transaction aborted");
      } finally { await session.endSession(); }
      expect((await capture("post-block-handoff")).messages).toHaveLength(2);
    });

    it("an expired lease cannot capture", async () => {
      await seedMessages(helper, 2);
      const id = new Types.ObjectId(requestId);
      await withTxn(async s => {
        await closeMessagingForPair(owner, helper, s);
        await grantReportCaptureLease(s, { requestId: id, helperId: helper, holderId: owner, });
      });
      await MessageConversation.updateOne({ requestId }, { $set: { reportLeaseUntil: new Date(Date.now() - 1) } });
      await expect(capture("post-block-handoff")).rejects.toThrow("unavailable");
    });
  });

  describe("cleanup lease interlock", () => {
    const leasedClosure = async () => {
      const id = new Types.ObjectId(requestId);
      await withTxn(async s => {
        await closeMessagingForPair(owner, helper, s);
        await grantReportCaptureLease(s, { requestId: id, helperId: helper, holderId: owner, });
      });
    };

    it("defers deletion while leased, then follows the ordinary path", async () => {
      await seedMessages(helper, 3);
      await leasedClosure();
      await sweepMessageCleanup(policy);
      expect(await messageCount()).toBe(3);
      await MessageConversation.updateOne({ requestId }, { $set: { reportLeaseUntil: new Date(Date.now() - 1) } });
      await sweepMessageCleanup(policy);
      expect(await messageCount()).toBe(0);
    });

    it("a lease never outlives the cleanup deadline", async () => {
      await seedMessages(helper, 3);
      await leasedClosure();
      await MessageConversation.updateOne({ requestId }, { $set: {
        cleanupDueAt: new Date(Date.now() - 1), reportLeaseUntil: new Date(Date.now() + REPORT_LEASE_MS),
      } });
      await sweepMessageCleanup(policy);
      expect(await messageCount()).toBe(0);
      await expect(capture()).rejects.toThrow("unavailable");
      function capture() {
        return withTxn(s => captureReportContext(s, {
          basis: "post-block-handoff", requestId: new Types.ObjectId(requestId), reporterId: owner, reportedId: helper,
        }));
      }
    });

    it("consumed lease releases cleanup; erased evidence is not an empty success", async () => {
      await seedMessages(helper, 3);
      await leasedClosure();
      await withTxn(s => captureReportContext(s, {
        basis: "post-block-handoff", requestId: new Types.ObjectId(requestId), reporterId: owner, reportedId: helper,
      }));
      await sweepMessageCleanup(policy);
      expect(await messageCount()).toBe(0);
      await expect(withTxn(s => captureReportContext(s, {
        basis: "post-block-handoff", requestId: new Types.ObjectId(requestId), reporterId: owner, reportedId: helper,
      }))).rejects.toThrow("unavailable");
    });

    it("a closed conversation without a lease is erased and capture fails rather than succeeding empty", async () => {
      await seedMessages(helper, 3);
      await withTxn(s => closeMessagingForPair(owner, helper, s));
      await sweepMessageCleanup(policy);
      expect(await messageCount()).toBe(0);
      expect(await withTxn(s => grantReportCaptureLease(s, {
        requestId: new Types.ObjectId(requestId), helperId: helper, holderId: owner,
      }))).toBe(false);
    });

    it("in-flight capture versus cleanup: capture wins its snapshot; cleanup follows deterministically", async () => {
      await seedMessages(helper, 3);
      await leasedClosure();
      const id = new Types.ObjectId(requestId);
      const session = await mongoose.startSession();
      let captured: Awaited<ReturnType<typeof captureReportContext>> | undefined;
      let reached!: () => void;
      let resume!: () => void;
      const entered = new Promise<void>(r => { reached = r; });
      const released = new Promise<void>(r => { resume = r; });
      const reporting = session.withTransaction(async () => {
        captured = await captureReportContext(session, {
          basis: "post-block-handoff", requestId: id, reporterId: owner, reportedId: helper,
        });
        reached();
        await released;
      }).finally(() => session.endSession());
      await entered;
      const sweeping = sweepMessageCleanup(policy);
      await new Promise(r => setTimeout(r, 300));
      resume();
      await Promise.all([reporting, sweeping]);
      expect(captured?.messages).toHaveLength(3);
      expect(await messageCount()).toBe(0);
    }, 60_000);

    it("Block closure with lease versus concurrent cleanup keeps the leased evidence", async () => {
      await seedMessages(helper, 3);
      const id = new Types.ObjectId(requestId);
      const session = await mongoose.startSession();
      let reached!: () => void;
      let resume!: () => void;
      const entered = new Promise<void>(r => { reached = r; });
      const released = new Promise<void>(r => { resume = r; });
      const blocking = session.withTransaction(async () => {
        await closeMessagingForPair(owner, helper, session);
        await grantReportCaptureLease(session, { requestId: id, helperId: helper, holderId: owner, });
        reached();
        await released;
      }).finally(() => session.endSession());
      await entered;
      const sweeping = sweepMessageCleanup(policy);
      await new Promise(r => setTimeout(r, 300));
      resume();
      await Promise.all([blocking, sweeping]);
      expect(await messageCount()).toBe(3);
      expect((await conversationOf(helper))?.closedAt).toBeTruthy();
      expect(MESSAGE_CLEANUP_DEADLINE_MS).toBeGreaterThan(REPORT_LEASE_MS);
    }, 60_000);
  });
});
