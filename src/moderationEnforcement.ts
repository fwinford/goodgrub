import type { ClientSession, Types } from "mongoose";
import mongoose from "mongoose";
import { Participant, Request as MealRequest } from "../models/db.js";
import {
  recordSuspension,
  liftSuspension,
  type RecordSuspensionInput,
  type LiftSuspensionResult,
} from "./moderationRecords.js";
import { closeMessagingForParticipantInSession } from "./messagingLifecycle.js";
import type { SafetyIdentityKeyring } from "./safetyIdentityKeyring.js";

/**
 * W4-U1.2 Checkpoint 2 — the Request/Participant enforcement half of
 * suspension and reinstatement (boundary contract EO). CP1's
 * `recordSuspension` / `liftSuspension` (`src/moderationRecords.ts`) own the
 * moderation record, the safety identity, and the retention clocks; the
 * functions here write the matching enforcement state — M, L, and the
 * Participant's own `suspended` flag — in the *same* transaction, exactly as
 * CP1's own doc comments require ("Checkpoint 2's reinstatement transaction
 * must do that in this same transaction, passing the same `session`").
 *
 * CP3's moderator operations call these primitives for report outcomes,
 * manual suspension and reinstatement.
 */

export const PARTICIPANT_SUSPENDED_CODE = "PARTICIPANT_SUSPENDED";
// Approved Home-notice wording (Section G); no other refusal copy exists.
export const PARTICIPANT_SUSPENDED_MESSAGE =
  "You can't post or help with new requests.";

export class RequesterSuspendedError extends Error {}

/**
 * Create gate (boundary contract EO): one atomic conditional write on the
 * requester's Participant document that matches only while not suspended and
 * bumps the private epoch, so it also conflicts with a concurrent requester
 * suspension (which writes the same document). Must run inside the same
 * transaction as the Request insert.
 */
export async function assertRequesterNotSuspendedWithinSession(
  participantId: Types.ObjectId | string,
  session: ClientSession
): Promise<void> {
  const result = await Participant.updateOne(
    {
      _id: new mongoose.Types.ObjectId(String(participantId)),
      suspended: { $ne: true },
    },
    { $inc: { suspensionFenceEpoch: 1 } },
    { session }
  ).exec();
  if (result.matchedCount === 0) throw new RequesterSuspendedError();
}

/** Whether this exact participant document is currently suspended. */
export async function isParticipantSuspended(
  participantId: Types.ObjectId | string,
  session?: ClientSession
): Promise<boolean> {
  const query = Participant.exists({
    _id: new mongoose.Types.ObjectId(String(participantId)),
    suspended: true,
  });
  const found = await (session ? query.session(session) : query);
  return Boolean(found);
}

/**
 * Whether either of two participants is currently suspended (EO: "an
 * affirmative-only, direction-agnostic signal... when either party is
 * suspended"). Used to extend the existing U1.3 contact-withheld channel.
 */
export async function isEitherParticipantSuspended(
  first: Types.ObjectId | string,
  second: Types.ObjectId | string,
  session?: ClientSession
): Promise<boolean> {
  const a = new mongoose.Types.ObjectId(String(first));
  const b = new mongoose.Types.ObjectId(String(second));
  const query = Participant.exists({ _id: { $in: [a, b] }, suspended: true });
  const found = await (session ? query.session(session) : query);
  return Boolean(found);
}

export interface SuspendParticipantInput {
  session: ClientSession;
  now: Date;
  keyring: SafetyIdentityKeyring | null;
  participantId: Types.ObjectId;
  email?: string;
  safetyIdentityId?: Types.ObjectId;
  origin: RecordSuspensionInput["origin"];
  reportId?: RecordSuspensionInput["reportId"];
  rationale: string;
  actor?: string;
}

export interface SuspendParticipantResult {
  suspensionId: Types.ObjectId;
  ref: string;
  created: boolean;
}

/**
 * Suspend a requester (EO scenario table, "Suspend requester"): the CP1
 * moderation record, the Participant's own `suspended` flag (and its
 * write-conflict epoch, so a concurrent create on the same document is
 * forced to retry against a fresh snapshot — the same role `blockFenceEpoch`
 * plays for Block), and M on every one of that requester's **non-placed**
 * requests, including scheduled Later requests. A `placed` request is left
 * exactly as it is: existing-order completion and pickup access are
 * preserved (Decision 12).
 *
 * Idempotent with `recordSuspension`: a second call while already suspended
 * still (re-)applies the enforcement writes, which are themselves idempotent
 * conditional updates, so nothing here can double-suspend or double-mark.
 */
export async function suspendRequester(
  input: SuspendParticipantInput
): Promise<SuspendParticipantResult> {
  const { session, now, keyring, participantId, email, origin, reportId, rationale, actor } =
    input;

  const { suspensionId, ref, created, identityId } = await recordSuspension(session, {
    keyring,
    suspendedEmail: email,
    safetyIdentityId: input.safetyIdentityId,
    origin,
    reportId,
    rationale,
    actor,
  });

  await Participant.updateOne(
    {
      _id: participantId,
      $or: [
        { suspended: { $ne: true } },
        { safetyIdentityRef: { $ne: identityId } },
      ],
    },
    {
      $set: {
        suspended: true,
        safetyIdentityRef: identityId,
      },
      $inc: { suspensionFenceEpoch: 1 },
    },
    { session }
  ).exec();

  await MealRequest.updateMany(
    { requesterParticipantId: participantId, status: { $ne: "placed" } },
    { $set: { moderationUnavailable: true, updatedAt: now } },
    { session }
  ).exec();

  // Permanent and in this transaction: reinstatement never reopens a chat.
  await closeMessagingForParticipantInSession(participantId, session);

  return { suspensionId, ref, created };
}

/**
 * Suspend a helper (EO scenario table, "Suspend helper, live reservation" /
 * "no live reservation" / "order already placed"): the CP1 moderation
 * record, the Participant's own `suspended` flag, and — only while this
 * participant genuinely holds a live, not-yet-affirmed reservation in this
 * same snapshot — L pinned to the exact reservation (same helper binding and
 * deadline the release mutation already pins against). A `placed` order or
 * one already carrying E is left untouched: L means "this reservation's
 * order status is Unknown", which is already settled for either of those.
 */
export async function suspendHelper(
  input: SuspendParticipantInput
): Promise<SuspendParticipantResult> {
  const { session, now, keyring, participantId, email, origin, reportId, rationale, actor } =
    input;

  const { suspensionId, ref, created, identityId } = await recordSuspension(session, {
    keyring,
    suspendedEmail: email,
    safetyIdentityId: input.safetyIdentityId,
    origin,
    reportId,
    rationale,
    actor,
  });

  await Participant.updateOne(
    {
      _id: participantId,
      $or: [
        { suspended: { $ne: true } },
        { safetyIdentityRef: { $ne: identityId } },
      ],
    },
    {
      $set: {
        suspended: true,
        safetyIdentityRef: identityId,
      },
      $inc: { suspensionFenceEpoch: 1 },
    },
    { session }
  ).exec();

  // Pinned to the exact live reservation in this same transaction snapshot:
  // same helper binding and deadline, never affirmed (E) already. A
  // reservation that races this write (an extension, a release, a
  // fulfillment) simply does not match and nothing is written for it — there
  // is no reservation left for L to mean anything about.
  const liveReservation = await MealRequest.findOne(
    {
      helperParticipantId: participantId,
      status: "claimed",
      claimExpiresAt: { $gt: now },
      externalOrderAffirmed: { $ne: true },
    },
    { _id: 1, claimExpiresAt: 1 },
    { session }
  )
    .lean()
    .exec();

  if (liveReservation) {
    await MealRequest.updateOne(
      {
        _id: liveReservation._id,
        status: "claimed",
        claimExpiresAt: liveReservation.claimExpiresAt,
        helperParticipantId: participantId,
        externalOrderAffirmed: { $ne: true },
      },
      { $set: { reservationLapseHold: true, updatedAt: now } },
      { session }
    ).exec();
  }

  // Permanent and in this transaction: reinstatement never reopens a chat.
  await closeMessagingForParticipantInSession(participantId, session);

  return { suspensionId, ref, created };
}

export interface ReinstateParticipantInput {
  session: ClientSession;
  now: Date;
  keyring: SafetyIdentityKeyring | null;
  suspensionId: Types.ObjectId;
  participantId: Types.ObjectId;
  actor?: string;
}

export type ReinstateParticipantResult = LiftSuspensionResult;

/**
 * Reinstate a participant of either origin (EO scenario table, "Reinstate
 * (either origin)"): lifts the CP1 moderation record and clears only the
 * Participant's own `suspended` state, prospectively. Never writes, clears,
 * or revives any Request, M, L, or E — a previously unavailable request
 * stays unavailable, exactly as the accepted contract requires.
 */
export async function reinstateParticipant(
  input: ReinstateParticipantInput
): Promise<ReinstateParticipantResult> {
  const { session, now, keyring, suspensionId, participantId, actor } = input;

  const result = await liftSuspension(session, { suspensionId, keyring, actor }, now);
  if (result.status !== "lifted") return result;

  await Participant.updateOne(
    { _id: participantId },
    { $unset: { suspended: 1 } },
    { session }
  ).exec();

  return result;
}
