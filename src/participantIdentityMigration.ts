import type { Collection } from "mongoose";

const LEGACY_IDENTITY_INDEXES = [
  {
    collection: "requestparticipations",
    name: "request_participation_identity_unique",
  },
  {
    collection: "participantblocks",
    name: "participant_block_owner_target_unique",
  },
  {
    collection: "participantblocks",
    name: "participant_block_blocked_lookup",
    replacement: {
      key: { blockedParticipantId: 1 },
      partialFilterExpression: {
        blockedParticipantId: { $type: "objectId" },
      },
    },
  },
] as const;

export async function assertParticipantIdentityIndexesMigrated(
  collections: ReadonlyMap<string, Collection>
): Promise<void> {
  for (const legacyIndex of LEGACY_IDENTITY_INDEXES) {
    const collection = collections.get(legacyIndex.collection);
    if (!collection) continue;
    let indexes;
    try {
      indexes = await collection.listIndexes().toArray();
    } catch (error) {
      const code = typeof error === "object" && error !== null && "code" in error
        ? (error as { code?: unknown }).code
        : undefined;
      if (code === 26) continue;
      throw error;
    }
    const obsoleteIndexExists = indexes.some((index) => {
      if (index.name !== legacyIndex.name) return false;
      if (!("replacement" in legacyIndex)) return true;
      return (
        JSON.stringify(index.key) !== JSON.stringify(legacyIndex.replacement.key) ||
        JSON.stringify(index.partialFilterExpression) !==
          JSON.stringify(legacyIndex.replacement.partialFilterExpression)
      );
    });
    if (obsoleteIndexExists) {
      throw new Error(
        "Participant identity migration is required before this instance can accept traffic"
      );
    }
  }
}
