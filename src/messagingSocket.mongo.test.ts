import { randomUUID } from "node:crypto";
import { createServer, type Server } from "node:http";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";
import express, { type RequestHandler } from "express";
import mongoose, { Types } from "mongoose";
import { WebSocket } from "ws";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it as test, vi } from "vitest";
import { Participant, ParticipantBlock, Request as MealRequest, RequestParticipation } from "../models/db.js";
import { ConversationMessage, MessageConversation, MessageReceipt, initializeMessagingIndexes } from "../models/messaging.js";
import { createMessagingService, closeMessagingRelationship, type MessagingPolicy, type MessagingObserver } from "./messaging.js";
import { createMessagingHandlers, CONVERSATION_ROUTE_PATH, MESSAGE_ROUTE_PATH, MESSAGE_RECONCILIATION_PATH } from "./messagingRoutes.js";
import { attachMessagingSocket, MESSAGING_SOCKET_PATH, SOCKET_LIMITS } from "./messagingSocket.js";
import { signParticipantAuthority } from "./participantCredentials.js";
import {
  blockSafetyIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";
import { bumpBlockFence } from "./participantBlocks.js";

const uri = process.env.MONGO_INTEGRATION_URI;
const secret = "messaging-socket-test-secret-32-bytes";
const owner = new Types.ObjectId();
const helper = new Types.ObjectId();
const replacement = new Types.ObjectId();
const stranger = new Types.ObjectId();
const credential = (id = owner, version = 1) => signParticipantAuthority(id, version, Buffer.from(secret));

// Every body, HTTP handler, barrier and detached operation belongs to one
// fixture. A timeout never permits later fixtures to reuse unsettled state.
class Work {
  pending = new Set<Promise<unknown>>();
  failures = new Map<Promise<unknown>, unknown>();
  releases = new Set<() => void>();
  drained = false;
  draining = false;
  own<T>(body: () => Promise<T>) {
    if (this.drained) throw new Error("Fixture already drained");
    const work = Promise.resolve().then(body);
    this.pending.add(work);
    void work.then(() => this.pending.delete(work), error => {
      this.pending.delete(work);
      this.failures.set(work, error);
    });
    return work;
  }
  async rejected(work: Promise<unknown>, message: string) {
    await expect(work).rejects.toThrow(message);
    this.failures.delete(work);
  }
  barrier() {
    let resume!: () => void;
    let enter!: () => void;
    const entered = new Promise<void>(resolve => { enter = resolve; });
    const released = new Promise<void>(resolve => { resume = resolve; });
    const release = () => { enter(); resume(); };
    this.releases.add(release);
    if (this.draining) release();
    return { entered, enter, released, resume };
  }
  async drain() {
    this.draining = true;
    do {
      for (const release of this.releases) release();
      await Promise.allSettled([...this.pending]);
    } while (this.pending.size);
    this.drained = true;
    if (this.failures.size) throw new AggregateError([...this.failures.values()], "Unasserted fixture rejection");
  }
}

let work: Work | undefined;
function current() {
  if (!work) throw new Error("Missing fixture");
  return work;
}
const it = (name: string, body: () => Promise<void>) => test(name, () => {
  const scope = current();
  const operation = scope.own(body);
  return operation.catch(error => {
    scope.failures.delete(operation);
    throw error;
  });
}, 20_000);
const tracked = <T>(body: () => Promise<T>) => current().own(body);
function protocolWork<T>(body: () => Promise<T>) {
  const scope = current();
  const operation = scope.own(body);
  return operation.catch(error => {
    // The transport owns this refusal and converts it to a generic close.
    scope.failures.delete(operation);
    throw error;
  });
}
let requestId: string;
let conversationId: string;
let server: Server;
let base: string;
let transport: ReturnType<typeof attachMessagingSocket>;
let service: ReturnType<typeof createMessagingService>;
let sockets: WebSocket[];
let frames: Map<WebSocket, Record<string, unknown>[]>;
interface Fact { requestId: Types.ObjectId; closed: boolean }
const facts = () => mongoose.connection.collection<Fact>("synthetic_socket_policy");
const policy: MessagingPolicy = {
  async authorize(request, session) {
    const fact = await facts().findOne({ requestId: request._id }, { session });
    return Boolean(fact && !fact.closed);
  },
};
const target = () => ({ conversationId });
const messagePath = () => `/api/request/${requestId}/conversation/${conversationId}/messages`;
const send = (id = randomUUID(), text = "Meet at the pickup counter", sender = helper) =>
  tracked(() => service.send(credential(sender), requestId, target(), id, text));
async function waitFor(check: () => boolean) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline && !check()) await delay(10);
  expect(check()).toBe(true);
}
const connect = (actor = owner, id = conversationId, token = credential(actor), relatedRequest = requestId) => tracked(async () => {
  const socket = new WebSocket(`${base.replace("http:", "ws:")}${MESSAGING_SOCKET_PATH}`, {
    headers: { "x-commonplate-participant": token },
  });
  sockets.push(socket);
  frames.set(socket, []);
  socket.on("error", () => {});
  socket.on("message", data => frames.get(socket)!.push(JSON.parse(data.toString())));
  await once(socket, "open");
  socket.send(JSON.stringify({ type: "subscribe", requestId: relatedRequest, conversationId: id }));
  await waitFor(() => frames.get(socket)!.length > 0 || socket.readyState === WebSocket.CLOSED);
  return socket;
});
const http = (path: string, body?: object) => tracked(async () => {
  const response = await fetch(`${base}${path}`, {
    headers: { "x-commonplate-participant": credential(owner), "Content-Type": "application/json" },
    method: body ? "POST" : "GET",
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  return { status: response.status, body: await response.json() };
});
function handler(operation: RequestHandler): RequestHandler {
  return (req, res, next) => {
    void tracked(async () => { await operation(req, res, next); }).catch(next);
  };
}
async function startServer() {
  const app = express();
  app.use(express.json());
  server = createServer({ maxHeaderSize: 16 * 1024, headersTimeout: 5000 }, app);
  service = createMessagingService(policy, { committed: key => transport.observer.committed(key) });
  transport = attachMessagingSocket(server, {
    authorizeSubscription: (...args) => protocolWork(() => service.authorizeSubscription(...args)),
  });
  const handlers = createMessagingHandlers(policy, transport.observer);
  app.get(CONVERSATION_ROUTE_PATH, handler(handlers.open));
  app.get(MESSAGE_ROUTE_PATH, handler(handlers.read));
  app.post(MESSAGE_ROUTE_PATH, handler(handlers.send));
  app.get(MESSAGE_RECONCILIATION_PATH, handler(handlers.reconcile));
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Missing test server");
  base = `http://127.0.0.1:${address.port}`;
}
async function closeRelationship(block = false) {
  await mongoose.connection.transaction(async session => {
    if (block) {
      await bumpBlockFence(owner, helper, session);
      await ParticipantBlock.create([{
        blockerParticipantId: owner, blockedParticipantId: helper,
        blockedRole: "helper", diningLocation: "Jasper Kane Cafe", interactionAt: new Date(),
        ...blockSafetyIdentityFields(`${helper}@nyu.edu`),
      }], { session });
    }
    await closeMessagingRelationship(new Types.ObjectId(requestId), helper, session);
  });
}

(uri ? describe : describe.skip)("dormant socket real-Mongo authority and recovery", () => {
  beforeAll(async () => {
    vi.stubEnv("PARTICIPANT_SIGNING_SECRET", secret);
    const isolated = new URL(uri!);
    isolated.pathname = "/commonplate_msg1_cp2_socket";
    await mongoose.connect(isolated.toString());
    await prepareParticipantIdentityMongoTestState();
    for (const model of [Participant, ParticipantBlock, MealRequest, RequestParticipation]) await model.createIndexes();
    await initializeMessagingIndexes();
  });
  beforeEach(async () => {
    if (work && !work.drained) throw new Error("Previous fixture unsettled; reuse refused");
    work = new Work();
    await tracked(async () => {
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
        email: `${owner}@nyu.edu`, requesterParticipantId: owner, helperParticipantId: helper,
        status: "claimed", expiresAt: future, claimExpiresAt: future, deleteAt: future,
      });
      requestId = String(request._id);
      await RequestParticipation.create({ requestId: request._id, participantId: helper });
      await facts().insertOne({ requestId: new Types.ObjectId(requestId), closed: false });
      sockets = [];
      frames = new Map();
      await startServer();
      conversationId = (await service.open(credential(), requestId)).conversationId;
    });
  });
  afterEach(async () => {
    try {
      for (const release of current().releases) release();
      for (const socket of sockets ?? []) socket.terminate();
      if (transport) expect(await transport.dispose()).toEqual({ pendingAuthorizations: 0 });
    } finally {
      try {
        await current().drain();
      } finally {
        if (current().drained) {
          if (server) await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
          vi.restoreAllMocks();
        }
      }
    }
  }, 130_000);
  afterAll(async () => {
    if (work && !work.drained) throw new Error("Unsettled fixture blocks disconnect");
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("drains late-created barriers and reports rather than swallowing detached rejections", async () => {
    const nested = new Work();
    current().releases.add(() => { for (const release of nested.releases) release(); });
    const barrier = nested.barrier();
    let completed = false;
    void nested.own(async () => {
      await barrier.released;
      await nested.barrier().released;
      completed = true;
    });
    await nested.drain();
    expect(completed).toBe(true);
    const failed = new Work();
    void failed.own(async () => { throw new Error("Synthetic detached failure"); });
    await expect(failed.drain()).rejects.toThrow("Unasserted fixture rejection");
    expect(failed.drained).toBe(true);
    expect(failed.failures.size).toBe(1);
  });
  it("authenticates actual current requester/helper and conceals stranger/stale conversations", async () => {
    for (const actor of [owner, helper]) {
      const socket = await connect(actor);
      expect(frames.get(socket)![0].type).toBe("subscribed");
    }
    for (const [actor, id] of [[stranger, conversationId], [owner, String(new Types.ObjectId())]] as const) {
      const socket = await connect(actor, id);
      await waitFor(() => socket.readyState === WebSocket.CLOSED);
      expect(frames.get(socket)).toEqual([{ type: "unavailable" }]);
    }
  });
  it("refuses forged, stale and ineligible credentials at upgrade", async () => {
    await current().rejected(connect(owner, conversationId, credential(owner, 2)), "503");
    const forged = `${credential().slice(0, -8)}forgedxx`;
    await current().rejected(connect(owner, conversationId, forged), "503");
    await Participant.updateOne({ _id: owner }, { $set: { email: "ineligible@example.com" } });
    await current().rejected(connect(), "503");
  });
  it("excludes previous and replacement helpers from the other reservation's conversation", async () => {
    const old = conversationId;
    await MealRequest.updateOne({ _id: requestId }, { $set: { helperParticipantId: replacement } });
    await RequestParticipation.create({ requestId: new Types.ObjectId(requestId), participantId: replacement });
    conversationId = (await service.open(credential(replacement), requestId)).conversationId;
    expect(conversationId).not.toBe(old);
    for (const [actor, id] of [[helper, old], [replacement, old], [helper, conversationId]] as const) {
      const socket = await connect(actor, id);
      await waitFor(() => socket.readyState === WebSocket.CLOSED);
      expect(frames.get(socket)!.some(frame => frame.type === "subscribed")).toBe(false);
    }
  });
  it("revokes multiple sockets immediately before delivery and never resurrects after Block/Unblock", async () => {
    const a = await connect();
    const b = await connect();
    await closeRelationship(true);
    await ParticipantBlock.deleteMany({});
    transport.observer.committed(conversationId);
    await waitFor(() => a.readyState === WebSocket.CLOSED && b.readyState === WebSocket.CLOSED);
    for (const socket of [a, b]) expect(frames.get(socket)!.some(frame => frame.type === "changed")).toBe(false);
    const next = await connect();
    await waitFor(() => next.readyState === WebSocket.CLOSED);
    expect(frames.get(next)!.some(frame => frame.type === "subscribed")).toBe(false);
  });
  it("coalesces sixteen real-Mongo subscribers into two serialized credential checks per hint", async () => {
    const clients = [
      ...await Promise.all(Array.from({ length: SOCKET_LIMITS.participantConnections }, () => connect())),
      ...await Promise.all(Array.from({ length: SOCKET_LIMITS.participantConnections }, () => connect(helper))),
    ];
    await waitFor(() => transport.stats().validations === 0);
    const before = await Participant.findById(owner).select("+blockFenceEpoch").lean();
    const authorize = vi.spyOn(service, "authorizeSubscription");
    const checks = vi.spyOn(policy, "authorize");
    for (let i = 0; i < 100; i++) transport.observer.committed(conversationId);
    await waitFor(() => clients.every(socket => frames.get(socket)!.length === 2));
    await waitFor(() => transport.stats().validations === 0);
    expect(authorize).toHaveBeenCalledTimes(2);
    expect(checks).toHaveBeenCalledTimes(2);
    expect(authorize.mock.calls.map(call => call[0]).sort()).toEqual([credential(), credential(helper)].sort());
    const after = await Participant.findById(owner).select("+blockFenceEpoch").lean();
    if (typeof before?.blockFenceEpoch !== "number" || typeof after?.blockFenceEpoch !== "number") {
      throw new Error("Missing participant fence");
    }
    expect(after.blockFenceEpoch - before.blockFenceEpoch).toBe(2);
    for (const socket of clients) expect(frames.get(socket)!.map(frame => frame.type)).toEqual(["subscribed", "changed"]);
    // HTTP remains independently authoritative and usable after the fanout.
    expect((await http(messagePath(), { clientMessageId: randomUUID(), text: "Meet at pickup" })).status).toBe(201);
  });
  it("defers overloaded real-Mongo checks, serves unrelated relationships and revokes without stale hints", async () => {
    const revoked = await connect();
    const others: { socket: WebSocket; request: string; conversation: string; actor: Types.ObjectId }[] = [];
    for (let i = 0; i < SOCKET_LIMITS.validations; i++) {
      const actor = new Types.ObjectId();
      const partner = new Types.ObjectId();
      await Participant.create([
        { _id: actor, email: `${actor}@nyu.edu`, verifiedAt: new Date() },
        { _id: partner, email: `${partner}@nyu.edu`, verifiedAt: new Date() },
      ]);
      const future = new Date(Date.now() + 3600_000);
      const request = await MealRequest.create({
        vendor: "Jasper Kane Cafe", food: "Rice bowl", pickupWindowText: "ASAP",
        email: `${actor}@nyu.edu`, requesterParticipantId: actor, helperParticipantId: partner,
        status: "claimed", expiresAt: future, claimExpiresAt: future, deleteAt: future,
      });
      await RequestParticipation.create({ requestId: request._id, participantId: partner });
      await facts().insertOne({ requestId: new Types.ObjectId(String(request._id)), closed: false });
      const conversation = (await service.open(credential(actor), String(request._id))).conversationId;
      const socket = await connect(actor, conversation, credential(actor), String(request._id));
      others.push({ socket, request: String(request._id), conversation, actor });
    }
    await waitFor(() => transport.stats().validations === 0);
    const barrier = current().barrier();
    const original = policy.authorize;
    let entered = 0;
    const paused = vi.spyOn(policy, "authorize").mockImplementation(async (...args) => {
      const allowed = await original(...args);
      if (entered < SOCKET_LIMITS.validations) {
        entered++;
        if (entered === SOCKET_LIMITS.validations) barrier.enter();
        await barrier.released;
      }
      return allowed;
    });
    transport.observer.committed(conversationId);
    for (const entry of others) transport.observer.committed(entry.conversation);
    await barrier.entered;
    expect(transport.stats().validations).toBe(8);
    expect(transport.stats().queuedValidations).toBe(1);
    expect(others.at(-1)!.socket.readyState).toBe(WebSocket.OPEN);
    expect(frames.get(others.at(-1)!.socket)).toHaveLength(1);
    await closeRelationship(true);
    await ParticipantBlock.deleteMany({});
    barrier.resume();
    await waitFor(() => revoked.readyState === WebSocket.CLOSED &&
      others.every(({ socket }) => frames.get(socket)!.length === 2));
    expect(frames.get(revoked)!.map(frame => frame.type)).toEqual(["subscribed", "unavailable"]);
    expect(others.every(({ socket }) => socket.readyState === WebSocket.OPEN)).toBe(true);
    await waitFor(() => transport.stats().validations === 0 && transport.stats().queuedValidations === 0);
    paused.mockRestore();
    const last = others.at(-1)!;
    expect((await tracked(() => service.send(credential(last.actor), last.request,
      { conversationId: last.conversation }, randomUUID(), "Meet at pickup"))).created).toBe(true);
    await waitFor(() => frames.get(last.socket)!.length === 3);
    expect(await ConversationMessage.countDocuments({ conversationId: last.conversation })).toBe(1);
  });
  it("serializes Block against pending subscription authorization", async () => {
    const barrier = current().barrier();
    let first = true;
    service = createMessagingService({
      async authorize(request, session, now) {
        const allowed = await policy.authorize(request, session, now);
        if (first) { first = false; barrier.enter(); await barrier.released; }
        return allowed;
      },
    });
    const connection = connect();
    await barrier.entered;
    await closeRelationship(true);
    barrier.resume();
    const socket = await connection;
    await waitFor(() => socket.readyState === WebSocket.CLOSED);
    expect(frames.get(socket)!.some(frame => frame.type === "subscribed")).toBe(false);
  });
  it("invalidates an outbound authorization racing terminal closure", async () => {
    const socket = await connect();
    const barrier = current().barrier();
    let first = true;
    service = createMessagingService({
      async authorize(request, session, now) {
        const allowed = await policy.authorize(request, session, now);
        if (first) { first = false; barrier.enter(); await barrier.released; }
        return allowed;
      },
    });
    transport.observer.committed(conversationId);
    await barrier.entered;
    await closeRelationship();
    barrier.resume();
    await waitFor(() => socket.readyState === WebSocket.CLOSED);
    expect(frames.get(socket)!.some(frame => frame.type === "changed")).toBe(false);
  });
  it("denies terminal closure, passive lapse and absent owner policy at the delivery boundary", async () => {
    for (const revoke of [
      () => MealRequest.updateOne({ _id: requestId }, { $set: { claimExpiresAt: new Date(0) } }),
    ]) {
      const socket = await connect();
      await revoke();
      transport.observer.committed(conversationId);
      await waitFor(() => socket.readyState === WebSocket.CLOSED);
      expect(frames.get(socket)!.some(frame => frame.type === "changed")).toBe(false);
    }
    await current().rejected(tracked(() => createMessagingService().authorizeSubscription(credential(), requestId, conversationId)), "unavailable");
  });
  it("revokes credentials on existing sockets and fails closed on unavailable policy", async () => {
    const a = await connect();
    await Participant.updateOne({ _id: owner }, { $inc: { authorityVersion: 1 } });
    transport.observer.committed(conversationId);
    await waitFor(() => a.readyState === WebSocket.CLOSED);
    const b = await connect(helper);
    service = createMessagingService({ authorize: async () => { throw new Error("Synthetic unavailable"); } });
    transport.observer.committed(conversationId);
    await waitFor(() => b.readyState === WebSocket.CLOSED);
    expect(frames.get(b)!.some(frame => frame.type === "changed")).toBe(false);
  });
  it("publishes once after retried transactions and none after abort; failed publisher cannot fail a commit", async () => {
    const observed: string[] = [];
    const publisher: MessagingObserver = { committed: key => { observed.push(key); } };
    const retried = createMessagingService(policy, publisher);
    const commit = vi.spyOn(mongoose.mongo.ClientSession.prototype, "commitTransaction")
      .mockImplementationOnce(async function (this: mongoose.mongo.ClientSession) {
        expect(await ConversationMessage.countDocuments({})).toBe(0);
        expect(observed).toEqual([]);
        await this.abortTransaction();
        const error = new mongoose.mongo.MongoServerError({ message: "synthetic retry" });
        error.addErrorLabel("TransientTransactionError");
        throw error;
      });
    const operationId = randomUUID();
    await tracked(() => retried.send(credential(), requestId, target(), operationId, "Meet at pickup"));
    expect(commit).toHaveBeenCalledTimes(2);
    commit.mockRestore();
    expect(observed).toEqual([conversationId]);
    expect(await ConversationMessage.countDocuments({})).toBe(1);
    expect((await tracked(() => retried.send(credential(), requestId, target(), operationId, "Meet at pickup"))).created).toBe(false);
    expect(observed).toEqual([conversationId]);
    const create = vi.spyOn(ConversationMessage, "create").mockRejectedValueOnce(new Error("Synthetic write abort"));
    await current().rejected(tracked(() => retried.send(credential(), requestId, target(), randomUUID(), "Meet by the entrance")), "Synthetic write abort");
    create.mockRestore();
    expect(observed).toHaveLength(1);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const id = randomUUID();
    const broken = createMessagingService(policy, { committed: () => { throw new Error("PRIVATE"); } });
    const result = await tracked(() => broken.send(credential(), requestId, target(), id, "Meet near the desk"));
    expect(result.created).toBe(true);
    expect(await MessageReceipt.countDocuments({ clientMessageId: id })).toBe(1);
    expect(log).toHaveBeenCalledWith("[messaging] Change publication failed");
    const rejectedPublisher = createMessagingService(policy, {
      committed: () => Promise.reject(new Error("PRIVATE ASYNC")),
    });
    expect((await tracked(() => rejectedPublisher.send(credential(), requestId, target(), randomUUID(), "Meet by the doorway"))).created).toBe(true);
    await waitFor(() => log.mock.calls.length === 2);
    expect(log.mock.calls).toEqual([
      ["[messaging] Change publication failed"], ["[messaging] Change publication failed"],
    ]);
    vi.spyOn(transport.observer, "committed").mockImplementation(() => { throw new Error("PRIVATE HTTP PUBLISHER"); });
    const response = await http(messagePath(), { clientMessageId: randomUUID(), text: "Meet near the counter" });
    expect(response.status).toBe(201);
    expect(log.mock.calls.at(-1)).toEqual(["[messaging] Change publication failed"]);
  });
  it("does not publish from a transaction that fails its commit", async () => {
    const committed = vi.fn();
    const service = createMessagingService(policy, { committed });
    const commit = vi.spyOn(mongoose.mongo.ClientSession.prototype, "commitTransaction")
      .mockRejectedValue(new mongoose.mongo.MongoServerError({ message: "Synthetic commit failure", code: 2 }));
    await current().rejected(tracked(() => service.send(credential(), requestId, target(), randomUUID(), "Meet near pickup")), "Synthetic commit failure");
    commit.mockRestore();
    expect(committed).not.toHaveBeenCalled();
    expect(await ConversationMessage.countDocuments({})).toBe(0);
  });
  it("recovers commit-before-subscribe, catch-up races and dropped live publications using HTTP pagination only", async () => {
    await send();
    const socket = await connect();
    let cursor = 0;
    let dirty = false;
    socket.on("message", data => { if (JSON.parse(data.toString()).type === "changed") dirty = true; });
    const barrier = current().barrier();
    const original = policy.authorize;
    const pausedRead = vi.spyOn(policy, "authorize").mockImplementationOnce(async (...args) => {
      const allowed = await original(...args);
      barrier.enter();
      await barrier.released;
      return allowed;
    });
    const fetching = http(`${messagePath()}?after=${cursor}&limit=1`);
    await barrier.entered;
    await send(randomUUID(), "Meet by the front desk");
    await waitFor(() => dirty);
    expect(cursor).toBe(0);
    barrier.resume();
    const first = await fetching;
    pausedRead.mockRestore();
    expect(first.body.messages).toHaveLength(1);
    cursor = first.body.nextAfter;
    expect(cursor).toBe(1);
    // A hint received during fetch survives the response and requires another
    // HTTP pass. The test client changes its cursor only from applied pages.
    expect(dirty).toBe(true);
    dirty = false;
    const second = await http(`${messagePath()}?after=${cursor}&limit=1`);
    cursor = second.body.nextAfter;
    expect(cursor).toBe(2);
    // A failed/lost publication on a live socket requires periodic HTTP
    // reconciliation, not waiting indefinitely for another hint.
    const hintCount = frames.get(socket)!.length;
    await tracked(() => createMessagingService(policy).send(credential(), requestId, target(), randomUUID(), "Meet at the entrance"));
    const final = await http(`${messagePath()}?after=${cursor}`);
    expect(final.body.messages.map((message: { sequence: number }) => message.sequence)).toEqual([3]);
    expect(frames.get(socket)).toHaveLength(hintCount);
    cursor = final.body.nextAfter;
    // Overflow is a second real lost-publication path, not only a missing
    // observer. Fill in the same callback so the message hint is actually lost.
    const overflowing = createMessagingService(policy, {
      committed(key) {
        for (let i = 0; i < 1000; i++) transport.observer.committed(`unused-${i}`);
        transport.observer.committed(key);
      },
    });
    await tracked(() => overflowing.send(credential(), requestId, target(), randomUUID(), "Meet near the side entrance"));
    const overflowCatchup = await http(`${messagePath()}?after=${cursor}`);
    expect(overflowCatchup.body.messages.map((message: { sequence: number }) => message.sequence)).toEqual([4]);
    expect(frames.get(socket)).toHaveLength(hintCount);
    cursor = overflowCatchup.body.nextAfter;
    transport.observer.committed(conversationId);
    transport.observer.committed("stale-routing-key");
    transport.observer.committed(conversationId);
    expect((await http(`${messagePath()}?after=${cursor}`)).body.messages).toEqual([]);
    expect(JSON.stringify(frames.get(socket))).not.toMatch(/sequence|cursor|text|sender|clientMessageId/);
  });
  it("reconnects after restart and manual HTTP Retry keeps one durable identity and conversation", async () => {
    const id = randomUUID();
    const text = "Meet at the front entrance";
    const first = await http(messagePath(), { clientMessageId: id, text });
    expect(first.status).toBe(201);
    const socket = await connect();
    socket.terminate();
    await once(socket, "close");
    expect(await transport.dispose()).toEqual({ pendingAuthorizations: 0 });
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    await startServer();
    const next = await connect();
    expect(frames.get(next)![0].type).toBe("subscribed");
    expect((await http(`${messagePath()}?after=0`)).body.messages).toHaveLength(1);
    // Reconnect did not resend; explicit retry uses the unchanged operation.
    expect(await MessageReceipt.countDocuments({ clientMessageId: id })).toBe(1);
    expect((await http(`${messagePath()}/${id}`)).body.message.clientMessageId).toBe(id);
    const retry = await http(messagePath(), { clientMessageId: id, text });
    expect(retry.status).toBe(200);
    expect(retry.body.message).toEqual(first.body.message);
    expect(await MessageReceipt.countDocuments({ clientMessageId: id })).toBe(1);
    expect((await http(messagePath(), { clientMessageId: id, text: `${text} changed` })).status).toBe(409);
  });
});
