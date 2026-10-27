import {
  ParticipantIdentityKeyVersion,
} from "../models/db.js";
import {
  BLOCK_SAFETY_HMAC_KEYRING_ENV,
  PARTICIPATION_HMAC_KEYRING_ENV,
  deriveParticipantIdentityAlias,
} from "./participantIdentityKeys.js";

const participationKey = Buffer.alloc(32, 0x31);
const blockSafetyKey = Buffer.alloc(32, 0x52);

export async function prepareParticipantIdentityMongoTestState(): Promise<void> {
  process.env[PARTICIPATION_HMAC_KEYRING_ENV] = JSON.stringify({
    currentVersion: 1,
    keys: { "1": participationKey.toString("base64") },
  });
  process.env[BLOCK_SAFETY_HMAC_KEYRING_ENV] = JSON.stringify({
    currentVersion: 1,
    keys: { "1": blockSafetyKey.toString("base64") },
  });
  await Promise.all(
    (["participation", "block-safety"] as const).map((purpose) =>
      ParticipantIdentityKeyVersion.updateOne(
        { purpose, version: 1 },
        { $setOnInsert: { normalizationVersion: 1 } },
        { upsert: true }
      ).exec()
    )
  );
}

export function participationIdentityFields(
  requestId: string,
  principal: string
): { participationKeyVersion: number; participationHmac: string } {
  const alias = deriveParticipantIdentityAlias(
    "participation",
    1,
    participationKey,
    requestId,
    principal
  );
  return {
    participationKeyVersion: alias.version,
    participationHmac: alias.digest,
  };
}

export function blockSafetyIdentityFields(
  principal: string
): { blockedSafetyKeyVersion: number; blockedSafetyHmac: string } {
  const alias = deriveParticipantIdentityAlias(
    "block-safety",
    1,
    blockSafetyKey,
    null,
    principal
  );
  return {
    blockedSafetyKeyVersion: alias.version,
    blockedSafetyHmac: alias.digest,
  };
}
