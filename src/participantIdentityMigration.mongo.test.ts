import { execFileSync } from "node:child_process";
import path from "node:path";
import mongoose from "mongoose";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  Participant,
  ParticipantBlock,
  ParticipantIdentityKeyVersion,
  RequestOperation,
  RequestParticipation,
  RequestUpdateOperation,
  REQUEST_UPDATE_EDIT,
} from "../models/db.js";
import { tombstoneParticipantOperationLedgers } from "./participantDeletionLedgers.js";
import {
  blockSafetyIdentityFields,
  participationIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_participant_identity_migration`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

describeMongo("W4-P2 real Mongo identity migration", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!, { autoIndex: false });
    await prepareParticipantIdentityMongoTestState();
    await ParticipantIdentityKeyVersion.createIndexes();
  });

  afterAll(async () => {
    await mongoose.connection.dropDatabase();
    await mongoose.disconnect();
  });

  it("replaces legacy indexes restart-safely, preserves event timestamps, and accepts Mongoose ledger documents", async () => {
    const blockerId = new mongoose.Types.ObjectId();
    const targetId = new mongoose.Types.ObjectId();
    const blocker = await Participant.create({
      _id: blockerId,
      email: "migration-blocker@nyu.edu",
      verifiedAt: new Date(),
      authorityVersion: 1,
      accountFenceEpoch: 0,
    });
    const target = await Participant.create({
      _id: targetId,
      email: "migration-target@nyu.edu",
      verifiedAt: new Date(),
      authorityVersion: 1,
      accountFenceEpoch: 0,
    });
    const requestId = new mongoose.Types.ObjectId();
    const eventTime = new Date("2024-02-03T04:05:06.000Z");

    await RequestParticipation.collection.createIndex(
      { requestId: 1, participantId: 1 },
      { name: "request_participation_identity_unique", unique: true }
    );
    await ParticipantBlock.collection.createIndex(
      { blockerParticipantId: 1, blockedParticipantId: 1 },
      { name: "participant_block_owner_target_unique", unique: true }
    );
    await ParticipantBlock.collection.createIndex(
      { blockedParticipantId: 1 },
      { name: "participant_block_blocked_lookup" }
    );
    await RequestParticipation.collection.insertOne({
      requestId,
      participantId: blockerId,
      createdAt: eventTime,
      updatedAt: eventTime,
    });
    await ParticipantBlock.collection.insertOne({
      blockerParticipantId: blockerId,
      blockedParticipantId: targetId,
      blockedRole: "requester",
      diningLocation: "North Dining",
      interactionAt: eventTime,
      createdAt: eventTime,
      updatedAt: eventTime,
    });

    const runMigration = () =>
      execFileSync(
        path.resolve("node_modules/.bin/tsx"),
        ["scripts/migrate-participant-identity.ts"],
        {
          cwd: process.cwd(),
          encoding: "utf8",
          timeout: 60_000,
          env: {
            ...process.env,
            MONGO_URI: mongoUri!,
            P2_IDENTITY_MIGRATION_DRAIN_CONFIRMED: "true",
          },
        }
      );

    runMigration();
    await RequestParticipation.collection.dropIndex(
      "request_participation_identity_live_unique"
    );
    await RequestParticipation.collection.createIndex(
      { participantId: 1, requestId: 1 },
      {
        name: "request_participation_identity_live_unique_migration",
        unique: true,
        partialFilterExpression: { participantId: { $type: "objectId" } },
      }
    );
    runMigration();

    const participation = await RequestParticipation.collection.findOne({
      requestId,
    });
    const block = await ParticipantBlock.collection.findOne({
      blockerParticipantId: blockerId,
      blockedParticipantId: targetId,
    });
    expect(participation).toMatchObject({
      ...participationIdentityFields(String(requestId), blocker.email),
      createdAt: eventTime,
      updatedAt: eventTime,
    });
    expect(block).toMatchObject({
      ...blockSafetyIdentityFields(target.email),
      createdAt: eventTime,
      updatedAt: eventTime,
    });

    const participationIndexes = await RequestParticipation.collection
      .listIndexes()
      .toArray();
    const blockIndexes = await ParticipantBlock.collection.listIndexes().toArray();
    expect(participationIndexes.map((index) => index.name)).toContain(
      "request_participation_identity_live_unique"
    );
    expect(participationIndexes.map((index) => index.name)).not.toContain(
      "request_participation_identity_unique"
    );
    expect(participationIndexes.map((index) => index.name)).not.toContain(
      "request_participation_identity_live_unique_migration"
    );
    expect(blockIndexes.map((index) => index.name)).toContain(
      "participant_block_owner_target_live_unique"
    );
    expect(blockIndexes.map((index) => index.name)).not.toContain(
      "participant_block_owner_target_unique"
    );
    expect(blockIndexes.map((index) => index.name)).not.toContain(
      "participant_block_owner_target_live_unique_migration"
    );

    await RequestOperation.create({
      operationId: "validator-live-request-operation",
      participantId: blockerId,
      requestId,
      outcome: "created",
    });
    await RequestUpdateOperation.create({
      operationId: "validator-live-update-operation",
      participantId: blockerId,
      requestId,
      kind: REQUEST_UPDATE_EDIT,
      resultingRevision: 2,
      payloadDigest: "a".repeat(64),
    });

    const session = await mongoose.startSession();
    try {
      await session.withTransaction(async () => {
        await tombstoneParticipantOperationLedgers(blockerId, session);
      });
    } finally {
      await session.endSession();
    }

    const tombstone = await RequestOperation.collection.findOne({
      operationId: "validator-live-request-operation",
    });
    const updateTombstone = await RequestUpdateOperation.collection.findOne({
      operationId: "validator-live-update-operation",
    });
    expect(tombstone).toMatchObject({ ownerDeleted: true, outcome: "created" });
    expect(tombstone).toHaveProperty("__v", 0);
    expect(tombstone).not.toHaveProperty("participantId");
    expect(tombstone).not.toHaveProperty("requestId");
    expect(updateTombstone).toMatchObject({ ownerDeleted: true });
    expect(updateTombstone).toHaveProperty("__v", 0);
    expect(updateTombstone).not.toHaveProperty("participantId");
    expect(updateTombstone).not.toHaveProperty("requestId");
  });
});
