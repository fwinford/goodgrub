import type { Model, Types } from "mongoose";
import {
  ModerationAuditEvent,
  ModerationReport,
  ReportCountBinding,
  ReportEvidence,
  ReportSubmissionLedger,
  RetentionAlertState,
  RetentionHold,
  SafetyIdentity,
  Suspension,
  SuspensionRationale,
  type IRetentionRunSummary,
} from "../models/moderation.js";
import { appendClockedAudit } from "./moderationAudit.js";
import {
  REPORT_LEDGER_RETENTION_MS,
  RETENTION_SWEEP_BATCH_LIMIT,
  RETENTION_SWEEP_CRON,
  RETENTION_SWEEP_GRACE_MS,
  RETENTION_SWEEP_STALE_MS,
} from "./moderationConstants.js";
import { raiseHoldReviewPrompt } from "./moderationHolds.js";
import {
  countKeyDependentRecordsUnavailable,
  releaseUnreferencedSafetyIdentity,
  runModerationTransaction,
} from "./safetyIdentity.js";
import {
  inspectSafetyIdentityKeyring,
  type SafetyIdentityKeyring,
  type SafetyIdentityKeyringInspection,
} from "./safetyIdentityKeyring.js";
import { deliverRetentionAlert } from "./retentionAlertDelivery.js";
import { registerScheduledJob } from "./scheduledJobs.js";

/**
 * The application-managed retention sweep (boundary contract RH, "Deletion and
 * its proof").
 *
 * MongoDB's TTL monitor is the physical deleter. This sweep is the **verifier,
 * the cascade and the visibility**: it deletes anything overdue beyond a grace
 * interval (TTL backstop), cascades orphaned children, raises review prompts for
 * holds past `reviewAt`, retries the guarded identity release, checks the
 * retention invariant, and appends one content-free `retention-run` event as
 * proof of what happened.
 *
 * ## What it never does
 *
 * - It never releases a hold and never deletes held records on a date: a passed
 *   `reviewAt` only raises a prompt.
 * - It never releases a safety identity on age, a guess or an unavailable key;
 *   it only retries the same guarded transaction for identities left
 *   unreferenced.
 * - It never extends retention implicitly and never turns a cleanup failure into
 *   a hold: a record that could not be deleted stays overdue, is retried on
 *   every run, and stays visible (`getRetentionHealth`) until it is gone.
 * - It never silently deletes or silently keeps an invariant violation: a
 *   record with neither a `deleteAt` nor a live reference is counted, surfaced
 *   as a retention incident, and left for an audited manual remediation.
 *
 * It is scheduled independently of `CRON_ENABLED` and `PUBLIC_ACTIONS_PAUSED`
 * (see `scheduleModerationRetentionSweep`), is idempotent, and is safe if two
 * runs overlap: every delete re-checks its own deadline in the same statement.
 */

type AnyModel = Model<any>; // eslint-disable-line @typescript-eslint/no-explicit-any

type CountKey = {
  [K in keyof IRetentionRunSummary]: IRetentionRunSummary[K] extends number ? K : never;
}[keyof IRetentionRunSummary];

interface DeadlineClass {
  step: string;
  model: AnyModel;
  summaryKey: CountKey;
  /** Overdue beyond the grace interval, evaluated at delete time. */
  overdue: (now: Date) => Record<string, unknown>;
}

function pastDeleteAt(now: Date): Record<string, unknown> {
  return { deleteAt: { $lte: new Date(now.getTime() - RETENTION_SWEEP_GRACE_MS) } };
}

function pastLedgerRetention(now: Date): Record<string, unknown> {
  return {
    createdAt: {
      $lte: new Date(now.getTime() - REPORT_LEDGER_RETENTION_MS - RETENTION_SWEEP_GRACE_MS),
    },
  };
}

const DEADLINE_CLASSES: DeadlineClass[] = [
  { step: "evidence", model: ReportEvidence, summaryKey: "deletedEvidence", overdue: pastDeleteAt },
  {
    step: "rationales",
    model: SuspensionRationale,
    summaryKey: "deletedRationales",
    overdue: pastDeleteAt,
  },
  { step: "case-history", model: ModerationReport, summaryKey: "deletedCaseHistory", overdue: pastDeleteAt },
  {
    step: "suspension-history",
    model: Suspension,
    summaryKey: "deletedSuspensionHistory",
    overdue: pastDeleteAt,
  },
  { step: "holds", model: RetentionHold, summaryKey: "deletedHolds", overdue: pastDeleteAt },
  {
    step: "audit-events",
    model: ModerationAuditEvent,
    summaryKey: "deletedAuditEvents",
    overdue: pastDeleteAt,
  },
  {
    step: "ledger",
    model: ReportSubmissionLedger,
    summaryKey: "deletedExpiredLedger",
    overdue: pastLedgerRetention,
  },
  {
    step: "count-bindings",
    model: ReportCountBinding,
    summaryKey: "deletedExpiredCountBindings",
    overdue: pastLedgerRetention,
  },
];

function blankSummary(startedAt: Date): IRetentionRunSummary {
  return {
    status: "succeeded",
    startedAt,
    finishedAt: startedAt,
    deletedEvidence: 0,
    deletedRationales: 0,
    deletedCaseHistory: 0,
    deletedSuspensionHistory: 0,
    deletedHolds: 0,
    deletedAuditEvents: 0,
    deletedOrphanEvidence: 0,
    deletedOrphanRationales: 0,
    deletedExpiredLedger: 0,
    deletedExpiredCountBindings: 0,
    holdReviewPromptsRaised: 0,
    identitiesReleased: 0,
    identitiesKept: 0,
    invariantViolations: 0,
    keyUnavailableCount: 0,
    keyringState: "ok",
    overdueAfterDelete: 0,
    failedSteps: [],
  };
}

/** Rows overdue across every deadline class, beyond the grace interval. */
export async function countOverdueRecords(now: Date): Promise<number> {
  const counts = await Promise.all(
    DEADLINE_CLASSES.map((entry) => entry.model.countDocuments(entry.overdue(now)))
  );
  return counts.reduce((sum, count) => sum + count, 0);
}

async function deleteOverdue(entry: DeadlineClass, now: Date): Promise<number> {
  const candidates = await entry.model
    .find(entry.overdue(now), { _id: 1 })
    .limit(RETENTION_SWEEP_BATCH_LIMIT)
    .lean()
    .exec();
  if (candidates.length === 0) return 0;
  // The deadline is re-checked in the delete itself: a hold created after the
  // find has cleared `deleteAt`, and the row then no longer matches.
  const result = await entry.model.deleteMany({
    _id: { $in: candidates.map((row) => row._id) },
    ...entry.overdue(now),
  });
  return result.deletedCount ?? 0;
}

/**
 * Ids in `child` whose parent (matched on `localField`) no longer exists.
 * Carries the parent id so callers can tell whether an active hold still names it.
 */
async function orphanRows(
  child: AnyModel,
  localField: string,
  parent: AnyModel,
  extraMatch: Record<string, unknown> = {}
): Promise<Array<{ _id: Types.ObjectId; parentId: Types.ObjectId }>> {
  const rows = await child.aggregate<{ _id: Types.ObjectId; parentId: Types.ObjectId }>([
    { $match: extraMatch },
    {
      $lookup: {
        from: parent.collection.name,
        localField,
        foreignField: "_id",
        as: "parent",
        pipeline: [{ $project: { _id: 1 } }, { $limit: 1 }],
      },
    },
    { $match: { parent: { $size: 0 } } },
    { $project: { _id: 1, parentId: `$${localField}` } },
    { $limit: RETENTION_SWEEP_BATCH_LIMIT },
  ]);
  return rows;
}

/**
 * Orphans whose missing parent is the target of an **active** hold: preserved
 * material that must neither be deleted nor silently ignored.
 */
async function splitByActiveHold(
  rows: Array<{ _id: Types.ObjectId; parentId: Types.ObjectId }>,
  targetKind: "case" | "suspension"
): Promise<{ deletable: Types.ObjectId[]; protectedCount: number }> {
  if (rows.length === 0) return { deletable: [], protectedCount: 0 };
  const held = new Set(
    (
      await RetentionHold.find(
        { targetKind, targetId: { $in: rows.map((row) => row.parentId) }, state: "active" },
        { targetId: 1 }
      )
        .lean()
        .exec()
    ).map((hold) => String(hold.targetId))
  );
  const deletable = rows.filter((row) => !held.has(String(row.parentId))).map((row) => row._id);
  return { deletable, protectedCount: rows.length - deletable.length };
}

async function deleteIds(model: AnyModel, ids: Types.ObjectId[]): Promise<number> {
  if (ids.length === 0) return 0;
  const result = await model.deleteMany({ _id: { $in: ids } });
  return result.deletedCount ?? 0;
}

/**
 * Cascades children whose parent row is gone. It never deletes an active hold,
 * and never deletes evidence or a rationale that an active hold still names:
 * those are an inconsistency for `countRetentionInvariantViolations` to surface
 * as a retention incident. Released holds are not cascaded either; they keep
 * their own authorized deadline.
 */
async function cascadeOrphans(summary: IRetentionRunSummary): Promise<void> {
  const evidence = await splitByActiveHold(
    await orphanRows(ReportEvidence, "reportId", ModerationReport),
    "case"
  );
  summary.deletedOrphanEvidence += await deleteIds(ReportEvidence, evidence.deletable);

  const rationales = await splitByActiveHold(
    await orphanRows(SuspensionRationale, "suspensionId", Suspension),
    "suspension"
  );
  summary.deletedOrphanRationales += await deleteIds(SuspensionRationale, rationales.deletable);

  const auditParents: Array<[string, AnyModel]> = [
    ["case", ModerationReport],
    ["suspension", Suspension],
    ["hold", RetentionHold],
  ];
  for (const [subjectKind, parent] of auditParents) {
    const orphans = await orphanRows(ModerationAuditEvent, "subjectId", parent, { subjectKind });
    summary.deletedAuditEvents += await deleteIds(
      ModerationAuditEvent,
      orphans.map((row) => row._id)
    );
  }
}

async function raiseDueHoldPrompts(now: Date): Promise<number> {
  const due = await RetentionHold.find(
    { state: "active", reviewAt: { $lte: now }, reviewPromptRaisedAt: { $exists: false } },
    { _id: 1 }
  )
    .limit(RETENTION_SWEEP_BATCH_LIMIT)
    .lean()
    .exec();
  let raised = 0;
  for (const hold of due) {
    const didRaise = await runModerationTransaction((session) =>
      raiseHoldReviewPrompt(session, hold._id as Types.ObjectId, now)
    );
    if (didRaise) raised += 1;
  }
  return raised;
}

async function retryIdentityReleases(
  keyring: SafetyIdentityKeyring | null,
  summary: IRetentionRunSummary
): Promise<void> {
  const unreferenced = await SafetyIdentity.aggregate<{ _id: Types.ObjectId }>([
    ...[
      [ModerationReport.collection.name, "r"],
      [Suspension.collection.name, "s"],
      [RetentionHold.collection.name, "h"],
    ].map(([from, as]) => ({
      $lookup: {
        from,
        localField: "_id",
        foreignField: "safetyIdentityRef",
        as,
        pipeline: [{ $project: { _id: 1 } }, { $limit: 1 }],
      },
    })),
    { $match: { r: { $size: 0 }, s: { $size: 0 }, h: { $size: 0 } } },
    { $project: { _id: 1 } },
    { $limit: RETENTION_SWEEP_BATCH_LIMIT },
  ]);
  for (const identity of unreferenced) {
    const result = await releaseUnreferencedSafetyIdentity(identity._id, keyring);
    if (result === "released") summary.identitiesReleased += 1;
    else if (result === "kept-key-unavailable") summary.identitiesKept += 1;
  }
}

/**
 * The retention invariant: every evidence and minimal record has either a
 * `deleteAt` or a live reference. Counts violations; never deletes or fixes.
 */
export async function countRetentionInvariantViolations(): Promise<number> {
  let violations = 0;

  // A live record must not carry a deadline: TTL would delete live data.
  violations += await ModerationReport.countDocuments({
    state: "open",
    deleteAt: { $exists: true },
  });
  violations += await Suspension.countDocuments({
    state: "active",
    deleteAt: { $exists: true },
  });

  // Closed cases held without a live reason.
  const heldCases = await ModerationReport.find(
    { state: "closed", deleteAt: { $exists: false } },
    { _id: 1 }
  )
    .limit(RETENTION_SWEEP_BATCH_LIMIT)
    .lean()
    .exec();
  for (const row of heldCases) {
    const [suspension, hold] = await Promise.all([
      Suspension.exists({ reportIds: row._id, state: "active" }),
      RetentionHold.exists({ targetKind: "case", targetId: row._id, state: "active" }),
    ]);
    if (!suspension && !hold) violations += 1;
  }

  // Lifted suspensions held without a live reason.
  const heldSuspensions = await Suspension.find(
    { state: "lifted", deleteAt: { $exists: false } },
    { _id: 1, reportIds: 1 }
  )
    .limit(RETENTION_SWEEP_BATCH_LIMIT)
    .lean()
    .exec();
  for (const row of heldSuspensions) {
    const [report, hold] = await Promise.all([
      row.reportIds && row.reportIds.length > 0
        ? ModerationReport.exists({ _id: { $in: row.reportIds }, state: "open" })
        : Promise.resolve(null),
      RetentionHold.exists({ targetKind: "suspension", targetId: row._id, state: "active" }),
    ]);
    if (!report && !hold) violations += 1;
  }

  // Detail held while its parent's minimal row carries a deadline.
  const evidenceRows = await ReportEvidence.find({ deleteAt: { $exists: false } }, { reportId: 1 })
    .limit(RETENTION_SWEEP_BATCH_LIMIT)
    .lean()
    .exec();
  for (const row of evidenceRows) {
    const parent = await ModerationReport.exists({
      _id: row.reportId,
      state: "closed",
      deleteAt: { $exists: true },
    });
    if (parent) violations += 1;
  }
  const rationaleRows = await SuspensionRationale.find(
    { deleteAt: { $exists: false } },
    { suspensionId: 1 }
  )
    .limit(RETENTION_SWEEP_BATCH_LIMIT)
    .lean()
    .exec();
  for (const row of rationaleRows) {
    const parent = await Suspension.exists({
      _id: row.suspensionId,
      state: "lifted",
      deleteAt: { $exists: true },
    });
    if (parent) violations += 1;
  }

  // An active hold whose target is gone, and evidence or a rationale an active
  // hold still names under a missing parent: preserved material in an
  // inconsistent state. Never deleted, never released: surfaced.
  for (const [targetKind, parent] of [
    ["case", ModerationReport],
    ["suspension", Suspension],
  ] as Array<["case" | "suspension", AnyModel]>) {
    violations += (
      await orphanRows(RetentionHold, "targetId", parent, { targetKind, state: "active" })
    ).length;
  }
  violations += (
    await splitByActiveHold(await orphanRows(ReportEvidence, "reportId", ModerationReport), "case")
  ).protectedCount;
  violations += (
    await splitByActiveHold(
      await orphanRows(SuspensionRationale, "suspensionId", Suspension),
      "suspension"
    )
  ).protectedCount;

  return violations;
}

export interface RetentionSweepDependencies {
  now: () => Date;
  inspectKeyring: () => SafetyIdentityKeyringInspection;
}

const defaultDependencies: RetentionSweepDependencies = {
  now: () => new Date(),
  inspectKeyring: () => inspectSafetyIdentityKeyring(),
};

/**
 * How many live records depend on key material that is missing, invalid or
 * reused, plus one for a configured-but-malformed keyring. An unconfigured
 * keyring that nothing depends on is zero: a deployment that has not enabled
 * moderation holds nothing keyed and is not an incident. A count only: no key,
 * key id, digest or reference leaves this function.
 */
async function keyUnavailableCount(inspection: SafetyIdentityKeyringInspection): Promise<number> {
  const counts = await countKeyDependentRecordsUnavailable(inspection.keyring);
  return (
    (inspection.state === "invalid" ? 1 : 0) +
    counts.mismatchedKeys +
    counts.identities +
    counts.ledgerRows
  );
}

/**
 * One sweep run. Each step is isolated: a step that throws is recorded by name
 * in `failedSteps` and the remaining steps still run, so one failing class
 * cannot hide another's overdue rows. The run always appends a `retention-run`
 * event; if that append fails the error propagates (and the last-success clock
 * stops advancing, which `getRetentionHealth` reports as stale).
 */
export async function runRetentionSweep(
  overrides: Partial<RetentionSweepDependencies> = {}
): Promise<IRetentionRunSummary> {
  const deps = { ...defaultDependencies, ...overrides };
  const startedAt = deps.now();
  const summary = blankSummary(startedAt);
  const inspection = deps.inspectKeyring();
  summary.keyringState = inspection.state;

  const attempt = async (step: string, work: () => Promise<void>) => {
    try {
      await work();
    } catch {
      // Names only: an error message could carry a value.
      summary.failedSteps.push(step);
    }
  };

  for (const entry of DEADLINE_CLASSES) {
    await attempt(entry.step, async () => {
      summary[entry.summaryKey] += await deleteOverdue(entry, startedAt);
    });
  }
  await attempt("cascade", () => cascadeOrphans(summary));
  await attempt("hold-review-prompts", async () => {
    summary.holdReviewPromptsRaised += await raiseDueHoldPrompts(startedAt);
  });
  await attempt("identity-release", () => retryIdentityReleases(inspection.keyring, summary));
  await attempt("key-availability", async () => {
    summary.keyUnavailableCount = await keyUnavailableCount(inspection);
  });
  await attempt("invariant", async () => {
    summary.invariantViolations = await countRetentionInvariantViolations();
  });
  await attempt("verify", async () => {
    summary.overdueAfterDelete = await countOverdueRecords(startedAt);
  });

  summary.finishedAt = deps.now();
  summary.status = summary.failedSteps.length === 0 ? "succeeded" : "failed";
  await appendClockedAudit("retention-run", summary.finishedAt, summary);
  return summary;
}

export interface RetentionHealth {
  lastRunAt: Date | null;
  lastSuccessAt: Date | null;
  lastRunStatus: "succeeded" | "failed" | null;
  /** Live count of rows overdue beyond grace right now. */
  overdueNow: number;
  /** Active holds whose mandatory review date has passed. */
  dueHoldReviews: number;
  /** Invariant violations and kept identities reported by the last run. */
  invariantViolationsLastRun: number;
  identitiesKeptLastRun: number;
  /**
   * Live count of identities, ledger rows and keys that cannot be used because
   * key material is missing, invalid or reused. A count only.
   */
  keyIssuesNow: number;
  /** No successful run within three hours (measured from `bootedAt` if none yet). */
  stale: boolean;
  /**
   * Whether the redacted operator-alert path should fire. Checkpoint 1 computes
   * the condition only; sending the alert is Checkpoint 3.
   */
  alertNeeded: boolean;
  alertReasons: string[];
  alertDeliveryStatus: "none" | "pending" | "submitted" | "failed";
  alertLastAttemptAt: Date | null;
}

export const RETENTION_MODULE_LOADED_AT = new Date();

/**
 * The cleanup-failure observability the dashboard health line will read: last
 * success, overdue count and failures. Computed from durable `retention-run`
 * events plus a live overdue count, so a run that never recorded an event cannot
 * hide an overdue record.
 */
export async function getRetentionHealth(
  now: Date = new Date(),
  bootedAt: Date = RETENTION_MODULE_LOADED_AT,
  inspection: SafetyIdentityKeyringInspection = inspectSafetyIdentityKeyring()
): Promise<RetentionHealth> {
  const [last, lastSuccess, overdueNow, dueHoldReviews, keyIssuesNow, alertState] = await Promise.all([
    ModerationAuditEvent.findOne({ kind: "retention-run" }).sort({ createdAt: -1 }).lean().exec(),
    ModerationAuditEvent.findOne({ kind: "retention-run", "run.status": "succeeded" })
      .sort({ createdAt: -1 })
      .lean()
      .exec(),
    countOverdueRecords(now),
    RetentionHold.countDocuments({ state: "active", reviewAt: { $lte: now } }),
    keyUnavailableCount(inspection),
    RetentionAlertState.findOne({ scope: "global" }).lean().exec(),
  ]);

  const lastSuccessAt = lastSuccess?.run?.finishedAt ?? null;
  const reference = lastSuccessAt ?? bootedAt;
  const stale = now.getTime() - reference.getTime() > RETENTION_SWEEP_STALE_MS;
  const alertReasons: string[] = [];
  if (last?.run?.status === "failed") alertReasons.push("last-run-failed");
  if (stale) alertReasons.push("stale-run");
  if (overdueNow > 0) alertReasons.push("overdue-records");
  if ((last?.run?.invariantViolations ?? 0) > 0) alertReasons.push("invariant-violation");
  if (keyIssuesNow > 0) alertReasons.push("key-unavailable");
  if (dueHoldReviews > 0) alertReasons.push("hold-review-due");

  return {
    lastRunAt: last?.run?.finishedAt ?? null,
    lastSuccessAt,
    lastRunStatus: last?.run?.status ?? null,
    overdueNow,
    dueHoldReviews,
    invariantViolationsLastRun: last?.run?.invariantViolations ?? 0,
    identitiesKeptLastRun: last?.run?.identitiesKept ?? 0,
    keyIssuesNow,
    stale,
    alertNeeded: alertReasons.length > 0,
    alertReasons,
    alertDeliveryStatus: alertState?.currentFingerprint
      ? alertState.currentStatus === "resolved"
        ? alertState.lastAttemptStatus ?? "none"
        : alertState.currentStatus
      : alertState?.lastAttemptStatus ?? "none",
    alertLastAttemptAt: alertState?.lastAttemptAt ?? null,
  };
}

/**
 * The scheduler-facing entry point, a **total** function: a failure is logged
 * (error class only, never a value) and never escapes into the cron callback.
 */
export async function startRetentionSweep(): Promise<void> {
  try {
    const summary = await runRetentionSweep();
    if (summary.status === "failed") {
      console.error(`[retention] sweep finished with failed steps: ${summary.failedSteps.join(",")}`);
    }
    const health = await getRetentionHealth();
    await deliverRetentionAlert(health.alertReasons, health.lastRunAt ?? new Date());
  } catch (error) {
    console.error(
      `[retention] sweep could not complete: ${error instanceof Error ? error.name : "unknown"}`
    );
    await deliverRetentionAlert(["last-run-failed"]);
  }
}

/**
 * Registered from `app.ts` at module scope, **independently of `CRON_ENABLED`**
 * (it is the verifier of a privacy promise, not an optional cleanup backup) and
 * without reading `PUBLIC_ACTIONS_PAUSED`.
 */
export function scheduleModerationRetentionSweep(): void {
  registerScheduledJob(RETENTION_SWEEP_CRON, startRetentionSweep);
}
