import type { ClientSession, Types } from "mongoose";
import {
  ModerationReport,
  ReportEvidence,
  RetentionHold,
  Suspension,
  SuspensionRationale,
} from "../models/moderation.js";
import type { HoldTargetKind } from "./moderationConstants.js";
import { computeRetentionClocks } from "./moderationRetention.js";

/**
 * Writes retention clocks from state (RH, "Mechanism: clocks are data written in
 * the same transaction as the event that starts them").
 *
 * Every lifecycle transition and every hold change calls the matching
 * recompute inside its own transaction. The recompute is a pure function of the
 * committed state it reads, so it is idempotent and cannot drift from the
 * transition that triggered it: a record is either held (no `deleteAt`) because
 * live state keeps it, or carries the deadline the one formula yields.
 */

function setOrUnset(deleteAt: Date | null) {
  return deleteAt ? { $set: { deleteAt } } : { $unset: { deleteAt: 1 as const } };
}

/**
 * Clocks for a case and its detailed evidence. A case is held while Open, while
 * a linked suspension is Active, or while an explicit hold is active; otherwise
 * its anchor is `closedAt`, or `max(closedAt, liftedAt)` once a linked
 * suspension has also lifted.
 */
export async function recomputeCaseClocks(
  session: ClientSession,
  reportId: Types.ObjectId,
  _now: Date
): Promise<void> {
  const report = await ModerationReport.findById(reportId, undefined, { session })
    .lean()
    .exec();
  if (!report) return;

  const [suspensions, holds] = await Promise.all([
    Suspension.find({ reportIds: reportId }, { state: 1, liftedAt: 1 }, { session })
      .lean()
      .exec(),
    RetentionHold.find(
      { targetKind: "case", targetId: reportId },
      { state: 1, endedAt: 1 },
      { session }
    )
      .lean()
      .exec(),
  ]);

  const activeSuspension = suspensions.some((row) => row.state === "active");
  const activeHold = holds.some((row) => row.state === "active");
  const liftedAt = latest(
    suspensions.filter((row) => row.state === "lifted").map((row) => row.liftedAt)
  );
  const clocks = computeRetentionClocks({
    ended: report.state === "closed",
    heldByLiveState: activeSuspension || activeHold,
    closedAt: report.closedAt ?? null,
    liftedAt,
    latestHoldEnd: latest(holds.filter((row) => row.state === "released").map((row) => row.endedAt)),
  });

  await ModerationReport.updateOne({ _id: reportId }, setOrUnset(clocks.historyDeleteAt), {
    session,
  });
  await ReportEvidence.updateMany({ reportId }, setOrUnset(clocks.evidenceDeleteAt), {
    session,
  });
}

/**
 * Clocks for a suspension and its rationale. Held while Active, while **any**
 * linked report is still Open (another active investigation), or while an
 * explicit hold is active. A suspension with no linked report anchors on
 * `liftedAt`; one with linked reports on `max(latest closedAt, liftedAt)`.
 */
export async function recomputeSuspensionClocks(
  session: ClientSession,
  suspensionId: Types.ObjectId,
  _now: Date
): Promise<void> {
  const suspension = await Suspension.findById(suspensionId, undefined, { session })
    .lean()
    .exec();
  if (!suspension) return;

  const [linkedReports, holds] = await Promise.all([
    suspension.reportIds && suspension.reportIds.length > 0
      ? ModerationReport.find(
          { _id: { $in: suspension.reportIds } },
          { state: 1, closedAt: 1 },
          { session }
        )
          .lean()
          .exec()
      : [],
    RetentionHold.find(
      { targetKind: "suspension", targetId: suspensionId },
      { state: 1, endedAt: 1 },
      { session }
    )
      .lean()
      .exec(),
  ]);

  // A linked report whose row is already gone has ended long ago; it neither
  // holds the suspension nor moves its anchor.
  const linkedReportOpen = linkedReports.some((report) => report.state === "open");
  const activeHold = holds.some((row) => row.state === "active");
  const clocks = computeRetentionClocks({
    ended: suspension.state === "lifted",
    heldByLiveState: linkedReportOpen || activeHold,
    closedAt: latest(
      linkedReports.filter((report) => report.state === "closed").map((report) => report.closedAt)
    ),
    liftedAt: suspension.liftedAt ?? null,
    latestHoldEnd: latest(holds.filter((row) => row.state === "released").map((row) => row.endedAt)),
  });

  await Suspension.updateOne({ _id: suspensionId }, setOrUnset(clocks.historyDeleteAt), {
    session,
  });
  await SuspensionRationale.updateMany(
    { suspensionId },
    setOrUnset(clocks.evidenceDeleteAt),
    { session }
  );
}

export async function recomputeClocksForTarget(
  session: ClientSession,
  kind: HoldTargetKind,
  targetId: Types.ObjectId,
  now: Date
): Promise<void> {
  if (kind === "case") await recomputeCaseClocks(session, targetId, now);
  else await recomputeSuspensionClocks(session, targetId, now);
}

function latest(dates: Array<Date | null | undefined>): Date | null {
  let result: Date | null = null;
  for (const date of dates) {
    if (date && (!result || date.getTime() > result.getTime())) result = date;
  }
  return result;
}
