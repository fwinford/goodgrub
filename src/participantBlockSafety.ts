import mongoose, { type ClientSession } from "mongoose";
import { ParticipantBlock } from "../models/db.js";
import {
  touchParticipantAccountsInSession,
  type FencedParticipant,
} from "./participantAccountFence.js";
import {
  deriveParticipantIdentityAliases,
  loadParticipantIdentityManifest,
  ParticipantIdentityConfigurationError,
} from "./participantIdentityKeys.js";

interface StoredSafetyBlock {
  _id: mongoose.Types.ObjectId;
  blockerParticipantId: mongoose.Types.ObjectId;
  blockedParticipantId?: mongoose.Types.ObjectId;
  blockedSafetyKeyVersion: number;
  blockedSafetyHmac: string;
}

async function requireKnownBlockSafetyRows(
  session: ClientSession,
  versions: number[]
): Promise<void> {
  const unknown = await ParticipantBlock.exists({
    $or: [
      { blockedSafetyKeyVersion: { $exists: false } },
      { blockedSafetyHmac: { $exists: false } },
      { blockedSafetyKeyVersion: { $nin: versions } },
    ],
  }).session(session);
  if (unknown) {
    throw new ParticipantIdentityConfigurationError(
      "Participant block safety identity data is unavailable"
    );
  }
}

function matchingSafetyAliases(
  aliases: Array<{ version: number; digest: string }>
): Record<string, unknown>[] {
  return aliases.map(({ version, digest }) => ({
    blockedSafetyKeyVersion: version,
    blockedSafetyHmac: digest,
  }));
}

export async function rebindRetainedParticipantBlocks(
  input: {
    participantId: string | mongoose.Types.ObjectId;
    principal: string;
    expectedAuthorityVersion?: number;
  },
  session: ClientSession
): Promise<FencedParticipant[]> {
  const participantId = new mongoose.Types.ObjectId(String(input.participantId));
  const { ring, entries } = await loadParticipantIdentityManifest(
    "block-safety",
    session
  );
  const versions = entries.map((entry) => entry.version);
  await requireKnownBlockSafetyRows(session, versions);
  const aliases = deriveParticipantIdentityAliases(
    "block-safety",
    ring,
    entries,
    null,
    input.principal
  );
  const rows = (await ParticipantBlock.find({
    $or: [
      { blockedParticipantId: participantId },
      {
        blockedParticipantId: { $exists: false },
        $or: matchingSafetyAliases(aliases),
      },
      {
        blockedParticipantId: { $type: "objectId", $ne: participantId },
        $or: matchingSafetyAliases(aliases),
      },
    ],
  })
    .select(
      "+blockerParticipantId +blockedParticipantId +blockedSafetyKeyVersion +blockedSafetyHmac"
    )
    .session(session)
    .lean<StoredSafetyBlock[]>()
    .exec()) as StoredSafetyBlock[];

  const conflicting = rows.find(
    (row) =>
      row.blockedParticipantId &&
      !row.blockedParticipantId.equals(participantId)
  );
  if (conflicting) {
    throw new ParticipantIdentityConfigurationError(
      "Participant block safety identity data is inconsistent"
    );
  }
  const blockerIds = rows.map((row) => row.blockerParticipantId);
  const expectedVersions = new Map<string, number>();
  if (input.expectedAuthorityVersion !== undefined) {
    expectedVersions.set(
      String(participantId),
      input.expectedAuthorityVersion
    );
  }
  const fenced = await touchParticipantAccountsInSession(
    [participantId, ...blockerIds],
    session,
    expectedVersions
  );
  for (const row of rows) {
    if (row.blockedParticipantId?.equals(participantId)) continue;
    const result = await ParticipantBlock.updateOne(
      {
        _id: row._id,
        blockedParticipantId: { $exists: false },
        blockedSafetyKeyVersion: row.blockedSafetyKeyVersion,
        blockedSafetyHmac: row.blockedSafetyHmac,
      },
      { $set: { blockedParticipantId: participantId } },
      { session, timestamps: false }
    ).exec();
    if (result.matchedCount !== 1) {
      throw new ParticipantIdentityConfigurationError(
        "Participant block safety identity changed during reconciliation"
      );
    }
  }
  return [...fenced.values()];
}

export async function transformParticipantBlocksForDeletion(
  participantId: string | mongoose.Types.ObjectId,
  expectedAuthorityVersion: number,
  session: ClientSession
): Promise<void> {
  const id = new mongoose.Types.ObjectId(String(participantId));
  const { entries } = await loadParticipantIdentityManifest(
    "block-safety",
    session
  );
  await requireKnownBlockSafetyRows(
    session,
    entries.map((entry) => entry.version)
  );
  const incoming = (await ParticipantBlock.find({
    blockedParticipantId: id,
    blockerParticipantId: { $ne: id },
  })
    .select("+blockerParticipantId")
    .session(session)
    .lean<Array<{ blockerParticipantId: mongoose.Types.ObjectId }>>()
    .exec()) as Array<{ blockerParticipantId: mongoose.Types.ObjectId }>;
  await touchParticipantAccountsInSession(
    [id, ...incoming.map((row) => row.blockerParticipantId)],
    session,
    new Map([[String(id), expectedAuthorityVersion]])
  );
  await ParticipantBlock.deleteMany({ blockerParticipantId: id }, { session }).exec();
  await ParticipantBlock.updateMany(
    {
      blockedParticipantId: id,
      blockerParticipantId: { $ne: id },
    },
    { $unset: { blockedParticipantId: "" } },
    { session, timestamps: false }
  ).exec();
}
