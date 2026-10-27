import type { ClientSession, Types } from "mongoose";
import type {
  IReportMessageContext,
  ReportMessageCaptureReason,
} from "../models/moderation.js";

/**
 * Neutral seam between the safety/lifecycle writers (Report, Block,
 * suspension) and the dormant messaging module. It deliberately imports no
 * messaging model, so loading a writer never registers messaging collections.
 * While no hooks are installed no conversation can exist, so every call is a
 * no-op; the activation composition root installs the real hooks.
 */
export type ReportMessageContext = IReportMessageContext;

export class ReportMessageCaptureDeniedError extends Error {
  constructor() {
    super("Report message context is unavailable.");
    this.name = "ReportMessageCaptureDeniedError";
  }
}

export class ReportMessageCaptureUnavailableError extends Error {
  constructor(
    readonly reason: ReportMessageCaptureReason,
    readonly messages: ReportMessageContext["messages"] = []
  ) {
    super("Report message context is unavailable.");
    this.name = "ReportMessageCaptureUnavailableError";
  }
}

export interface MessagingLifecycleHooks {
  closeForRelationship(
    requestId: Types.ObjectId,
    helperId: Types.ObjectId,
    session: ClientSession
  ): Promise<void>;
  closeForRequest(
    requestId: Types.ObjectId,
    helperId: Types.ObjectId | null,
    session: ClientSession
  ): Promise<void>;
  closeForPair(first: Types.ObjectId, second: Types.ObjectId, session: ClientSession): Promise<void>;
  closeForParticipant(participantId: Types.ObjectId, session: ClientSession): Promise<void>;
  grantReportLease(
    session: ClientSession,
    input: { requestId: Types.ObjectId; helperId: Types.ObjectId; holderId: Types.ObjectId }
  ): Promise<boolean>;
  captureReportContext(
    session: ClientSession,
    input: {
      handoff: boolean;
      requestId: Types.ObjectId;
      reporterId: Types.ObjectId;
      reportedId: Types.ObjectId;
    }
  ): Promise<ReportMessageContext>;
}

let installed: MessagingLifecycleHooks | null = null;

export function installMessagingLifecycleHooks(hooks: MessagingLifecycleHooks): void {
  installed = hooks;
}

export function uninstallMessagingLifecycleHooks(): void {
  installed = null;
}

export function messagingLifecycleInstalled(): boolean {
  return installed !== null;
}

/** Call inside the owner's own transaction, after its fence write. */
export async function closeMessagingForPairInSession(
  first: Types.ObjectId,
  second: Types.ObjectId,
  session: ClientSession
): Promise<void> {
  await installed?.closeForPair(first, second, session);
}

/** Call inside the owner's transaction; an installed closure failure aborts it. */
export async function closeMessagingRelationshipInSession(
  requestId: Types.ObjectId,
  helperId: Types.ObjectId,
  session: ClientSession
): Promise<void> {
  await installed?.closeForRelationship(requestId, helperId, session);
}

/** Retire every existing relationship for one request in its owner's transaction. */
export async function closeMessagingRequestInSession(
  requestId: Types.ObjectId,
  helperId: Types.ObjectId | null,
  session: ClientSession
): Promise<void> {
  await installed?.closeForRequest(requestId, helperId, session);
}

export async function closeMessagingForParticipantInSession(
  participantId: Types.ObjectId,
  session: ClientSession
): Promise<void> {
  await installed?.closeForParticipant(participantId, session);
}

export async function grantMessagingReportLeaseInSession(
  session: ClientSession,
  input: { requestId: Types.ObjectId; helperId: Types.ObjectId; holderId: Types.ObjectId }
): Promise<boolean> {
  return (await installed?.grantReportLease(session, input)) ?? false;
}

export async function captureMessagingReportContextInSession(
  session: ClientSession,
  input: {
    handoff: boolean;
    requestId: Types.ObjectId;
    reporterId: Types.ObjectId;
    reportedId: Types.ObjectId;
  }
): Promise<ReportMessageContext> {
  return installed
    ? installed.captureReportContext(session, input)
    : {
        captureStatus: "incomplete",
        captureReason: "lifecycle-unavailable",
        messages: [],
      };
}
