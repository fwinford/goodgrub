import { sendEmailSafe } from "./emailHelpers.js";
import { readModeratorConfig } from "./moderatorSecurity.js";
import type { ReportAlertSender } from "./reportRoutes.js";
import type { ReportReason } from "./moderationConstants.js";
import { emailSender } from "./emailSender.js";

export type RetentionAlertReason =
  | "last-run-failed"
  | "stale-run"
  | "overdue-records"
  | "invariant-violation"
  | "key-unavailable"
  | "hold-review-due";

export interface ReportAlertContent {
  subject: string;
  text: string;
}

export function buildReportAlertContent(
  reportRef: string,
  reason: ReportReason,
  submittedAt: Date
): ReportAlertContent {
  const config = readModeratorConfig();
  if (!config) throw new Error("Moderator configuration is unavailable.");
  const link = `${config.origin}/moderation/reports/${encodeURIComponent(reportRef)}`;
  return {
    subject: "New report submitted",
    text: [
      "A new report is ready for private review.",
      `Reason: ${reason}`,
      `Submitted: ${submittedAt.toISOString()}`,
      `Moderator dashboard: ${link}`,
    ].join("\n"),
  };
}

export const sendReportAlert: ReportAlertSender = async (recipient, content) => {
  const result = await sendEmailSafe(
    {
      from: emailSender(),
      to: recipient,
      subject: content.subject,
      text: content.text,
    },
    undefined,
    { redactedLabel: "Moderation alert" }
  );
  if (!result.success) throw new Error("Moderation alert was not accepted.");
};

export function buildRetentionAlertContent(
  reasons: RetentionAlertReason[],
  checkedAt: Date
): ReportAlertContent {
  const config = readModeratorConfig();
  if (!config) throw new Error("Moderator configuration is unavailable.");
  const allowedReasons = new Set<RetentionAlertReason>([
    "last-run-failed",
    "stale-run",
    "overdue-records",
    "invariant-violation",
    "key-unavailable",
    "hold-review-due",
  ]);
  const safeReasons = [...new Set(reasons)].filter((reason) => allowedReasons.has(reason));
  if (safeReasons.length === 0) throw new Error("Retention alert has no approved reason.");
  return {
    subject: "Retention health needs review",
    text: [
      "A retention health check requires moderator review.",
      `Conditions: ${safeReasons.join(", ")}`,
      `Checked: ${checkedAt.toISOString()}`,
      `Moderator dashboard: ${config.origin}/moderation/health`,
    ].join("\n"),
  };
}

export const sendRetentionAlert: ReportAlertSender = async (recipient, content) => {
  const result = await sendEmailSafe(
    {
      from: emailSender(),
      to: recipient,
      subject: content.subject,
      text: content.text,
    },
    undefined,
    { redactedLabel: "Retention health alert" }
  );
  if (!result.success) throw new Error("Retention alert was not accepted.");
};
