/**
 * W4-U1.2 constants for the moderation data and reporting foundation.
 *
 * Every value is either fixed by an approved Faith decision (evidence 90 days,
 * history one year, authentication audit 90 days, five reasons, four outcomes,
 * 250-character explanation) or fixed by the READY transcription's constants
 * table (submission window, ledger retention, report caps, hold review
 * interval, sweep cadence). Nothing here is read from the environment.
 */

export const DAY_MS = 24 * 60 * 60 * 1000;
export const HOUR_MS = 60 * 60 * 1000;
export const MINUTE_MS = 60 * 1000;

/** Decisions 2 and 4: detailed evidence is deleted 90 days after the anchor. */
export const REPORT_EVIDENCE_RETENTION_MS = 90 * DAY_MS;

/** Decision 5: minimal case history is kept one calendar year after the anchor. */
export const MODERATION_HISTORY_RETENTION_YEARS = 1;

/** Authentication audit events and retention-run proof events: 90 days. */
export const MODERATION_AUDIT_EVENT_RETENTION_MS = 90 * DAY_MS;

/**
 * A released hold row is a detailed record (it carries a private note), so it
 * follows the detailed-evidence period measured from its end. The target's
 * deadlines are recomputed at release, so deleting the row later never changes
 * a deadline.
 */
export const RELEASED_HOLD_RETENTION_MS = REPORT_EVIDENCE_RETENTION_MS;

/** A hold's `reviewAt` is at most 90 days after creation or the last review. */
export const HOLD_REVIEW_INTERVAL_MAX_MS = 90 * DAY_MS;

/** Retention sweep: hourly; TTL is the physical deleter, the sweep the verifier. */
export const RETENTION_SWEEP_CRON = "17 * * * *";
export const RETENTION_SWEEP_GRACE_MS = 1 * HOUR_MS;
export const RETENTION_SWEEP_STALE_MS = 3 * HOUR_MS;
/** Bound on rows one class of one run touches; the next run takes the rest. */
export const RETENTION_SWEEP_BATCH_LIMIT = 500;

/** Report-submission window W, mint-time skew bound and ledger retention R. */
export const REPORT_SUBMISSION_WINDOW_MS = 24 * HOUR_MS;
export const REPORT_MINT_SKEW_TOLERANCE_MS = 5 * MINUTE_MS;
export const REPORT_LEDGER_RETENTION_MS = 48 * HOUR_MS;
export const REPORT_LEDGER_RETENTION_SECONDS = REPORT_LEDGER_RETENTION_MS / 1000;
export const REPORT_HANDOFF_LIFETIME_MS = 10 * MINUTE_MS;

/** Rolling-window report caps (best-effort; never drops a committed report). */
export const REPORT_CAP_WINDOW_MS = 24 * HOUR_MS;
export const REPORT_VOLUME_CAP = 10;
export const REPORT_PER_REQUEST_CAP = 1;

/** Decision A: the five exact reasons, in the approved order. */
export const REPORT_REASONS = [
  "Harassment or hateful behavior",
  "Sexual or inappropriate content",
  "Threats or unsafe behavior",
  "Spam or misuse of CommonPlate",
  "Other concern",
] as const;
export type ReportReason = (typeof REPORT_REASONS)[number];

export const REPORT_EXPLANATION_MAX_LENGTH = 250;
export const SUSPENSION_RATIONALE_MAX_LENGTH = 1000;
export const HOLD_NOTE_MAX_LENGTH = 500;
export const HOLD_ENDING_CONDITION_MAX_LENGTH = 300;

/** Section B: exactly four outcomes. */
export const REPORT_OUTCOMES = [
  "no-action",
  "request-removed",
  "participant-suspended",
  "request-removed-and-participant-suspended",
] as const;
export type ReportOutcome = (typeof REPORT_OUTCOMES)[number];

export const REPORT_STATES = ["open", "closed"] as const;
export type ReportState = (typeof REPORT_STATES)[number];

export const SUSPENSION_STATES = ["active", "lifted"] as const;
export type SuspensionState = (typeof SUSPENSION_STATES)[number];

export const SUSPENSION_ORIGINS = ["report", "manual"] as const;
export type SuspensionOrigin = (typeof SUSPENSION_ORIGINS)[number];

/** The two explicit hold classes; open cases and active suspensions are structural. */
export const HOLD_CLASSES = ["overlapping-case", "legal-preservation"] as const;
export type HoldClass = (typeof HOLD_CLASSES)[number];

export const HOLD_TARGET_KINDS = ["case", "suspension"] as const;
export type HoldTargetKind = (typeof HOLD_TARGET_KINDS)[number];

export const HOLD_STATES = ["active", "released"] as const;
export type HoldState = (typeof HOLD_STATES)[number];

/** A reason code is a bounded token, not free text. */
export const HOLD_REASON_CODE_PATTERN = /^[a-z0-9][a-z0-9-]{0,39}$/;
