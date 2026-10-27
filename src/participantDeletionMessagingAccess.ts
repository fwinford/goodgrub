import type { ClientSession, Types } from "mongoose";
import {
  Participant,
  ParticipantDeletionOperation,
  PARTICIPANT_DELETION_PHASES,
  type ParticipantDeletionPhase,
} from "../models/db.js";
import { ACTIVE_PHASES } from "./participantDeletionOperations.js";
import type { DeletionAccess, DeletionAccessPort } from "./messagingPolicy.js";

const KNOWN_PHASES = new Set<string>(PARTICIPANT_DELETION_PHASES);
const ACTIVE_PHASE_SET = new Set<string>(ACTIVE_PHASES);

/**
 * MSG1's real `DeletionAccessPort`, read against accepted P2 CP8 state only.
 * A pure read in the caller's own transaction: no independent fencing, no
 * P2 status helper (those normalize expiry and write), no installation-level
 * freeze interaction (that bookkeeping lives entirely outside this model).
 *
 * `participant_deletion_one_active_operation_per_participant` is P2's own
 * concurrency primitive (a partial-unique index on `participantId` scoped to
 * the four active phases) and is trusted as authoritative, not re-derived.
 * This function reads every operation row for the participant (not just an
 * active-phase-filtered query) so an unrecognized/malformed persisted phase
 * cannot be misread as "no active intent" simply because it fell outside an
 * `$in` filter.
 */
export const getParticipantDeletionMessagingAccess: DeletionAccessPort = async (
  participantId: Types.ObjectId,
  session: ClientSession
): Promise<DeletionAccess> => {
  const participant = await Participant.findById(participantId)
    .select("_id")
    .session(session)
    .lean()
    .exec();
  if (!participant) return "final";

  const rows = await ParticipantDeletionOperation.find({ participantId })
    .select("phase")
    .session(session)
    .lean<{ phase?: ParticipantDeletionPhase | string }[]>()
    .exec();

  let activeCount = 0;
  for (const row of rows) {
    const phase = row.phase;
    if (phase === undefined || !KNOWN_PHASES.has(phase)) {
      throw new Error(
        "participant deletion messaging access: unrecognized or missing persisted phase"
      );
    }
    if (ACTIVE_PHASE_SET.has(phase)) activeCount += 1;
  }

  if (activeCount > 1) {
    throw new Error(
      "participant deletion messaging access: more than one active operation, contradicts the accepted one-active-operation-per-participant invariant"
    );
  }

  return activeCount === 1 ? "pending" : "none";
};
