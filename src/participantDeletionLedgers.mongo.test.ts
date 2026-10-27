import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  Participant,
  ParticipantBlock,
  RequestOperation,
  RequestParticipation,
  RequestUpdateOperation,
  REQUEST_UPDATE_EDIT,
} from "../models/db.js";
import {
  tombstoneParticipantOperationLedgers,
  unlinkParticipantFromRequestParticipation,
} from "./participantDeletionLedgers.js";
import {
  blockSafetyIdentityFields,
  participationIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";
import { transformParticipantBlocksForDeletion } from "./participantBlockSafety.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_participant_deletion_ledgers`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

describeMongo("W4-P2 real Mongo permanent operation tombstones", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await RequestOperation.syncIndexes();
    await RequestUpdateOperation.syncIndexes();
    await RequestParticipation.syncIndexes();
    await ParticipantBlock.syncIndexes();
  });

  afterEach(async () => {
    await Participant.deleteMany({});
    await RequestOperation.deleteMany({});
    await RequestUpdateOperation.deleteMany({});
    await RequestParticipation.deleteMany({});
    await ParticipantBlock.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("unlinks owner-deleted ledgers transactionally without freeing either identity", async () => {
    const participantId = new mongoose.Types.ObjectId();
    const requestId = new mongoose.Types.ObjectId();
    await Participant.create({
      _id: participantId,
      email: "tombstone-owner@nyu.edu",
      verifiedAt: new Date(),
      authorityVersion: 1,
      accountFenceEpoch: 0,
    });
    await RequestOperation.create({
      operationId: "permanent-request-operation",
      participantId,
      requestId,
      outcome: "created",
    });
    await RequestUpdateOperation.create({
      operationId: "permanent-update-operation",
      participantId,
      requestId,
      kind: REQUEST_UPDATE_EDIT,
      resultingRevision: 2,
      payloadDigest: "a".repeat(64),
    });

    const session = await mongoose.startSession();
    try {
      await session.withTransaction(async () => {
        await tombstoneParticipantOperationLedgers(participantId, session);
      });
    } finally {
      await session.endSession();
    }

    const requestOperation = await RequestOperation.findOne({
      operationId: "permanent-request-operation",
    })
      .select("+participantId +requestId +ownerDeleted")
      .lean<Record<string, unknown>>()
      .exec();
    expect(requestOperation).toMatchObject({
      operationId: "permanent-request-operation",
      ownerDeleted: true,
      outcome: "created",
    });
    expect(requestOperation).not.toHaveProperty("participantId");
    expect(requestOperation).not.toHaveProperty("requestId");

    const updateOperation = await RequestUpdateOperation.findOne({
      operationId: "permanent-update-operation",
    })
      .select(
        "+participantId +requestId +kind +resultingRevision +payloadDigest +ownerDeleted"
      )
      .lean<Record<string, unknown>>()
      .exec();
    expect(updateOperation).toMatchObject({
      operationId: "permanent-update-operation",
      ownerDeleted: true,
    });
    for (const field of [
      "participantId",
      "requestId",
      "kind",
      "resultingRevision",
      "payloadDigest",
    ]) {
      expect(updateOperation).not.toHaveProperty(field);
    }

    await expect(
      RequestOperation.create({
        operationId: "permanent-request-operation",
        ownerDeleted: true,
        outcome: "created",
      })
    ).rejects.toMatchObject({ code: 11000 });
    await expect(
      RequestUpdateOperation.create({
        operationId: "permanent-update-operation",
        ownerDeleted: true,
      })
    ).rejects.toMatchObject({ code: 11000 });
  });

  it("unlinks participation ownership without changing the permanent event timestamps", async () => {
    const participantId = new mongoose.Types.ObjectId();
    const requestId = new mongoose.Types.ObjectId();
    const eventTime = new Date("2024-02-03T04:05:06.000Z");
    await RequestParticipation.create({
      requestId,
      participantId,
      ...participationIdentityFields(String(requestId), "unlink-owner@nyu.edu"),
      createdAt: eventTime,
      updatedAt: eventTime,
    });

    const session = await mongoose.startSession();
    try {
      await session.withTransaction(async () => {
        await unlinkParticipantFromRequestParticipation(participantId, session);
      });
    } finally {
      await session.endSession();
    }

    const unlinked = await RequestParticipation.collection.findOne({ requestId });
    expect(unlinked).toMatchObject({
      ...participationIdentityFields(String(requestId), "unlink-owner@nyu.edu"),
      createdAt: eventTime,
      updatedAt: eventTime,
    });
    expect(unlinked).not.toHaveProperty("participantId");
  });

  it("removes the deleted target link without changing a retained block event timestamp", async () => {
    const blockerId = new mongoose.Types.ObjectId();
    const targetId = new mongoose.Types.ObjectId();
    const blocker = await Participant.create({
      _id: blockerId,
      email: "retained-block-owner@nyu.edu",
      verifiedAt: new Date(),
      authorityVersion: 1,
      accountFenceEpoch: 0,
    });
    const target = await Participant.create({
      _id: targetId,
      email: "retained-block-target@nyu.edu",
      verifiedAt: new Date(),
      authorityVersion: 1,
      accountFenceEpoch: 0,
    });
    const blockId = new mongoose.Types.ObjectId();
    const eventTime = new Date("2024-02-03T04:05:06.000Z");
    const block = await ParticipantBlock.create({
      _id: blockId,
      blockerParticipantId: blockerId,
      blockedParticipantId: targetId,
      ...blockSafetyIdentityFields(target.email),
      blockedRole: "requester",
      diningLocation: "North Dining",
      interactionAt: eventTime,
      createdAt: eventTime,
      updatedAt: eventTime,
    });

    const session = await mongoose.startSession();
    try {
      await session.withTransaction(async () => {
        await transformParticipantBlocksForDeletion(
          targetId,
          target.authorityVersion,
          session
        );
      });
    } finally {
      await session.endSession();
    }

    const retained = await ParticipantBlock.collection.findOne({
      _id: blockId,
    });
    expect(retained).toMatchObject({
      blockerParticipantId: blockerId,
      ...blockSafetyIdentityFields(target.email),
      createdAt: eventTime,
      updatedAt: eventTime,
    });
    expect(retained).not.toHaveProperty("blockedParticipantId");
  });
});
