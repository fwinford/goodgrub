import mongoose, { type ClientSession } from "mongoose";
import {
  ParticipantDeletionOperation,
  RequestOperation,
  RequestParticipation,
  RequestUpdateOperation,
} from "../models/db.js";
import { loadParticipantIdentityManifest } from "./participantIdentityKeys.js";
import { ParticipantIdentityConfigurationError } from "./participantIdentityKeys.js";

export async function unlinkParticipantFromRequestParticipation(
  participantId: string | mongoose.Types.ObjectId,
  session: ClientSession
): Promise<number> {
  const ownerId = new mongoose.Types.ObjectId(String(participantId));
  const { entries } = await loadParticipantIdentityManifest(
    "participation",
    session
  );
  const versions = entries.map((entry) => entry.version);
  const invalid = await RequestParticipation.exists({
    participantId: ownerId,
    $or: [
      { participationKeyVersion: { $exists: false } },
      { participationKeyVersion: { $nin: versions } },
      { participationHmac: { $not: /^[0-9a-f]{64}$/ } },
    ],
  }).session(session);
  if (invalid) {
    throw new ParticipantIdentityConfigurationError(
      "Request participation identity data is unavailable"
    );
  }
  const ownedCount = await RequestParticipation.countDocuments({
    participantId: ownerId,
  }).session(session);
  const result = await RequestParticipation.updateMany(
    {
      participantId: ownerId,
      participationKeyVersion: { $in: versions },
      participationHmac: { $type: "string" },
    },
    { $unset: { participantId: "" } },
    { session, timestamps: false }
  ).exec();
  if (result.modifiedCount !== ownedCount) {
    throw new ParticipantIdentityConfigurationError(
      "Request participation identity changed during unlinking"
    );
  }
  return result.modifiedCount;
}

export async function tombstoneParticipantOperationLedgers(
  participantId: string | mongoose.Types.ObjectId,
  session: ClientSession
): Promise<{ requestOperations: number; updateOperations: number }> {
  const ownerId = new mongoose.Types.ObjectId(String(participantId));
  const requestOperations = await RequestOperation.collection.updateMany(
    { participantId: ownerId, ownerDeleted: { $ne: true } },
    [
      {
        $set: {
          ownerDeleted: true,
          outcome: { $ifNull: ["$outcome", "created"] },
        },
      },
      { $unset: ["participantId", "requestId"] },
    ],
    { session }
  );
  const updateOperations = await RequestUpdateOperation.collection.updateMany(
    { participantId: ownerId, ownerDeleted: { $ne: true } },
    [
      { $set: { ownerDeleted: true } },
      {
        $unset: [
          "participantId",
          "requestId",
          "kind",
          "resultingRevision",
          "payloadDigest",
        ],
      },
    ],
    { session }
  );
  return {
    requestOperations: requestOperations.modifiedCount,
    updateOperations: updateOperations.modifiedCount,
  };
}

export async function tombstoneCanceledParticipantDeletionOperations(
  participantId: string | mongoose.Types.ObjectId,
  session: ClientSession
): Promise<number> {
  const ownerId = new mongoose.Types.ObjectId(String(participantId));
  const result = await ParticipantDeletionOperation.collection.updateMany(
    { participantId: ownerId, phase: "canceled" },
    [
      {
        $unset: [
          "participantId",
          "emailBinding",
          "authorityVersion",
          "phase",
          "readinessGeneration",
          "challengeGeneration",
          "readyAt",
          "challengeDigest",
          "challengeIssuedAt",
          "challengeCooldownEndsAt",
          "challengeExpiresAt",
          "challengeAttemptsRemaining",
          "authorizedAt",
          "authorizationExpiresAt",
          "canceledAt",
          "completedAt",
          "recoveryExpiresAt",
          "recoveryCapabilityDigest",
          "namespaceBinding",
          "createdAt",
          "updatedAt",
        ],
      },
    ],
    { session }
  );
  return result.modifiedCount;
}
