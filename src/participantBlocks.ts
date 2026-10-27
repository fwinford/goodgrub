import mongoose, { type ClientSession } from "mongoose";
import { Participant, ParticipantBlock } from "../models/db.js";

/**
 * Participant-pair eligibility (W4-U1.3).
 *
 * A pair is fenced when a block exists in *either* direction. Callers get a
 * yes/no (or the caller-relative set of fenced counterparts) and never the
 * direction, the owner, or the row, so nothing downstream can tell the blocked
 * party who blocked whom.
 *
 * ## Serialization against claims and extensions
 *
 * A claim and a block touch different documents (`Request`/`Participant`/
 * `RequestParticipation` versus `ParticipantBlock`), so under snapshot
 * isolation a claim that read "no block" and a block that committed meanwhile
 * would both commit: write skew, and a reservation granted across a block.
 *
 * The invariant that closes it: *every transaction that creates a block writes
 * both participants' Participant documents* (`bumpBlockFence`), and *every
 * transaction that grants a reservation writes the claiming helper's own
 * Participant document* (the one-active-reservation lock in `claimRequest`). A
 * claim between A and B is always made by A or by B, so it always shares a
 * written document with a block between A and B. MongoDB's first-committer-wins
 * write-conflict detection then orders the two: whichever commits second is
 * retried by `withTransaction` against a fresh snapshot, so a claim either
 * reads the committed block and is refused, or committed first and the block is
 * applied to a reservation that legitimately already existed.
 *
 * Extension is deliberately not serialized against a block (W4-U1.3,
 * post-Block autonomy): it starts no new interaction, so the fence never
 * consults it and a holder may always use the ordinary one-time extension.
 *
 * Unblock deliberately does not bump the fence: a claim that read a block that
 * was removed concurrently is merely refused conservatively, which is safe.
 */

/**
 * Every participant fenced from `participantId`, in either direction.
 * Resolved fresh per call from the durable relation; there is no cache.
 */
export async function findFencedCounterpartIds(
  participantId: string | mongoose.Types.ObjectId,
  session?: ClientSession,
  maxTimeMS?: number
): Promise<Set<string>> {
  const id = new mongoose.Types.ObjectId(String(participantId));
  const query = ParticipantBlock.find(
    { $or: [{ blockerParticipantId: id }, { blockedParticipantId: id }] },
    undefined,
    session ? { session } : undefined
  )
    .select("+blockerParticipantId +blockedParticipantId");
  if (maxTimeMS !== undefined) query.maxTimeMS(maxTimeMS);
  const rows = await query.lean().exec();

  const fenced = new Set<string>();
  for (const row of rows as unknown as Array<{
    blockerParticipantId: unknown;
    blockedParticipantId?: unknown;
  }>) {
    const blocker = String(row.blockerParticipantId);
    const blocked =
      row.blockedParticipantId == null
        ? undefined
        : String(row.blockedParticipantId);
    if (!blocked) continue;
    fenced.add(blocker === String(id) ? blocked : blocker);
  }
  return fenced;
}

/** Whether any block exists between the two participants, either direction. */
export async function isParticipantPairFenced(
  first: string | mongoose.Types.ObjectId,
  second: string | mongoose.Types.ObjectId,
  session?: ClientSession
): Promise<boolean> {
  const a = new mongoose.Types.ObjectId(String(first));
  const b = new mongoose.Types.ObjectId(String(second));
  if (a.equals(b)) return false;

  const row = await ParticipantBlock.findOne(
    {
      $or: [
        { blockerParticipantId: a, blockedParticipantId: b },
        { blockerParticipantId: b, blockedParticipantId: a },
      ],
    },
    { _id: 1 },
    session ? { session } : undefined
  )
    .lean()
    .exec();

  return row !== null;
}

/**
 * The write that makes a block conflict with a concurrent claim/extension on
 * the same pair. Must run in the same transaction that inserts the block.
 */
export async function bumpBlockFence(
  first: mongoose.Types.ObjectId,
  second: mongoose.Types.ObjectId,
  session: ClientSession
): Promise<number> {
  if (first.equals(second)) return 0;
  const result = await Participant.updateMany(
    { _id: { $in: [first, second] } },
    { $inc: { blockFenceEpoch: 1 } },
    { session }
  ).exec();
  return result.matchedCount;
}

/**
 * The board-discovery predicate for one caller (W4-U1.3): excludes requests
 * authored by any participant fenced from them, in either direction. Returned
 * as a query fragment rather than applied in memory so it takes effect ahead of
 * the list's fixed `limit` — excluded requests can never occupy slots that a
 * visible one would have filled. An anonymous or unresolved caller has no
 * participant authority to fence and gets an empty fragment, which is also what
 * a participant with no blocks gets.
 */
export async function buildParticipantFenceFilter(
  participantId: string | null,
  options: { maxTimeMS?: number } = {}
): Promise<Record<string, unknown>> {
  if (!participantId) return {};
  const fenced = await findFencedCounterpartIds(
    participantId,
    undefined,
    options.maxTimeMS
  );
  if (fenced.size === 0) return {};
  return {
    requesterParticipantId: {
      $nin: [...fenced].map((id) => new mongoose.Types.ObjectId(id)),
    },
  };
}
