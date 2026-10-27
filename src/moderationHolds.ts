import type { ClientSession, Types } from "mongoose";
import {
  ModerationReport,
  RetentionHold,
  SafetyIdentity,
  Suspension,
  type HoldReleaseBasis,
  type IRetentionHold,
} from "../models/moderation.js";
import { appendSubjectAudit } from "./moderationAudit.js";
import { recomputeClocksForTarget } from "./moderationClocks.js";
import {
  HOLD_ENDING_CONDITION_MAX_LENGTH,
  HOLD_NOTE_MAX_LENGTH,
  HOLD_REASON_CODE_PATTERN,
  HOLD_REVIEW_INTERVAL_MAX_MS,
  RELEASED_HOLD_RETENTION_MS,
  type HoldClass,
  type HoldTargetKind,
} from "./moderationConstants.js";
import { isPastDeleteAt } from "./moderationRetention.js";
import { releaseSafetyIdentityIfUnreferenced } from "./safetyIdentity.js";
import type { SafetyIdentityKeyring } from "./safetyIdentityKeyring.js";

/**
 * The retention-hold ledger (RH, "Hold classes").
 *
 * Only the two explicit classes are rows: an **overlapping safety case** and a
 * **documented legal preservation**. An Open case and an Active suspension are
 * structural holds (the state is the hold) and have no row.
 *
 * A hold preserves records only and never creates enforcement authority. It
 * requires a reason code, a documented ending condition and a `reviewAt` at
 * most 90 days away. **Reaching `reviewAt` never releases a hold and never
 * authorizes deletion**: it raises a prompt (`raiseHoldReviewPrompt`) and the
 * hold stays in force until a review or an authorized release. A review re-sets
 * `reviewAt` with the reason unchanged and is audited; it is not a silent
 * extension. There is no release by clock.
 *
 * Every function here runs inside the caller's transaction (`session`) and
 * writes its audit row through the same session, so an unauditable action does
 * not run. The CP3 moderator surface authenticates Faith and supplies the
 * audited actor for each operation.
 */

export type RetentionHoldRefusalCode =
  | "invalid-reason-code"
  | "invalid-ending-condition"
  | "invalid-note"
  | "invalid-review-at"
  | "related-case-required"
  | "target-not-found"
  | "identity-detached"
  | "not-active"
  | "ending-condition-not-met";

export class RetentionHoldRefusal extends Error {
  readonly code: RetentionHoldRefusalCode;
  constructor(code: RetentionHoldRefusalCode) {
    super(`Retention hold refused: ${code}.`);
    this.name = "RetentionHoldRefusal";
    this.code = code;
  }
}

function assertReviewAt(reviewAt: Date | undefined, now: Date): void {
  const time = reviewAt instanceof Date ? reviewAt.getTime() : Number.NaN;
  if (
    Number.isNaN(time) ||
    time <= now.getTime() ||
    time > now.getTime() + HOLD_REVIEW_INTERVAL_MAX_MS
  ) {
    throw new RetentionHoldRefusal("invalid-review-at");
  }
}

export interface CreateRetentionHoldInput {
  targetKind: HoldTargetKind;
  targetId: Types.ObjectId;
  holdClass: HoldClass;
  reasonCode: string;
  note?: string;
  endingCondition: string;
  reviewAt: Date;
  /** Required for an overlapping-case hold: the related case whose closure ends it. */
  relatedReportId?: Types.ObjectId;
  /**
   * Keep the target's safety-identity reference alive through closure. Only
   * possible while the target still holds the reference: a released identity
   * cannot be recreated because the raw email is not retained.
   */
  keepSafetyIdentity?: boolean;
  actor?: string;
}

export async function createRetentionHold(
  session: ClientSession,
  input: CreateRetentionHoldInput,
  now: Date
): Promise<{ holdId: Types.ObjectId; ref: string }> {
  if (!HOLD_REASON_CODE_PATTERN.test(input.reasonCode)) {
    throw new RetentionHoldRefusal("invalid-reason-code");
  }
  const endingCondition = input.endingCondition?.trim() ?? "";
  if (endingCondition === "" || endingCondition.length > HOLD_ENDING_CONDITION_MAX_LENGTH) {
    throw new RetentionHoldRefusal("invalid-ending-condition");
  }
  if (input.note !== undefined && input.note.length > HOLD_NOTE_MAX_LENGTH) {
    throw new RetentionHoldRefusal("invalid-note");
  }
  assertReviewAt(input.reviewAt, now);
  if (input.holdClass === "overlapping-case" && !input.relatedReportId) {
    throw new RetentionHoldRefusal("related-case-required");
  }

  // The target must exist and not be past its own deadline: a read treats a
  // record past `deleteAt` as absent, so a hold cannot resurrect it.
  const target =
    input.targetKind === "case"
      ? await ModerationReport.findById(input.targetId, undefined, { session }).lean().exec()
      : await Suspension.findById(input.targetId, undefined, { session }).lean().exec();
  if (!target || isPastDeleteAt(target, now)) throw new RetentionHoldRefusal("target-not-found");

  let safetyIdentityRef: Types.ObjectId | undefined;
  if (input.keepSafetyIdentity) {
    if (!target.safetyIdentityRef) throw new RetentionHoldRefusal("identity-detached");
    safetyIdentityRef = target.safetyIdentityRef as Types.ObjectId;
    // Attach through the identity serialization protocol: write the identity's
    // anchor in this transaction. A closure or lift that detaches the target and
    // releases the identity writes (or deletes) the same record, so whichever
    // commits second conflicts and retries into the committed truth. Reading the
    // target's reference alone is a snapshot read that a concurrent release can
    // outrun, leaving an active hold on a deleted identity. An identity that is
    // already gone is refused, never accepted.
    const pinned = await SafetyIdentity.findOneAndUpdate(
      { _id: safetyIdentityRef },
      { $inc: { serial: 1 } },
      { session, new: false, projection: { _id: 1 } }
    )
      .lean()
      .exec();
    if (!pinned) throw new RetentionHoldRefusal("identity-detached");
  }

  const [hold] = await RetentionHold.create(
    [
      {
        targetKind: input.targetKind,
        targetId: input.targetId,
        holdClass: input.holdClass,
        reasonCode: input.reasonCode,
        note: input.note,
        endingCondition,
        reviewAt: input.reviewAt,
        relatedReportId: input.relatedReportId,
        safetyIdentityRef,
      },
    ],
    { session }
  );
  // Creating a hold clears the target's deadlines: it is held until release.
  await recomputeClocksForTarget(session, input.targetKind, input.targetId, now);
  await appendSubjectAudit(session, "hold-created", "hold", hold._id as Types.ObjectId, input.actor);
  return { holdId: hold._id as Types.ObjectId, ref: hold.ref };
}

/**
 * An audited review: sets a new `reviewAt` (at most 90 days from `now`) with the
 * reason and ending condition unchanged, and clears the raised prompt. Refused
 * unless the hold is still active.
 */
export async function reviewRetentionHold(
  session: ClientSession,
  holdId: Types.ObjectId,
  nextReviewAt: Date,
  now: Date,
  actor?: string
): Promise<void> {
  assertReviewAt(nextReviewAt, now);
  const updated = await RetentionHold.updateOne(
    { _id: holdId, state: "active" },
    {
      $set: { reviewAt: nextReviewAt, lastReviewedAt: now },
      $unset: { reviewPromptRaisedAt: 1 },
    },
    { session }
  );
  if (updated.modifiedCount !== 1) throw new RetentionHoldRefusal("not-active");
  await appendSubjectAudit(session, "hold-reviewed", "hold", holdId, actor);
}

export interface ReleasedHoldOutcome {
  holdId: Types.ObjectId;
  targetKind: HoldTargetKind;
  targetId: Types.ObjectId;
}

/**
 * Ends one active hold: conditional on `state: "active"`, records the end and
 * basis, detaches the identity reference, schedules the row's own deletion,
 * recomputes the target's clocks (an already-past deadline is due now) and
 * attempts the guarded identity release in the same transaction. Returns
 * `null` when the hold was no longer active (a concurrent release won).
 */
export async function endRetentionHold(
  session: ClientSession,
  holdId: Types.ObjectId,
  basis: HoldReleaseBasis,
  now: Date,
  keyring: SafetyIdentityKeyring | null,
  actor?: string
): Promise<ReleasedHoldOutcome | null> {
  const before = await RetentionHold.findOneAndUpdate(
    { _id: holdId, state: "active" },
    {
      $set: {
        state: "released",
        endedAt: now,
        releaseBasis: basis,
        deleteAt: new Date(now.getTime() + RELEASED_HOLD_RETENTION_MS),
      },
      $unset: { safetyIdentityRef: 1 },
    },
    { session, new: false }
  )
    .lean<IRetentionHold>()
    .exec();
  if (!before) return null;

  await recomputeClocksForTarget(session, before.targetKind, before.targetId, now);
  await appendSubjectAudit(session, "hold-released", "hold", holdId, actor);
  if (before.safetyIdentityRef) {
    await releaseSafetyIdentityIfUnreferenced(
      before.safetyIdentityRef as Types.ObjectId,
      keyring,
      session
    );
  }
  return { holdId, targetKind: before.targetKind, targetId: before.targetId as Types.ObjectId };
}

/**
 * Faith's explicit, audited release, recording that the documented ending
 * condition has been met. Refuses unless that is asserted: no clock, review
 * date or sweep ever calls this.
 */
export async function releaseRetentionHold(
  session: ClientSession,
  holdId: Types.ObjectId,
  assertion: { endingConditionMet: boolean },
  now: Date,
  keyring: SafetyIdentityKeyring | null,
  actor?: string
): Promise<ReleasedHoldOutcome> {
  if (assertion.endingConditionMet !== true) {
    throw new RetentionHoldRefusal("ending-condition-not-met");
  }
  const outcome = await endRetentionHold(
    session,
    holdId,
    "ending-condition-met",
    now,
    keyring,
    actor
  );
  if (!outcome) throw new RetentionHoldRefusal("not-active");
  return outcome;
}

/**
 * Raises the review prompt for one active hold whose `reviewAt` has passed.
 * Conditional on no prompt already raised, so overlapping sweeps raise one.
 * This is the only thing a passed `reviewAt` ever causes: the hold stays in
 * force and nothing is released or deleted. Returns whether this call raised it.
 */
export async function raiseHoldReviewPrompt(
  session: ClientSession,
  holdId: Types.ObjectId,
  now: Date
): Promise<boolean> {
  const updated = await RetentionHold.updateOne(
    {
      _id: holdId,
      state: "active",
      reviewAt: { $lte: now },
      reviewPromptRaisedAt: { $exists: false },
    },
    { $set: { reviewPromptRaisedAt: now } },
    { session }
  );
  if (updated.modifiedCount !== 1) return false;
  await appendSubjectAudit(session, "hold-review-prompted", "hold", holdId);
  return true;
}
