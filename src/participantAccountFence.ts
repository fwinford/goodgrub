import mongoose, { type ClientSession, Types } from "mongoose";
import { Participant } from "../models/db.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";

export class ParticipantAccountFenceUnavailable extends Error {}

export interface FencedParticipant {
  participantId: string;
  authorityVersion: number;
  principal: string;
}

export async function touchParticipantAccountsInSession(
  participantIds: Array<string | Types.ObjectId>,
  session: ClientSession,
  expectedVersions: ReadonlyMap<string, number> = new Map()
): Promise<Map<string, FencedParticipant>> {
  const ids = [...new Set(participantIds.map(String))].sort();
  const fenced = new Map<string, FencedParticipant>();
  for (const participantId of ids) {
    if (!mongoose.Types.ObjectId.isValid(participantId)) {
      throw new ParticipantAccountFenceUnavailable();
    }
    const objectId = new mongoose.Types.ObjectId(participantId);
    const current = await Participant.findById(objectId)
      .select("authorityVersion")
      .session(session)
      .lean<{ authorityVersion: number } | null>()
      .exec();
    if (
      !current ||
      !Number.isInteger(current.authorityVersion) ||
      (expectedVersions.has(participantId) &&
        expectedVersions.get(participantId) !== current.authorityVersion)
    ) {
      throw new ParticipantAccountFenceUnavailable();
    }
    const touched = await Participant.updateOne(
      { _id: objectId, authorityVersion: current.authorityVersion },
      { $inc: { accountFenceEpoch: 1 } },
      { session }
    ).exec();
    if (touched.matchedCount !== 1) {
      throw new ParticipantAccountFenceUnavailable();
    }
    const row = await Participant.findById(objectId, null, { session })
      .select("email authorityVersion")
      .lean<{ email: string; authorityVersion: number }>()
      .exec();
    if (!row || !Number.isInteger(row.authorityVersion)) {
      throw new ParticipantAccountFenceUnavailable();
    }
    const principal = normalizeParticipantPrincipal(row.email);
    if (principal === null) throw new ParticipantAccountFenceUnavailable();
    fenced.set(participantId, {
      participantId,
      authorityVersion: row.authorityVersion,
      principal,
    });
  }
  return fenced;
}
