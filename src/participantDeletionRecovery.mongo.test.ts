import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { ParticipantDeletionOperation } from "../models/db.js";
import {
  deletionRecoveryCapabilityDigest,
  generateDeletionRecoveryCapability,
  readCompletedDeletionRecovery,
  scrubExpiredDeletionRecoveryReceipts,
} from "./participantDeletionRecovery.js";
import { establishRequestOperationLedger } from "./requestOperationAuthority.js";
import { deletionNamespaceBinding } from "./participantDeletionNamespace.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_participant_deletion_recovery`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;
let namespaceBinding: string;

describeMongo("W4-P2 real Mongo completion recovery", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
    namespaceBinding = deletionNamespaceBinding(await establishRequestOperationLedger());
  });

  afterEach(async () => {
    await ParticipantDeletionOperation.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("allows duplicate in-window reads to return only the completed outcome", async () => {
    const operationId = "recovery-duplicate-read";
    const capability = generateDeletionRecoveryCapability();
    const digest = deletionRecoveryCapabilityDigest(capability);
    await ParticipantDeletionOperation.collection.insertOne({
      operationId,
      namespaceBinding,
      phase: "completed",
      completedAt: new Date(),
      recoveryExpiresAt: new Date(Date.now() + 60_000),
      recoveryCapabilityDigest: digest,
    });

    const results = await Promise.all([
      readCompletedDeletionRecovery(operationId, capability, namespaceBinding),
      readCompletedDeletionRecovery(operationId, capability, namespaceBinding),
    ]);

    expect(results).toEqual([{ outcome: "completed" }, { outcome: "completed" }]);
    const stored = await ParticipantDeletionOperation.collection.findOne({
      operationId,
    });
    expect(stored).not.toHaveProperty("recoveryCapability");
    expect(stored).toHaveProperty("recoveryCapabilityDigest", digest);
  });

  it("races expired reads and scrubbing without fabricating completion or freeing the operation ID", async () => {
    const operationId = "recovery-expiry-race";
    const capability = generateDeletionRecoveryCapability();
    await ParticipantDeletionOperation.collection.insertOne({
      operationId,
      phase: "completed",
      namespaceBinding,
      completedAt: new Date(Date.now() - 8 * 24 * 60 * 60 * 1000),
      recoveryExpiresAt: new Date(Date.now() - 1_000),
      recoveryCapabilityDigest: deletionRecoveryCapabilityDigest(capability),
    });

    const [firstRead, secondRead, scrubCount] = await Promise.all([
      readCompletedDeletionRecovery(operationId, capability, namespaceBinding),
      readCompletedDeletionRecovery(operationId, capability, namespaceBinding),
      scrubExpiredDeletionRecoveryReceipts(),
    ]);

    expect(firstRead).toEqual({ outcome: "unavailable" });
    expect(secondRead).toEqual({ outcome: "unavailable" });
    expect(scrubCount).toBeGreaterThanOrEqual(0);
    const tombstone = await ParticipantDeletionOperation.collection.findOne({
      operationId,
    });
    expect(tombstone).toEqual(
      expect.objectContaining({ operationId })
    );
    expect(tombstone).not.toHaveProperty("phase");
    expect(tombstone).not.toHaveProperty("completedAt");
    expect(tombstone).not.toHaveProperty("recoveryExpiresAt");
    expect(tombstone).not.toHaveProperty("recoveryCapabilityDigest");
    expect(tombstone).not.toHaveProperty("namespaceBinding");
    expect(await ParticipantDeletionOperation.collection.countDocuments({ operationId })).toBe(1);
  });

  it("never scrubs or clears a non-completed deletion freeze", async () => {
    const operationId = "recovery-unresolved-freeze";
    const capability = generateDeletionRecoveryCapability();
    await ParticipantDeletionOperation.collection.insertOne({
      operationId,
      phase: "authorized",
      participantId: new mongoose.Types.ObjectId(),
      emailBinding: "opaque-binding",
      authorityVersion: 1,
      recoveryExpiresAt: new Date(Date.now() - 1_000),
      recoveryCapabilityDigest: deletionRecoveryCapabilityDigest(capability),
    });

    await Promise.all([
      readCompletedDeletionRecovery(operationId, capability, namespaceBinding),
      scrubExpiredDeletionRecoveryReceipts(),
    ]);

    const frozen = await ParticipantDeletionOperation.collection.findOne({
      operationId,
    });
    expect(frozen).toMatchObject({
      operationId,
      phase: "authorized",
      emailBinding: "opaque-binding",
      authorityVersion: 1,
    });
  });
});
