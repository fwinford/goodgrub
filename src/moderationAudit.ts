import type { ClientSession, Types } from "mongoose";
import {
  ModerationAuditEvent,
  type AuditSubjectKind,
  type IRetentionRunSummary,
  type ModerationAuditEventKind,
} from "../models/moderation.js";
import { MODERATION_AUDIT_EVENT_RETENTION_MS } from "./moderationConstants.js";

/**
 * Append-only, content-free audit writes (RH, "Audit events").
 *
 * A moderation mutation and its audit row commit in one transaction: both go
 * through the same `session`, so an action that cannot be audited does not run.
 * Rows carry references, kinds, counts and a session fingerprint, never an
 * email, report text, rationale, hold note or credential.
 */

/** A case, suspension or hold event. No clock of its own: it cascades. */
export async function appendSubjectAudit(
  session: ClientSession,
  kind: Exclude<ModerationAuditEventKind, "moderator-authentication" | "retention-run">,
  subjectKind: AuditSubjectKind,
  subjectId: Types.ObjectId,
  actor?: string
): Promise<void> {
  await ModerationAuditEvent.create([{ kind, subjectKind, subjectId, actor }], { session });
}

/** Authentication events and retention-run proof carry a 90-day TTL at creation. */
export async function appendClockedAudit(
  kind: "moderator-authentication" | "retention-run",
  now: Date,
  run?: IRetentionRunSummary,
  session?: ClientSession,
  actor?: string
): Promise<void> {
  await ModerationAuditEvent.create(
    [
      {
        kind,
        run,
        actor,
        deleteAt: new Date(now.getTime() + MODERATION_AUDIT_EVENT_RETENTION_MS),
      },
    ],
    session ? { session } : undefined
  );
}
