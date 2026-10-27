import { createHash, randomBytes } from "node:crypto";
import { RetentionAlertState } from "../models/moderation.js";
import type { RetentionAlertReason } from "./reportAlerts.js";
import { readModeratorConfig } from "./moderatorSecurity.js";

const DELIVERY_LEASE_MS = 5 * 60 * 1000;
export type RetentionAlertSender = (
  recipient: string,
  content: { subject: string; text: string }
) => Promise<void>;
const APPROVED_REASONS = new Set<RetentionAlertReason>([
  "last-run-failed",
  "stale-run",
  "overdue-records",
  "invariant-violation",
  "key-unavailable",
  "hold-review-due",
]);

function safeReasons(reasons: string[]): RetentionAlertReason[] {
  return [...new Set(reasons)].filter((reason): reason is RetentionAlertReason =>
    APPROVED_REASONS.has(reason as RetentionAlertReason)
  );
}

function fingerprint(reasons: RetentionAlertReason[]): string {
  return createHash("sha256").update([...reasons].sort().join("\0")).digest("hex");
}

async function initializeState(): Promise<void> {
  await RetentionAlertState.updateOne(
    { scope: "global" },
    {
      $setOnInsert: {
        scope: "global",
        currentStatus: "resolved",
        currentReasons: [],
        attempts: 0,
        serial: 0,
      },
    },
    { upsert: true, runValidators: true }
  ).exec();
}

async function clearCurrentIncident(): Promise<void> {
  await initializeState();
  await RetentionAlertState.updateOne(
    { scope: "global" },
    {
      $set: { currentStatus: "resolved", currentReasons: [] },
      $unset: { currentFingerprint: 1, leaseId: 1, leaseUntil: 1 },
      $inc: { serial: 1 },
    },
    { runValidators: true }
  ).exec();
}

async function claimDelivery(
  incidentFingerprint: string,
  reasons: RetentionAlertReason[],
  now: Date
): Promise<string | null> {
  await initializeState();
  const leaseId = randomBytes(32).toString("hex");
  const claimed = await RetentionAlertState.findOneAndUpdate(
    {
      scope: "global",
      $and: [
        {
          $or: [
            { currentFingerprint: { $ne: incidentFingerprint } },
            { currentStatus: { $in: ["failed", "pending"] } },
          ],
        },
        {
          $or: [
            { currentStatus: { $ne: "pending" } },
            { leaseUntil: { $lte: now } },
            { leaseUntil: { $exists: false } },
          ],
        },
      ],
    },
    {
      $set: {
        currentFingerprint: incidentFingerprint,
        currentReasons: reasons,
        currentStatus: "pending",
        leaseId,
        leaseUntil: new Date(now.getTime() + DELIVERY_LEASE_MS),
        lastAttemptAt: now,
      },
      $unset: { lastAttemptStatus: 1 },
      $inc: { attempts: 1, serial: 1 },
    },
    { new: true, runValidators: true }
  )
    .select("leaseId")
    .lean<{ leaseId?: string }>()
    .exec();
  return claimed?.leaseId ?? null;
}

async function finishDelivery(
  incidentFingerprint: string,
  leaseId: string,
  outcome: "submitted" | "failed",
  now: Date
): Promise<void> {
  const result = await RetentionAlertState.updateOne(
    {
      scope: "global",
      currentFingerprint: incidentFingerprint,
      leaseId,
      currentStatus: "pending",
    },
    {
      $set: {
        currentStatus: outcome,
        lastAttemptStatus: outcome,
        lastAttemptAt: now,
      },
      $unset: { leaseId: 1, leaseUntil: 1 },
      $inc: { serial: 1 },
    },
    { runValidators: true }
  ).exec();
  if (result.modifiedCount !== 1) {
    console.error("[retention] alert outcome could not be recorded");
  }
}

/**
 * Sends one content-free alert for each distinct active retention condition.
 * Failed attempts are retried on the next sweep; an accepted provider request
 * is recorded as submitted, never as delivered.
 */
export async function deliverRetentionAlert(
  reasons: string[],
  now: Date = new Date(),
  sender?: RetentionAlertSender
): Promise<void> {
  const normalized = safeReasons(reasons);
  try {
    if (normalized.length === 0) {
      await clearCurrentIncident();
      return;
    }
    const incidentFingerprint = fingerprint(normalized);
    const leaseId = await claimDelivery(incidentFingerprint, normalized, now);
    if (!leaseId) return;

    let outcome: "submitted" | "failed" = "failed";
    try {
      const config = readModeratorConfig();
      if (!config) throw new Error("Moderator configuration is unavailable.");
      const { buildRetentionAlertContent, sendRetentionAlert } = await import("./reportAlerts.js");
      const content = buildRetentionAlertContent(normalized, now);
      await (sender ?? sendRetentionAlert)(config.alertRecipient, content);
      outcome = "submitted";
    } catch {
      outcome = "failed";
    }
    await finishDelivery(incidentFingerprint, leaseId, outcome, new Date());
  } catch {
    console.error("[retention] alert state could not be updated");
  }
}
