import { type ClientSession, Types } from "mongoose";
import { Participant, Request as MealRequest, RequestParticipation } from "../models/db.js";
import { ConversationMessage, MessageConversation } from "../models/messaging.js";
import {
  MESSAGE_CLEANUP_DEADLINE_MS,
  MessagingError,
  closeMessagingRelationship,
  relationshipAllowed,
  requestInSession,
  type MessagingPolicy,
} from "./messaging.js";
import {
  installMessagingLifecycleHooks,
  ReportMessageCaptureDeniedError,
  ReportMessageCaptureUnavailableError,
  type ReportMessageContext,
} from "./messagingLifecycle.js";

export const REPORT_CONTEXT_MAX_MESSAGES = 10;
export const REPORT_LEASE_MS = 10 * 60 * 1000;

function requireTransaction(session: ClientSession): void {
  if (!session.inTransaction()) throw new MessagingError("unavailable");
}

async function closeExistingConversations(
  filter: Record<string, unknown>,
  session: ClientSession
): Promise<void> {
  const now = new Date();
  await MessageConversation.updateMany(
    { ...filter, closedAt: null },
    { $set: {
      closedAt: now,
      cleanupDueAt: new Date(now.getTime() + MESSAGE_CLEANUP_DEADLINE_MS),
    } },
    { session }
  );
}

async function helpedRequestIds(
  helper: Types.ObjectId,
  requester: Types.ObjectId | null,
  session: ClientSession
): Promise<Types.ObjectId[]> {
  const rows = await RequestParticipation.find({ participantId: helper })
    .select("requestId").session(session).lean().exec();
  if (!rows.length) return [];
  const requests = await MealRequest.find({
    _id: { $in: rows.map(row => row.requestId) },
    ...(requester ? { requesterParticipantId: requester } : {}),
  }).select("_id").session(session).lean().exec();
  return requests.map(request => request._id as Types.ObjectId);
}

/**
 * Permanently closes every private conversation between the pair in either
 * direction, including relationships whose chat was never opened. Idempotent;
 * Unblock never reopens. Must run inside the Block owner's own transaction.
 */
export async function closeMessagingForPair(
  first: Types.ObjectId,
  second: Types.ObjectId,
  session: ClientSession
): Promise<void> {
  requireTransaction(session);
  if (first.equals(second)) throw new MessagingError("unavailable");
  for (const [requester, helper] of [[first, second], [second, first]]) {
    for (const requestId of await helpedRequestIds(helper, requester, session)) {
      await closeMessagingRelationship(requestId, helper, session);
    }
  }
  await closeExistingConversations({ $or: [
    { requesterParticipantId: first, helperParticipantId: second },
    { requesterParticipantId: second, helperParticipantId: first },
  ] }, session);
}

/** Permanently retires every existing helper relationship for a removed request. */
export async function closeMessagingForRequest(
  requestId: Types.ObjectId,
  helperId: Types.ObjectId | null,
  session: ClientSession
): Promise<void> {
  requireTransaction(session);
  if (helperId) await closeMessagingRelationship(requestId, helperId, session);
  await closeExistingConversations({ requestId }, session);
}

/**
 * Permanently closes every private conversation the participant is part of,
 * as requester or helper, including never-opened relationships. Idempotent;
 * reinstatement never reopens. Must run inside the owner's own transaction.
 */
export async function closeMessagingForParticipant(
  participantId: Types.ObjectId,
  session: ClientSession
): Promise<void> {
  requireTransaction(session);
  for (const requestId of await helpedRequestIds(participantId, null, session)) {
    await closeMessagingRelationship(requestId, participantId, session);
  }
  const owned = await MealRequest.find({ requesterParticipantId: participantId })
    .select("_id").session(session).lean().exec();
  if (owned.length) {
    const rows = await RequestParticipation.find({ requestId: { $in: owned.map(r => r._id) } })
      .select("requestId participantId").session(session).lean().exec();
    for (const row of rows) {
      await closeMessagingRelationship(row.requestId as Types.ObjectId, row.participantId as Types.ObjectId, session);
    }
  }
  await closeExistingConversations({ $or: [
    { requesterParticipantId: participantId }, { helperParticipantId: participantId },
  ] }, session);
}

/**
 * Defers ordinary cleanup of one already-closed conversation for at most ten
 * minutes (never past its cleanup deadline) so the named holder can complete a
 * report-only handoff. Granted at most once per conversation, so repeating it
 * cannot extend retention. Grants no read or send authority.
 */
// Lease and deadline decisions always use the server clock; callers cannot
// supply an instant that shortens, extends or revives a lease.
const serverNow = (): Date => new Date();

export async function grantReportCaptureLease(
  session: ClientSession,
  input: { requestId: Types.ObjectId; helperId: Types.ObjectId; holderId: Types.ObjectId }
): Promise<boolean> {
  requireTransaction(session);
  const conversation = await MessageConversation.findOne({
    requestId: input.requestId, helperParticipantId: input.helperId,
  }).session(session).lean().exec();
  if (!conversation || !conversation.closedAt || conversation.cleanedAt ||
    !conversation.cleanupDueAt || conversation.cleanupDueAt <= serverNow() ||
    (!input.holderId.equals(conversation.requesterParticipantId) &&
      !input.holderId.equals(conversation.helperParticipantId))) return false;
  const until = new Date(Math.min(
    serverNow().getTime() + REPORT_LEASE_MS, conversation.cleanupDueAt.getTime()
  ));
  const result = await MessageConversation.updateOne({
    _id: conversation._id, closedAt: { $ne: null }, cleanedAt: null, reportLeaseUntil: null,
  }, { $set: { reportLeaseHolderId: input.holderId, reportLeaseUntil: until } }, { session });
  return result.matchedCount === 1;
}

export interface ReportContextInput {
  // "live": the relationship is currently authorized. "post-block-handoff":
  // the conversation is closed and the reporter holds the unconsumed lease.
  basis: "live" | "post-block-handoff";
  requestId: Types.ObjectId;
  reporterId: Types.ObjectId;
  reportedId: Types.ObjectId;
}

export interface ReportContextMessage {
  sequence: number;
  sender: "reporter" | "reported";
  text: string;
  createdAt: Date;
}

export interface ReportContext {
  conversationId: Types.ObjectId | null;
  requestId: Types.ObjectId;
  requesterId: Types.ObjectId;
  helperId: Types.ObjectId;
  newestSequence: number;
  messages: ReportContextMessage[];
}

/**
 * Server-only capture of up to ten newest committed messages of the exact
 * reporter/reported relationship. Call inside the report transaction; a
 * handoff capture consumes its lease in that same transaction. It is not an
 * HTTP surface and returns no clientMessageId, credentials or request data.
 * Throws "unavailable" for any denial, including erased evidence.
 */
export async function captureReportContext(
  session: ClientSession,
  input: ReportContextInput,
  policy?: MessagingPolicy
): Promise<ReportContext> {
  requireTransaction(session);
  const { requestId, reporterId, reportedId } = input;
  const now = serverNow();
  if (reporterId.equals(reportedId)) throw new ReportMessageCaptureDeniedError();
  const request = await requestInSession(requestId, session);
  const requester = request?.requesterParticipantId;
  if (!request || !requester) throw new ReportMessageCaptureDeniedError();
  const helper = requester.equals(reporterId) ? reportedId
    : requester.equals(reportedId) ? reporterId : null;
  if (!helper) throw new ReportMessageCaptureDeniedError();
  const conversation = await MessageConversation.findOne({
    requestId, helperParticipantId: helper,
  }).session(session).exec();
  if (!conversation && input.basis !== "live") {
    throw new ReportMessageCaptureUnavailableError("conversation-unavailable");
  }
  if (conversation && !conversation.requesterParticipantId.equals(requester)) {
    throw new ReportMessageCaptureDeniedError();
  }

  if (input.basis === "live") {
    if (!policy || conversation?.closedAt ||
      !await relationshipAllowed(request, helper, session, now, policy)) {
      throw new ReportMessageCaptureUnavailableError(
        conversation?.closedAt ? "conversation-closed" : "chat-not-authorized"
      );
    }
    const fenced = await Participant.updateMany(
      { _id: { $in: [requester, helper] } }, { $inc: { blockFenceEpoch: 1 } }, { session }
    );
    const touched = await MealRequest.updateOne({ _id: requestId }, { $inc: { __v: 1 } }, { session });
    if (fenced.matchedCount !== 2 || touched.matchedCount !== 1) throw new MessagingError("unavailable");
    if (conversation) {
      await MessageConversation.updateOne({ _id: conversation._id }, { $set: { checkedAt: now } }, { session });
    }
  } else {
    if (!conversation!.closedAt) throw new ReportMessageCaptureDeniedError();
    if (conversation!.cleanedAt) {
      throw new ReportMessageCaptureUnavailableError("conversation-erased");
    }
    const consumed = await MessageConversation.updateOne({
      _id: conversation!._id,
      closedAt: { $ne: null },
      cleanedAt: null,
      reportLeaseHolderId: reporterId,
      reportLeaseConsumedAt: null,
      reportLeaseUntil: { $gt: now },
      cleanupDueAt: { $gt: now },
    }, { $set: { reportLeaseConsumedAt: now } }, { session });
    if (consumed.matchedCount !== 1) {
      throw new ReportMessageCaptureUnavailableError("handoff-unavailable");
    }
  }

  const newest = conversation?.sequence ?? 0;
  const expected = Math.min(REPORT_CONTEXT_MAX_MESSAGES, newest);
  const rows = expected === 0 ? [] : await ConversationMessage.find({ conversationId: conversation!._id })
    .select("+text").sort({ sequence: -1 }).limit(REPORT_CONTEXT_MAX_MESSAGES)
    .session(session).lean().exec();
  const historyComplete =
    rows.length === expected &&
    rows.every((row, index) => row.sequence === newest - index);
  const messages = rows.slice().reverse().map(row => ({
    sequence: row.sequence,
    sender: row.senderParticipantId.equals(reporterId) ? "reporter" as const : "reported" as const,
    text: row.text,
    createdAt: row.createdAt,
  }));
  const context = {
    conversationId: conversation?._id ?? null,
    requestId,
    requesterId: requester,
    helperId: helper,
    newestSequence: newest,
    messages,
  };
  // Preserve only committed messages from this exact conversation; the status
  // makes a sequence gap explicit rather than implying a complete transcript.
  if (!historyComplete) {
    throw new ReportMessageCaptureUnavailableError("message-history-incomplete", messages);
  }
  return context;
}

/**
 * Report authority is resolved independently by U1.2. This adapter either
 * returns a typed capture result or refuses an invalid reporter/counterpart;
 * it never represents a failed capture as successful empty evidence.
 */
export async function resolveReportMessageContext(
  session: ClientSession,
  input: { handoff: boolean; requestId: Types.ObjectId; reporterId: Types.ObjectId; reportedId: Types.ObjectId },
  policy: MessagingPolicy
): Promise<ReportMessageContext> {
  requireTransaction(session);
  const { requestId, reporterId, reportedId } = input;
  const request = await requestInSession(requestId, session);
  const requester = request?.requesterParticipantId;
  if (!requester || reporterId.equals(reportedId)) {
    throw new ReportMessageCaptureDeniedError();
  }
  const reporterIsRequester = requester.equals(reporterId);
  const reportedIsRequester = requester.equals(reportedId);
  if (!reporterIsRequester && !reportedIsRequester) {
    throw new ReportMessageCaptureDeniedError();
  }
  const helper = requester.equals(reporterId) ? reportedId : reporterId;
  const participation = await RequestParticipation.exists({
    requestId,
    participantId: helper,
  }).session(session);
  if (input.handoff && !participation) throw new ReportMessageCaptureDeniedError();
  if (request.helperParticipantId?.equals(helper) && !participation) {
    throw new ReportMessageCaptureDeniedError();
  }
  if (reporterIsRequester && !request.helperParticipantId?.equals(helper) && !input.handoff) {
    throw new ReportMessageCaptureDeniedError();
  }
  if (reportedIsRequester && !request.helperParticipantId?.equals(helper) && !input.handoff) {
    // U1.2 also authorizes reports of an available requester by participants
    // who never held the request; lack of a chat relationship limits evidence,
    // not that independently authorized safety action.
    return {
      captureStatus: "incomplete",
      captureReason: "chat-not-authorized",
      messages: [],
    };
  }
  const conversation = await MessageConversation.findOne({ requestId, helperParticipantId: helper })
    .session(session).lean().exec();
  if (conversation && !conversation.requesterParticipantId.equals(requester)) {
    throw new ReportMessageCaptureDeniedError();
  }
  if (!conversation && input.handoff) {
    return {
      captureStatus: "incomplete",
      captureReason: "conversation-unavailable",
      messages: [],
    };
  }
  const basis = input.handoff ? "post-block-handoff" : "live";
  if (conversation?.closedAt && !input.handoff) {
    return {
      captureStatus: "incomplete",
      captureReason: "conversation-closed",
      messages: [],
    };
  }
  if (input.handoff && conversation && !conversation.closedAt) {
    throw new ReportMessageCaptureDeniedError();
  }
  try {
    const context = await captureReportContext(session, { basis, requestId, reporterId, reportedId }, policy);
    return {
      captureStatus: "complete",
      messages: context.messages,
    };
  } catch (error) {
    if (error instanceof ReportMessageCaptureUnavailableError) {
      return {
        captureStatus: "incomplete",
        captureReason: error.reason,
        messages: error.messages,
      };
    }
    throw error;
  }
}

/** Activation composition root only: wires the real lifecycle hooks. */
export function installMessagingLifecycle(policy: MessagingPolicy): void {
  installMessagingLifecycleHooks({
    closeForRelationship: closeMessagingRelationship,
    closeForRequest: closeMessagingForRequest,
    closeForPair: closeMessagingForPair,
    closeForParticipant: closeMessagingForParticipant,
    grantReportLease: grantReportCaptureLease,
    captureReportContext: (session, input) => resolveReportMessageContext(session, input, policy),
  });
}
