import { randomUUID } from "node:crypto";
import { createServer, type Server } from "node:http";
import { once } from "node:events";
import { AsyncLocalStorage } from "node:async_hooks";
import express from "express";
import mongoose, { Types } from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it as vitestIt, vi } from "vitest";
import type { RequestHandler } from "express";
import { Participant, ParticipantBlock, Request as MealRequest, RequestParticipation } from "../models/db.js";
import { ConversationMessage, MessageConversation, MessageReceipt, initializeMessagingIndexes } from "../models/messaging.js";
import {
  createMessagingService as untrackedMessagingService,
  sweepMessageCleanup as untrackedMessageCleanup, closeMessagingRelationship, MESSAGE_CLEANUP_DEADLINE_MS, MAX_UNREAD_CONVERSATIONS,
  type MessagingPolicy,
} from "./messaging.js";
import {
  createMessagingHandlers, CONVERSATION_ROUTE_PATH, MESSAGE_ROUTE_PATH,
  MESSAGE_RECONCILIATION_PATH, MESSAGE_READ_ACK_ROUTE_PATH, MESSAGE_UNREAD_COUNT_ROUTE_PATH,
} from "./messagingRoutes.js";
import { createParticipantBlock, REQUEST_BLOCK_ROUTE_PATH } from "./participantBlockRoute.js";
import { claimRequest, releaseClaim, CLAIM_ROUTE_PATH, CLAIM_RELEASE_ROUTE_PATH } from "./claimRoute.js";
import { signParticipantAuthority } from "./participantCredentials.js";
import { bumpBlockFence } from "./participantBlocks.js";
import {
  blockSafetyIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";

const uri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = uri ? describe : describe.skip;
const isolationProbe = process.env.MSG1_ISOLATION_PROBE;
if (isolationProbe && !["failure", "timeout", "detached", "mixed"].includes(isolationProbe)) {
  throw new Error("Unknown MSG1 isolation probe");
}
const secret = "messaging-test-signing-secret-32-bytes";
const owner = new Types.ObjectId();
const helper = new Types.ObjectId();
const replacement = new Types.ObjectId();
const stranger = new Types.ObjectId();
const credential = (id: Types.ObjectId, version = 1) => signParticipantAuthority(id, version, Buffer.from(secret));

class TestWork {
  readonly id = randomUUID();
  private pending = new Set<Promise<unknown>>();
  private failures = new Map<Promise<unknown>, unknown>();
  private registered = new WeakSet<Promise<unknown>>();
  private asserted = new WeakSet<Promise<unknown>>();
  private releases = new Set<() => void>();
  private draining = false;
  private drained = false;
  private drainPromise?: Promise<void>;

  start<T>(work: () => Promise<T>): Promise<T> {
    if (this.drained) throw new Error("Work started after fixture settlement");
    // Register before invoking work, including synchronously rejecting callbacks.
    const promise = Promise.resolve().then(work);
    this.pending.add(promise);
    this.registered.add(promise);
    void promise.then(
      () => this.pending.delete(promise),
      error => {
        this.pending.delete(promise);
        if (!this.asserted.has(promise)) this.failures.set(promise, error);
      }
    );
    return promise;
  }

  async assertRejected(promise: Promise<unknown>, assertion: () => Promise<unknown>): Promise<void> {
    if (!this.registered.has(promise)) throw new Error("Expected rejection has no registered operation");
    await assertion();
    this.asserted.add(promise);
    this.failures.delete(promise);
  }

  reported<T>(work: () => Promise<T>): Promise<T> {
    const promise = this.start(work);
    // The test runner receives this exact rejection; teardown must not duplicate it.
    return promise.catch(error => {
      this.asserted.add(promise);
      this.failures.delete(promise);
      throw error;
    });
  }

  barrier() {
    if (this.drained) throw new Error("Barrier started after fixture settlement");
    let enter!: () => void;
    let resume!: () => void;
    const entered = new Promise<void>(resolve => { enter = resolve; });
    const released = new Promise<void>(resolve => { resume = resolve; });
    const release = () => { enter(); resume(); };
    this.releases.add(release);
    if (this.draining) release();
    return { enter, resume, entered, released };
  }

  assertReusable(): void {
    if (!this.drained) throw new Error("Previous test work has not settled; fixture reuse refused");
  }

  drain(): Promise<void> {
    this.drainPromise ??= (async () => {
      this.draining = true;
      // Bodies can resume and start more work/barriers while being drained.
      do {
        for (const release of this.releases) release();
        await Promise.allSettled([...this.pending]);
      } while (this.pending.size);
      this.drained = true;
      if (this.failures.size) {
        throw new AggregateError([...this.failures.values()], "Unexpected registered test-work rejection");
      }
    })();
    return this.drainPromise;
  }
}

const testWork = new AsyncLocalStorage<TestWork>();
let fixtureWork: TestWork | undefined;
function currentWork(): TestWork {
  const work = testWork.getStore();
  if (!work) throw new Error("Async test work has no owning fixture");
  return work;
}
function tracked<A extends unknown[], R>(operation: (...args: A) => Promise<R>) {
  return (...args: A): Promise<R> => currentWork().start(() => operation(...args));
}
function expectRejected<T>(promise: Promise<T>, message: string): Promise<void> {
  return currentWork().assertRejected(promise, () => expect(promise).rejects.toThrow(message));
}
function isolatedTest(body: () => Promise<void>) {
  return () => {
    const work = fixtureWork;
    if (!work) throw new Error("Test fixture missing");
    return testWork.run(work, () => work.reported(body));
  };
}
const it = Object.assign(
  (name: string, body: () => Promise<void>, timeout?: number) =>
    vitestIt(name, isolatedTest(body), timeout),
  {
    each: <T>(values: readonly T[]) =>
      (name: string, body: (value: T) => Promise<void>, timeout?: number) =>
        vitestIt.each(values)(name, value => isolatedTest(() => body(value))(), timeout),
  }
);
function createMessagingService(policy?: MessagingPolicy) {
  const service = untrackedMessagingService(policy);
  return {
    open: tracked(service.open),
    send: tracked(service.send),
    read: tracked(service.read),
    reconcile: tracked(service.reconcile),
    acknowledgeDisplayed: tracked(service.acknowledgeDisplayed),
    unreadCounts: tracked(service.unreadCounts),
  };
}
const sweepMessageCleanup = tracked(untrackedMessageCleanup);

function nestedWork(): TestWork {
  const work = new TestWork();
  const parent = currentWork();
  const gate = parent.barrier();
  void parent.start(async () => {
    await gate.released;
    await work.drain();
  });
  return work;
}

interface Facts {
  requestId: Types.ObjectId;
  pickupConfirmed: boolean;
  restricted: boolean;
  pendingDeletion: boolean;
}
const facts = () => mongoose.connection.collection<Facts>("synthetic_messaging_authority");
// Synthetic integration only. Production must consume owner-approved sources;
// these are not invented Request fields or production moderation behavior.
const policy: MessagingPolicy = {
  async authorize(request, session) {
    const state = await facts().findOne({ requestId: request._id }, { session });
    return Boolean(state && !state.pickupConfirmed && !state.restricted);
  },
};
const service = createMessagingService(policy);
let server: Server;
let base: string;
let requestId: string;
let conversationId: string;
const path = () => `/api/request/${requestId}/conversation/${conversationId}/messages`;
const conversationPath = () => `/api/request/${requestId}/conversation`;
const readAckPath = () => `/api/request/${requestId}/conversation/${conversationId}/read`;
const readAt = async (sequence: number) => ConversationMessage.findOne({
  conversationId: new Types.ObjectId(conversationId), sequence,
}).select("+readAt").lean().then(message => message?.readAt);

const http = tracked(async (url: string, actor: Types.ObjectId | null, body?: unknown, method: string = body === undefined ? "GET" : "POST") => {
  const response = await fetch(`${base}${url}`, {
    method,
    headers: {
      "x-test-fixture": currentWork().id,
      ...(actor ? { "x-commonplate-participant": credential(actor) } : {}),
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { status: response.status, headers: response.headers, body: await response.json() };
});
const send = (id = randomUUID(), text = "Meet by the pickup counter", actor = helper) =>
  service.send(credential(actor), requestId, String(helper), id, text);

async function settledSends(operations: ReturnType<typeof send>[]) {
  const results = await Promise.allSettled(operations);
  return results.map(result => {
    if (result.status === "rejected") throw result.reason;
    return result.value;
  });
}

async function replaceHelper() {
  expect((await http(`/api/request/${requestId}/claim/release`, helper, {})).status).toBe(200);
  expect((await http(`/api/request/${requestId}/claim`, replacement, {})).status).toBe(200);
}

function barrierPolicy() {
  const { enter, resume, entered, released } = currentWork().barrier();
  let first = true;
  const paused: MessagingPolicy = {
    async authorize(request, session, now) {
      const result = await policy.authorize(request, session, now);
      if (first) {
        first = false;
        enter();
        await released;
      }
      return result;
    },
  };
  return { paused, entered, resume };
}

function trackedHandler(handler: RequestHandler): RequestHandler {
  return (req, res, next) => {
    const work = fixtureWork;
    // A request arriving after its fixture drained must never adopt a new one.
    if (!work || req.headers["x-test-fixture"] !== work.id) {
      res.status(503).end();
      return;
    }
    void testWork.run(work, () => work.start(async () => {
      await handler(req, res, next);
    })).catch(next);
  };
}

describeMongo("dormant messaging real Mongo persistence and concurrency", () => {
  beforeAll(async () => {
    vi.stubEnv("PARTICIPANT_SIGNING_SECRET", secret);
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    const isolated = new URL(uri!);
    isolated.pathname = "/commonplate_msg1_cp1";
    await mongoose.connect(isolated.toString());
    await prepareParticipantIdentityMongoTestState();
    await Participant.createIndexes();
    await ParticipantBlock.createIndexes();
    await MealRequest.createIndexes();
    await RequestParticipation.createIndexes();
    await initializeMessagingIndexes();
    const app = express();
    app.use(express.json({ limit: "16kb" }));
    const handlers = createMessagingHandlers(policy);
    app.get(CONVERSATION_ROUTE_PATH, trackedHandler(handlers.open));
    app.post(MESSAGE_ROUTE_PATH, trackedHandler(handlers.send));
    app.get(MESSAGE_ROUTE_PATH, trackedHandler(handlers.read));
    app.get(MESSAGE_RECONCILIATION_PATH, trackedHandler(handlers.reconcile));
    app.post(MESSAGE_READ_ACK_ROUTE_PATH, trackedHandler(handlers.acknowledgeDisplayed));
    app.get(MESSAGE_UNREAD_COUNT_ROUTE_PATH, trackedHandler(handlers.unreadCounts));
    app.post(REQUEST_BLOCK_ROUTE_PATH, trackedHandler(createParticipantBlock));
    app.post(CLAIM_ROUTE_PATH, trackedHandler(claimRequest));
    app.post(CLAIM_RELEASE_ROUTE_PATH, trackedHandler(releaseClaim));
    server = createServer(app);
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test HTTP server missing");
    base = `http://127.0.0.1:${address.port}`;
  });
  beforeEach(() => {
    // Remains closed if the preceding teardown times out: timeout is not cancellation.
    fixtureWork?.assertReusable();
    const work = new TestWork();
    fixtureWork = work;
    return testWork.run(work, () => work.reported(async () => {
      for (const model of [ConversationMessage, MessageReceipt, MessageConversation, ParticipantBlock, RequestParticipation, MealRequest, Participant]) {
        await model.collection.deleteMany({});
      }
      await facts().deleteMany({});
      for (const id of [owner, helper, replacement, stranger]) {
        await Participant.create({ _id: id, email: `${id}@nyu.edu`, verifiedAt: new Date() });
      }
      const future = new Date(Date.now() + 3600_000);
      const request = await MealRequest.create({
        vendor: "Jasper Kane Cafe", food: "Rice bowl", pickupWindowText: "ASAP",
        email: `${owner}@nyu.edu`, requesterParticipantId: owner,
        status: "open", expiresAt: future, deleteAt: future,
      });
      requestId = String(request._id);
      await facts().insertOne({ requestId: new Types.ObjectId(requestId), pickupConfirmed: false, restricted: false, pendingDeletion: false });
      expect((await http(`/api/request/${requestId}/claim`, helper, {})).status).toBe(200);
      conversationId = (await service.open(credential(owner), requestId)).conversationId;
    }));
  });
  afterEach(async () => {
    try {
      await fixtureWork?.drain();
    } finally {
      fixtureWork?.assertReusable();
      vi.restoreAllMocks();
    }
  }, 130_000);
  afterAll(async () => {
    fixtureWork?.assertReusable();
    if (server) await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  // Opt-in subprocess proof: the first test MUST fail, the next fixture MUST pass.
  if (isolationProbe) {
    let previousWork: TestWork;
    let readSettled = false;
    let sendSettled = false;
    let mockPresentAtSettlement = false;
    let detachedRejected = false;
    let rejectedWhileReadPending = false;
    it(`controlled ${isolationProbe} with outstanding read and send`, async () => {
      previousWork = currentWork();
      const barrier = barrierPolicy();
      const bodyGate = currentWork().barrier();
      vi.spyOn(console, "error").mockImplementation(() => {});
      void currentWork().start(async () => {
        await createMessagingService(barrier.paused).read(credential(owner), requestId, { conversationId });
        mockPresentAtSettlement = vi.isMockFunction(console.error);
        readSettled = true;
      });
      void currentWork().start(async () => {
        await send(randomUUID(), "Late operation owned by the failed test");
        sendSettled = true;
      });
      await barrier.entered;
      if (isolationProbe === "detached" || isolationProbe === "mixed") {
        void currentWork().start(async () => {
          if (isolationProbe === "detached") await bodyGate.released;
          detachedRejected = true;
          rejectedWhileReadPending = !readSettled;
          throw new Error("Controlled unexpected detached rejection");
        });
        return;
      }
      if (isolationProbe === "timeout") await bodyGate.released;
      throw new Error("Intentional isolation-probe failure; must not become a pass");
    }, isolationProbe === "timeout" ? 500 : 15_000);

    it("next fixture starts only after all previous operations and mocks settle", async () => {
      previousWork.assertReusable();
      expect(readSettled).toBe(true);
      expect(sendSettled).toBe(true);
      expect(mockPresentAtSettlement).toBe(true);
      if (isolationProbe === "detached" || isolationProbe === "mixed") {
        expect(detachedRejected).toBe(true);
        expect(rejectedWhileReadPending).toBe(true);
      }
      expect(vi.isMockFunction(console.error)).toBe(false);
      expect(await ConversationMessage.countDocuments()).toBe(0);
      expect(await MessageReceipt.countDocuments()).toBe(0);
      expect((await send()).message.sequence).toBe(1);
    });
    return;
  }
  it("consumes an intentionally asserted registered rejection without a teardown failure", async () => {
    await expectRejected(send(randomUUID(), ""), "invalid");
    expect(await ConversationMessage.countDocuments()).toBe(0);
    expect(await MessageReceipt.countDocuments()).toBe(0);
  });

  it("drains a rejected body, its detached child and barriers created during teardown", async () => {
    const work = nestedWork();
    let completed = false;
    const body = testWork.run(work, () => work.start(async () => {
      const barrier = currentWork().barrier();
      void currentWork().start(async () => {
        await barrier.released;
        const lateBarrier = currentWork().barrier();
        await lateBarrier.released;
        completed = true;
      });
      throw new Error("controlled body rejection");
    }));
    await work.assertRejected(body, () => expect(body).rejects.toThrow("controlled body rejection"));
    expect(() => work.assertReusable()).toThrow("fixture reuse refused");
    expect(completed).toBe(false);
    await work.drain();
    work.assertReusable();
    expect(completed).toBe(true);
  });

  it("refuses fixture reuse while teardown is still waiting for uncancelled work", async () => {
    const work = nestedWork();
    const external = currentWork().barrier();
    void work.start(() => external.released);
    const drain = work.drain();
    try {
      await expect(Promise.race([drain, Promise.reject(new Error("controlled teardown timeout"))]))
        .rejects.toThrow("controlled teardown timeout");
      expect(() => work.assertReusable()).toThrow("fixture reuse refused");
    } finally { external.resume(); }
    await drain;
    work.assertReusable();
    expect(() => work.start(async () => {})).toThrow("after fixture settlement");
  });

  it("establishes real unique indexes and private text projections", async () => {
    await send();
    const message = await ConversationMessage.findOne().lean().exec();
    expect(message).not.toHaveProperty("text");
    const indexes = await ConversationMessage.collection.indexes();
    expect(indexes.find(index => index.name === "message_sequence_unique")?.unique).toBe(true);
    const original = await ConversationMessage.findOne().select("+text").lean().exec();
    expect(original).not.toBeNull();
    await expect(ConversationMessage.create({
      ...original, _id: new Types.ObjectId(), clientMessageId: randomUUID(),
    })).rejects.toMatchObject({ code: 11000 });
  });

  it("allows both participants, returns exact text and an explicit wire allowlist", async () => {
    const sent = await http(path(), helper, { clientMessageId: randomUUID(), text: "  Keep exact spacing  " });
    expect(sent.status).toBe(201);
    const read = await http(path(), owner);
    expect(read.status).toBe(200);
    expect(read.body.messages[0]).toEqual({
      clientMessageId: sent.body.message.clientMessageId, sequence: 1,
      sender: "other", text: "  Keep exact spacing  ", createdAt: sent.body.message.createdAt,
    });
    expect(read.headers.get("cache-control")).toBe("private, no-store");
    expect(read.headers.get("vary")).toBe("x-commonplate-participant");
    expect(JSON.stringify(read.body)).not.toContain(String(helper));
    expect(JSON.stringify(read.body)).not.toContain("@nyu.edu");
  });

  it("denies missing, forged, revoked, replaced and unknown participant identities", async () => {
    expect((await http(path(), null)).status).toBe(401);
    expect((await http(path(), stranger)).status).toBe(404);
    await expectRejected(service.read("forged", requestId, String(helper)), "unavailable");
    await Participant.updateOne({ _id: helper }, { $inc: { authorityVersion: 1 } });
    await expectRejected(send(), "unavailable");
    expect((await http(path(), helper)).status).toBe(401);
    await Participant.deleteOne({ _id: owner });
    await expectRejected(service.read(credential(helper, 2), requestId, String(helper)), "unavailable");
  });

  it("does not treat conversation membership or a helper binding as sufficient authority", async () => {
    await send();
    await RequestParticipation.deleteMany({});
    await expectRejected(send(), "unavailable");
    expect(await ConversationMessage.countDocuments()).toBe(1);
  });

  it("denies by default without the pickup/moderation adapter", async () => {
    await expectRejected(createMessagingService().read(credential(owner), requestId, String(helper)), "unavailable");
    expect(await ConversationMessage.countDocuments()).toBe(0);
  });

  it("keeps former-helper history inaccessible to requester and replacement helper", async () => {
    await send();
    await replaceHelper();
    await expectRejected(service.read(credential(owner), requestId, String(helper)), "unavailable");
    await expectRejected(service.read(credential(helper), requestId, String(helper)), "unavailable");
    await expectRejected(service.read(credential(replacement), requestId, String(helper)), "unavailable");
    expect((await http(path(), owner)).status).toBe(404);
    const opened = await http(`/api/request/${requestId}/conversation`, owner);
    expect(opened.status).toBe(200);
    expect(opened.body.conversationId).not.toBe(conversationId);
    expect(JSON.stringify(opened.body)).not.toContain(String(replacement));
    expect((await http(path(), owner, { clientMessageId: randomUUID(), text: "Never forward a stale send" })).status).toBe(404);
    expect(await service.read(credential(replacement), requestId, String(replacement))).toEqual({ messages: [], nextAfter: 0 });
    await service.send(credential(replacement), requestId, String(replacement), randomUUID(), "New relationship");
    expect((await service.read(credential(owner), requestId, String(replacement))).messages).toHaveLength(1);
    expect((await http(`/api/request/${requestId}/claim`, helper, {})).status).not.toBe(200);
  });

  it.each(["release", "lapse", "requestExpiry", "withdraw", "missingRequest"])("revokes immediately at %s despite retained content", async ending => {
    await send();
    if (ending === "release") {
      expect((await http(`/api/request/${requestId}/claim/release`, helper, {})).status).toBe(200);
    } else if (ending === "missingRequest") {
      await MealRequest.deleteOne({ _id: requestId });
    } else {
      await MealRequest.updateOne({ _id: requestId }, { $set: {
        ...(ending === "lapse" ? { claimExpiresAt: new Date(Date.now() - 1) } : {}),
        ...(ending === "requestExpiry" ? { expiresAt: new Date(Date.now() - 1) } : {}),
        ...(ending === "withdraw" ? { status: "withdrawn" } : {}),
      } });
    }
    await expectRejected(service.read(credential(owner), requestId, String(helper)), "unavailable");
    expect(await ConversationMessage.countDocuments()).toBe(1);
  });

  it("continues after placement with expired claim time, until synthetic pickup authority revokes", async () => {
    await send();
    await MealRequest.updateOne({ _id: requestId }, { $set: {
      status: "placed", claimExpiresAt: new Date(0), expiresAt: new Date(0),
      placedAt: new Date(), deleteAt: new Date(Date.now() + 7 * 86400_000),
    } });
    await send();
    await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: { pickupConfirmed: true } });
    await expectRejected(send(), "unavailable");
    await expectRejected(service.read(credential(owner), requestId, String(helper)), "unavailable");
  });

  it("enforces the placed horizon during TTL lag", async () => {
    await send();
    await MealRequest.updateOne({ _id: requestId }, { $set: { status: "placed", deleteAt: new Date(Date.now() - 1) } });
    await expectRejected(send(), "unavailable");
    expect(await ConversationMessage.countDocuments()).toBe(1);
    expect((await sweepMessageCleanup(policy)).deleted).toBe(1);
  });

  it("preserves the synthetic pending-deletion exception but denies restrictions", async () => {
    await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: { pendingDeletion: true } });
    await send();
    await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: { restricted: true } });
    await expectRejected(send(), "unavailable");
  });

  // These batches contend on the same transaction anchors during the full Mongo suite.
  it("orders concurrent sends deterministically without gaps or duplicate sequences", async () => {
    const results = await settledSends(Array.from({ length: 12 }, (_, index) => send(randomUUID(), `Message ${index}`, index % 2 ? owner : helper)));
    expect(results.map(result => result.message.sequence).sort((a, b) => a - b)).toEqual(Array.from({ length: 12 }, (_, i) => i + 1));
    const read = await service.read(credential(owner), requestId, String(helper));
    expect(read.messages.map(message => message.sequence)).toEqual(Array.from({ length: 12 }, (_, i) => i + 1));
    expect(await ConversationMessage.countDocuments({ conversationId })).toBe(12);
    expect(await MessageReceipt.countDocuments()).toBe(12);
  }, 15_000);

  it("converges identical concurrent and manual retries to one message", async () => {
    const id = randomUUID();
    const results = await settledSends(Array.from({ length: 6 }, () => send(id)));
    expect(results.filter(result => result.created)).toHaveLength(1);
    const identity = { conversationId, senderParticipantId: helper, clientMessageId: id };
    expect(await ConversationMessage.countDocuments(identity)).toBe(1);
    expect(await MessageReceipt.countDocuments(identity)).toBe(1);
    expect(await ConversationMessage.countDocuments()).toBe(1);
    expect(await MessageReceipt.countDocuments()).toBe(1);
    expect((await send(id)).created).toBe(false);
    const reconciled = await service.reconcile(credential(helper), requestId, String(helper), id);
    expect(reconciled.message?.sequence).toBe(1);
  }, 15_000);

  it("settles every concurrent send before propagating a batch failure", async () => {
    const barrier = barrierPolicy();
    let committed = false;
    const pending = createMessagingService(barrier.paused)
      .send(credential(helper), requestId, String(helper), randomUUID(), "Delayed valid send")
      .then(result => { committed = true; return result; });
    const invalid = send(randomUUID(), "");
    const batch = settledSends([pending, invalid]);
    const rejected = expect(batch).rejects.toThrow("invalid");
    await barrier.entered;
    barrier.resume();
    await rejected;
    await expectRejected(invalid, "invalid");
    expect(committed).toBe(true);
    expect(await ConversationMessage.countDocuments({ conversationId })).toBe(1);
    expect(await MessageReceipt.countDocuments({ conversationId })).toBe(1);
  });

  it("rejects payload/relationship identity conflicts without another message", async () => {
    const id = randomUUID();
    await send(id, "Original");
    await expectRejected(send(id, "Different"), "conflict");
    const ownerId = randomUUID();
    await service.send(credential(owner), requestId, String(helper), ownerId, "Owner");
    await replaceHelper();
    await expectRejected(service.send(credential(helper), requestId, String(replacement), id, "Original"), "unavailable");
    await expectRejected(service.send(credential(owner), requestId, String(replacement), ownerId, "Owner"), "conflict");
    expect(await ConversationMessage.countDocuments()).toBe(2);
  });

  it("paginates and reconciles read-only; absence never allocates an identity", async () => {
    for (let i = 0; i < 5; i++) await send(randomUUID(), `Page ${i}`);
    const first = await http(`${path()}?limit=2`, owner);
    const second = await http(`${path()}?limit=2&after=${first.body.nextAfter}`, owner);
    expect(first.body.messages.map((message: { sequence: number }) => message.sequence)).toEqual([1, 2]);
    expect(second.body.messages.map((message: { sequence: number }) => message.sequence)).toEqual([3, 4]);
    const unknown = await http(`${path()}/${randomUUID()}`, helper);
    expect(unknown.body).toEqual({ message: null });
    expect(await MessageReceipt.countDocuments()).toBe(5);
    for (const query of ["limit=101", "after=-1", "after=9007199254740992", "other=1"]) {
      expect((await http(`${path()}?${query}`, owner)).status).toBe(400);
    }
  });

  it("filters U1.1 text before allocating message/receipt/sequence and never logs content", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const result = await http(path(), helper, { clientMessageId: randomUUID(), text: "I will kill you" });
    expect(result.status).toBe(400);
    expect(result.body.error.code).toBe("MESSAGE_TEXT_NOT_ALLOWED");
    expect(await MessageReceipt.countDocuments()).toBe(0);
    expect(await ConversationMessage.countDocuments()).toBe(0);
    expect(log).not.toHaveBeenCalled();
    expect((await send()).message.sequence).toBe(1);
  });

  it("serializes a stale pre-Block snapshot against a real Block write", async () => {
    await send();
    const barrier = barrierPolicy();
    const pending = createMessagingService(barrier.paused).send(credential(owner), requestId, String(helper), randomUUID(), "Racing send");
    await barrier.entered;
    try {
      const block = await http(`/api/request/${requestId}/block`, helper, { externalOrderPlaced: true });
      expect(block.status).toBe(200);
    } finally { barrier.resume(); }
    await currentWork().assertRejected(pending, () => expect(pending).rejects.toMatchObject({ code: "unavailable" }));
    expect(await ConversationMessage.countDocuments()).toBe(1);
    await expectRejected(service.read(credential(owner), requestId, String(helper)), "unavailable");
  });

  it.each(["release", "replacement", "expiry", "revocation", "pickup"])("serializes stale send against %s", async ending => {
    await send();
    const barrier = barrierPolicy();
    const pending = createMessagingService(barrier.paused).send(credential(helper), requestId, String(helper), randomUUID(), "Stale send");
    await barrier.entered;
    try {
      if (ending === "release") {
        expect((await http(`/api/request/${requestId}/claim/release`, helper, {})).status).toBe(200);
      } else if (ending === "replacement") {
        await replaceHelper();
      } else if (ending === "revocation") {
        await Participant.updateOne({ _id: helper }, { $inc: { authorityVersion: 1 } });
      } else if (ending === "pickup") {
        // Model the future R3 atomic Request write in the same transaction as
        // the synthetic terminal fact, without adding R3 fields to main.
        const session = await mongoose.startSession();
        try {
          await session.withTransaction(async () => {
            await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: { pickupConfirmed: true } }, { session });
            await MealRequest.updateOne({ _id: requestId }, { $inc: { __v: 1 } }, { session });
          });
        } finally { await session.endSession(); }
      } else {
        await MealRequest.updateOne({ _id: requestId }, { $set: { claimExpiresAt: new Date(0) } });
      }
    } finally { barrier.resume(); }
    await currentWork().assertRejected(pending, () => expect(pending).rejects.toMatchObject({ code: "unavailable" }));
    expect(await ConversationMessage.countDocuments()).toBe(1);
  });

  it("makes both block directions indistinguishable from lifecycle loss", async () => {
    await send();
    // Requester-before-placement Block is an explicitly deferred U1.3 gate.
    // Exercise the existing placed requester direction through the real route.
    await MealRequest.updateOne({ _id: requestId }, { $set: { status: "placed" } });
    expect((await http(`/api/request/${requestId}/block`, owner, {})).status).toBe(200);
    const blocked = await http(path(), helper);
    await MealRequest.updateOne({ _id: requestId }, { $set: { status: "withdrawn" } });
    const ended = await http(path(), owner);
    expect(blocked.status).toBe(404);
    expect(ended.body).toEqual(blocked.body);
    expect(JSON.stringify(blocked.body)).not.toMatch(/block|suspend|moderation/i);
  });

  it("deletes ordinary content within the bounded pass and keeps content-free receipts", async () => {
    const id = randomUUID();
    await send(id);
    const last = new Date(Date.now() - 1000);
    await MessageConversation.updateMany({}, { $set: { lastAuthorizedAt: last } });
    await MealRequest.deleteOne({ _id: requestId });
    const result = await sweepMessageCleanup(policy);
    expect(result).toEqual({ checked: 1, deleted: 1, failed: 0, overdue: 0 });
    const closed = await MessageConversation.findOne().lean().exec();
    expect(closed?.cleanupDueAt?.getTime()).toBe(last.getTime() + MESSAGE_CLEANUP_DEADLINE_MS);
    expect(closed?.cleanedAt).toBeInstanceOf(Date);
    expect(await MessageReceipt.countDocuments()).toBe(1);
    expect(await MessageReceipt.findOne().select("+payloadDigest").lean().exec()).not.toHaveProperty("text");
    expect(await sweepMessageCleanup(policy)).toMatchObject({ checked: 0, deleted: 0 });
    await expectRejected(send(id), "unavailable");
  });

  it("retries failed cleanup without deleting independently held safety evidence", async () => {
    await send();
    const safety = mongoose.connection.collection("synthetic_independent_safety_evidence");
    await safety.deleteMany({});
    await safety.insertOne({ hold: "authorized", evidence: "Independently preserved" });
    await MealRequest.deleteOne({ _id: requestId });
    vi.spyOn(ConversationMessage, "deleteMany").mockImplementationOnce(() => { throw new Error("synthetic failure"); });
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(await sweepMessageCleanup(policy)).toMatchObject({ failed: 1, deleted: 0 });
    expect(await ConversationMessage.countDocuments()).toBe(1);
    expect(await sweepMessageCleanup(policy)).toMatchObject({ failed: 0, deleted: 1 });
    expect(await safety.countDocuments()).toBe(1);
    expect(log.mock.calls.flat()).toEqual(["[messaging] Ordinary message cleanup failed"]);
  });

  it("does not delete ordinary content when authoritative safety/lifecycle evaluation is unavailable", async () => {
    await send();
    vi.spyOn(console, "error").mockImplementation(() => {});
    const unavailable: MessagingPolicy = { async authorize() { throw new Error("dependency down"); } };
    expect(await sweepMessageCleanup(unavailable)).toMatchObject({ failed: 1, deleted: 0 });
    expect(await ConversationMessage.countDocuments()).toBe(1);
    expect((await MessageConversation.findOne().lean().exec())?.closedAt).toBeUndefined();
  });

  it("bounds message deletion per pass and reports an overdue deadline until drained", async () => {
    await send();
    const conversation = await MessageConversation.findOne().exec();
    expect(conversation).not.toBeNull();
    await ConversationMessage.insertMany(Array.from({ length: 104 }, (_, index) => ({
      conversationId: conversation!._id, senderParticipantId: helper,
      clientMessageId: randomUUID(), sequence: index + 2, text: "Backlog", createdAt: new Date(),
    })));
    await MessageConversation.updateOne({}, { $set: {
      lastAuthorizedAt: new Date(Date.now() - MESSAGE_CLEANUP_DEADLINE_MS - 1000),
    } });
    await MealRequest.deleteOne({ _id: requestId });
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(await sweepMessageCleanup(policy)).toEqual({ checked: 1, deleted: 100, failed: 0, overdue: 1 });
    expect(await sweepMessageCleanup(policy)).toEqual({ checked: 1, deleted: 5, failed: 0, overdue: 0 });
  });

  it("never resurrects a cleaned conversation or operation, even if source facts are restored", async () => {
    const id = randomUUID();
    await send(id);
    await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: { restricted: true } });
    expect((await sweepMessageCleanup(policy)).deleted).toBe(1);
    await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: { restricted: false } });
    await expectRejected(send(id), "unavailable");
    await expectRejected(send(), "unavailable");
    expect(await ConversationMessage.countDocuments()).toBe(0);
    expect(await MessageReceipt.countDocuments()).toBe(1);
  });

  it.each([false, true])("provides atomic Block closure even when conversation already exists = %s", async existing => {
    if (existing) await send();
    else await MessageConversation.deleteMany({});
    const session = await mongoose.startSession();
    try {
      await session.withTransaction(async () => {
        await ParticipantBlock.create([{
          blockerParticipantId: owner, blockedParticipantId: helper,
          blockedRole: "helper", diningLocation: "Jasper Kane Cafe", interactionAt: new Date(),
          ...blockSafetyIdentityFields(`${helper}@nyu.edu`),
        }], { session });
        await bumpBlockFence(owner, helper, session);
        await closeMessagingRelationship(new Types.ObjectId(requestId), helper, session);
      });
    } finally { await session.endSession(); }
    await ParticipantBlock.deleteMany({});
    await expectRejected(send(), "unavailable");
    await expectRejected(service.read(credential(owner), requestId, String(helper)), "unavailable");
    expect((await sweepMessageCleanup(policy)).deleted).toBe(existing ? 1 : 0);
    expect(await MessageConversation.countDocuments({ closedAt: { $exists: true } })).toBe(1);
  });

  it("rolls the closure hook back with the owning transaction", async () => {
    await send();
    const session = await mongoose.startSession();
    try {
      await expect(session.withTransaction(async () => {
        await closeMessagingRelationship(new Types.ObjectId(requestId), helper, session);
        throw new Error("owner mutation aborted");
      })).rejects.toThrow("owner mutation aborted");
    } finally { await session.endSession(); }
    expect((await send()).message.sequence).toBe(2);
  });

  it("refuses a closure handoff outside the owner's transaction", async () => {
    const session = await mongoose.startSession();
    try {
      await expect(closeMessagingRelationship(new Types.ObjectId(requestId), helper, session)).rejects.toThrow("unavailable");
    } finally { await session.endSession(); }
    expect((await send()).message.sequence).toBe(1);
  });

  it("prevents stale sends from committing after cleanup has removed content", async () => {
    await send();
    const barrier = barrierPolicy();
    const pending = createMessagingService(barrier.paused).send(credential(helper), requestId, String(helper), randomUUID(), "Orphan attempt");
    await barrier.entered;
    try {
      await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: { restricted: true } });
      expect((await sweepMessageCleanup(policy)).deleted).toBe(1);
    } finally { barrier.resume(); }
    await currentWork().assertRejected(pending, () => expect(pending).rejects.toMatchObject({ code: "unavailable" }));
    expect(await ConversationMessage.countDocuments()).toBe(0);
    expect(await MessageReceipt.countDocuments()).toBe(1);
  });

  it("does not prematurely close a conversation when placement wins against stale cleanup", async () => {
    await send();
    await MealRequest.updateOne({ _id: requestId }, { $set: { claimExpiresAt: new Date(0) } });
    const { enter, resume, entered, released } = currentWork().barrier();
    const original = MealRequest.findById;
    let first = true;
    // Pause the cleanup's initial source read, before it takes write anchors.
    const spy = vi.spyOn(MealRequest, "findById").mockImplementation(function (...args: Parameters<typeof original>) {
      const query = original.apply(MealRequest, args);
      const exec = query.exec.bind(query);
      query.exec = async function () {
        const result = await exec();
        if (first) { first = false; enter(); await released; }
        return result;
      };
      return query;
    });
    const pending = sweepMessageCleanup(policy);
    await entered;
    try {
      await MealRequest.updateOne({ _id: requestId }, { $set: { status: "placed" } });
    } finally { resume(); }
    expect(await pending).toMatchObject({ deleted: 0, failed: 0 });
    spy.mockRestore();
    expect((await send()).message.sequence).toBe(2);
  });

  it("rechecks passive lapse even without a lifecycle write during a paused send", async () => {
    const expiry = Date.now() + 2000;
    await MealRequest.updateOne({ _id: requestId }, { $set: { claimExpiresAt: new Date(expiry) } });
    const barrier = barrierPolicy();
    const pending = createMessagingService(barrier.paused).send(credential(helper), requestId, String(helper), randomUUID(), "Expired while waiting");
    await barrier.entered;
    await new Promise(resolve => setTimeout(resolve, Math.max(0, expiry - Date.now()) + 20));
    barrier.resume();
    await currentWork().assertRejected(pending, () => expect(pending).rejects.toMatchObject({ code: "unavailable" }));
    expect(await ConversationMessage.countDocuments()).toBe(0);
    expect(await MessageReceipt.countDocuments()).toBe(0);
  }, 15_000);

  it("accepts a send linearized before Block but denies every later protected operation", async () => {
    await send();
    expect((await http(`/api/request/${requestId}/block`, helper, { externalOrderPlaced: true })).status).toBe(200);
    await expectRejected(send(), "unavailable");
    await expectRejected(service.reconcile(credential(helper), requestId, String(helper), randomUUID()), "unavailable");
    expect(await ConversationMessage.countDocuments()).toBe(1);
  });

  it("bounds conversation discovery per pass and drains the next batch fairly", async () => {
    await MessageConversation.deleteMany({});
    const now = new Date();
    await MessageConversation.insertMany(Array.from({ length: 101 }, () => ({
      requestId: new Types.ObjectId(), helperParticipantId: helper, requesterParticipantId: owner,
      sequence: 0, lastAuthorizedAt: now, checkedAt: now,
    })));
    expect(await sweepMessageCleanup(policy)).toMatchObject({ checked: 100, deleted: 0, failed: 0 });
    expect(await sweepMessageCleanup(policy)).toMatchObject({ checked: 1, deleted: 0, failed: 0 });
    expect(await MessageConversation.countDocuments({ cleanedAt: { $exists: true } })).toBe(101);
  });

  it.each(["read", "reconcile", "acknowledge"])("serializes protected %s against Block", async operation => {
    const id = randomUUID();
    await send(id);
    const barrier = barrierPolicy();
    const protectedService = createMessagingService(barrier.paused);
    const pending = operation === "read"
      ? protectedService.read(credential(owner), requestId, { conversationId })
      : operation === "reconcile"
        ? protectedService.reconcile(credential(helper), requestId, { conversationId }, id)
        : protectedService.acknowledgeDisplayed(credential(owner), requestId, { conversationId }, [1]);
    await barrier.entered;
    try {
      expect((await http(`/api/request/${requestId}/block`, helper, { externalOrderPlaced: true })).status).toBe(200);
    } finally { barrier.resume(); }
    await currentWork().assertRejected(pending, () => expect(pending).rejects.toMatchObject({ code: "unavailable" }));
    if (operation === "acknowledge") expect(await readAt(1)).toBeUndefined();
  });

  it("does not transfer conversation history if persisted requester authority changes", async () => {
    await send();
    await MealRequest.updateOne({ _id: requestId }, { $set: { requesterParticipantId: stranger } });
    await expectRejected(service.read(credential(stranger), requestId, { conversationId }), "unavailable");
    expect((await sweepMessageCleanup(policy)).deleted).toBe(1);
  });

  it("denies without mutating an existing conversation when integration is absent", async () => {
    await send();
    await expectRejected(createMessagingService().read(credential(owner), requestId, { conversationId }), "unavailable");
    expect((await MessageConversation.findById(conversationId).lean().exec())?.closedAt).toBeUndefined();
    expect((await send()).message.sequence).toBe(2);
  });

  it("enforces the exact 100-message page boundary", async () => {
    await ConversationMessage.insertMany(Array.from({ length: 101 }, (_, index) => ({
      conversationId: new Types.ObjectId(conversationId), senderParticipantId: helper,
      clientMessageId: randomUUID(), sequence: index + 1, text: `Page boundary ${index}`,
      createdAt: new Date(),
    })));
    const page = await http(path(), owner);
    expect(page.body.messages).toHaveLength(100);
    expect(page.body.nextAfter).toBe(100);
    const tail = await http(`${path()}?after=100`, owner);
    expect(tail.body.messages).toHaveLength(1);
    expect(tail.body.nextAfter).toBe(101);
  });

  it("provides HTTP manual Retry and content-free ambiguous database errors", async () => {
    const body = { clientMessageId: randomUUID(), text: "Keep this message private" };
    expect((await http(path(), helper, body)).status).toBe(201);
    const replay = await http(path(), helper, body);
    expect(replay.status).toBe(200);
    expect(replay.body.message.sequence).toBe(1);
    const conflict = await http(path(), helper, { ...body, text: "Changed payload" });
    expect(conflict.status).toBe(409);
    expect(conflict.headers.get("cache-control")).toBe("private, no-store");
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(ConversationMessage, "create").mockImplementationOnce(() => {
      throw new Error(`synthetic failure: ${body.text}`);
    });
    const failed = await http(path(), helper, { ...body, clientMessageId: randomUUID() });
    expect(failed.status).toBe(503);
    expect(JSON.stringify(failed.body)).not.toContain(body.text);
    expect(log.mock.calls.flat()).toEqual(["[messaging] Protected message operation unavailable"]);
    expect(await ConversationMessage.countDocuments()).toBe(1);
    expect(await MessageReceipt.countDocuments()).toBe(1);
  });

  it("keeps history reads unread until actual conversation open acknowledges its snapshot", async () => {
    await send(randomUUID(), "Helper message");
    await send(randomUUID(), "Requester message", owner);
    await send(randomUUID(), "Another helper message");

    const prefetched = await service.read(credential(owner), requestId, { conversationId });
    expect(prefetched.messages.map(message => message.sequence)).toEqual([1, 2, 3]);
    expect(prefetched.messages.every(message => !("readAt" in message))).toBe(true);
    expect(await readAt(1)).toBeUndefined();
    expect(await readAt(2)).toBeUndefined();
    expect(await readAt(3)).toBeUndefined();

    expect(await service.unreadCounts(credential(owner))).toMatchObject({
      unreadCount: 2,
      conversations: [{ requestId, conversationId, unreadCount: 2 }],
    });
    const opened = await http(conversationPath(), owner);
    expect(opened.status).toBe(200);
    expect(opened.body).toEqual({
      conversationId,
      openingSnapshotSequence: 3,
    });
    expect(await readAt(1)).toBeInstanceOf(Date);
    expect(await readAt(2)).toBeUndefined();
    expect(await readAt(3)).toBeInstanceOf(Date);
    expect(await service.unreadCounts(credential(owner))).toMatchObject({
      unreadCount: 0,
      conversations: [],
    });
  });

  it("acknowledges only explicitly displayed incoming sequences, idempotently and out of order", async () => {
    await send(randomUUID(), "incoming-1");
    await send(randomUUID(), "own-2", owner);
    await send(randomUUID(), "incoming-3");
    await send(randomUUID(), "incoming-4");

    const first = await http(readAckPath(), owner, { displayedSequences: [4] });
    expect(first.status).toBe(200);
    expect(first.body).toEqual({ conversationId, acknowledgedCount: 1 });
    expect(await readAt(1)).toBeUndefined();
    expect(await readAt(2)).toBeUndefined();
    expect(await readAt(3)).toBeUndefined();
    expect(await readAt(4)).toBeInstanceOf(Date);
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(2);

    const repeat = await http(readAckPath(), owner, { displayedSequences: [4] });
    expect(repeat.status).toBe(200);
    expect(repeat.body).toEqual({ conversationId, acknowledgedCount: 0 });
    await service.acknowledgeDisplayed(credential(owner), requestId, { conversationId }, [1]);
    expect(await readAt(1)).toBeInstanceOf(Date);
    expect(await readAt(3)).toBeUndefined();
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(1);
    await service.acknowledgeDisplayed(credential(owner), requestId, { conversationId }, [3]);
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
  });

  it("rejects own, unknown and cross-relationship acknowledgements without mutation", async () => {
    await send(randomUUID(), "incoming");
    await send(randomUUID(), "own", owner);

    for (const displayedSequences of [[2], [99], [1, 2], [1, 99]]) {
      const refused = await http(readAckPath(), owner, { displayedSequences });
      expect(refused.status).toBe(400);
      expect(refused.body).toEqual({ error: expect.objectContaining({ code: "INVALID_MESSAGE" }) });
    }
    const strangerResponse = await http(readAckPath(), stranger, { displayedSequences: [1] });
    expect(strangerResponse.status).toBe(404);
    const wrongRequest = await http(
      `/api/request/${"f".repeat(24)}/conversation/${conversationId}/read`,
      owner,
      { displayedSequences: [1] }
    );
    expect(wrongRequest.status).toBe(404);
    const wrongConversation = await http(
      `/api/request/${requestId}/conversation/${"e".repeat(24)}/read`,
      owner,
      { displayedSequences: [1] }
    );
    expect(wrongConversation.status).toBe(404);
    expect(await readAt(1)).toBeUndefined();
  });

  it("treats duplicate displayed sequences as one acknowledgement, idempotently, and never marks gaps", async () => {
    await send(randomUUID(), "incoming-1");
    await send(randomUUID(), "incoming-2");
    await send(randomUUID(), "incoming-3");
    const first = await http(readAckPath(), owner, { displayedSequences: [3, 3, 3] });
    expect(first.status).toBe(200);
    expect(first.body).toEqual({ conversationId, acknowledgedCount: 1 });
    const repeat = await http(readAckPath(), owner, { displayedSequences: [3, 3] });
    expect(repeat.body).toEqual({ conversationId, acknowledgedCount: 0 });
    expect(await readAt(1)).toBeUndefined();
    expect(await readAt(2)).toBeUndefined();
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(2);
    const empty = await http(readAckPath(), owner, { displayedSequences: [] });
    expect(empty.body).toEqual({ conversationId, acknowledgedCount: 0 });
  });

  it("applies an acknowledgement batch atomically: one invalid reference marks nothing", async () => {
    await send(randomUUID(), "incoming-1");
    await send(randomUUID(), "own-2", owner);
    await send(randomUUID(), "incoming-3");
    const refused = await http(readAckPath(), owner, { displayedSequences: [1, 3, 2] });
    expect(refused.status).toBe(400);
    expect(await readAt(1)).toBeUndefined();
    expect(await readAt(3)).toBeUndefined();
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(2);
  });

  it("keeps a sender's view free of read state after the recipient acknowledges", async () => {
    await send(randomUUID(), "incoming-1");
    await service.acknowledgeDisplayed(credential(owner), requestId, { conversationId }, [1]);
    const senderView = await service.read(credential(helper), requestId, { conversationId });
    expect(JSON.stringify(senderView)).not.toMatch(/readAt|seen|read/i);
  });

  it("keeps unread state on the authenticated participant across installations and excludes own sends", async () => {
    await send(randomUUID(), "helper-to-requester");
    await send(randomUUID(), "requester-to-helper", owner);

    const requesterFromFirstInstallation = await http(MESSAGE_UNREAD_COUNT_ROUTE_PATH, owner);
    const requesterFromSecondInstallation = await http(MESSAGE_UNREAD_COUNT_ROUTE_PATH, owner);
    expect(requesterFromFirstInstallation.body).toEqual({
      unreadCount: 1,
      conversations: [{ requestId, conversationId, unreadCount: 1 }],
    });
    expect(requesterFromSecondInstallation.body).toEqual(requesterFromFirstInstallation.body);
    expect((await service.unreadCounts(credential(helper))).unreadCount).toBe(1);
  });

  it("does not transfer the old helper's conversation or unread messages to a replacement", async () => {
    await send(randomUUID(), "old-helper-message");
    const oldConversationId = conversationId;
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(1);

    await replaceHelper();
    const replacementConversation = await service.open(credential(replacement), requestId);
    expect(replacementConversation.conversationId).not.toBe(oldConversationId);
    expect((await service.unreadCounts(credential(replacement))).unreadCount).toBe(0);
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
    await expectRejected(
      service.read(credential(replacement), requestId, { conversationId: oldConversationId }),
      "unavailable"
    );
    expect(await ConversationMessage.countDocuments({ conversationId: oldConversationId })).toBe(1);
  });

  it("excludes a closed conversation immediately and refuses a delayed acknowledgement before cleanup", async () => {
    await send(randomUUID(), "must-remain-unread");
    const session = await mongoose.startSession();
    try {
      await session.withTransaction(async () => {
        await closeMessagingRelationship(new Types.ObjectId(requestId), helper, session);
      });
    } finally {
      await session.endSession();
    }

    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
    expect(await ConversationMessage.countDocuments({ conversationId })).toBe(1);
    const delayed = await http(readAckPath(), owner, { displayedSequences: [1] });
    expect(delayed.status).toBe(404);
    expect(await readAt(1)).toBeUndefined();
  });

  async function expectUnreadExcludedAfterIneligibility(factsUpdate: Partial<Facts>) {
    await send(randomUUID(), "eligible-message");
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(1);
    await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: factsUpdate });
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
    // The projection is read-only; the next protected operation closes.
    expect((await MessageConversation.findById(conversationId).lean())?.closedAt).toBeUndefined();
    await expectRejected(service.read(credential(owner), requestId, { conversationId }), "unavailable");
    expect((await MessageConversation.findById(conversationId).lean())?.closedAt).toBeTruthy();
  }

  it("stops counting and closes a relationship after pickup ineligibility", async () => {
    await expectUnreadExcludedAfterIneligibility({ pickupConfirmed: true });
  });

  it("stops counting and closes a relationship after suspension ineligibility", async () => {
    await expectUnreadExcludedAfterIneligibility({ restricted: true });
  });

  it("projects unread counts without mutating fences, versions, leases or closure", async () => {
    await send(randomUUID(), "unread-1");
    const snapshot = async () => ({
      participants: await Participant.find({ _id: { $in: [owner, helper] } }).sort({ _id: 1 }).lean(),
      request: await MealRequest.findById(requestId).lean(),
      conversation: await MessageConversation.findById(conversationId).lean(),
      messages: await ConversationMessage.find({ conversationId }).select("+readAt").lean(),
    });
    const before = await snapshot();
    for (const who of [owner, owner, helper]) await service.unreadCounts(credential(who));
    expect(await snapshot()).toEqual(before);
    await facts().updateOne({ requestId: new Types.ObjectId(requestId) }, { $set: { restricted: true } });
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
    expect(await snapshot()).toEqual(before);
  });

  it("does not block or conflict with a concurrent send while projecting", async () => {
    await send(randomUUID(), "unread-1");
    const results = await Promise.all([
      ...Array.from({ length: 5 }, () => service.unreadCounts(credential(owner))),
      send(randomUUID(), "concurrent-2"),
      send(randomUUID(), "concurrent-3"),
    ]);
    for (const counted of results.slice(0, 5) as Array<{ unreadCount: number }>) {
      expect(counted.unreadCount).toBeGreaterThanOrEqual(1);
      expect(counted.unreadCount).toBeLessThanOrEqual(3);
    }
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(3);
  });

  it("fails closed instead of returning a partial total past the conversation bound", async () => {
    await send(randomUUID(), "unread-1");
    const now = new Date();
    await MessageConversation.insertMany(Array.from({ length: MAX_UNREAD_CONVERSATIONS }, () => ({
      requestId: new Types.ObjectId(), helperParticipantId: new Types.ObjectId(),
      requesterParticipantId: owner, sequence: 0, lastAuthorizedAt: now, checkedAt: now,
    })));
    await expectRejected(service.unreadCounts(credential(owner)), "unavailable");
    expect((await service.unreadCounts(credential(helper))).unreadCount).toBe(0);
  });

  it("excludes unread by suspension or final loss regardless of their order, but keeps the pending-deletion exception", async () => {
    await send(randomUUID(), "unread-1");
    const key = { requestId: new Types.ObjectId(requestId) };
    await facts().updateOne(key, { $set: { pendingDeletion: true } });
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(1);
    await facts().updateOne(key, { $set: { restricted: true } });
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
    await Participant.deleteOne({ _id: helper });
    await facts().updateOne(key, { $set: { restricted: false } });
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);
    await expectRejected(service.read(credential(owner), requestId, { conversationId }), "unavailable");
    await expectRejected(
      service.acknowledgeDisplayed(credential(owner), requestId, { conversationId }, [1]), "unavailable"
    );
    expect(await readAt(1)).toBeUndefined();
  });

  it("serializes a send racing the authoritative opening snapshot", async () => {
    const barrier = barrierPolicy();
    const openingService = createMessagingService(barrier.paused);
    const openingPromise = openingService.open(credential(owner), requestId);
    await barrier.entered;
    let sent: Awaited<ReturnType<typeof send>> | undefined;
    try {
      sent = await send(randomUUID(), "committed during opening");
    } finally {
      barrier.resume();
    }
    if (!sent) throw new Error("Concurrent send did not produce a result");
    const opened = await openingPromise;
    expect(opened.openingSnapshotSequence).toBe(sent.message.sequence);
    expect(await readAt(sent.message.sequence)).toBeInstanceOf(Date);
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(0);

    const afterSnapshot = await send(randomUUID(), "arrived after opening");
    expect(afterSnapshot.message.sequence).toBeGreaterThan(opened.openingSnapshotSequence);
    expect((await service.unreadCounts(credential(owner))).unreadCount).toBe(1);
    const ack = await service.acknowledgeDisplayed(
      credential(owner), requestId, { conversationId }, [afterSnapshot.message.sequence]
    );
    expect(ack.acknowledgedCount).toBe(1);
  });
});
