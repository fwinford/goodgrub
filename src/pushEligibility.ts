import type { ClientSession } from "mongoose";
import mongoose from "mongoose";
import { Installation, Participant, type IInstallation } from "../models/db.js";
import { findFencedCounterpartIds } from "./participantBlocks.js";
import { isParticipantSuspended } from "./moderationEnforcement.js";
import { isNormalizedApnsToken } from "./installationPushRoute.js";

/**
 * W4-N1 design §1 — the one shared Push eligibility predicate. Every Push
 * selection (helper new-request fan-out today; requester-fulfillment and the
 * pickup notification later; MSG1 messaging push after that) reads through
 * this rather than re-deriving eligibility.
 *
 * ANDs applied: `pushEnabled` ∧ a usable stored token ∧ not invalidated ∧
 * `participantId` present ∧ the Participant exists and is not suspended ∧ its
 * current `authorityVersion` still equals the version recorded at
 * association ∧ not `excludeParticipantId` itself (requester self-exclusion)
 * ∧ not pair-fenced (either direction) from `excludeParticipantId` when one
 * is supplied.
 *
 * Fails closed with no migration: a legacy row with no `participantId`, a
 * suspended/revoked/replaced/deleted Participant, or an `authorityVersion`
 * mismatch is ineligible. This does not resolve an APNs origin or validate
 * the stored environment enum — that transport concern stays with each
 * caller's own dispatch loop, exactly as it did before this predicate
 * existed.
 */
export interface PushEligibilityCandidate {
  _id: IInstallation["_id"];
  apnsToken: string;
  apnsEnvironment: IInstallation["apnsEnvironment"];
}

export interface PushEligibilityOptions {
  /** The Request's `requesterParticipantId` — excluded from its own fan-out. */
  excludeParticipantId?: string | mongoose.Types.ObjectId | null;
  installationId?: unknown;
  requiredParticipantId?: string | mongoose.Types.ObjectId | null;
  counterpartParticipantId?: string | mongoose.Types.ObjectId | null;
  session?: ClientSession;
}

export async function selectEligiblePushInstallations(
  options: PushEligibilityOptions = {}
): Promise<PushEligibilityCandidate[]> {
  const { excludeParticipantId, session } = options;
  if ("requiredParticipantId" in options && options.requiredParticipantId == null) return [];

  const rows = await Installation.find(
    {
      pushEnabled: true,
      apnsToken: { $type: "string" },
      invalidatedAt: null,
      participantId: { $ne: null },
      ...(options.installationId == null ? {} : { _id: options.installationId }),
    },
    undefined,
    session ? { session } : undefined
  )
    .select(
      "+apnsToken +participantId +participantAuthorityVersion apnsEnvironment"
    )
    .lean<
      Pick<
        IInstallation,
        | "_id"
        | "apnsToken"
        | "apnsEnvironment"
        | "participantId"
        | "participantAuthorityVersion"
      >[]
    >()
    .exec();

  if (rows.length === 0) return [];

  const excludeId = excludeParticipantId ? String(excludeParticipantId) : null;
  const counterpart = options.counterpartParticipantId ?? excludeId;
  const fenced = counterpart
    ? await findFencedCounterpartIds(counterpart, session)
    : new Set<string>();

  const candidateParticipantIds = [
    ...new Set(
      rows
        .map((row) => row.participantId)
        .filter((id): id is NonNullable<typeof id> => id != null)
        .map((id) => String(id))
    ),
  ].filter((id) => id !== excludeId && !fenced.has(id) &&
    (options.requiredParticipantId == null || id === String(options.requiredParticipantId)));

  if (candidateParticipantIds.length === 0) return [];

  const participants = await Participant.find(
    {
      _id: {
        $in: candidateParticipantIds.map((id) => new mongoose.Types.ObjectId(id)),
      },
    },
    undefined,
    session ? { session } : undefined
  )
    .select("authorityVersion")
    .lean<{ _id: unknown; authorityVersion: number }[]>()
    .exec();

  const liveAuthorityVersionByParticipantId = new Map(
    participants.map((participant) => [
      String(participant._id),
      participant.authorityVersion,
    ])
  );
  for (const id of liveAuthorityVersionByParticipantId.keys()) {
    if (await isParticipantSuspended(id, session)) {
      liveAuthorityVersionByParticipantId.delete(id);
    }
  }

  const eligible: PushEligibilityCandidate[] = [];
  for (const row of rows) {
    if (row.participantId == null) continue;
    const participantId = String(row.participantId);
    if (participantId === excludeId || fenced.has(participantId)) continue;
    if (options.requiredParticipantId != null && participantId !== String(options.requiredParticipantId)) continue;
    const liveAuthorityVersion =
      liveAuthorityVersionByParticipantId.get(participantId);
    // Not found here means suspended, revoked, or deleted — all ineligible.
    if (liveAuthorityVersion === undefined) continue;
    if (liveAuthorityVersion !== row.participantAuthorityVersion) continue;
    if (!isNormalizedApnsToken(row.apnsToken)) continue;
    eligible.push({
      _id: row._id,
      apnsToken: row.apnsToken,
      apnsEnvironment: row.apnsEnvironment,
    });
  }
  return eligible;
}
