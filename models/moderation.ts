// moderation.ts
// Mongoose schemas for the W4-U1.2 moderation data foundation (Checkpoint 1),
// consumed by the authorized enforcement and reporting/moderator paths in CP2
// and CP3.
//
// Privacy shape (boundary contracts RH and the P2 fixed mechanism):
// - No collection here holds a participant ID, a raw email, a reporter, or a
//   Subscriber. Moderation rows reference only the restricted `SafetyIdentity`.
// - Detail (evidence, rationale, hold notes) and minimal history (case row,
//   suspension row) live in separate documents so TTL can delete a whole
//   document on each clock. An absent `deleteAt` means "held by live state":
//   MongoDB's TTL monitor ignores documents that lack the indexed field.
// - Audit rows are content-free: references, kinds and counts only.
import crypto from "node:crypto";
import mongoose, { Schema, type Document, type Types } from "mongoose";
import {
  HOLD_CLASSES,
  HOLD_ENDING_CONDITION_MAX_LENGTH,
  HOLD_NOTE_MAX_LENGTH,
  HOLD_REASON_CODE_PATTERN,
  HOLD_STATES,
  HOLD_TARGET_KINDS,
  REPORT_EXPLANATION_MAX_LENGTH,
  REPORT_LEDGER_RETENTION_SECONDS,
  REPORT_OUTCOMES,
  REPORT_REASONS,
  REPORT_STATES,
  SUSPENSION_ORIGINS,
  SUSPENSION_RATIONALE_MAX_LENGTH,
  SUSPENSION_STATES,
  type HoldClass,
  type HoldState,
  type HoldTargetKind,
  type ReportOutcome,
  type ReportReason,
  type ReportState,
  type SuspensionOrigin,
  type SuspensionState,
} from "../src/moderationConstants.js";

/** An opaque, unguessable external reference (dashboard URLs, audit subjects). */
export function generateModerationRef(): string {
  return crypto.randomBytes(18).toString("base64url");
}

const HEX_DIGEST_PATTERN = /^[0-9a-f]{64}$/;
const KEY_ID_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;

/* ========================= SafetyIdentity ========================= */
// The restricted, purpose-limited identity (P2 fixed mechanism). Keyed MACs of
// the exact normalized verified email, one per configured key at the time the
// identity was created or last verified, each with the id of the key that
// produced it. Holds no raw email, participant ID, reporter, or
// deletion-binding material, and supports no use other than enforcing an active
// suspension or an active hold.
//
// Why a set of digests and not one: during a rolling key rotation two instances
// can have different *current* keys while both hold every key. If identity
// uniqueness were per (keyId, digest), each would mint its own identity for the
// same principal. The unique multikey index on `entries.digest` makes any two
// identities that share even one digest a database-level conflict, so the
// second creator fails and retries into the first's identity.
//
// `serial` is the serialization anchor: every transaction that creates,
// references, detaches, confirms or releases an identity writes it, so
// MongoDB's first-committer-wins write conflict orders them. A release that
// re-verified "zero references" can therefore never commit alongside a
// concurrent creator, verification or P2 confirmation.
export interface ISafetyIdentityEntry {
  keyId: string;
  digest: string;
}

export interface ISafetyIdentity extends Document {
  entries: ISafetyIdentityEntry[];
  serial: number;
  createdAt: Date;
}

const SafetyIdentityEntrySchema = new Schema<ISafetyIdentityEntry>(
  {
    keyId: { type: String, required: true, match: KEY_ID_PATTERN },
    digest: { type: String, required: true, match: HEX_DIGEST_PATTERN },
  },
  { _id: false, strict: true }
);

const SafetyIdentitySchema = new Schema<ISafetyIdentity>(
  {
    entries: {
      type: [SafetyIdentityEntrySchema],
      validate: {
        validator: (value: ISafetyIdentityEntry[]) => value.length > 0,
        message: "A safety identity carries at least one keyed digest.",
      },
    },
    serial: { type: Number, required: true, default: 0 },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

SafetyIdentitySchema.index(
  { "entries.digest": 1 },
  { unique: true, name: "safety_identity_digest_unique" }
);
SafetyIdentitySchema.index({ "entries.keyId": 1 }, { name: "safety_identity_key" });

export const SafetyIdentity =
  (mongoose.models.SafetyIdentity as mongoose.Model<ISafetyIdentity>) ||
  mongoose.model<ISafetyIdentity>("SafetyIdentity", SafetyIdentitySchema);

/* ========================= SafetyKeyCheck ========================= */
// One non-secret check value per key id ever used: a MAC of a fixed constant
// under that key. It exists so that reusing a key id with *different* key
// material (which would make every digest minted under the old material
// unfindable, silently lifting suspensions) is detected and fails closed. It
// reveals nothing about the key and holds no participant data.
export interface ISafetyKeyCheck extends Document {
  keyId: string;
  check: string;
  createdAt: Date;
}

const SafetyKeyCheckSchema = new Schema<ISafetyKeyCheck>(
  {
    keyId: { type: String, required: true, match: KEY_ID_PATTERN },
    check: { type: String, required: true, match: HEX_DIGEST_PATTERN },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

SafetyKeyCheckSchema.index({ keyId: 1 }, { unique: true, name: "safety_key_check_key_unique" });

export const SafetyKeyCheck =
  (mongoose.models.SafetyKeyCheck as mongoose.Model<ISafetyKeyCheck>) ||
  mongoose.model<ISafetyKeyCheck>("SafetyKeyCheck", SafetyKeyCheckSchema);

/* ========================= ModerationReport ========================= */
// Minimal case history: outcome, state, dates, origin. No reporter, no email,
// no text, and no identity reference once the case closes. `deleteAt` is the
// history clock and is absent while the case is live.
export interface IModerationReport extends Document {
  ref: string;
  origin: "report";
  state: ReportState;
  outcome?: ReportOutcome;
  closedAt?: Date;
  safetyIdentityRef?: Types.ObjectId;
  /** Content-free operator-alert attempt state; provider acceptance is not delivery. */
  alertStatus: "pending" | "submitted" | "failed";
  alertAttemptedAt?: Date;
  deleteAt?: Date;
  createdAt: Date;
}

const ModerationReportSchema = new Schema<IModerationReport>(
  {
    ref: { type: String, required: true, default: generateModerationRef },
    origin: { type: String, enum: ["report"], required: true, default: "report" },
    state: { type: String, enum: REPORT_STATES, required: true, default: "open" },
    outcome: { type: String, enum: REPORT_OUTCOMES },
    closedAt: { type: Date },
    safetyIdentityRef: { type: Schema.Types.ObjectId, ref: "SafetyIdentity" },
    alertStatus: {
      type: String,
      enum: ["pending", "submitted", "failed"],
      required: true,
      default: "pending",
    },
    alertAttemptedAt: { type: Date },
    deleteAt: {
      type: Date,
      index: { expireAfterSeconds: 0, name: "moderation_report_deleteAt_ttl" },
    },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

ModerationReportSchema.index(
  { ref: 1 },
  { unique: true, name: "moderation_report_ref_unique" }
);
ModerationReportSchema.index(
  { safetyIdentityRef: 1 },
  { name: "moderation_report_identity", sparse: true }
);

// An Open case carries neither outcome nor closedAt; a Closed case carries both.
ModerationReportSchema.pre("validate", function () {
  if (this.state === "open" && (this.outcome || this.closedAt || this.deleteAt)) {
    throw new Error("An open report carries no outcome, closedAt, or deleteAt.");
  }
  if (this.state === "closed" && (!this.outcome || !this.closedAt)) {
    throw new Error("A closed report requires an outcome and closedAt.");
  }
});

export const ModerationReport =
  (mongoose.models.ModerationReport as mongoose.Model<IModerationReport>) ||
  mongoose.model<IModerationReport>("ModerationReport", ModerationReportSchema);

/* ========================= ReportEvidence ========================= */
// Detailed evidence, one document per item, each with its own `deleteAt`
// (the evidence clock). Absent while the case (or a linked suspension, or a
// hold) keeps it live.
//
// The request snapshot is an explicit allowlist (Decision 7): reported request
// content and the minimum interaction context. It deliberately has no field for
// an email, an order number, screenshots, a pickup name, a claim token, or the
// helper's transient Message. `buildReportRequestSnapshot` is the only
// intended constructor.
export const REPORT_EVIDENCE_KINDS = ["request-snapshot", "explanation", "message-context"] as const;
export type ReportEvidenceKind = (typeof REPORT_EVIDENCE_KINDS)[number];

export interface IReportRequestSnapshot {
  requestId: Types.ObjectId;
  reportedRole: "requester" | "helper";
  requestStatus: "open" | "claimed" | "placed";
  vendor?: string;
  food?: string;
  pickupWindowText?: string;
  menuPath?: string;
  mealSwipes?: number;
  mealItems?: Array<{ name: string; details?: string }>;
  orderDetails?: string;
  estimatedDiningDollarsCents?: number;
}

// FD-MSG1-2: at most ten newest committed messages of the reporter's current
// authorized conversation, captured server-side. Roles only: no participant
// identifier, client id, credential or draft.
export const REPORT_MESSAGE_CONTEXT_MAX_MESSAGES = 10;
export const REPORT_MESSAGE_CAPTURE_REASONS = [
  "chat-not-authorized",
  "capture-failed",
  "conversation-closed",
  "conversation-erased",
  "conversation-unavailable",
  "handoff-unavailable",
  "lifecycle-unavailable",
  "message-history-incomplete",
] as const;
export type ReportMessageCaptureReason = (typeof REPORT_MESSAGE_CAPTURE_REASONS)[number];
export interface IReportMessageContext {
  captureStatus: "complete" | "incomplete";
  captureReason?: ReportMessageCaptureReason;
  messages: Array<{
    sequence: number;
    sender: "reporter" | "reported";
    text: string;
    createdAt: Date;
  }>;
}

export interface IReportEvidence extends Document {
  reportId: Types.ObjectId;
  kind: ReportEvidenceKind;
  snapshot?: IReportRequestSnapshot;
  messageContext?: IReportMessageContext;
  reason?: ReportReason;
  text?: string;
  deleteAt?: Date;
  createdAt: Date;
}

const ReportRequestSnapshotSchema = new Schema<IReportRequestSnapshot>(
  {
    requestId: { type: Schema.Types.ObjectId, required: true },
    reportedRole: { type: String, enum: ["requester", "helper"], required: true },
    requestStatus: { type: String, enum: ["open", "claimed", "placed"], required: true },
    vendor: { type: String, maxlength: 200 },
    food: { type: String, maxlength: 1000 },
    pickupWindowText: { type: String, maxlength: 200 },
    menuPath: { type: String, maxlength: 40 },
    mealSwipes: { type: Number },
    mealItems: {
      type: [
        new Schema(
          {
            name: { type: String, required: true, maxlength: 200 },
            details: { type: String, maxlength: 500 },
          },
          { _id: false }
        ),
      ],
      default: undefined,
    },
    orderDetails: { type: String, maxlength: 1000 },
    estimatedDiningDollarsCents: { type: Number },
  },
  { _id: false, strict: true }
);

const ReportMessageContextSchema = new Schema<IReportMessageContext>(
  {
    captureStatus: { type: String, enum: ["complete", "incomplete"], required: true },
    captureReason: { type: String, enum: REPORT_MESSAGE_CAPTURE_REASONS },
    messages: {
      type: [
        new Schema(
          {
            sequence: { type: Number, required: true, min: 1 },
            sender: { type: String, enum: ["reporter", "reported"], required: true },
            text: { type: String, required: true, maxlength: 2000 },
            createdAt: { type: Date, required: true },
          },
          { _id: false, strict: true }
        ),
      ],
      required: true,
      default: [],
      validate: (value: unknown[]) => value.length <= REPORT_MESSAGE_CONTEXT_MAX_MESSAGES,
    },
  },
  { _id: false, strict: true }
);

ReportMessageContextSchema.pre("validate", function () {
  if (this.captureStatus === "incomplete" && !this.captureReason) {
    throw new Error("Incomplete message capture requires a reason.");
  }
  if (this.captureStatus === "complete" && this.captureReason) {
    throw new Error("Complete message capture cannot carry an incomplete reason.");
  }
});

const ReportEvidenceSchema = new Schema<IReportEvidence>(
  {
    reportId: { type: Schema.Types.ObjectId, ref: "ModerationReport", required: true },
    kind: { type: String, enum: REPORT_EVIDENCE_KINDS, required: true },
    snapshot: { type: ReportRequestSnapshotSchema },
    messageContext: { type: ReportMessageContextSchema },
    // The reason category belongs to the explanation item: it is the structured
    // part of what the student submitted, and it is detailed evidence deleted on
    // the evidence clock rather than minimal history.
    reason: { type: String, enum: REPORT_REASONS },
    text: { type: String, maxlength: REPORT_EXPLANATION_MAX_LENGTH },
    deleteAt: {
      type: Date,
      index: { expireAfterSeconds: 0, name: "report_evidence_deleteAt_ttl" },
    },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

ReportEvidenceSchema.index(
  { reportId: 1, kind: 1 },
  { unique: true, name: "report_evidence_report_kind_unique" }
);

ReportEvidenceSchema.pre("validate", function () {
  if (
    this.kind === "request-snapshot" &&
    (!this.snapshot || this.reason || this.text || this.messageContext)
  ) {
    throw new Error("A request-snapshot item carries only a snapshot.");
  }
  if (this.kind === "explanation" && (!this.reason || this.snapshot || this.messageContext)) {
    throw new Error("An explanation item requires a reason and no snapshot.");
  }
  if (
    this.kind === "message-context" &&
    (!this.messageContext || this.snapshot || this.reason || this.text)
  ) {
    throw new Error("A message-context item carries only message context.");
  }
});

export const ReportEvidence =
  (mongoose.models.ReportEvidence as mongoose.Model<IReportEvidence>) ||
  mongoose.model<IReportEvidence>("ReportEvidence", ReportEvidenceSchema);

/* ========================= Suspension ========================= */
// Minimal suspension history: reference, origin, state, dates. The identity
// reference exists only while the suspension is Active (it is the same-email
// enforcement continuity). The partial unique index makes a second active
// suspension for one identity an idempotent no-op rather than a second row.
export interface ISuspension extends Document {
  ref: string;
  origin: SuspensionOrigin;
  state: SuspensionState;
  safetyIdentityRef?: Types.ObjectId;
  /**
   * Every case that relies on this suspension. Several reports about one
   * participant can resolve to the one Active suspension (the partial unique
   * index allows only one per identity), so the link is a set. Ids only: no
   * identity, text or reporter.
   */
  reportIds?: Types.ObjectId[];
  liftedAt?: Date;
  deleteAt?: Date;
  createdAt: Date;
}

const SuspensionSchema = new Schema<ISuspension>(
  {
    ref: { type: String, required: true, default: generateModerationRef },
    origin: { type: String, enum: SUSPENSION_ORIGINS, required: true },
    state: { type: String, enum: SUSPENSION_STATES, required: true, default: "active" },
    safetyIdentityRef: { type: Schema.Types.ObjectId, ref: "SafetyIdentity" },
    reportIds: { type: [Schema.Types.ObjectId], default: undefined },
    liftedAt: { type: Date },
    deleteAt: {
      type: Date,
      index: { expireAfterSeconds: 0, name: "suspension_deleteAt_ttl" },
    },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

SuspensionSchema.index({ ref: 1 }, { unique: true, name: "suspension_ref_unique" });
SuspensionSchema.index(
  { safetyIdentityRef: 1 },
  {
    unique: true,
    name: "suspension_active_identity_unique",
    partialFilterExpression: { state: "active" },
  }
);
SuspensionSchema.index({ reportIds: 1 }, { name: "suspension_reports", sparse: true });

SuspensionSchema.pre("validate", function () {
  if (this.state === "active" && (!this.safetyIdentityRef || this.liftedAt || this.deleteAt)) {
    throw new Error("An active suspension requires an identity and carries no liftedAt or deleteAt.");
  }
  if (this.state === "lifted" && (!this.liftedAt || this.safetyIdentityRef)) {
    throw new Error("A lifted suspension requires liftedAt and carries no identity reference.");
  }
  if (this.origin === "report" && !(this.reportIds && this.reportIds.length > 0)) {
    throw new Error("A report-origin suspension links its report.");
  }
  if (this.origin === "manual" && this.isNew && this.reportIds && this.reportIds.length > 0) {
    throw new Error("A manual suspension starts with no report.");
  }
});

export const Suspension =
  (mongoose.models.Suspension as mongoose.Model<ISuspension>) ||
  mongoose.model<ISuspension>("Suspension", SuspensionSchema);

/* ========================= SuspensionRationale ========================= */
// The private rationale is the suspension's detailed evidence: its own
// `deleteAt`, absent while the suspension (or a linked open case, or a hold)
// keeps it live.
export interface ISuspensionRationale extends Document {
  suspensionId: Types.ObjectId;
  text: string;
  deleteAt?: Date;
  createdAt: Date;
}

const SuspensionRationaleSchema = new Schema<ISuspensionRationale>(
  {
    suspensionId: { type: Schema.Types.ObjectId, ref: "Suspension", required: true },
    // Trimmed at the persistence boundary: a blank or whitespace-only rationale
    // fails `required`/`minlength` after the trim.
    text: {
      type: String,
      required: true,
      trim: true,
      minlength: 1,
      maxlength: SUSPENSION_RATIONALE_MAX_LENGTH,
    },
    deleteAt: {
      type: Date,
      index: { expireAfterSeconds: 0, name: "suspension_rationale_deleteAt_ttl" },
    },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

SuspensionRationaleSchema.index(
  { suspensionId: 1 },
  { unique: true, name: "suspension_rationale_suspension_unique" }
);

export const SuspensionRationale =
  (mongoose.models.SuspensionRationale as mongoose.Model<ISuspensionRationale>) ||
  mongoose.model<ISuspensionRationale>("SuspensionRationale", SuspensionRationaleSchema);

/* ========================= RetentionHold ========================= */
// An explicit hold (overlapping safety case or documented legal preservation).
// Structural holds (an Open case, an Active suspension) are state, not rows.
// A hold preserves records only: it never creates enforcement authority.
//
// Every hold requires a reason code, a documented ending condition and a
// `reviewAt`. Reaching `reviewAt` raises a prompt (`reviewPromptRaisedAt`) and
// nothing else: a hold ends only by an authorized release.
export const HOLD_RELEASE_BASES = ["ending-condition-met", "related-case-closed"] as const;
export type HoldReleaseBasis = (typeof HOLD_RELEASE_BASES)[number];

export interface IRetentionHold extends Document {
  ref: string;
  targetKind: HoldTargetKind;
  targetId: Types.ObjectId;
  holdClass: HoldClass;
  reasonCode: string;
  note?: string;
  endingCondition: string;
  reviewAt: Date;
  lastReviewedAt?: Date;
  reviewPromptRaisedAt?: Date;
  relatedReportId?: Types.ObjectId;
  safetyIdentityRef?: Types.ObjectId;
  state: HoldState;
  endedAt?: Date;
  releaseBasis?: HoldReleaseBasis;
  deleteAt?: Date;
  createdAt: Date;
}

const RetentionHoldSchema = new Schema<IRetentionHold>(
  {
    ref: { type: String, required: true, default: generateModerationRef },
    targetKind: { type: String, enum: HOLD_TARGET_KINDS, required: true },
    targetId: { type: Schema.Types.ObjectId, required: true },
    holdClass: { type: String, enum: HOLD_CLASSES, required: true },
    reasonCode: { type: String, required: true, match: HOLD_REASON_CODE_PATTERN },
    note: { type: String, maxlength: HOLD_NOTE_MAX_LENGTH },
    endingCondition: {
      type: String,
      required: true,
      trim: true,
      minlength: 1,
      maxlength: HOLD_ENDING_CONDITION_MAX_LENGTH,
    },
    reviewAt: { type: Date, required: true },
    lastReviewedAt: { type: Date },
    reviewPromptRaisedAt: { type: Date },
    relatedReportId: { type: Schema.Types.ObjectId, ref: "ModerationReport" },
    safetyIdentityRef: { type: Schema.Types.ObjectId, ref: "SafetyIdentity" },
    state: { type: String, enum: HOLD_STATES, required: true, default: "active" },
    endedAt: { type: Date },
    releaseBasis: { type: String, enum: HOLD_RELEASE_BASES },
    deleteAt: {
      type: Date,
      index: { expireAfterSeconds: 0, name: "retention_hold_deleteAt_ttl" },
    },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

RetentionHoldSchema.index({ ref: 1 }, { unique: true, name: "retention_hold_ref_unique" });
RetentionHoldSchema.index(
  { targetKind: 1, targetId: 1, state: 1 },
  { name: "retention_hold_target_state" }
);
RetentionHoldSchema.index(
  { state: 1, reviewAt: 1 },
  { name: "retention_hold_state_review" }
);
RetentionHoldSchema.index(
  { safetyIdentityRef: 1 },
  { name: "retention_hold_identity", sparse: true }
);
RetentionHoldSchema.index(
  { relatedReportId: 1, state: 1 },
  { name: "retention_hold_related_report", sparse: true }
);

RetentionHoldSchema.pre("validate", function () {
  if (this.holdClass === "overlapping-case" && !this.relatedReportId) {
    throw new Error("An overlapping-case hold names its related case.");
  }
  if (this.state === "active" && (this.endedAt || this.releaseBasis || this.deleteAt)) {
    throw new Error("An active hold carries no end, release basis, or deleteAt.");
  }
  if (this.state === "released" && (!this.endedAt || !this.releaseBasis || this.safetyIdentityRef)) {
    throw new Error("A released hold records its end and basis and keeps no identity reference.");
  }
});

export const RetentionHold =
  (mongoose.models.RetentionHold as mongoose.Model<IRetentionHold>) ||
  mongoose.model<IRetentionHold>("RetentionHold", RetentionHoldSchema);

/* ========================= ModerationAuditEvent ========================= */
// Append-only, content-free audit. References, kinds, counts and a session
// fingerprint only: never an email, report text, rationale text, hold note or
// credential. Case, suspension and hold events have no clock of their own: the
// sweep removes them with their parent row (cascade) and never before it.
// Authentication and retention-run events carry a 90-day `deleteAt` written at
// creation.
export const AUDIT_CASCADE_EVENT_KINDS = {
  "report-created": "case",
  "report-viewed": "case",
  "request-removed": "case",
  "report-closed": "case",
  "suspension-created": "suspension",
  "suspension-viewed": "suspension",
  "suspension-lifted": "suspension",
  "hold-created": "hold",
  "hold-reviewed": "hold",
  "hold-released": "hold",
  "hold-review-prompted": "hold",
} as const;
export const AUDIT_CLOCKED_EVENT_KINDS = ["moderator-authentication", "retention-run"] as const;
export const AUDIT_EVENT_KINDS = [
  ...(Object.keys(AUDIT_CASCADE_EVENT_KINDS) as Array<keyof typeof AUDIT_CASCADE_EVENT_KINDS>),
  ...AUDIT_CLOCKED_EVENT_KINDS,
] as const;
export type ModerationAuditEventKind = (typeof AUDIT_EVENT_KINDS)[number];
export type AuditSubjectKind = "case" | "suspension" | "hold";

export const RETENTION_RUN_STATUSES = ["succeeded", "failed"] as const;
export const KEYRING_STATES_FOR_RUN = ["ok", "absent", "invalid"] as const;
export type KeyringStateForRun = (typeof KEYRING_STATES_FOR_RUN)[number];
export type RetentionRunStatus = (typeof RETENTION_RUN_STATUSES)[number];

/** Counts only: nothing here can carry a reference, identity or text. */
export interface IRetentionRunSummary {
  status: RetentionRunStatus;
  startedAt: Date;
  finishedAt: Date;
  deletedEvidence: number;
  deletedRationales: number;
  deletedCaseHistory: number;
  deletedSuspensionHistory: number;
  deletedHolds: number;
  deletedAuditEvents: number;
  deletedOrphanEvidence: number;
  deletedOrphanRationales: number;
  deletedExpiredLedger: number;
  deletedExpiredCountBindings: number;
  holdReviewPromptsRaised: number;
  identitiesReleased: number;
  identitiesKept: number;
  invariantViolations: number;
  /** Identities, live ledger rows and keys that cannot be used (a count only). */
  keyUnavailableCount: number;
  keyringState: KeyringStateForRun;
  overdueAfterDelete: number;
  failedSteps: string[];
}

export interface IModerationAuditEvent extends Document {
  kind: ModerationAuditEventKind;
  subjectKind?: AuditSubjectKind;
  subjectId?: Types.ObjectId;
  actor?: string;
  run?: IRetentionRunSummary;
  deleteAt?: Date;
  createdAt: Date;
}

const countField = { type: Number, required: true, default: 0, min: 0 };

const RetentionRunSummarySchema = new Schema<IRetentionRunSummary>(
  {
    status: { type: String, enum: RETENTION_RUN_STATUSES, required: true },
    startedAt: { type: Date, required: true },
    finishedAt: { type: Date, required: true },
    deletedEvidence: countField,
    deletedRationales: countField,
    deletedCaseHistory: countField,
    deletedSuspensionHistory: countField,
    deletedHolds: countField,
    deletedAuditEvents: countField,
    deletedOrphanEvidence: countField,
    deletedOrphanRationales: countField,
    deletedExpiredLedger: countField,
    deletedExpiredCountBindings: countField,
    holdReviewPromptsRaised: countField,
    identitiesReleased: countField,
    identitiesKept: countField,
    invariantViolations: countField,
    keyUnavailableCount: countField,
    keyringState: { type: String, enum: KEYRING_STATES_FOR_RUN, required: true, default: "ok" },
    overdueAfterDelete: countField,
    failedSteps: { type: [String], default: [] },
  },
  { _id: false, strict: true }
);

const ModerationAuditEventSchema = new Schema<IModerationAuditEvent>(
  {
    kind: { type: String, enum: AUDIT_EVENT_KINDS, required: true },
    subjectKind: { type: String, enum: ["case", "suspension", "hold"] },
    subjectId: { type: Schema.Types.ObjectId },
    // A session fingerprint (digest), never a credential or an identity.
    actor: { type: String, match: /^[0-9a-f]{16,64}$/ },
    run: { type: RetentionRunSummarySchema },
    deleteAt: {
      type: Date,
      index: { expireAfterSeconds: 0, name: "moderation_audit_deleteAt_ttl" },
    },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

ModerationAuditEventSchema.index(
  { subjectKind: 1, subjectId: 1 },
  { name: "moderation_audit_subject", sparse: true }
);
ModerationAuditEventSchema.index(
  { kind: 1, createdAt: -1 },
  { name: "moderation_audit_kind_created" }
);

ModerationAuditEventSchema.pre("validate", function () {
  const cascadeSubject =
    AUDIT_CASCADE_EVENT_KINDS[this.kind as keyof typeof AUDIT_CASCADE_EVENT_KINDS];
  if (cascadeSubject) {
    if (this.subjectKind !== cascadeSubject || !this.subjectId || this.deleteAt || this.run) {
      throw new Error("A case, suspension, or hold event names its parent and has no clock of its own.");
    }
    return;
  }
  if (!this.deleteAt || this.subjectKind || this.subjectId) {
    throw new Error("An authentication or retention-run event carries deleteAt and no subject.");
  }
  if ((this.kind === "retention-run") !== Boolean(this.run)) {
    throw new Error("Only a retention-run event carries a run summary.");
  }
});

export const ModerationAuditEvent =
  (mongoose.models.ModerationAuditEvent as mongoose.Model<IModerationAuditEvent>) ||
  mongoose.model<IModerationAuditEvent>("ModerationAuditEvent", ModerationAuditEventSchema);

/* ========================= Retention alert delivery state ========================= */
export interface IRetentionAlertState extends Document {
  scope: "global";
  currentFingerprint?: string;
  currentReasons: string[];
  currentStatus: "resolved" | "pending" | "submitted" | "failed";
  leaseId?: string;
  leaseUntil?: Date;
  lastAttemptStatus?: "submitted" | "failed";
  lastAttemptAt?: Date;
  attempts: number;
  serial: number;
}

const RETENTION_ALERT_REASONS = [
  "last-run-failed",
  "stale-run",
  "overdue-records",
  "invariant-violation",
  "key-unavailable",
  "hold-review-due",
] as const;

const RetentionAlertStateSchema = new Schema<IRetentionAlertState>(
  {
    scope: { type: String, enum: ["global"], required: true, default: "global" },
    currentFingerprint: { type: String, match: HEX_DIGEST_PATTERN },
    currentReasons: {
      type: [{ type: String, enum: RETENTION_ALERT_REASONS }],
      required: true,
      default: [],
    },
    currentStatus: {
      type: String,
      enum: ["resolved", "pending", "submitted", "failed"],
      required: true,
      default: "resolved",
    },
    leaseId: { type: String, match: HEX_DIGEST_PATTERN },
    leaseUntil: { type: Date },
    lastAttemptStatus: { type: String, enum: ["submitted", "failed"] },
    lastAttemptAt: { type: Date },
    attempts: { type: Number, required: true, default: 0, min: 0 },
    serial: { type: Number, required: true, default: 0, min: 0 },
  },
  { timestamps: false, strict: true }
);
RetentionAlertStateSchema.index({ scope: 1 }, { unique: true, name: "retention_alert_scope_unique" });

export const RetentionAlertState =
  (mongoose.models.RetentionAlertState as mongoose.Model<IRetentionAlertState>) ||
  mongoose.model<IRetentionAlertState>("RetentionAlertState", RetentionAlertStateSchema);

/* ========================= Moderator authentication ========================= */
export interface IModeratorSession extends Document {
  scope: "faith";
  sessionDigest: string;
  csrfDigest: string;
  configFingerprint: string;
  createdAt: Date;
  lastSeenAt: Date;
  idleExpiresAt: Date;
  absoluteExpiresAt: Date;
}

const ModeratorSessionSchema = new Schema<IModeratorSession>(
  {
    scope: { type: String, enum: ["faith"], required: true, default: "faith" },
    sessionDigest: { type: String, required: true, match: HEX_DIGEST_PATTERN },
    csrfDigest: { type: String, required: true, match: HEX_DIGEST_PATTERN },
    configFingerprint: { type: String, required: true, match: HEX_DIGEST_PATTERN },
    createdAt: { type: Date, required: true },
    lastSeenAt: { type: Date, required: true },
    idleExpiresAt: { type: Date, required: true },
    absoluteExpiresAt: { type: Date, required: true },
  },
  { timestamps: false }
);
ModeratorSessionSchema.index({ scope: 1 }, { unique: true, name: "moderator_session_single_active" });
ModeratorSessionSchema.index({ sessionDigest: 1 }, { unique: true, name: "moderator_session_digest_unique" });

export const ModeratorSession =
  (mongoose.models.ModeratorSession as mongoose.Model<IModeratorSession>) ||
  mongoose.model<IModeratorSession>("ModeratorSession", ModeratorSessionSchema);

export interface IModeratorThrottle extends Document {
  scope: "global";
  failures: number;
  delayMs: number;
  blockedUntil?: Date;
  lastAcceptedTotpStep?: number;
  serial: number;
}

const ModeratorThrottleSchema = new Schema<IModeratorThrottle>(
  {
    scope: { type: String, enum: ["global"], required: true, default: "global" },
    failures: { type: Number, required: true, default: 0, min: 0 },
    delayMs: { type: Number, required: true, default: 0, min: 0 },
    blockedUntil: { type: Date },
    lastAcceptedTotpStep: { type: Number, min: 0 },
    serial: { type: Number, required: true, default: 0, min: 0 },
  },
  { timestamps: false }
);
ModeratorThrottleSchema.index({ scope: 1 }, { unique: true, name: "moderator_throttle_global_unique" });

export const ModeratorThrottle =
  (mongoose.models.ModeratorThrottle as mongoose.Model<IModeratorThrottle>) ||
  mongoose.model<IModeratorThrottle>("ModeratorThrottle", ModeratorThrottleSchema);

/* ========================= ReportSubmissionLedger ========================= */
// The private submission ledger, outside the case record. It carries no case
// reference, and the case carries no ledger reference, so no field or index
// joins a reporter to a case. Every digest is a keyed MAC (see
// `src/safetyIdentityKeyring.ts`); none is recoverable.
//
// Retention R is enforced by the TTL index on `createdAt` (server creation
// time), not asserted: the index's `expireAfterSeconds` is the R constant.
export const REPORT_LEDGER_OUTCOMES = ["created", "no-create"] as const;
export type ReportLedgerOutcome = (typeof REPORT_LEDGER_OUTCOMES)[number];

export interface IReportSubmissionLedger extends Document {
  /** The creator's current key; the participant binding is minted under it. */
  keyId: string;
  /**
   * The operation digest under every key the creator held. Unique and multikey,
   * so two instances with different current keys cannot both create the same
   * logical operation.
   */
  operationDigests: string[];
  participantBinding: string;
  /** Likewise for the single-use post-Block handoff, when one was presented. */
  handoffDigests?: string[];
  outcome: ReportLedgerOutcome;
  createdAt: Date;
}

const ReportSubmissionLedgerSchema = new Schema<IReportSubmissionLedger>(
  {
    keyId: { type: String, required: true, match: KEY_ID_PATTERN },
    operationDigests: {
      type: [{ type: String, match: HEX_DIGEST_PATTERN }],
      validate: {
        validator: (value: string[]) => value.length > 0,
        message: "A ledger row carries at least one operation digest.",
      },
    },
    participantBinding: { type: String, required: true, match: HEX_DIGEST_PATTERN },
    handoffDigests: {
      type: [{ type: String, match: HEX_DIGEST_PATTERN }],
      default: undefined,
    },
    outcome: { type: String, enum: REPORT_LEDGER_OUTCOMES, required: true },
    createdAt: {
      type: Date,
      required: true,
      default: () => new Date(),
      index: {
        expireAfterSeconds: REPORT_LEDGER_RETENTION_SECONDS,
        name: "report_ledger_createdAt_ttl",
      },
    },
  },
  { timestamps: false }
);

ReportSubmissionLedgerSchema.index(
  { operationDigests: 1 },
  { unique: true, name: "report_ledger_operation_unique" }
);
// A handoff value is consumed by the first committed report that presents it.
ReportSubmissionLedgerSchema.index(
  { handoffDigests: 1 },
  {
    unique: true,
    name: "report_ledger_handoff_unique",
    partialFilterExpression: { handoffDigests: { $exists: true } },
  }
);
ReportSubmissionLedgerSchema.index({ keyId: 1 }, { name: "report_ledger_key" });

export const ReportSubmissionLedger =
  (mongoose.models.ReportSubmissionLedger as mongoose.Model<IReportSubmissionLedger>) ||
  mongoose.model<IReportSubmissionLedger>("ReportSubmissionLedger", ReportSubmissionLedgerSchema);

/* ========================= ReportCountBinding ========================= */
// One keyed, private row per accepted report, written in the same transaction
// as the ledger row. Counting rows within the rolling window yields the
// per-reporter volume and per-reporter-per-request counts. Best-effort: a
// concurrent burst can exceed a cap by a small margin, and that is never a
// reason to drop or merge an accepted report. Expires with the ledger (R).
export interface IReportCountBinding extends Document {
  keyId: string;
  reporterBinding: string;
  requestBinding: string;
  createdAt: Date;
}

const ReportCountBindingSchema = new Schema<IReportCountBinding>(
  {
    keyId: { type: String, required: true, match: KEY_ID_PATTERN },
    reporterBinding: { type: String, required: true, match: HEX_DIGEST_PATTERN },
    requestBinding: { type: String, required: true, match: HEX_DIGEST_PATTERN },
    createdAt: {
      type: Date,
      required: true,
      default: () => new Date(),
      index: {
        expireAfterSeconds: REPORT_LEDGER_RETENTION_SECONDS,
        name: "report_count_binding_createdAt_ttl",
      },
    },
  },
  { timestamps: false }
);

ReportCountBindingSchema.index(
  { reporterBinding: 1, createdAt: 1 },
  { name: "report_count_reporter_created" }
);
ReportCountBindingSchema.index(
  { requestBinding: 1, createdAt: 1 },
  { name: "report_count_request_created" }
);

export const ReportCountBinding =
  (mongoose.models.ReportCountBinding as mongoose.Model<IReportCountBinding>) ||
  mongoose.model<IReportCountBinding>("ReportCountBinding", ReportCountBindingSchema);

/**
 * Every moderation model, in a stable order, for startup index establishment
 * and for tests that inspect the whole foundation.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const MODERATION_MODELS: ReadonlyArray<mongoose.Model<any>> = [
  SafetyIdentity,
  SafetyKeyCheck,
  ModerationReport,
  ReportEvidence,
  Suspension,
  SuspensionRationale,
  RetentionHold,
  ModerationAuditEvent,
  RetentionAlertState,
  ModeratorSession,
  ModeratorThrottle,
  ReportSubmissionLedger,
  ReportCountBinding,
];

/** Establishes every moderation index; rejects if any cannot be established. */
export async function establishModerationIndexes(): Promise<void> {
  for (const model of MODERATION_MODELS) {
    await model.createIndexes();
  }
}
