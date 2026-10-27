import type { ClientSession, Types } from "mongoose";
import {
  ModerationReport,
  ReportEvidence,
  RetentionHold,
  Suspension,
  SuspensionRationale,
  type IReportMessageContext,
  type IReportRequestSnapshot,
} from "../models/moderation.js";
import { appendSubjectAudit } from "./moderationAudit.js";
import { recomputeCaseClocks, recomputeSuspensionClocks } from "./moderationClocks.js";
import {
  REPORT_OUTCOMES,
  SUSPENSION_RATIONALE_MAX_LENGTH,
  type ReportOutcome,
  type ReportReason,
  type SuspensionOrigin,
} from "./moderationConstants.js";
import { endRetentionHold } from "./moderationHolds.js";
import {
  SafetyIdentityUnavailableError,
  ensureSafetyIdentity,
  confirmSafetyIdentity,
  releaseSafetyIdentityIfUnreferenced,
} from "./safetyIdentity.js";
import type { SafetyIdentityKeyring } from "./safetyIdentityKeyring.js";

/**
 * Record-level moderation transitions (W4-U1.2 Checkpoint 1; boundary contract
 * RH, "Atomic transitions").
 *
 * **Scope.** These write moderation records, identity references, retention
 * clocks and audit rows only. They do *not* remove a request, suspend or
 * reinstate a Participant, or touch any availability predicate: those
 * enforcement writes belong to the CP2 enforcement layer and must run in the
 * **same transaction** as the matching function here, passing the transaction's
 * `session`. CP3 moderator operations compose these record and enforcement
 * steps in one transaction.
 *
 * Each function is one conditional, audited step meant to run inside the
 * caller's transaction. An unauditable action does not run, because the audit
 * row is written through the same session.
 */

export type ModerationTransitionRefusalCode =
  | "enforcement-not-applied"
  | "suspension-required"
  | "report-not-open"
  | "identity-mismatch"
  | "invalid-outcome"
  | "invalid-rationale";

export class ModerationTransitionRefusal extends Error {
  readonly code: ModerationTransitionRefusalCode;
  constructor(code: ModerationTransitionRefusalCode) {
    super(`Moderation transition refused: ${code}.`);
    this.name = "ModerationTransitionRefusal";
    this.code = code;
  }
}

const OUTCOMES_WITH_SUSPENSION: ReadonlySet<ReportOutcome> = new Set([
  "participant-suspended",
  "request-removed-and-participant-suspended",
]);

export interface RecordReportCaseInput {
  keyring: SafetyIdentityKeyring | null;
  /** The reported party's verified email, resolved server-side; never stored. */
  reportedEmail: string;
  snapshot: IReportRequestSnapshot;
  reason: ReportReason;
  explanation?: string;
  /** Server-captured FD-MSG1-2 context; never client-supplied. Omitted when none. */
  messageContext?: IReportMessageContext;
  actor?: string;
}

/**
 * Creates the Open case, its restricted identity reference and its two detailed
 * evidence items in one step. The identity is created or reused here, in the
 * same transaction that names the reported party, so final deletion never needs
 * to create it (P2 fixed mechanism item 3). Open cases carry no `deleteAt`.
 */
export async function recordReportCase(
  session: ClientSession,
  input: RecordReportCaseInput
): Promise<{ reportId: Types.ObjectId; ref: string; identityId: Types.ObjectId }> {
  const { identityId } = await ensureSafetyIdentity(input.keyring, input.reportedEmail, session);
  const [report] = await ModerationReport.create([{ safetyIdentityRef: identityId }], { session });
  await ReportEvidence.create(
    [
      { reportId: report._id, kind: "request-snapshot", snapshot: input.snapshot },
      {
        reportId: report._id,
        kind: "explanation",
        reason: input.reason,
        text: input.explanation || undefined,
      },
      ...(input.messageContext
        ? [{ reportId: report._id, kind: "message-context", messageContext: input.messageContext }]
        : []),
    ],
    { session, ordered: true }
  );
  await appendSubjectAudit(session, "report-created", "case", report._id as Types.ObjectId, input.actor);
  return { reportId: report._id as Types.ObjectId, ref: report.ref, identityId };
}

export interface RecordSuspensionInput {
  keyring: SafetyIdentityKeyring | null;
  suspendedEmail?: string;
  /** Existing case identity permits enforcement after the ordinary account is deleted. */
  safetyIdentityId?: Types.ObjectId;
  origin: SuspensionOrigin;
  /** Required for a report-origin suspension: the Open case it enforces. */
  reportId?: Types.ObjectId;
  /** Required, trimmed, and refused when blank: the private rationale. */
  rationale: string;
  actor?: string;
}

/**
 * Creates an Active suspension and its private rationale, attached to the
 * restricted identity. An identity that already has an Active suspension is an
 * idempotent no-op for the enforcement: no second suspension row or rationale
 * is written. A report-origin call on that identity **links its report to the
 * existing suspension**, so several reports about one participant each resolve
 * truthfully to the one Active suspension, and the suspension's evidence stays
 * held until every linked report has closed (and the suspension has lifted).
 * The partial unique index is the backstop.
 */
export async function recordSuspension(
  session: ClientSession,
  input: RecordSuspensionInput
): Promise<{
  suspensionId: Types.ObjectId;
  ref: string;
  created: boolean;
  identityId: Types.ObjectId;
}> {
  // Refused before any write, so a blank rationale never costs an identity.
  const rationale = typeof input.rationale === "string" ? input.rationale.trim() : "";
  if (rationale === "" || rationale.length > SUSPENSION_RATIONALE_MAX_LENGTH) {
    throw new ModerationTransitionRefusal("invalid-rationale");
  }

  let identityId: Types.ObjectId;
  if (input.safetyIdentityId) {
    const usable = await confirmSafetyIdentity(input.safetyIdentityId, input.keyring, session);
    if (!usable) throw new SafetyIdentityUnavailableError();
    identityId = input.safetyIdentityId;
  } else if (input.suspendedEmail) {
    ({ identityId } = await ensureSafetyIdentity(input.keyring, input.suspendedEmail, session));
  } else {
    throw new Error("A suspension requires a verified identity.");
  }

  if (input.origin === "report") {
    const report = input.reportId
      ? await ModerationReport.findById(input.reportId, undefined, { session }).lean().exec()
      : null;
    if (!report || report.state !== "open") {
      throw new ModerationTransitionRefusal("report-not-open");
    }
    if (String(report.safetyIdentityRef) !== String(identityId)) {
      throw new ModerationTransitionRefusal("identity-mismatch");
    }
  }

  const existing = await Suspension.findOne(
    { safetyIdentityRef: identityId, state: "active" },
    undefined,
    { session }
  )
    .lean()
    .exec();
  if (existing) {
    if (input.origin === "report") {
      // The write also anchors the existing suspension against a concurrent lift.
      await Suspension.updateOne(
        { _id: existing._id, state: "active" },
        { $addToSet: { reportIds: input.reportId } },
        { session }
      );
    }
    return {
      suspensionId: existing._id as Types.ObjectId,
      ref: existing.ref,
      created: false,
      identityId,
    };
  }

  const [suspension] = await Suspension.create(
    [
      {
        origin: input.origin,
        reportIds: input.origin === "report" ? [input.reportId] : undefined,
        safetyIdentityRef: identityId,
      },
    ],
    { session }
  );
  await SuspensionRationale.create([{ suspensionId: suspension._id, text: rationale }], {
    session,
  });
  await appendSubjectAudit(
    session,
    "suspension-created",
    "suspension",
    suspension._id as Types.ObjectId,
    input.actor
  );
  return {
    suspensionId: suspension._id as Types.ObjectId,
    ref: suspension.ref,
    created: true,
    identityId,
  };
}

export interface CloseReportCaseInput {
  reportId: Types.ObjectId;
  outcome: ReportOutcome;
  /**
   * The caller's read of **committed** enforcement state: every selected
   * enforcement is applied ("already unavailable" counts as applied). A report
   * is never closed while enforcement is pending, failed or uncertain, so
   * anything but `true` refuses.
   */
  enforcementApplied: boolean;
  keyring: SafetyIdentityKeyring | null;
  actor?: string;
}

export type CloseReportCaseResult = { status: "closed" } | { status: "not-open" };

/**
 * Open → Closed, conditional on `state: "open"`. Sets `closedAt`, detaches the
 * case's identity reference, ends overlapping-case holds that name this case as
 * their related case, writes the case's and any linked suspension's clocks, and
 * releases the identity in the same transaction when nothing else references it.
 * Removal-only closure (Decision 14) uses the same anchor as "No action".
 */
export async function closeReportCase(
  session: ClientSession,
  input: CloseReportCaseInput,
  now: Date
): Promise<CloseReportCaseResult> {
  if (!REPORT_OUTCOMES.includes(input.outcome)) {
    throw new ModerationTransitionRefusal("invalid-outcome");
  }
  if (input.enforcementApplied !== true) {
    throw new ModerationTransitionRefusal("enforcement-not-applied");
  }
  if (OUTCOMES_WITH_SUSPENSION.has(input.outcome)) {
    const linked = await Suspension.exists({ reportIds: input.reportId }).session(session);
    if (!linked) throw new ModerationTransitionRefusal("suspension-required");
  }

  const before = await ModerationReport.findOneAndUpdate(
    { _id: input.reportId, state: "open" },
    {
      $set: { state: "closed", outcome: input.outcome, closedAt: now },
      $unset: { safetyIdentityRef: 1 },
    },
    { session, new: false }
  )
    .lean()
    .exec();
  if (!before) return { status: "not-open" };

  // An overlapping-case hold ends with the related case's closure, Faith's own
  // audited act. A legal-preservation hold never does, even if it names this
  // case as a reference: it ends only by an authorized release after its
  // documented ending condition.
  const related = await RetentionHold.find(
    { relatedReportId: input.reportId, holdClass: "overlapping-case", state: "active" },
    { _id: 1 },
    { session }
  )
    .lean()
    .exec();
  for (const hold of related) {
    await endRetentionHold(
      session,
      hold._id as Types.ObjectId,
      "related-case-closed",
      now,
      input.keyring,
      input.actor
    );
  }

  await recomputeCaseClocks(session, input.reportId, now);
  const linkedSuspensions = await Suspension.find({ reportIds: input.reportId }, { _id: 1 }, {
    session,
  })
    .lean()
    .exec();
  for (const suspension of linkedSuspensions) {
    await recomputeSuspensionClocks(session, suspension._id as Types.ObjectId, now);
  }
  await appendSubjectAudit(session, "report-closed", "case", input.reportId, input.actor);
  if (before.safetyIdentityRef) {
    await releaseSafetyIdentityIfUnreferenced(
      before.safetyIdentityRef as Types.ObjectId,
      input.keyring,
      session
    );
  }
  return { status: "closed" };
}

export interface LiftSuspensionInput {
  suspensionId: Types.ObjectId;
  keyring: SafetyIdentityKeyring | null;
  actor?: string;
}

export type LiftSuspensionResult = { status: "lifted" } | { status: "not-active" };

/**
 * Active → Lifted, conditional on `state: "active"`. Sets `liftedAt`, detaches
 * the identity reference, writes the suspension's and any linked case's clocks
 * (an Open linked case starts its clocks at its later closure), and releases the
 * identity in the same transaction when nothing else references it.
 *
 * It does not clear the Participant's suspended state: Checkpoint 2's
 * reinstatement transaction must do that in this same transaction, passing the
 * same `session`.
 */
export async function liftSuspension(
  session: ClientSession,
  input: LiftSuspensionInput,
  now: Date
): Promise<LiftSuspensionResult> {
  const before = await Suspension.findOneAndUpdate(
    { _id: input.suspensionId, state: "active" },
    { $set: { state: "lifted", liftedAt: now }, $unset: { safetyIdentityRef: 1 } },
    { session, new: false }
  )
    .lean()
    .exec();
  if (!before) return { status: "not-active" };

  await recomputeSuspensionClocks(session, input.suspensionId, now);
  for (const reportId of before.reportIds ?? []) {
    await recomputeCaseClocks(session, reportId as Types.ObjectId, now);
  }
  await appendSubjectAudit(
    session,
    "suspension-lifted",
    "suspension",
    input.suspensionId,
    input.actor
  );
  if (before.safetyIdentityRef) {
    await releaseSafetyIdentityIfUnreferenced(
      before.safetyIdentityRef as Types.ObjectId,
      input.keyring,
      session
    );
  }
  return { status: "lifted" };
}

export interface ClosureOverlapIndicator {
  /** Another Open report names the same restricted identity. */
  otherOpenReport: boolean;
  /** An Active suspension references the same restricted identity. */
  activeSuspension: boolean;
}

/**
 * The closure-time overlap indicator (RH, "Hold classes"): content-free
 * booleans telling the operator whether closing this case would leave another
 * open case or an active suspension on the same identity. An open report
 * against the same participant does not automatically retain a closed case's
 * evidence; this only makes an overlapping-case hold a deliberate, reasoned
 * act. Returns `null` once the case has detached its identity (closed).
 */
export async function getClosureOverlapIndicator(
  reportId: Types.ObjectId,
  session?: ClientSession
): Promise<ClosureOverlapIndicator | null> {
  const report = await ModerationReport.findById(reportId, { safetyIdentityRef: 1 })
    .session(session ?? null)
    .lean<{ safetyIdentityRef?: Types.ObjectId }>()
    .exec();
  if (!report?.safetyIdentityRef) return null;
  const [otherOpenReport, activeSuspension] = await Promise.all([
    ModerationReport.exists({
      _id: { $ne: reportId },
      state: "open",
      safetyIdentityRef: report.safetyIdentityRef,
    }).session(session ?? null),
    Suspension.exists({ state: "active", safetyIdentityRef: report.safetyIdentityRef }).session(
      session ?? null
    ),
  ]);
  return { otherOpenReport: otherOpenReport !== null, activeSuspension: activeSuspension !== null };
}
