import { randomUUID } from "node:crypto";
import { createServer, type Server } from "node:http";
import { once } from "node:events";
import express from "express";
import mongoose, { Types } from "mongoose";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, ParticipantBlock, Request as MealRequest, RequestParticipation } from "../models/db.js";
import { ConversationMessage, MessageConversation, MessageReceipt, initializeMessagingIndexes } from "../models/messaging.js";
import {
  createMessagingService, sweepMessageCleanup, closeMessagingRelationship, type MessagingPolicy,
} from "./messaging.js";
import { createMessagingHandlers, CONVERSATION_ROUTE_PATH, MESSAGE_ROUTE_PATH } from "./messagingRoutes.js";
import { claimRequest, releaseClaim, CLAIM_ROUTE_PATH, CLAIM_RELEASE_ROUTE_PATH } from "./claimRoute.js";
import { signParticipantAuthority } from "./participantCredentials.js";
import {
  blockSafetyIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";

const uri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = uri ? describe : describe.skip;
const secret = "messaging-test-signing-secret-32-bytes";
const owner = new Types.ObjectId();
const helper = new Types.ObjectId();
const replacement = new Types.ObjectId();
const stranger = new Types.ObjectId();
const credential = (id: Types.ObjectId, version = 1) => signParticipantAuthority(id, version, Buffer.from(secret));

interface Facts { requestId: Types.ObjectId; pickupConfirmed: boolean; restricted: boolean; pendingDeletion: boolean }
const facts = () => mongoose.connection.collection<Facts>("synthetic_messaging_cp4_authority");
// Synthetic authority only; production policy adapters are activation gates.
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
let requestId2: string;
let conversationId2: string;

const target = (id = conversationId) => ({ conversationId: id });
const history = (actor: Types.ObjectId, before?: number, limit?: number, rid = requestId, cid = conversationId) =>
  service.history(credential(actor), rid, target(cid), before, limit);
const send = (id = randomUUID(), text = "Meet by the pickup counter", actor = helper) =>
  service.send(credential(actor), requestId, String(helper), id, text);

async function http(url: string, actor: Types.ObjectId | null, body?: unknown) {
  const response = await fetch(`${base}${url}`, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      ...(actor ? { "x-commonplate-participant": credential(actor) } : {}),
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { status: response.status, headers: response.headers, body: await response.json() };
}
const historyPath = (q: string, rid = requestId, cid = conversationId) => `/api/request/${rid}/conversation/${cid}/messages?${q}`;

async function seed(count: number, id = conversationId, prefix = "c1", createdAt = (_n: number) => new Date(1_700_000_000_000)) {
  const start = (await MessageConversation.findById(id).lean())!.sequence;
  const docs = Array.from({ length: count }, (_, i) => {
    const sequence = start + i + 1;
    return {
      conversationId: new Types.ObjectId(id), clientMessageId: randomUUID(),
      senderParticipantId: sequence % 2 ? owner : helper, sequence, text: `${prefix}-${sequence}`,
      createdAt: createdAt(sequence),
    };
  });
  if (docs.length) await ConversationMessage.collection.insertMany(docs);
  await MessageConversation.updateOne({ _id: id }, { $set: { sequence: start + count } });
}

async function walk(actor: Types.ObjectId, limit: number, rid = requestId, cid = conversationId, hook?: (page: number) => Promise<void>) {
  const pages: Awaited<ReturnType<typeof history>>[] = [];
  let before: number | undefined;
  for (;;) {
    const page = await history(actor, before, limit, rid, cid);
    pages.push(page);
    if (!page.hasOlder) return pages;
    before = page.nextBefore!;
    await hook?.(pages.length);
  }
}
const seqs = (pages: { messages: { sequence: number }[] }[]) => pages.flatMap(page => page.messages.map(m => m.sequence));
const range = (from: number, to: number) => Array.from({ length: Math.max(0, to - from + 1) }, (_, i) => from + i);
const facts2 = (rid: string, set: Partial<Facts>) => facts().updateOne({ requestId: new Types.ObjectId(rid) }, { $set: set });

async function forwardAll(actor: Types.ObjectId, after = 0, rid = requestId, cid = conversationId) {
  const all: { sequence: number; text: string }[] = [];
  for (;;) {
    const page = await service.read(credential(actor), rid, target(cid), after, 100);
    all.push(...page.messages);
    if (page.messages.length < 100) return all;
    after = page.nextAfter;
  }
}

describeMongo("MSG1 CP4 real-Mongo history pagination", () => {
  beforeAll(async () => {
    vi.stubEnv("PARTICIPANT_SIGNING_SECRET", secret);
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    const isolated = new URL(uri!);
    isolated.pathname = "/commonplate_msg1_cp4_history";
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
    app.get(CONVERSATION_ROUTE_PATH, handlers.open);
    app.get(MESSAGE_ROUTE_PATH, handlers.read);
    app.post(CLAIM_ROUTE_PATH, claimRequest);
    app.post(CLAIM_RELEASE_ROUTE_PATH, releaseClaim);
    server = createServer(app);
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test HTTP server missing");
    base = `http://127.0.0.1:${address.port}`;
  });

  async function makeRequest(requester: Types.ObjectId, claimer: Types.ObjectId) {
    const future = new Date(Date.now() + 3600_000);
    const request = await MealRequest.create({
      vendor: "Jasper Kane Cafe", food: "Rice bowl", pickupWindowText: "ASAP",
      email: `${requester}@nyu.edu`, requesterParticipantId: requester,
      status: "open", expiresAt: future, deleteAt: future,
    });
    const rid = String(request._id);
    await facts().insertOne({ requestId: new Types.ObjectId(rid), pickupConfirmed: false, restricted: false, pendingDeletion: false });
    expect((await http(`/api/request/${rid}/claim`, claimer, {})).status).toBe(200);
    return { rid, cid: (await service.open(credential(requester), rid)).conversationId };
  }

  beforeEach(async () => {
    for (const model of [ConversationMessage, MessageReceipt, MessageConversation, ParticipantBlock, RequestParticipation, MealRequest, Participant]) {
      await model.collection.deleteMany({});
    }
    await facts().deleteMany({});
    for (const id of [owner, helper, replacement, stranger]) {
      await Participant.create({ _id: id, email: `${id}@nyu.edu`, verifiedAt: new Date() });
    }
    ({ rid: requestId, cid: conversationId } = await makeRequest(owner, helper));
  });

  afterAll(async () => {
    if (server) await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  describe("ordering, boundaries and projection", () => {
    it("returns an empty first page for an empty conversation", async () => {
      expect(await history(owner)).toEqual({ messages: [], hasOlder: false, nextBefore: null, newestSequence: 0 });
      expect(await history(helper, 1)).toEqual({ messages: [], hasOlder: false, nextBefore: null, newestSequence: 0 });
    });

    it("handles a single-message conversation and exposes only the allowlisted projection", async () => {
      await send(randomUUID(), "only");
      const page = await history(owner);
      expect(Object.keys(page).sort()).toEqual(["hasOlder", "messages", "newestSequence", "nextBefore"]);
      expect(page).toMatchObject({ hasOlder: false, nextBefore: 1, newestSequence: 1 });
      expect(Object.keys(page.messages[0]).sort()).toEqual(["clientMessageId", "createdAt", "sender", "sequence", "text"]);
      expect(page.messages[0]).toMatchObject({ sender: "other", text: "only" });
      expect((await history(helper)).messages[0].sender).toBe("own");
    });

    it.each([
      [0], [1], [49], [50], [51], [100], [101], [201],
    ])("walks a %s-message conversation by 50 with every sequence exactly once", async count => {
      await seed(count);
      const pages = await walk(owner, 50);
      expect(seqs(pages).sort((a, b) => a - b)).toEqual(range(1, count));
      expect(pages[0].messages.map(m => m.sequence)).toEqual(range(Math.max(1, count - 49), count));
      pages.forEach(page => {
        expect(page.messages.map(m => m.sequence)).toEqual([...page.messages.map(m => m.sequence)].sort((a, b) => a - b));
        expect(page.newestSequence).toBe(count);
      });
    });

    it.each([[3, 6], [3, 7], [3, 9], [1, 5], [100, 201]])("limit=%s over %s messages: hasOlder is exact at every boundary", async (limit, count) => {
      await seed(count);
      const pages = await walk(owner, limit);
      pages.forEach((page, i) => {
        const expectedHasOlder = i < pages.length - 1;
        expect(page.hasOlder).toBe(expectedHasOlder);
        expect(page.hasOlder).toBe(page.messages[0].sequence > 1);
      });
      expect(seqs(pages).sort((a, b) => a - b)).toEqual(range(1, count));
    });

    it("treats before bounds exactly: before=1 empty, before>head+1 equals the latest page, before=head excludes head", async () => {
      await seed(10);
      expect(await history(owner, 1, 5)).toMatchObject({ messages: [], hasOlder: false, nextBefore: null, newestSequence: 10 });
      expect(await history(owner, 11, 5)).toEqual(await history(owner, undefined, 5));
      expect(await history(owner, Number.MAX_SAFE_INTEGER, 5)).toEqual(await history(owner, undefined, 5));
      expect((await history(owner, 10, 5)).messages.map(m => m.sequence)).toEqual(range(5, 9));
      expect((await history(owner, 6, 5))).toMatchObject({ hasOlder: false, nextBefore: 1 });
    });

    it("orders strictly by sequence regardless of equal or reversed createdAt", async () => {
      await seed(120, conversationId, "same", () => new Date(1_700_000_000_000));
      const same = await walk(owner, 7);
      expect(seqs(same).sort((a, b) => a - b)).toEqual(range(1, 120));
      expect(same[0].messages.map(m => m.sequence)).toEqual(range(114, 120));

      await ConversationMessage.collection.deleteMany({});
      await MessageConversation.updateOne({ _id: conversationId }, { $set: { sequence: 0 } });
      await seed(90, conversationId, "rev", n => new Date(1_700_000_000_000 - n * 1000));
      const reversed = await walk(helper, 10);
      expect(seqs(reversed).sort((a, b) => a - b)).toEqual(range(1, 90));
      reversed.forEach(page => expect(page.messages.map(m => m.sequence)).toEqual(
        [...page.messages.map(m => m.sequence)].sort((a, b) => a - b)));
      expect(reversed[0].messages.map(m => m.sequence)).toEqual(range(81, 90));
    });
  });

  describe("large conversation, bounded work and index support", () => {
    const COUNT = 5_000;

    it("walks 5,000 messages by 100 without duplicates or gaps and matches a forward walk", async () => {
      await seed(COUNT);
      const pages = await walk(owner, 100);
      expect(pages).toHaveLength(50);
      const backward = seqs(pages).sort((a, b) => a - b);
      expect(backward).toEqual(range(1, COUNT));
      const forward = await forwardAll(owner);
      expect(forward.map(m => m.sequence)).toEqual(backward);
      const byBackward = new Map(pages.flatMap(p => p.messages).map(m => [m.sequence, m.text]));
      forward.forEach(m => expect(byBackward.get(m.sequence)).toBe(m.text));
    }, 120_000);

    it("uses message_sequence_unique in reverse with no collection scan or in-memory sort", async () => {
      await seed(COUNT);
      const id = new Types.ObjectId(conversationId);
      for (const [before, limit] of [[undefined, 50], [4_000, 50], [2_500, 100], [60, 50], [1, 50]] as const) {
        const plan = await ConversationMessage.find(before === undefined ? { conversationId: id } : { conversationId: id, sequence: { $lt: before } })
          .select("+text").sort({ sequence: -1 }).limit(limit + 1).explain("executionStats") as any;
        const text = JSON.stringify(plan.queryPlanner.winningPlan);
        expect(text).toContain('"stage":"IXSCAN"');
        expect(text).toContain('"indexName":"message_sequence_unique"');
        expect(text).toContain('"direction":"backward"');
        expect(text).not.toContain("COLLSCAN");
        expect(text).not.toMatch(/"stage":"(SORT|SORT_KEY_GENERATOR)"/);
        expect(plan.executionStats.nReturned).toBeLessThanOrEqual(limit + 1);
        expect(plan.executionStats.totalKeysExamined).toBeLessThanOrEqual(limit + 1);
        expect(plan.executionStats.totalDocsExamined).toBeLessThanOrEqual(limit + 1);
      }
    });

    it("the executed service query itself (profiler) is index-bounded for latest and older pages", async () => {
      await seed(COUNT);
      const db = mongoose.connection.db!;
      await db.command({ profile: 0 });
      await db.dropCollection("system.profile").catch(() => undefined);
      await db.command({ profile: 2 });
      try {
        await history(owner, undefined, 50);
        await history(owner, 3_000, 100);
        await history(owner, 40, 50);
      } finally {
        await db.command({ profile: 0 });
      }
      const entries = await db.collection("system.profile").find({
        ns: `${db.databaseName}.${ConversationMessage.collection.collectionName}`,
      }).toArray() as any[];
      const finds = entries.filter(e => e.command?.find);
      expect(finds).toHaveLength(3);
      for (const entry of finds) {
        expect(entry.planSummary).toBe("IXSCAN { conversationId: 1, sequence: 1 }");
        expect(entry.hasSortStage).toBeFalsy();
        expect(entry.docsExamined).toBeLessThanOrEqual(entry.command.limit);
        expect(entry.command.limit).toBeLessThanOrEqual(101);
        expect(entry.keysExamined).toBeLessThanOrEqual(entry.command.limit);
      }
      expect(finds.map(e => e.command.limit)).toEqual([51, 101, 51]);
    });
  });

  describe("concurrency", () => {
    it("concurrent sends never shift, duplicate or skip an older page; forward catch-up from newestSequence has no seam gap", async () => {
      await seed(60);
      const first = await history(owner, undefined, 10);
      expect(first.newestSequence).toBe(60);
      const sends = Array.from({ length: 25 }, (_, i) => send(randomUUID(), `late-${i}`, i % 2 ? helper : owner));
      const olderPages: typeof first[] = [];
      let page = first;
      while (page.hasOlder) {
        page = await history(owner, page.nextBefore!, 10);
        olderPages.push(page);
      }
      await Promise.all(sends);
      const walked = [first, ...olderPages].flatMap(p => p.messages.map(m => m.sequence)).sort((a, b) => a - b);
      expect(walked).toEqual(range(1, 60));
      const caught = await forwardAll(owner, first.newestSequence);
      expect(caught.map(m => m.sequence)).toEqual(range(61, 85));
      expect(new Set(caught.map(m => m.text))).toEqual(new Set(Array.from({ length: 25 }, (_, i) => `late-${i}`)));
    });

    it("a replayed older cursor after later sends returns the identical page", async () => {
      await seed(30);
      const before = await history(owner, 21, 10);
      await Promise.all(Array.from({ length: 5 }, () => send()));
      expect(await history(owner, 21, 10)).toEqual({ ...before, newestSequence: 35 });
      expect((await history(owner)).messages.map(m => m.sequence)).toEqual(range(1, 35));
    });

    it("sequential interleave: a send between every page of a full walk preserves the original set", async () => {
      await seed(40);
      const pages = await walk(owner, 7, requestId, conversationId, async () => { await send(); });
      expect(seqs(pages).sort((a, b) => a - b)).toEqual(range(1, 40));
      expect(pages[0].newestSequence).toBe(40);
      expect((await forwardAll(owner, 40)).map(m => m.sequence)).toEqual(range(41, 40 + pages.length - 1));
    });

    it("concurrent history, send and forward reads serialize under the CP1 fences", async () => {
      await seed(20);
      const ops: Promise<unknown>[] = [];
      for (let i = 0; i < 12; i++) {
        ops.push(history(owner, undefined, 5), history(helper, 15, 5), send(), service.read(credential(owner), requestId, target(), 0, 5));
      }
      const results = await Promise.all(ops);
      results.forEach((result, i) => { if (i % 4 === 1) expect((result as { messages: { sequence: number }[] }).messages.map(m => m.sequence)).toEqual(range(10, 14)); });
      expect(await MessageConversation.findById(conversationId).lean().then(c => c!.sequence)).toBe(32);
      expect(await ConversationMessage.countDocuments({ conversationId })).toBe(32);
    }, 15_000);

    it("retries a history snapshot after a concurrent send and reconciles the seam exactly once", async () => {
      await seed(20);
      const newest = await history(owner, undefined, 10);
      let entered!: () => void;
      let resume!: () => void;
      const hasEntered = new Promise<void>(resolve => { entered = resolve; });
      const gate = new Promise<void>(resolve => { resume = resolve; });
      let authorizations = 0;
      const paused = createMessagingService({
        async authorize(request, session, now) {
          const allowed = await policy.authorize(request, session, now);
          if (authorizations++ === 0) {
            entered();
            await gate;
          }
          return allowed;
        },
      });
      const olderPending = paused.history(credential(owner), requestId, target(), newest.nextBefore!, 10);
      await hasEntered;
      try {
        await send();
      } finally {
        resume();
        await olderPending.catch(() => undefined);
      }
      const older = await olderPending;
      expect(authorizations).toBeGreaterThan(1);
      expect(older.messages.map(message => message.sequence)).toEqual(range(1, 10));
      expect(older.newestSequence).toBe(21);

      const caught = await forwardAll(owner, newest.newestSequence);
      expect(caught.map(message => message.sequence)).toEqual([21]);
      const combined = [
        ...older.messages.map(message => message.sequence),
        ...newest.messages.map(message => message.sequence),
        ...caught.map(message => message.sequence),
      ];
      expect(combined.sort((a, b) => a - b)).toEqual(range(1, 21));
      expect(new Set(combined).size).toBe(21);
    }, 15_000);

    it("an idempotent retry creates nothing and leaves pages unchanged", async () => {
      const id = randomUUID();
      await send(id, "once");
      const before = await history(owner);
      expect((await send(id, "once")).created).toBe(false);
      expect(await history(owner)).toEqual(before);
    });
  });

  describe("forged, stale and cross-conversation bounds", () => {
    it("an out-of-range or huge bound grants nothing beyond this conversation", async () => {
      await seed(5);
      const all = await history(owner, Number.MAX_SAFE_INTEGER, 100);
      expect(all.messages.map(m => m.sequence)).toEqual(range(1, 5));
      expect(await history(owner, 3, 100)).toMatchObject({ messages: expect.any(Array), hasOlder: false });
    });

    it("applying another conversation's cursor returns only this conversation's content", async () => {
      await seed(8);
      ({ rid: requestId2, cid: conversationId2 } = await makeRequest(stranger, replacement));
      await seed(30, conversationId2, "c2");
      const foreign = await history(stranger, undefined, 10, requestId2, conversationId2);
      const applied = await history(owner, foreign.nextBefore!, 50);
      expect(applied.messages.map(m => m.text)).toEqual(range(1, 8).map(n => `c1-${n}`));
      const reverse = await history(stranger, 5, 50, requestId2, conversationId2);
      expect(reverse.messages.every(m => m.text.startsWith("c2-"))).toBe(true);
    });

    it("keeps interleaved conversations with overlapping sequences isolated and denies cross-account/path mixes", async () => {
      await seed(12);
      ({ rid: requestId2, cid: conversationId2 } = await makeRequest(stranger, replacement));
      await seed(12, conversationId2, "c2");
      const p1 = await walk(owner, 5);
      const p2 = await walk(stranger, 5, requestId2, conversationId2);
      expect(p1.flatMap(p => p.messages).every(m => m.text.startsWith("c1-"))).toBe(true);
      expect(p2.flatMap(p => p.messages).every(m => m.text.startsWith("c2-"))).toBe(true);
      await expect(history(owner, undefined, 5, requestId, conversationId2)).rejects.toThrow("unavailable");
      await expect(history(owner, undefined, 5, requestId2, conversationId2)).rejects.toThrow("unavailable");
      await expect(history(owner, undefined, 5, requestId2, conversationId)).rejects.toThrow("unavailable");
      await expect(history(stranger, undefined, 5, requestId, conversationId)).rejects.toThrow("unavailable");
      await expect(history(replacement, undefined, 5, requestId, conversationId)).rejects.toThrow("unavailable");
      await expect(history(helper, undefined, 5, requestId2, conversationId2)).rejects.toThrow("unavailable");
      await expect(history(owner, undefined, 5, requestId, new Types.ObjectId().toString())).rejects.toThrow("unavailable");
    });
  });

  describe("authority on every page", () => {
    it("denies a third participant, stale/unverified credentials, bad identifiers and an absent policy", async () => {
      await seed(5);
      await expect(history(stranger)).rejects.toThrow("unavailable");
      await expect(service.history(credential(owner, 2), requestId, target(), undefined, 5)).rejects.toThrow("unavailable");
      await expect(service.history("not-a-credential", requestId, target(), undefined, 5)).rejects.toThrow("unavailable");
      await expect(service.history(credential(owner).replace(/.$/, c => c === "a" ? "b" : "a"), requestId, target(), undefined, 5)).rejects.toThrow("unavailable");
      await expect(service.history(credential(owner), "bad", target(), undefined, 5)).rejects.toThrow("unavailable");
      await expect(service.history(credential(owner), requestId, { conversationId: "bad" }, undefined, 5)).rejects.toThrow("unavailable");
      await expect(createMessagingService(undefined).history(credential(owner), requestId, target(), undefined, 5)).rejects.toThrow("unavailable");
      const failing = createMessagingService({ authorize: async () => { throw new Error("adapter down"); } });
      await expect(failing.history(credential(owner), requestId, target(), undefined, 5)).rejects.toThrow("adapter down");
      const denying = createMessagingService({ authorize: async () => false });
      await expect(denying.history(credential(owner), requestId, target(), undefined, 5)).rejects.toThrow("unavailable");
    });

    it("denies without disclosing existence: a nonexistent conversation, a denied one and an invalid credential are indistinguishable", async () => {
      await send(randomUUID(), "SECRET-TEXT");
      const outcomes = await Promise.all([
        http(historyPath("direction=backward"), stranger),
        http(historyPath("direction=backward", requestId, new Types.ObjectId().toString()), owner),
        http(historyPath("direction=backward", new Types.ObjectId().toString(), conversationId), owner),
      ]);
      outcomes.forEach(o => {
        expect(o.status).toBe(404);
        expect(o.body).toEqual(outcomes[0].body);
        expect(JSON.stringify(o.body)).not.toContain("SECRET-TEXT");
      });
      const missing = await http(historyPath("direction=backward"), null);
      expect(missing.status).toBe(401);
      expect(JSON.stringify(missing.body)).not.toContain("SECRET-TEXT");
    });

    it("HTTP: private headers, ascending page, content-free 400s and unchanged forward shape", async () => {
      await seed(12);
      const page = await http(historyPath("direction=backward&limit=5"), owner);
      expect(page.status).toBe(200);
      expect(page.headers.get("cache-control")).toBe("private, no-store");
      expect(page.headers.get("vary")).toMatch(/x-commonplate-participant/i);
      expect(page.body.messages.map((m: { sequence: number }) => m.sequence)).toEqual(range(8, 12));
      expect(page.body).toMatchObject({ hasOlder: true, nextBefore: 8, newestSequence: 12 });
      const older = await http(historyPath("direction=backward&limit=5&before=8"), helper);
      expect(older.body.messages.map((m: { sequence: number }) => m.sequence)).toEqual(range(3, 7));
      const forward = await http(historyPath("after=10"), owner);
      expect(Object.keys(forward.body).sort()).toEqual(["messages", "nextAfter"]);
      expect(forward.body.messages.map((m: { sequence: number }) => m.sequence)).toEqual([11, 12]);
      for (const bad of ["direction=backward&after=1", "before=3", "direction=backward&before=0", "direction=sideways", "direction=backward&limit=101"]) {
        const result = await http(historyPath(bad), owner);
        expect(result.status).toBe(400);
        expect(result.body.error.code).toBe("INVALID_MESSAGE");
      }
    });

    it("HTTP: a throwing policy is 503 without leaking content", async () => {
      await send(randomUUID(), "SECRET-TEXT");
      const app = express();
      const handlers = createMessagingHandlers({ authorize: async () => { throw new Error("PRIVATE adapter detail"); } });
      app.get(MESSAGE_ROUTE_PATH, handlers.read);
      const local = createServer(app);
      local.listen(0, "127.0.0.1");
      await once(local, "listening");
      const address = local.address() as { port: number };
      const error = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        const response = await fetch(`http://127.0.0.1:${address.port}${historyPath("direction=backward")}`, {
          headers: { "x-commonplate-participant": credential(owner) },
        });
        const body = JSON.stringify(await response.json());
        expect(response.status).toBe(503);
        expect(body).not.toMatch(/SECRET|PRIVATE/);
        expect(error.mock.calls.flat().join(" ")).not.toMatch(/SECRET|PRIVATE/);
      } finally {
        error.mockRestore();
        await new Promise<void>(resolve => local.close(() => resolve()));
      }
    });
  });

  describe("lifecycle, closure and non-resurrection", () => {
    it("a replacement helper cannot read the former helper's transcript; old cursors are useless", async () => {
      await seed(15);
      const oldPage = await history(owner, undefined, 5);
      expect((await http(`/api/request/${requestId}/claim/release`, helper, {})).status).toBe(200);
      expect((await http(`/api/request/${requestId}/claim`, replacement, {})).status).toBe(200);
      await expect(history(owner)).rejects.toThrow("unavailable");
      await expect(history(helper)).rejects.toThrow("unavailable");
      await expect(history(replacement)).rejects.toThrow("unavailable");
      await expect(history(owner, oldPage.nextBefore!, 5)).rejects.toThrow("unavailable");
      const fresh = (await service.open(credential(owner), requestId)).conversationId;
      expect(fresh).not.toBe(conversationId);
      expect(await history(owner, undefined, 50, requestId, fresh)).toEqual({ messages: [], hasOlder: false, nextBefore: null, newestSequence: 0 });
      expect(await history(owner, oldPage.nextBefore!, 5, requestId, fresh)).toMatchObject({ messages: [] });
      await expect(history(replacement, undefined, 50)).rejects.toThrow("unavailable");
      expect((await MessageConversation.findById(conversationId).lean())!.closedAt).toBeTruthy();
    });

    it.each(["release", "lapse", "requestExpiry", "withdraw", "missingRequest"])("denies every later page after %s", async ending => {
      await seed(30);
      expect((await history(owner, undefined, 10)).hasOlder).toBe(true);
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
      await expect(history(owner, 21, 10)).rejects.toThrow("unavailable");
      await expect(history(helper, 21, 10)).rejects.toThrow("unavailable");
      expect(await ConversationMessage.countDocuments({ conversationId })).toBe(30);
    });

    it("synthetic pickup closure and moderation restriction revoke; pending deletion keeps access", async () => {
      await seed(10);
      await facts2(requestId, { pendingDeletion: true });
      expect((await history(owner)).messages).toHaveLength(10);
      await facts2(requestId, { restricted: true });
      await expect(history(owner)).rejects.toThrow("unavailable");
      await facts2(requestId, { restricted: false });
      await expect(history(owner)).rejects.toThrow("unavailable");
      expect((await MessageConversation.findById(conversationId).lean())!.closedAt).toBeTruthy();
    });

    it("placed continues until synthetic pickup closes it, then history stays denied", async () => {
      await seed(10);
      await MealRequest.updateOne({ _id: requestId }, { $set: {
        status: "placed", claimExpiresAt: new Date(0), expiresAt: new Date(0),
        placedAt: new Date(), deleteAt: new Date(Date.now() + 7 * 86400_000),
      } });
      expect((await history(owner)).messages).toHaveLength(10);
      await facts2(requestId, { pickupConfirmed: true });
      await expect(history(owner)).rejects.toThrow("unavailable");
      await facts2(requestId, { pickupConfirmed: false });
      await expect(history(helper)).rejects.toThrow("unavailable");
    });

    it("denies at the placed horizon during TTL lag", async () => {
      await seed(3);
      await MealRequest.updateOne({ _id: requestId }, { $set: { status: "placed", deleteAt: new Date(Date.now() - 1) } });
      await expect(history(owner)).rejects.toThrow("unavailable");
    });

    it("credential revocation during a walk denies the next page and every later one", async () => {
      await seed(50);
      let served = 0;
      await expect(walk(helper, 10, requestId, conversationId, async page => {
        served = page;
        if (page === 2) await Participant.updateOne({ _id: helper }, { $inc: { authorityVersion: 1 } });
      })).rejects.toThrow("unavailable");
      expect(served).toBe(2);
      await expect(history(helper, 10, 5)).rejects.toThrow("unavailable");
      await expect(service.history(credential(helper, 2), requestId, target(), 10, 5)).resolves.toMatchObject({ messages: expect.any(Array) });
    });

    it("removing the requester Participant denies the requester's next page", async () => {
      await seed(30);
      await expect(history(owner, undefined, 10)).resolves.toMatchObject({ hasOlder: true });
      await Participant.deleteOne({ _id: owner });
      await expect(history(owner, 21, 10)).rejects.toThrow("unavailable");
    });

    it.each([false, true])("Block closure (conversation already opened = %s) is terminal, including Block then Unblock", async opened => {
      await seed(opened ? 10 : 0);
      if (!opened) await MessageConversation.deleteMany({});
      const session = await mongoose.startSession();
      try {
        await session.withTransaction(async () => {
          await ParticipantBlock.create([{
            blockerParticipantId: owner, blockedParticipantId: helper,
            blockedRole: "helper", diningLocation: "Jasper Kane Cafe", interactionAt: new Date(),
            ...blockSafetyIdentityFields(`${helper}@nyu.edu`),
          }], { session });
          await closeMessagingRelationship(new Types.ObjectId(requestId), helper, session);
        });
      } finally { await session.endSession(); }
      await ParticipantBlock.deleteMany({});
      const before = await MessageConversation.countDocuments();
      await expect(history(owner)).rejects.toThrow("unavailable");
      await expect(history(helper, 5, 5)).rejects.toThrow("unavailable");
      await expect(service.history(credential(owner), requestId, { current: true } as never, undefined, 5)).rejects.toThrow();
      expect(await MessageConversation.countDocuments()).toBe(before);
    });

    it("a pair-fenced Block denies history even before closure is written", async () => {
      await seed(10);
      await ParticipantBlock.create([{
        blockerParticipantId: helper, blockedParticipantId: owner,
        blockedRole: "requester", diningLocation: "Jasper Kane Cafe", interactionAt: new Date(),
        ...blockSafetyIdentityFields(`${owner}@nyu.edu`),
      }]);
      await expect(history(owner)).rejects.toThrow("unavailable");
      await expect(history(helper)).rejects.toThrow("unavailable");
    });

    it("terminal closure is non-resurrecting: repeated, post-cleanup and unblocked pages stay 404 with no new rows", async () => {
      await seed(10);
      await facts2(requestId, { restricted: true });
      await expect(history(owner)).rejects.toThrow("unavailable");
      const closedAt = (await MessageConversation.findById(conversationId).lean())!.closedAt;
      await facts2(requestId, { restricted: false });
      for (let i = 0; i < 3; i++) await expect(history(owner, 5, 5)).rejects.toThrow("unavailable");
      await MessageConversation.updateOne({ _id: conversationId }, { $set: { cleanupDueAt: new Date(0) } });
      await sweepMessageCleanup(policy);
      expect(await ConversationMessage.countDocuments({ conversationId })).toBe(0);
      const conversations = await MessageConversation.countDocuments();
      await expect(history(owner)).rejects.toThrow("unavailable");
      await expect(history(helper, 3, 2)).rejects.toThrow("unavailable");
      expect(await MessageConversation.countDocuments()).toBe(conversations);
      expect((await MessageConversation.findById(conversationId).lean())!.closedAt).toEqual(closedAt);
    });

    it("history never creates a conversation for a nonexistent or foreign id", async () => {
      const before = await MessageConversation.countDocuments();
      await expect(history(owner, undefined, 5, requestId, new Types.ObjectId().toString())).rejects.toThrow("unavailable");
      await expect(history(stranger, undefined, 5, requestId, conversationId)).rejects.toThrow("unavailable");
      expect(await MessageConversation.countDocuments()).toBe(before);
    });

    it("same-email recreation with a fresh credential cannot read prior open or closed history", async () => {
      await seed(10);
      const email = `${helper}@nyu.edu`;
      await Participant.deleteOne({ _id: helper });
      const recreated = new Types.ObjectId();
      await Participant.create({ _id: recreated, email, verifiedAt: new Date() });
      await expect(history(helper)).rejects.toThrow("unavailable");
      await expect(history(recreated)).rejects.toThrow("unavailable");
      const ownerEmail = `${owner}@nyu.edu`;
      await Participant.deleteOne({ _id: owner });
      const recreatedOwner = new Types.ObjectId();
      await Participant.create({ _id: recreatedOwner, email: ownerEmail, verifiedAt: new Date() });
      await expect(history(recreatedOwner)).rejects.toThrow("unavailable");
    });

    it("races: a page paused inside authorization linearizes entirely after a committed revocation", async () => {
      await seed(20);
      let entered!: () => void;
      let resume!: () => void;
      const hasEntered = new Promise<void>(r => { entered = r; });
      const gate = new Promise<void>(r => { resume = r; });
      let first = true;
      const paused = createMessagingService({
        async authorize(request, session, now) {
          const allowed = await policy.authorize(request, session, now);
          if (first) { first = false; entered(); await gate; }
          return allowed;
        },
      });
      const pending = paused.history(credential(owner), requestId, target(), undefined, 10);
      const settled = pending.then(() => "page" as const, (e: Error) => e.message);
      await hasEntered;
      await MealRequest.updateOne({ _id: requestId }, { $set: { status: "withdrawn" } });
      resume();
      expect(await settled).toBe("unavailable");
    });

    it("races: a page that commits before a revocation returns whole content, and no later page can", async () => {
      await seed(20);
      const page = await history(owner, undefined, 10);
      expect(page.messages).toHaveLength(10);
      await facts2(requestId, { restricted: true });
      await expect(history(owner, page.nextBefore!, 10)).rejects.toThrow("unavailable");
    });

    it("races: concurrent history pages versus release/replacement never leak content after the commit", async () => {
      await seed(40);
      const pages = Array.from({ length: 16 }, () => history(owner, undefined, 10).then(
        p => ({ ok: true as const, p }), (e: Error) => ({ ok: false as const, e: e.message })));
      const release = http(`/api/request/${requestId}/claim/release`, helper, {});
      const results = await Promise.all(pages);
      expect((await release).status).toBe(200);
      results.forEach(r => {
        if (r.ok) expect(r.p.messages.map(m => m.sequence)).toEqual(range(31, 40));
        else expect(r.e).toBe("unavailable");
      });
      await expect(history(owner)).rejects.toThrow("unavailable");
    });
  });

  describe("CP1 compatibility", () => {
    it("forward and backward walks return identical message sets; forward defaults, caps and keys are unchanged", async () => {
      await seed(250);
      const backward = (await walk(owner, 50)).flatMap(p => p.messages);
      const forward = await forwardAll(owner);
      expect(forward).toHaveLength(250);
      expect(forward).toEqual([...backward].sort((a, b) => a.sequence - b.sequence));
      const first = await service.read(credential(owner), requestId, target());
      expect(first.messages).toHaveLength(100);
      expect(Object.keys(first).sort()).toEqual(["messages", "nextAfter"]);
      expect(first.nextAfter).toBe(100);
      await expect(service.read(credential(owner), requestId, target(), 0, 101)).rejects.toThrow("invalid");
      await expect(service.history(credential(owner), requestId, target(), undefined, 101)).rejects.toThrow("invalid");
    });

    it("send, forward read, reconcile and idempotency remain intact alongside history", async () => {
      const id = randomUUID();
      const created = await send(id, "hello");
      expect(created).toMatchObject({ created: true, message: { sequence: 1, text: "hello" } });
      expect(await send(id, "hello")).toMatchObject({ created: false });
      await expect(send(id, "different")).rejects.toThrow("conflict");
      expect((await service.reconcile(credential(helper), requestId, target(), id)).message).toMatchObject({ sequence: 1 });
      expect((await history(owner)).messages).toHaveLength(1);
      expect((await service.read(credential(owner), requestId, target())).nextAfter).toBe(1);
    });
  });
});
