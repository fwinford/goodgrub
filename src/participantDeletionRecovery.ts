import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import mongoose from "mongoose";
import { ParticipantDeletionOperation } from "../models/db.js";
import {
  DeletionNamespaceUnavailable,
  isDeletionNamespaceBinding,
  readDeletionNamespace,
} from "./participantDeletionNamespace.js";

export const DELETION_RECOVERY_MAX_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;
const RECOVERY_CAPABILITY_DOMAIN = "commonplate:participant-deletion-recovery:v1";
const CAPABILITY_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export type DeletionRecoveryResult =
  | { outcome: "completed" }
  | { outcome: "unavailable" };

export function generateDeletionRecoveryCapability(): string {
  return randomBytes(32).toString("base64url");
}

function validCapability(value: unknown): value is string {
  if (typeof value !== "string" || !CAPABILITY_PATTERN.test(value)) return false;
  const bytes = Buffer.from(value, "base64url");
  return bytes.byteLength === 32 && bytes.toString("base64url") === value;
}

export function deletionRecoveryCapabilityDigest(capability: unknown): string {
  if (!validCapability(capability)) {
    throw new Error("deletion recovery capability is invalid");
  }
  return createHash("sha256")
    .update(RECOVERY_CAPABILITY_DOMAIN, "utf8")
    .update(Buffer.from([0]))
    .update(capability, "utf8")
    .digest("hex");
}

function digestsMatch(expectedHex: unknown, submittedHex: string): boolean {
  if (
    typeof expectedHex !== "string" ||
    !/^[0-9a-f]{64}$/.test(expectedHex) ||
    !/^[0-9a-f]{64}$/.test(submittedHex)
  ) {
    return false;
  }
  return timingSafeEqual(Buffer.from(expectedHex, "hex"), Buffer.from(submittedHex, "hex"));
}

/**
 * Constant-time proof that a presented capability is the one bound to an
 * operation's stored digest. Used by final completion (which requires the
 * exact capability minted at authorization, not only an unexpired
 * authorization) and by completion recovery. A malformed capability or a
 * missing/invalid expected digest answers `false`, never an exception.
 */
export function verifyDeletionRecoveryCapability(
  capability: unknown,
  expectedDigestHex: unknown
): boolean {
  if (!validCapability(capability)) return false;
  return digestsMatch(expectedDigestHex, deletionRecoveryCapabilityDigest(capability));
}

export function participantDeletionCompletionReceiptPipeline(): Array<
  Record<string, unknown>
> {
  return [
    {
      $set: {
        phase: "completed",
        completedAt: "$$NOW",
        recoveryExpiresAt: {
          $add: ["$$NOW", DELETION_RECOVERY_MAX_LIFETIME_MS],
        },
      },
    },
    {
      $unset: [
        "participantId",
        "emailBinding",
        "authorityVersion",
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
        "createdAt",
        "updatedAt",
      ],
    },
  ];
}

async function scrubExpiredReceipt(operationId: string): Promise<void> {
  await ParticipantDeletionOperation.collection.updateOne(
    {
      operationId,
      phase: "completed",
      $expr: { $lte: ["$recoveryExpiresAt", "$$NOW"] },
    },
    [
      {
        $unset: [
          "phase",
          "completedAt",
          "recoveryExpiresAt",
          "recoveryCapabilityDigest",
          "namespaceBinding",
        ],
      },
    ],
  );
}

export async function readCompletedDeletionRecovery(
  operationId: string,
  capability: unknown,
  namespaceBinding: unknown,
  testHooks: { afterNamespaceRead?: () => Promise<void> } = {}
): Promise<DeletionRecoveryResult> {
  if (!validCapability(capability) || !isDeletionNamespaceBinding(namespaceBinding)) {
    return { outcome: "unavailable" };
  }
  const candidateDigest = deletionRecoveryCapabilityDigest(capability);
  const session = await mongoose.startSession();
  let completed = false;
  try {
    await session.withTransaction(async () => {
      completed = false;
      const current = await readDeletionNamespace(session);
      if (current.binding !== namespaceBinding) return;
      await testHooks.afterNamespaceRead?.();
      const row = await ParticipantDeletionOperation.findOne({
        operationId,
        namespaceBinding,
        phase: "completed",
        $expr: { $gt: ["$recoveryExpiresAt", "$$NOW"] },
      })
        .select("+recoveryCapabilityDigest +namespaceBinding")
        .session(session)
        .lean<{ recoveryCapabilityDigest?: string; namespaceBinding?: unknown } | null>()
        .exec();
      completed = !!row &&
        isDeletionNamespaceBinding(row.namespaceBinding) &&
        row.namespaceBinding === namespaceBinding &&
        digestsMatch(row.recoveryCapabilityDigest, candidateDigest);
    }, { readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
  } catch (error) {
    if (!(error instanceof DeletionNamespaceUnavailable)) throw error;
  } finally {
    await session.endSession();
  }
  if (!completed) {
    await scrubExpiredReceipt(operationId);
    return { outcome: "unavailable" };
  }
  return { outcome: "completed" };
}

export async function scrubExpiredDeletionRecoveryReceipts(): Promise<number> {
  const result = await ParticipantDeletionOperation.collection.updateMany(
    {
      phase: "completed",
      $expr: { $lte: ["$recoveryExpiresAt", "$$NOW"] },
    },
    [
      {
        $unset: [
          "phase",
          "completedAt",
          "recoveryExpiresAt",
          "recoveryCapabilityDigest",
          "namespaceBinding",
        ],
      },
    ],
  );
  return result.modifiedCount;
}
