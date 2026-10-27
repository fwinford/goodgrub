import { createHash } from "node:crypto";
import mongoose, { type ClientSession, Types } from "mongoose";
import {
  Participant,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
import {
  ConversationMessage,
  MessageConversation,
  MessageReceipt,
  type Message,
} from "../models/messaging.js";
import { isParticipantPairFenced } from "./participantBlocks.js";
import {
  readParticipantSigningSecret,
  verifyParticipantAuthority,
} from "./participantCredentials.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import { evaluateParticipantText } from "./participantTextFilter.js";

export const MESSAGE_CLEANUP_DEADLINE_MS = 24 * 60 * 60 * 1000;
export const MESSAGE_CLEANUP_INTERVAL_MS = 60 * 1000;
export const MESSAGE_BATCH_SIZE = 100;
export const MAX_UNREAD_CONVERSATIONS = 100;
export const MESSAGE_HISTORY_DEFAULT_LIMIT = 50;

export class MessagingError extends Error {
  constructor(public readonly code: "unavailable" | "invalid" | "conflict" | "filtered") {
    super(code);
  }
}

export interface MessagingRequest {
  _id: Types.ObjectId;
  status: string;
  requesterParticipantId?: Types.ObjectId | null;
  helperParticipantId?: Types.ObjectId | null;
  expiresAt?: Date | null;
  claimExpiresAt?: Date | null;
  deleteAt?: Date | null;
}

export interface MessagingPolicy {
  // Must read authoritative pickup/moderation/deletion facts in this session.
  // A missing adapter denies access; an unavailable adapter must throw.
  authorize: (request: MessagingRequest, session: ClientSession, now: Date) => Promise<boolean>;
}

export interface MessageView {
  clientMessageId: string;
  sequence: number;
  sender: "own" | "other";
  text: string;
  createdAt: Date;
}

type MessagingTarget = string | { conversationId: string } | { current: true };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const objectId = /^[0-9a-f]{24}$/;

export function validateMessage(text: unknown, clientMessageId: unknown): asserts text is string {
  if (
    typeof text !== "string" || text.length === 0 || text.length > 2000 ||
    text.trim().length === 0 || Buffer.byteLength(text, "utf8") > 8000 ||
    typeof clientMessageId !== "string" || !uuid.test(clientMessageId)
  ) throw new MessagingError("invalid");
}

function view(message: Message, actor: string): MessageView {
  return {
    clientMessageId: message.clientMessageId,
    sequence: message.sequence,
    sender: String(message.senderParticipantId) === actor ? "own" : "other",
    text: message.text,
    createdAt: message.createdAt,
  };
}

function isLive(request: MessagingRequest, now: Date): boolean {
  if (request.status === "placed") {
    return Boolean(request.deleteAt && request.deleteAt > now);
  }
  return request.status === "claimed" &&
    Boolean(request.expiresAt && request.expiresAt > now) &&
    Boolean(request.claimExpiresAt && request.claimExpiresAt > now);
}

export async function relationshipAllowed(
  request: MessagingRequest | null,
  helper: Types.ObjectId,
  session: ClientSession,
  now: Date,
  policy?: MessagingPolicy
): Promise<boolean> {
  if (
    !request || !request.requesterParticipantId ||
    !request.helperParticipantId?.equals(helper) ||
    request.requesterParticipantId.equals(helper) || !isLive(request, now)
  ) return false;
  const participants = await Participant.find({
    _id: { $in: [request.requesterParticipantId, helper] },
  }).select("email").session(session).lean().exec();
  if (participants.length !== 2 || participants.some(p => !normalizeParticipantPrincipal(p.email))) {
    return false;
  }
  const participation = await RequestParticipation.exists({
    requestId: request._id, participantId: helper,
  }).session(session);
  if (!participation || await isParticipantPairFenced(request.requesterParticipantId, helper, session)) {
    return false;
  }
  return policy ? policy.authorize(request, session, now) : false;
}

export async function requestInSession(id: Types.ObjectId, session: ClientSession) {
  return MealRequest.findById(id)
    .select("status expiresAt claimExpiresAt deleteAt +requesterParticipantId +helperParticipantId")
    .session(session).lean<MessagingRequest>().exec();
}

export async function closeConversation(
  id: Types.ObjectId,
  lastAuthorizedAt: Date,
  session: ClientSession
): Promise<void> {
  await MessageConversation.updateOne(
    { _id: id, closedAt: null },
    { $set: {
      closedAt: lastAuthorizedAt,
      cleanupDueAt: new Date(lastAuthorizedAt.getTime() + MESSAGE_CLEANUP_DEADLINE_MS),
    } },
    { session }
  );
}

// Integration owners call this in the authoritative terminal/Block transaction,
// including when chat has never been opened. Unblock must not undo this row.
export async function closeMessagingRelationship(
  requestId: Types.ObjectId,
  helperId: Types.ObjectId,
  session: ClientSession
): Promise<void> {
  if (!session.inTransaction()) throw new MessagingError("unavailable");
  const request = await requestInSession(requestId, session);
  const participation = await RequestParticipation.exists({
    requestId, participantId: helperId,
  }).session(session);
  if (!request?.requesterParticipantId || !participation ||
    request.requesterParticipantId.equals(helperId)) throw new MessagingError("unavailable");
  const now = new Date();
  await MessageConversation.updateOne(
    { requestId, helperParticipantId: helperId },
    { $setOnInsert: {
      requesterParticipantId: request.requesterParticipantId,
      sequence: 0, lastAuthorizedAt: now, checkedAt: now,
    } },
    { upsert: true, session }
  );
  const conversation = await MessageConversation.findOne({
    requestId, helperParticipantId: helperId,
  }).session(session).exec();
  if (!conversation) throw new MessagingError("unavailable");
  await closeConversation(conversation._id, now, session);
}

export interface MessagingObserver {
  committed(conversationId: string): void | Promise<void>;
}

export function createMessagingService(policy?: MessagingPolicy, observer?: MessagingObserver) {
  async function protectedOperation<T>(
    credential: string,
    requestId: string,
    target: MessagingTarget,
    operation: (conversationId: Types.ObjectId, actor: string, session: ClientSession, now: Date) => Promise<T>,
    signal?: AbortSignal
  ): Promise<T> {
    signal?.throwIfAborted();
    if (!policy) throw new MessagingError("unavailable");
    if (!objectId.test(requestId) ||
      (typeof target === "string" && !objectId.test(target)) ||
      (typeof target === "object" && "conversationId" in target && !objectId.test(target.conversationId))) {
      throw new MessagingError("unavailable");
    }
    const verified = verifyParticipantAuthority(credential, readParticipantSigningSecret());
    if (!verified) throw new MessagingError("unavailable");
    const requestKey = new Types.ObjectId(requestId);
    const session = await mongoose.startSession();
    try {
      const outcome = await session.withTransaction(async () => {
        signal?.throwIfAborted();
        const now = new Date();
        const actor = String(verified.participantId);
        const participant = await Participant.exists({
          _id: verified.participantId, authorityVersion: verified.authorityVersion,
        }).session(session);
        if (!participant) return { allowed: false as const };
        const request = await requestInSession(requestKey, session);
        if (!request) return { allowed: false as const };
        const explicitConversation = typeof target === "object" && "conversationId" in target
          ? await MessageConversation.findOne({
            _id: target.conversationId, requestId: requestKey,
          }).session(session).exec()
          : null;
        const helper = typeof target === "string" ? new Types.ObjectId(target)
          : "conversationId" in target ? explicitConversation?.helperParticipantId
          : request.helperParticipantId;
        if (!helper) return { allowed: false as const };
        const helperId = String(helper);
        if (!request?.requesterParticipantId ||
          (actor !== String(request.requesterParticipantId) && actor !== helperId)) {
          return { allowed: false as const };
        }
        let conversation = explicitConversation ?? await MessageConversation.findOne({
          requestId: requestKey, helperParticipantId: helper,
        }).session(session).exec();
        if (conversation?.closedAt ||
          (conversation && !conversation.requesterParticipantId.equals(request.requesterParticipantId))) {
          return { allowed: false as const };
        }
        if (!await relationshipAllowed(request, helper, session, now, policy)) {
          if (conversation) await closeConversation(conversation._id, conversation.lastAuthorizedAt, session);
          return { allowed: false as const };
        }
        // Real increments on documents written by Block and lifecycle owners
        // prevent snapshot write skew. No upsert may recreate a deleted source.
        const fenced = await Participant.updateMany(
          { _id: { $in: [request.requesterParticipantId, helper] } },
          { $inc: { blockFenceEpoch: 1 } }, { session }
        );
        const touched = await MealRequest.updateOne(
          { _id: requestKey }, { $inc: { __v: 1 } }, { session }
        );
        if (fenced.matchedCount !== 2 || touched.matchedCount !== 1) {
          throw new MessagingError("unavailable");
        }
        if (!conversation) {
          [conversation] = await MessageConversation.create([{
            requestId: requestKey, helperParticipantId: helper,
            requesterParticipantId: request.requesterParticipantId,
            sequence: 0, lastAuthorizedAt: now, checkedAt: now,
          }], { session });
        } else {
          await MessageConversation.updateOne({ _id: conversation._id }, {
            $set: { lastAuthorizedAt: now, checkedAt: now },
          }, { session });
        }
        const value = await operation(conversation._id, actor, session, now);
        signal?.throwIfAborted();
        // Passive lapse has no competing database write to cause a conflict.
        if (!isLive(request, new Date())) throw new MessagingError("unavailable");
        return { allowed: true as const, value };
      });
      if (!outcome?.allowed) throw new MessagingError("unavailable");
      return outcome.value;
    } finally {
      await session.endSession();
    }
  }

  return {
    async authorizeSubscription(credential: string, requestId: string, conversationId: string, signal?: AbortSignal) {
      await protectedOperation(credential, requestId, { conversationId }, async () => undefined, signal);
    },
    async open(credential: string, requestId: string) {
      return protectedOperation(credential, requestId, { current: true }, async (id, actor, session, now) => {
        const conversation = await MessageConversation.findById(id)
          .select("sequence requesterParticipantId helperParticipantId")
          .session(session).lean().exec();
        if (!conversation || !Number.isSafeInteger(conversation.sequence)) {
          throw new MessagingError("unavailable");
        }
        const actorId = new Types.ObjectId(actor);
        const incomingSender = conversation.requesterParticipantId.equals(actorId)
          ? conversation.helperParticipantId
          : conversation.requesterParticipantId;
        await ConversationMessage.updateMany({
          conversationId: id,
          senderParticipantId: incomingSender,
          sequence: { $lte: conversation.sequence },
          readAt: null,
        }, { $set: { readAt: now } }, { session });
        return {
          conversationId: String(id),
          openingSnapshotSequence: conversation.sequence,
        };
      });
    },
    async send(credential: string, requestId: string, target: MessagingTarget, clientMessageId: string, text: string) {
      validateMessage(text, clientMessageId);
      const payloadDigest = createHash("sha256").update(text, "utf8").digest("hex");
      const committed = await protectedOperation(credential, requestId, target, async (id, actor, session, now) => {
        const receipt = await MessageReceipt.findOne({
          senderParticipantId: actor, clientMessageId,
        }).select("+payloadDigest").session(session).exec();
        if (receipt) {
          if (!receipt.conversationId.equals(id) || receipt.payloadDigest !== payloadDigest) {
            throw new MessagingError("conflict");
          }
          const existing = await ConversationMessage.findOne({
            conversationId: id, sequence: receipt.sequence,
          }).select("+text").session(session).lean().exec();
          if (!existing) throw new MessagingError("unavailable");
          return { created: false, message: view(existing, actor), routingKey: String(id) };
        }
        if (!evaluateParticipantText(text).allowed) throw new MessagingError("filtered");
        const conversation = await MessageConversation.findOneAndUpdate(
          { _id: id, closedAt: null }, { $inc: { sequence: 1 } }, { new: true, session }
        );
        if (!conversation || !Number.isSafeInteger(conversation.sequence)) throw new MessagingError("unavailable");
        const [message] = await ConversationMessage.create([{
          conversationId: id, senderParticipantId: actor, clientMessageId,
          sequence: conversation.sequence, text, createdAt: now,
        }], { session });
        await MessageReceipt.create([{
          conversationId: id, senderParticipantId: actor, clientMessageId,
          payloadDigest, sequence: message.sequence, createdAt: now,
        }], { session });
        return { created: true, message: view(message, actor), routingKey: String(id) };
      });
      if (committed.created && observer) {
        // This is outside withTransaction and endSession. Publication is never
        // awaited by HTTP and cannot turn a durable commit into a failed send.
        try {
          void Promise.resolve(observer.committed(committed.routingKey)).catch(() => {
            console.error("[messaging] Change publication failed");
          });
        } catch {
          console.error("[messaging] Change publication failed");
        }
      }
      return { created: committed.created, message: committed.message };
    },
    async read(credential: string, requestId: string, target: MessagingTarget, after = 0, limit = MESSAGE_BATCH_SIZE) {
      if (!Number.isSafeInteger(after) || after < 0 || !Number.isInteger(limit) || limit < 1 || limit > MESSAGE_BATCH_SIZE) {
        throw new MessagingError("invalid");
      }
      return protectedOperation(credential, requestId, target, async (id, actor, session) => {
        const messages = await ConversationMessage.find({ conversationId: id, sequence: { $gt: after } })
          .select("+text").sort({ sequence: 1 }).limit(limit).session(session).lean().exec();
        return { messages: messages.map(message => view(message, actor)),
          nextAfter: messages.at(-1)?.sequence ?? after };
      });
    },
    // `before` is only an exclusive numeric bound inside the target conversation.
    // Every page runs the complete protectedOperation; a bound grants nothing.
    async history(credential: string, requestId: string, target: MessagingTarget, before?: number,
      limit = MESSAGE_HISTORY_DEFAULT_LIMIT) {
      if ((before !== undefined && (!Number.isSafeInteger(before) || before < 1)) ||
        !Number.isInteger(limit) || limit < 1 || limit > MESSAGE_BATCH_SIZE) {
        throw new MessagingError("invalid");
      }
      return protectedOperation(credential, requestId, target, async (id, actor, session) => {
        const rows = await ConversationMessage.find(
          before === undefined ? { conversationId: id } : { conversationId: id, sequence: { $lt: before } }
        ).select("+text").sort({ sequence: -1 }).limit(limit + 1).session(session).lean().exec();
        const head = await MessageConversation.findById(id).select("sequence").session(session).lean().exec();
        if (!head || !Number.isSafeInteger(head.sequence)) throw new MessagingError("unavailable");
        const page = rows.slice(0, limit).reverse();
        return {
          messages: page.map(message => view(message, actor)),
          hasOlder: rows.length > limit,
          nextBefore: page[0]?.sequence ?? null,
          newestSequence: head.sequence,
        };
      });
    },
    async reconcile(credential: string, requestId: string, target: MessagingTarget, clientMessageId: string) {
      if (!uuid.test(clientMessageId)) throw new MessagingError("invalid");
      return protectedOperation(credential, requestId, target, async (id, actor, session) => {
        const message = await ConversationMessage.findOne({
          conversationId: id, senderParticipantId: actor, clientMessageId,
        }).select("+text").session(session).lean().exec();
        return { message: message ? view(message, actor) : null };
      });
    },
    async acknowledgeDisplayed(
      credential: string,
      requestId: string,
      target: MessagingTarget,
      sequences: number[]
    ) {
      if (!Array.isArray(sequences) || sequences.length > MESSAGE_BATCH_SIZE ||
        sequences.some(sequence => !Number.isSafeInteger(sequence) || sequence < 1)) {
        throw new MessagingError("invalid");
      }
      // Repeated entries in one batch are harmless.
      const distinct = [...new Set(sequences)];
      return protectedOperation(credential, requestId, target, async (id, actor, session, now) => {
        const conversation = await MessageConversation.findById(id)
          .select("requesterParticipantId helperParticipantId sequence")
          .session(session).lean().exec();
        if (!conversation || !Number.isSafeInteger(conversation.sequence)) {
          throw new MessagingError("unavailable");
        }
        const actorId = new Types.ObjectId(actor);
        const incomingSender = conversation.requesterParticipantId.equals(actorId)
          ? conversation.helperParticipantId
          : conversation.requesterParticipantId;
        if (distinct.length === 0) {
          return { conversationId: String(id), acknowledgedCount: 0 };
        }
        const displayed = await ConversationMessage.countDocuments({
          conversationId: id,
          senderParticipantId: incomingSender,
          sequence: { $in: distinct, $lte: conversation.sequence },
        }).session(session);
        // Any unknown, own or foreign reference rejects the whole batch.
        if (displayed !== distinct.length) throw new MessagingError("invalid");
        const result = await ConversationMessage.updateMany({
          conversationId: id,
          senderParticipantId: incomingSender,
          sequence: { $in: distinct, $lte: conversation.sequence },
          readAt: null,
        }, { $set: { readAt: now } }, { session });
        return {
          conversationId: String(id),
          acknowledgedCount: result.modifiedCount,
        };
      });
    },
    // Read-only projection: one snapshot transaction, no fence, version,
    // lease or closure writes. Closure of an ineligible relationship is left to
    // the authoritative lifecycle writers and the next protected operation.
    async unreadCounts(credential: string) {
      if (!policy) throw new MessagingError("unavailable");
      const verified = verifyParticipantAuthority(credential, readParticipantSigningSecret());
      if (!verified) throw new MessagingError("unavailable");
      // The signed credential carries a string id; aggregation does not cast.
      const actorId = new Types.ObjectId(String(verified.participantId));
      const session = await mongoose.startSession();
      try {
        return await session.withTransaction(async () => {
          const now = new Date();
          const activeParticipant = await Participant.exists({
            _id: actorId, authorityVersion: verified.authorityVersion,
          }).session(session);
          if (!activeParticipant) throw new MessagingError("unavailable");
          const open = await MessageConversation.find({
            closedAt: null,
            $or: [{ requesterParticipantId: actorId }, { helperParticipantId: actorId }],
          }).select("_id requestId helperParticipantId requesterParticipantId")
            .sort({ _id: 1 }).limit(MAX_UNREAD_CONVERSATIONS + 1)
            .session(session).lean().exec();
          // Fail closed rather than return a silently partial total.
          if (open.length > MAX_UNREAD_CONVERSATIONS) throw new MessagingError("unavailable");
          if (open.length === 0) return { unreadCount: 0, conversations: [] };
          const unread = await ConversationMessage.aggregate<{ _id: Types.ObjectId; count: number }>([
            { $match: {
              conversationId: { $in: open.map(c => c._id) },
              senderParticipantId: { $ne: actorId },
              readAt: null,
            } },
            { $group: { _id: "$conversationId", count: { $sum: 1 } } },
          ]).session(session);
          const counts = new Map(unread.map(entry => [String(entry._id), entry.count]));
          const conversations: Array<{ requestId: string; conversationId: string; unreadCount: number }> = [];
          let unreadCount = 0;
          for (const conversation of open) {
            const count = counts.get(String(conversation._id)) ?? 0;
            if (count === 0) continue;
            const request = await requestInSession(conversation.requestId, session);
            if (!request || !request.requesterParticipantId ||
              !request.requesterParticipantId.equals(conversation.requesterParticipantId) ||
              !await relationshipAllowed(request, conversation.helperParticipantId, session, now, policy)) {
              continue;
            }
            unreadCount += count;
            conversations.push({
              requestId: String(conversation.requestId),
              conversationId: String(conversation._id),
              unreadCount: count,
            });
          }
          return { unreadCount, conversations };
        }, { readConcern: { level: "snapshot" } });
      } finally {
        await session.endSession();
      }
    },
  };
}

export async function sweepMessageCleanup(policy?: MessagingPolicy): Promise<{
  checked: number; deleted: number; failed: number; overdue: number;
}> {
  if (!policy) throw new MessagingError("unavailable");
  const candidates = await MessageConversation.find({ cleanedAt: null })
    .sort({ checkedAt: 1, _id: 1 }).limit(MESSAGE_BATCH_SIZE).lean().exec();
  let deleted = 0;
  let failed = 0;
  for (const candidate of candidates) {
    const session = await mongoose.startSession();
    try {
      const count = await session.withTransaction(async () => {
        const now = new Date();
        const conversation = await MessageConversation.findById(candidate._id).session(session).exec();
        if (!conversation || conversation.cleanedAt) return 0;
        if (!conversation.closedAt) {
          const request = await requestInSession(conversation.requestId, session);
          if (request) {
            await MealRequest.updateOne({ _id: request._id }, { $inc: { __v: 1 } }, { session });
            await Participant.updateMany({
              _id: { $in: [conversation.requesterParticipantId, conversation.helperParticipantId] },
            }, { $inc: { blockFenceEpoch: 1 } }, { session });
          }
          if (request?.requesterParticipantId?.equals(conversation.requesterParticipantId) &&
            await relationshipAllowed(request, conversation.helperParticipantId, session, now, policy)) {
            await MessageConversation.updateOne({ _id: conversation._id }, { $set: { checkedAt: now } }, { session });
            return 0;
          }
          await closeConversation(conversation._id, conversation.lastAuthorizedAt, session);
        }
        // An unexpired, unconsumed report lease defers deletion only; it never
        // outlives the ordinary cleanup deadline and grants no chat access.
        if (conversation.closedAt && conversation.reportLeaseUntil &&
          !conversation.reportLeaseConsumedAt && conversation.reportLeaseUntil > now &&
          !(conversation.cleanupDueAt && conversation.cleanupDueAt <= now)) {
          await MessageConversation.updateOne({ _id: conversation._id }, { $set: { checkedAt: now } }, { session });
          return 0;
        }
        // Conversation write conflicts with sends; a stale send cannot commit
        // after cleanup has won, nor can retry create an orphan after deletion.
        const messages = await ConversationMessage.find({ conversationId: conversation._id })
          .select("_id").sort({ sequence: 1 }).limit(MESSAGE_BATCH_SIZE).session(session).lean().exec();
        const result = await ConversationMessage.deleteMany({
          _id: { $in: messages.map(message => message._id) },
        }, { session });
        const remaining = await ConversationMessage.exists({ conversationId: conversation._id }).session(session);
        await MessageConversation.updateOne({ _id: conversation._id }, { $set: {
          checkedAt: now, ...(!remaining ? { cleanedAt: now } : {}),
        } }, { session });
        return result.deletedCount;
      });
      if (count === undefined) throw new MessagingError("unavailable");
      deleted += count;
    } catch {
      failed++;
      console.error("[messaging] Ordinary message cleanup failed");
    } finally {
      await session.endSession();
    }
  }
  const overdue = await MessageConversation.countDocuments({
    cleanedAt: null, cleanupDueAt: { $lte: new Date() },
  });
  if (overdue) console.error("[messaging] Ordinary message cleanup overdue");
  return { checked: candidates.length, deleted, failed, overdue };
}
