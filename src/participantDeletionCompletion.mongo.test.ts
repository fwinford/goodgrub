import type { Request, Response } from "express";
import { randomUUID } from "node:crypto";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Installation,
  Participant,
  ParticipantBlock,
  ParticipantDeletionOperation,
  ParticipantVerification,
  Fulfillment,
  PlacementEvidence,
  Request as MealRequest,
  RequestOperation,
  RequestParticipation,
  SendLog,
  Subscriber,
  RequestUpdateOperation,
  RequestOperationAuthority,
} from "../models/db.js";
const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import { SafetyIdentity } from "../models/moderation.js";
import {
  createOrResolveParticipantDeletionOperation,
  issueParticipantDeletionChallenge,
  readParticipantDeletionStatus,
  redeemParticipantDeletionChallenge,
  type DeletionOwner,
  type ParticipantDeletionDependencies,
} from "./participantDeletionOperations.js";
import { completeParticipantDeletionOperation } from "./participantDeletionCompletion.js";
import { readCompletedDeletionRecovery } from "./participantDeletionRecovery.js";
import { establishRequestOperationLedger } from "./requestOperationAuthority.js";
import {
  DeletionNamespaceUnavailable,
  deletionNamespaceBinding,
} from "./participantDeletionNamespace.js";
import { ensureSafetyIdentity, runModerationTransaction } from "./safetyIdentity.js";
import { SAFETY_IDENTITY_KEYRING_ENV, readSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";
import { claimRequest } from "./claimRoute.js";
import { fulfillRequest } from "./fulfillmentRoute.js";
import { confirmPlacedOrderPickup } from "./placedOrderRoutes.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import { PARTICIPANT_SIGNING_SECRET_ENV, signParticipantAuthority } from "./participantCredentials.js";
import {
  createParticipantEmailUnsubscribeHandler,
} from "./participantEmailUnsubscribeRoute.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_p2_completion`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const deletionSecret = Buffer.from("e".repeat(32));
const participantSigningSecretText = "p2-completion-test-participant-secret-32b";
let now = new Date("2026-10-23T12:00:00.000Z");

const safetyKey = Buffer.alloc(32, 0x77);
const safetyKeyring = readSafetyIdentityKeyring({
  [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
    current: "k1",
    keys: { k1: safetyKey.toString("base64url") },
  }),
});
const unusableSafetyKeyring = readSafetyIdentityKeyring({
  [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
    current: "kX",
    keys: { kX: Buffer.alloc(32, 0x99).toString("base64url") },
  }),
});

function dependencies(
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Partial<ParticipantDeletionDependencies> {
  return {
    now: () => now,
    readSecret: () => deletionSecret,
    generateCode: () => "424242",
    sendChallengeEmail: async () => {},
    ...overrides,
  };
}

async function makeParticipant(email: string, authorityVersion = 1) {
  const participantId = new mongoose.Types.ObjectId();
  await Participant.create({
    _id: participantId,
    email,
    verifiedAt: now,
    authorityVersion,
    accountFenceEpoch: 0,
  });
  return participantId;
}

function pickupContext(requestId: unknown, participantId: mongoose.Types.ObjectId) {
  const req = {
    params: { requestId: String(requestId) },
    headers: {
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
        participantId,
        1,
        Buffer.from(participantSigningSecretText)
      ),
    },
  } as unknown as Request;
  let status = 200;
  let payload: unknown;
  const res = {
    status(value: number) { status = value; return this; },
    json(value: unknown) { payload = value; return this; },
    setHeader() { return this; },
  } as unknown as Response;
  return { req, res, get status() { return status; }, get payload() { return payload; } };
}

/** Drives a fresh participant all the way to an `authorized` deletion operation. */
async function authorizedOperation(email: string, authorityVersion = 1) {
  const participantId = await makeParticipant(email, authorityVersion);
  const created = await createOrResolveParticipantDeletionOperation(
    { participantId, canonicalEmail: email, authorityVersion, initialPhase: "ready" },
    dependencies()
  );
  const owner: DeletionOwner = {
    operationId: created.status.operationId,
    namespaceBinding: created.status.namespaceBinding,
    participantId,
    canonicalEmail: email,
    authorityVersion,
  };
  const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
  if (issued.outcome !== "issued") throw new Error("test setup: challenge not issued");
  const redeemed = await redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies());
  if (redeemed.outcome !== "authorized") throw new Error("test setup: challenge not redeemed");
  return { owner, participantId, recoveryCapability: redeemed.recoveryCapability };
}

async function verificationRow(email: string) {
  await ParticipantVerification.create({
    email,
    codeDigest: "a".repeat(64),
    issuedAt: now,
    expiresAt: new Date(now.getTime() + 10 * 60 * 1000),
    attemptsRemaining: 5,
    deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
  });
}

function claimContext(requestId: unknown, participantId: mongoose.Types.ObjectId) {
  const req = {
    params: { id: String(requestId) },
    body: {},
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(participantId, 1, Buffer.from(participantSigningSecretText)) },
  } as unknown as Request;
  let status = 200;
  let payload: unknown;
  const res = {
    status(value: number) { status = value; return this; },
    json(value: unknown) { payload = value; return this; },
    setHeader() { return this; },
  } as unknown as Response;
  return { req, res, get status() { return status; }, get payload() { return payload; } };
}

describeMongo("W4-P2 Checkpoint 8 final deletion transaction (real Mongo)", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSigningSecretText);
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "p2-completion-claim-token-secret-32bytes");
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    // `completeParticipantDeletionOperation` reads the live
    // SAFETY_IDENTITY_KEYRING_ENV itself (through `tryReadSafetyIdentityKeyring`),
    // so the environment must carry the same material `safetyKeyring` was
    // built from above, not just the in-memory object.
    vi.stubEnv(
      SAFETY_IDENTITY_KEYRING_ENV,
      JSON.stringify({ current: "k1", keys: { k1: safetyKey.toString("base64url") } })
    );
    await mongoose.connect(mongoUri!);
    await establishRequestOperationLedger();
    await prepareParticipantIdentityMongoTestState();
    await Promise.all(
      [
        Participant,
        Installation,
        ParticipantDeletionOperation,
        ParticipantVerification,
        ParticipantBlock,
        MealRequest,
        Fulfillment,
        PlacementEvidence,
        RequestOperation,
        RequestParticipation,
        RequestUpdateOperation,
        Subscriber,
        SendLog,
        SafetyIdentity,
      ].map((model) => model.createIndexes())
    );
  });

  beforeEach(() => {
    now = new Date("2026-10-23T12:00:00.000Z");
    sendFulfillmentEmail.mockReset();
    sendFulfillmentEmail.mockResolvedValue(undefined);
  });

  afterEach(async () => {
    for (const model of [
      MealRequest,
      Installation,
      ParticipantDeletionOperation,
      Participant,
      ParticipantVerification,
      ParticipantBlock,
      RequestOperation,
      RequestParticipation,
      RequestUpdateOperation,
      SafetyIdentity,
      Fulfillment,
      PlacementEvidence,
      Subscriber,
      SendLog,
    ]) {
      await model.collection.deleteMany({});
    }
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("refuses final completion without the initiating namespace", async () => {
    const { owner, participantId, recoveryCapability } = await authorizedOperation("unbound-final@nyu.edu");
    const { namespaceBinding: _binding, ...unbound } = owner;
    expect(await completeParticipantDeletionOperation(unbound, 1, recoveryCapability, dependencies()))
      .toBe("notOwned");
    expect(await Participant.findById(participantId)).not.toBeNull();
  });

  it("rejects a namespace replacement between precheck and the irreversible transaction without partial writes", async () => {
    const { owner, participantId, recoveryCapability } = await authorizedOperation("namespace-final@nyu.edu");
    const authority = await RequestOperationAuthority.findById("request-operation-ledger").lean();
    try {
      await expect(completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies(), {
        afterPreCheck: async () => {
          await RequestOperationAuthority.updateOne(
            { _id: "request-operation-ledger" }, { $set: { authorityId: randomUUID() } }
          );
        },
      })).rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
      expect(await Participant.findById(participantId)).not.toBeNull();
      expect(await ParticipantDeletionOperation.collection.findOne({ operationId: owner.operationId }))
        .toMatchObject({ phase: "authorized", namespaceBinding: owner.namespaceBinding });
    } finally {
      await RequestOperationAuthority.updateOne(
        { _id: "request-operation-ledger" }, { $set: { authorityId: authority!.authorityId } }
      );
    }
  });

  it("refuses final completion when the submitted namespace differs from the stored operation", async () => {
    const { owner, participantId, recoveryCapability } = await authorizedOperation("copied-final@nyu.edu");
    const replacement = deletionNamespaceBinding(randomUUID());
    expect(await completeParticipantDeletionOperation(
      { ...owner, namespaceBinding: replacement }, 1, recoveryCapability, dependencies()
    )).toBe("notOwned");
    expect(await Participant.findById(participantId)).not.toBeNull();
  });

  it.each(["array", "multipleNamespaces", "object", "number", "null"])(
    "refuses a malformed stored operation namespace (%s) without deleting its owner",
    async (kind) => {
      const { owner, participantId, recoveryCapability } = await authorizedOperation(`malformed-${kind}@nyu.edu`);
      const malformed: unknown = kind === "array" ? [owner.namespaceBinding]
        : kind === "multipleNamespaces" ? [owner.namespaceBinding, deletionNamespaceBinding(randomUUID())]
        : kind === "object" ? { value: owner.namespaceBinding }
        : kind === "number" ? 123 : null;
      await ParticipantDeletionOperation.collection.updateOne(
        { operationId: owner.operationId },
        [{ $set: { namespaceBinding: { $literal: malformed } } }]
      );
      expect(await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies()))
        .toBe("notOwned");
      expect(await Participant.findById(participantId)).not.toBeNull();
      expect(await ParticipantDeletionOperation.collection.findOne({ operationId: owner.operationId }))
        .toHaveProperty("phase", "authorized");
    }
  );

  it("serializes a concurrent authority replacement with final deletion, then refuses old-namespace recovery", async () => {
    const { owner, participantId, recoveryCapability } = await authorizedOperation("concurrent-namespace@nyu.edu");
    const authority = await RequestOperationAuthority.findById("request-operation-ledger").lean();
    let replacementWrite: Promise<unknown> | undefined;
    try {
      expect(await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies(), {
        beforeInstallationUnlink: async () => {
          replacementWrite = RequestOperationAuthority.updateOne(
            { _id: "request-operation-ledger" }, { $set: { authorityId: randomUUID() } }
          ).exec();
        },
      })).toBe("completed");
      await replacementWrite;
      expect(await Participant.findById(participantId)).toBeNull();
      expect(await readCompletedDeletionRecovery(owner.operationId, recoveryCapability, owner.namespaceBinding))
        .toEqual({ outcome: "unavailable" });
    } finally {
      await replacementWrite;
      await RequestOperationAuthority.updateOne(
        { _id: "request-operation-ledger" }, { $set: { authorityId: authority!.authorityId } }
      );
    }
  });

  it("completes an all-clear deletion: deletes the Participant, invalidates the challenge, and leaves a minimal completed receipt", async () => {
    const email = "clear-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    await verificationRow(email);

    const outcome = await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());
    expect(outcome).toBe("completed");

    expect(await Participant.findById(participantId).exec()).toBeNull();
    expect(await ParticipantVerification.findOne({ email }).exec()).toBeNull();

    const op = await ParticipantDeletionOperation.findOne({ operationId: owner.operationId })
      .select("+participantId +emailBinding +authorityVersion +recoveryExpiresAt +recoveryCapabilityDigest +completedAt +challengeDigest +authorizedAt")
      .lean()
      .exec();
    expect(op).toMatchObject({ phase: "completed" });
    expect(op!.participantId).toBeUndefined();
    expect(op!.emailBinding).toBeUndefined();
    expect(op!.authorityVersion).toBeUndefined();
    expect(op!.challengeDigest).toBeUndefined();
    expect(op!.authorizedAt).toBeUndefined();
    expect(op!.completedAt).toBeInstanceOf(Date);
    expect(op!.recoveryExpiresAt!.getTime() - op!.completedAt!.getTime()).toBe(7 * 24 * 60 * 60 * 1000);
    expect(op!.recoveryCapabilityDigest).toMatch(/^[0-9a-f]{64}$/);
  });

  it("unlinks every Installation for the deleting Participant and preserves device state and other principals", async () => {
    const email = "installation-owner@nyu.edu";
    const otherEmail = "other-installation-owner@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email, 2);
    const otherParticipantId = await makeParticipant(otherEmail);

    const [first, second, other] = await Installation.create([
      {
        installationCredentialDigest: "a".repeat(64),
        pushEnabled: true,
        apnsToken: "aa",
        apnsEnvironment: "development",
        participantId,
        participantAuthorityVersion: 1,
      },
      {
        installationCredentialDigest: "b".repeat(64),
        pushEnabled: false,
        participantId,
        participantAuthorityVersion: 2,
      },
      {
        installationCredentialDigest: "c".repeat(64),
        pushEnabled: true,
        apnsToken: "bb",
        apnsEnvironment: "production",
        participantId: otherParticipantId,
        participantAuthorityVersion: 1,
      },
    ]);

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies()
    );
    expect(outcome).toBe("completed");

    for (const installation of [first, second]) {
      const after = await Installation.findById(installation._id)
        .select("+participantId +participantAuthorityVersion +apnsToken")
        .lean()
        .exec();
      expect(after?.participantId).toBeUndefined();
      expect(after?.participantAuthorityVersion).toBeUndefined();
    }
    const preservedFirst = await Installation.findById(first._id)
      .select("+apnsToken")
      .lean()
      .exec();
    expect(preservedFirst).toMatchObject({
      pushEnabled: true,
      apnsToken: "aa",
      apnsEnvironment: "development",
    });
    const preservedOther = await Installation.findById(other._id)
      .select("+participantId +participantAuthorityVersion +apnsToken")
      .lean()
      .exec();
    expect(preservedOther?.participantId?.toString()).toBe(otherParticipantId.toString());
    expect(preservedOther?.participantAuthorityVersion).toBe(1);
    expect(preservedOther?.pushEnabled).toBe(true);
    expect(preservedOther?.apnsToken).toBe("bb");
  });

  it("deletes requester-owned Request content and evidence immediately but retains Fulfillment", async () => {
    const email = "requester-delete@nyu.edu";
    const helperEmail = "helper-retained@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const helperId = await makeParticipant(helperEmail);
    const request = await MealRequest.create({
      vendor: "Campus Market",
      food: "Rice bowl",
      pickupWindowText: "ASAP",
      menuPath: "meal-exchange",
      mealSwipes: 1,
      mealItems: [{ name: "Rice bowl", details: "extra sauce" }],
      email,
      status: "placed",
      requesterParticipantId: participantId,
      helperParticipantId: helperId,
      fulfillerEmail: helperEmail,
      orderNumber: "001234",
      placedAt: now,
      requesterPickupConfirmedAt: now,
      expiresAt: new Date(now.getTime() + 60_000),
      deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
    });
    const fulfillment = await Fulfillment.create({
      requestId: request._id,
      orderNumber: "001234",
      etaText: "12:30 PM",
      note: `Legacy requester contact: ${email}`,
      placedAt: now,
    });
    const evidence = await PlacementEvidence.create({
      requestId: request._id,
      image: Buffer.from("private evidence"),
      mimeType: "image/png",
      byteLength: Buffer.byteLength("private evidence"),
      deleteAt: request.deleteAt,
    });

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies()
    );

    expect(outcome).toBe("completed");
    expect(await MealRequest.findById(request._id).exec()).toBeNull();
    expect(await PlacementEvidence.findById(evidence._id).exec()).toBeNull();
    const retainedFulfillment = await Fulfillment.findById(fulfillment._id).lean().exec();
    expect(retainedFulfillment).toMatchObject({
      requestId: request._id,
      orderNumber: "001234",
      etaText: "12:30 PM",
    });
    expect(retainedFulfillment?.note).toBeUndefined();
    expect(retainedFulfillment?.createdAt).toEqual(fulfillment.createdAt);
    expect(retainedFulfillment?.updatedAt).toEqual(fulfillment.updatedAt);
  });

  it("deletes the matching Subscriber and its SendLogs plus deleted-Request SendLogs, preserving unrelated rows and fresh same-email signup", async () => {
    const email = "subscriber-delete@nyu.edu";
    const otherEmail = "unrelated-subscriber@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const otherParticipantId = await makeParticipant("unrelated-requester@nyu.edu");
    const ownedRequest = await MealRequest.create({
      vendor: "Campus Market",
      food: "Rice bowl",
      pickupWindowText: "ASAP",
      menuPath: "meal-exchange",
      mealSwipes: 1,
      email,
      status: "placed",
      requesterParticipantId: participantId,
      orderNumber: "001237",
      placedAt: now,
      requesterPickupConfirmedAt: now,
      expiresAt: new Date(now.getTime() + 60_000),
      deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
    });
    const unrelatedRequest = await MealRequest.create({
      vendor: "Campus Market",
      food: "Soup",
      pickupWindowText: "ASAP",
      menuPath: "meal-exchange",
      mealSwipes: 1,
      email: otherEmail,
      status: "open",
      requesterParticipantId: otherParticipantId,
      expiresAt: new Date(now.getTime() + 60_000),
      deleteAt: new Date(now.getTime() + 60_000),
    });
    const [deletedSubscriber, unrelatedSubscriber] = await Subscriber.create([
      {
        email,
        status: "confirmed",
        dailyCount: 3,
        bounced: true,
        lastSentAt: now,
        unsubToken: "legacy-unsubscribe-capability",
      },
      {
        email: otherEmail,
        status: "confirmed",
      },
    ]);
    const [subscriberLog, deletedRequestLog, unrelatedLog] = await SendLog.create([
      {
        subscriberId: deletedSubscriber._id,
        requestId: unrelatedRequest._id,
        status: "fail",
        error: `recipient ${email} failed`,
      },
      {
        subscriberId: unrelatedSubscriber._id,
        requestId: ownedRequest._id,
        status: "fail",
        error: `requester ${email} failed`,
      },
      {
        subscriberId: unrelatedSubscriber._id,
        requestId: unrelatedRequest._id,
        status: "sent",
      },
    ]);

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies()
    );

    expect(outcome).toBe("completed");
    expect(await Subscriber.findById(deletedSubscriber._id).exec()).toBeNull();
    expect(await SendLog.findById(subscriberLog._id).exec()).toBeNull();
    expect(await SendLog.findById(deletedRequestLog._id).exec()).toBeNull();
    expect(await Subscriber.findById(unrelatedSubscriber._id).exec()).not.toBeNull();
    expect(await SendLog.findById(unrelatedLog._id).exec()).not.toBeNull();

    const recreated = await Subscriber.create({
      email,
      status: "pending",
      confirmationTokenDigest: "b".repeat(64),
      confirmationExpiresAt: new Date(now.getTime() + 10 * 60 * 1000),
    });
    expect(recreated._id.equals(deletedSubscriber._id)).toBe(false);
    expect(recreated).toMatchObject({
      status: "pending",
      dailyCount: 0,
      bounced: false,
      lastSentAt: null,
    });
    expect(await SendLog.countDocuments({ subscriberId: recreated._id })).toBe(0);
  });

  it("unlinks an expired helper binding but preserves another participant's Request", async () => {
    const email = "expired-helper-delete@nyu.edu";
    const requesterEmail = "requester-kept@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const requesterId = await makeParticipant(requesterEmail);
    const request = await MealRequest.create({
      vendor: "Campus Market",
      food: "Soup",
      pickupWindowText: "ASAP",
      menuPath: "meal-exchange",
      mealSwipes: 1,
      email: requesterEmail,
      status: "claimed",
      requesterParticipantId: requesterId,
      helperParticipantId: participantId,
      claimedAt: new Date(now.getTime() - 60_000),
      claimExpiresAt: new Date(now.getTime() - 1),
      claimTokenDigest: "f".repeat(64),
      expiresAt: new Date(now.getTime() + 60_000),
      deleteAt: new Date(now.getTime() + 60_000),
    });

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies()
    );

    expect(outcome).toBe("completed");
    const retained = await MealRequest.findById(request._id)
      .select("+requesterParticipantId +helperParticipantId")
      .lean()
      .exec();
    expect(retained).toMatchObject({
      status: "claimed",
      email: requesterEmail,
      requesterParticipantId: requesterId,
    });
    expect(retained?.helperParticipantId).toBeUndefined();
  });

  it("unlinks a placed helper only after R3 pickup confirmation, retaining the other requester's operational record", async () => {
    const email = "confirmed-helper-delete@nyu.edu";
    const requesterEmail = "confirmed-requester-kept@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const requesterId = await makeParticipant(requesterEmail);
    const request = await MealRequest.create({
      vendor: "Campus Market",
      food: "Soup",
      pickupWindowText: "ASAP",
      menuPath: "meal-exchange",
      mealSwipes: 1,
      email: requesterEmail,
      status: "placed",
      requesterParticipantId: requesterId,
      helperParticipantId: participantId,
      fulfillerEmail: email,
      orderNumber: "001235",
      placedAt: now,
      requesterPickupConfirmedAt: now,
      expiresAt: new Date(now.getTime() + 60_000),
      deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
    });
    const fulfillment = await Fulfillment.create({
      requestId: request._id,
      orderNumber: "001235",
      etaText: "12:30 PM",
      placedAt: now,
    });
    const evidence = await PlacementEvidence.create({
      requestId: request._id,
      image: Buffer.from("other request evidence"),
      mimeType: "image/png",
      byteLength: Buffer.byteLength("other request evidence"),
      deleteAt: request.deleteAt,
    });

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies()
    );

    expect(outcome).toBe("completed");
    const retained = await MealRequest.findById(request._id)
      .select("+requesterParticipantId +helperParticipantId +fulfillerEmail +requesterPickupConfirmedAt")
      .lean()
      .exec();
    expect(retained).toMatchObject({
      status: "placed",
      email: requesterEmail,
      requesterParticipantId: requesterId,
      requesterPickupConfirmedAt: now,
    });
    expect(retained?.helperParticipantId).toBeUndefined();
    expect(retained?.fulfillerEmail).toBeUndefined();
    expect(await Fulfillment.findById(fulfillment._id).lean().exec()).not.toBeNull();
    expect(await PlacementEvidence.findById(evidence._id).lean().exec()).not.toBeNull();
  });

  it("rechecks a pickup confirmed after layer 1, then deletes requester content and evidence while retaining Fulfillment", async () => {
    const email = "pickup-race-delete@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const helperId = await makeParticipant("pickup-race-helper@nyu.edu");
    let requestId: mongoose.Types.ObjectId | undefined;
    let confirmationStatus = 0;

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies(),
      {
        afterPreCheck: async () => {
          const placedRequestId = new mongoose.Types.ObjectId();
          const request = await MealRequest.create({
            _id: placedRequestId,
            vendor: "Campus Market",
            food: "Rice bowl",
            pickupWindowText: "ASAP",
            menuPath: "meal-exchange",
            mealSwipes: 1,
            email,
            status: "placed",
            requesterParticipantId: participantId,
            helperParticipantId: helperId,
            orderNumber: "001236",
            placedAt: now,
            expiresAt: new Date(now.getTime() + 60_000),
            deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
          });
          requestId = placedRequestId;
          await Fulfillment.create({
            requestId: placedRequestId,
            orderNumber: "001236",
            etaText: "12:30 PM",
            placedAt: now,
          });
          await PlacementEvidence.create({
            requestId: placedRequestId,
            image: Buffer.from("pickup race evidence"),
            mimeType: "image/png",
            byteLength: Buffer.byteLength("pickup race evidence"),
            deleteAt: request.deleteAt,
          });
          const pickup = pickupContext(requestId, participantId);
          await confirmPlacedOrderPickup(pickup.req, pickup.res);
          confirmationStatus = pickup.status;
        },
      }
    );

    expect(confirmationStatus).toBe(200);
    expect(outcome).toBe("completed");
    expect(await MealRequest.findById(requestId).exec()).toBeNull();
    expect(await PlacementEvidence.countDocuments({ requestId })).toBe(0);
    expect(await Fulfillment.countDocuments({ requestId })).toBe(1);
  });

  it("aborts deletion when a real fulfillment and evidence write commits after layer 1", async () => {
    const email = "fulfillment-race-helper@nyu.edu";
    const requesterEmail = "fulfillment-race-requester@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const requesterId = await makeParticipant(requesterEmail);
    const wallNow = Date.now();
    const request = await MealRequest.create({
      vendor: "Campus Market",
      food: "Rice bowl",
      pickupWindowText: "ASAP",
      menuPath: "meal-exchange",
      mealSwipes: 1,
      email: requesterEmail,
      status: "open",
      requesterParticipantId: requesterId,
      visibleFrom: new Date(wallNow - 1_000),
      expiresAt: new Date(wallNow + 3 * 60 * 60 * 1000),
      deleteAt: new Date(wallNow + 24 * 60 * 60 * 1000),
    });
    let fulfillmentStatus = 200;

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies(),
      {
        afterPreCheck: async () => {
          const claim = claimContext(request._id, participantId);
          await claimRequest(claim.req, claim.res);
          expect(claim.status).toBe(200);
          const fulfillment = {
            params: { id: String(request._id) },
            body: {
              claimToken: (claim.payload as { claim: { claimToken: string } }).claim.claimToken,
              fulfillment: {
                orderNumber: "001237",
                eta: "15 minutes",
                placedOrderScreenshot: {
                  mimeType: "image/png",
                  imageBase64:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
                },
              },
            },
          } as unknown as Request;
          const response = {
            status(value: number) { fulfillmentStatus = value; return this; },
            json() { return this; },
          } as unknown as Response;
          await fulfillRequest(fulfillment, response);
        },
      }
    );

    expect(fulfillmentStatus).toBe(200);
    expect(outcome).toBe("blocked");
    expect(await Participant.findById(participantId).exec()).not.toBeNull();
    expect((await MealRequest.findById(request._id).lean().exec())?.status).toBe("placed");
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
    expect(await PlacementEvidence.countDocuments({ requestId: request._id })).toBe(1);
  });

  it("serializes a newly established Installation association before deletion and unlinks it", async () => {
    const email = "install-race-delete@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const rawCredential = Buffer.alloc(32, 0x51).toString("base64url");
    const request = {
      body: {
        installationCredential: rawCredential,
        enabled: true,
        apnsToken: Buffer.alloc(32, 0x51).toString("hex"),
        environment: "development",
      },
      headers: {
        [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
          participantId,
          owner.authorityVersion,
          Buffer.from(participantSigningSecretText)
        ),
      },
    } as unknown as Request;
    const response = {
      status() { return this; },
      json() { return this; },
    } as unknown as Response;
    const associationRoute = (await import("./installationPushRoute.js"))
      .createInstallationPushHandler({ now: () => now });

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies(),
      {
        afterPreCheck: async () => {
          await associationRoute(request, response);
        },
      }
    );

    expect(outcome).toBe("completed");
    expect(await Installation.countDocuments({ participantId })).toBe(0);
    const installation = await Installation.findOne({
      installationCredentialDigest: (await import("./installationCredential.js"))
        .digestInstallationCredential(rawCredential),
    })
      .select("+participantId +participantAuthorityVersion")
      .lean()
      .exec();
    expect(installation?.participantId).toBeUndefined();
    expect(installation?.participantAuthorityVersion).toBeUndefined();
  });

  it("retries deletion safely when an Installation is rebound during the final transaction", async () => {
    const email = "installation-race-owner@nyu.edu";
    const otherEmail = "installation-race-other@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const otherParticipantId = await makeParticipant(otherEmail);
    const [rebound, untouched] = await Installation.create([
      {
        installationCredentialDigest: "d".repeat(64),
        pushEnabled: true,
        apnsToken: "cc",
        apnsEnvironment: "development",
        participantId,
        participantAuthorityVersion: 1,
      },
      {
        installationCredentialDigest: "e".repeat(64),
        pushEnabled: true,
        apnsToken: "dd",
        apnsEnvironment: "production",
        participantId: otherParticipantId,
        participantAuthorityVersion: 1,
      },
    ]);
    let reboundOutsideTransaction = false;

    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies(),
      {
        beforeInstallationUnlink: async () => {
          if (reboundOutsideTransaction) return;
          reboundOutsideTransaction = true;
          const result = await Installation.updateOne(
            { _id: rebound._id, participantId },
            {
              $set: {
                participantId: otherParticipantId,
                participantAuthorityVersion: 1,
              },
            }
          ).exec();
          expect(result.modifiedCount).toBe(1);
        },
      }
    );

    expect(outcome).toBe("completed");
    expect(reboundOutsideTransaction).toBe(true);
    const reboundAfter = await Installation.findById(rebound._id)
      .select("+participantId +participantAuthorityVersion")
      .lean()
      .exec();
    expect(reboundAfter?.participantId?.toString()).toBe(otherParticipantId.toString());
    expect(reboundAfter?.participantAuthorityVersion).toBe(1);
    const untouchedAfter = await Installation.findById(untouched._id)
      .select("+participantId +participantAuthorityVersion")
      .lean()
      .exec();
    expect(untouchedAfter?.participantId?.toString()).toBe(otherParticipantId.toString());
    expect(untouchedAfter?.participantAuthorityVersion).toBe(1);
    expect(await Participant.findById(participantId).exec()).toBeNull();
  });

  it.each(["enable", "replace"] as const)(
    "refuses a late %s after authority resolution when deletion wins the account fence",
    async (action) => {
      const { owner, participantId, recoveryCapability } =
        await authorizedOperation(`late-${action}@nyu.edu`);
      const rawCredential = Buffer.alloc(32, 0x64).toString("base64url");
      const digest = (await import("./installationCredential.js"))
        .digestInstallationCredential(rawCredential);
      await Installation.create({
        installationCredentialDigest: digest,
        pushEnabled: true,
        apnsToken: "ee",
        apnsEnvironment: "development",
        participantId,
        participantAuthorityVersion: 1,
        pushMutationVersion: 10,
      });
      const context = pickupContext(new mongoose.Types.ObjectId(), participantId);
      context.req.body = {
        installationCredential: rawCredential,
        mutationVersion: 11,
        ...(action === "enable"
          ? { enabled: true, apnsToken: "ee", environment: "development" }
          : { association: "replace" }),
      };
      const originalStart = mongoose.startSession.bind(mongoose);
      let resume!: () => void;
      let reached!: () => void;
      const paused = new Promise<void>((resolve) => { resume = resolve; });
      const resolvedAuthority = new Promise<void>((resolve) => { reached = resolve; });
      const spy = vi.spyOn(mongoose, "startSession").mockImplementationOnce(async () => {
        reached();
        await paused;
        return originalStart();
      });
      const route = (await import("./installationPushRoute.js")).createInstallationPushHandler();
      const pending = route(context.req, context.res);
      try {
        await resolvedAuthority;
        expect(await completeParticipantDeletionOperation(
          owner, 1, recoveryCapability, dependencies()
        )).toBe("completed");
      } finally {
        resume();
        await pending;
        spy.mockRestore();
      }
      expect(context.status).toBe(401);
      const stored = await Installation.collection.findOne({ installationCredentialDigest: digest });
      expect(stored).not.toHaveProperty("participantId");
      expect(stored).not.toHaveProperty("participantAuthorityVersion");
      expect(stored?.pushMutationVersion).toBe(10);
      expect(stored?.apnsToken).toBe("ee");
      expect(stored?.pushEnabled).toBe(true);
    }
  );

  it("refuses participant-authorized email unsubscribe when deletion wins after authority resolution", async () => {
    const email = "unsubscribe-race-delete@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    await Subscriber.create({ email, status: "confirmed" });
    const request = {
      headers: {
        [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
          participantId,
          owner.authorityVersion,
          Buffer.from(participantSigningSecretText)
        ),
      },
      body: {},
    } as unknown as Request;
    let status = 200;
    let body: unknown;
    const response = {
      status(value: number) { status = value; return this; },
      json(value: unknown) { body = value; return this; },
    } as unknown as Response;
    const handler = createParticipantEmailUnsubscribeHandler({ now: () => now });
    const originalStartSession = mongoose.startSession.bind(mongoose);
    let resume!: () => void;
    let reached!: () => void;
    const paused = new Promise<void>((resolve) => { resume = resolve; });
    const authorityResolved = new Promise<void>((resolve) => { reached = resolve; });
    const startSessionSpy = vi.spyOn(mongoose, "startSession").mockImplementationOnce(async () => {
      reached();
      await paused;
      return originalStartSession();
    });
    const pending = handler(request, response);
    try {
      await authorityResolved;
      expect(
        await completeParticipantDeletionOperation(
          owner,
          1,
          recoveryCapability,
          dependencies()
        )
      ).toBe("completed");
    } finally {
      resume();
      await pending;
      startSessionSpy.mockRestore();
    }
    expect(status).toBe(401);
    expect(body).not.toEqual({ email: { unsubscribed: true } });
    expect(await Participant.findById(participantId).exec()).toBeNull();
    expect(
      await Subscriber.findOne({ email }).lean<{ status: string } | null>().exec()
    ).toBeNull();
  });

  it("recovery lookup answers completed exactly once wired through, and refuses a wrong capability", async () => {
    const email = "recovery-student@nyu.edu";
    const { owner, recoveryCapability } = await authorizedOperation(email);
    await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());

    await expect(readCompletedDeletionRecovery(owner.operationId, recoveryCapability, owner.namespaceBinding))
      .resolves.toEqual({ outcome: "completed" });
    await expect(readCompletedDeletionRecovery(owner.operationId, recoveryCapability.replace(/^./, recoveryCapability[0] === "A" ? "B" : "A"), owner.namespaceBinding))
      .resolves.toEqual({ outcome: "unavailable" });
  });

  it("unlinks permanent RequestParticipation while preserving the request-scoped pseudonym", async () => {
    const email = "participation-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const requestId = new mongoose.Types.ObjectId();
    await MealRequest.create({
      _id: requestId,
      vendor: "Crave NYU",
      food: "Rice bowl",
      pickupWindowText: "ASAP",
      menuPath: "meal-exchange",
      mealSwipes: 1,
      email: "requester@nyu.edu",
      status: "claimed",
      helperParticipantId: participantId,
      claimExpiresAt: new Date(now.getTime() - 1),
      expiresAt: new Date(now.getTime() + 60_000),
      deleteAt: new Date(now.getTime() + 60_000),
    });
    const row = await RequestParticipation.create({ requestId, participantId });
    const before = await RequestParticipation.findById(row._id)
      .select("+participationKeyVersion +participationHmac").lean().exec();
    expect(before!.participationKeyVersion).toBeUndefined(); // backfill happens on claim, not creation; unaffected here

    // Give it a valid backfilled pair directly, as the accepted migration would.
    const { participationIdentityFields } = await import("./participantIdentityMongoTestSupport.js");
    const fields = participationIdentityFields(String(requestId), email);
    await RequestParticipation.updateOne({ _id: row._id }, { $set: fields }).exec();

    const outcome = await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());
    expect(outcome).toBe("completed");

    const after = await RequestParticipation.findById(row._id)
      .select("+requestId +participantId +participationKeyVersion +participationHmac").lean().exec();
    expect(after!.participantId).toBeUndefined();
    expect(after!.requestId).toEqual(requestId);
    expect(after!.participationKeyVersion).toBe(fields.participationKeyVersion);
    expect(after!.participationHmac).toBe(fields.participationHmac);
  });

  it("tombstones RequestOperation and RequestUpdateOperation to the minimal permanent shape", async () => {
    const email = "ledger-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const requestId = new mongoose.Types.ObjectId();
    const opRow = await RequestOperation.create({
      operationId: "op-1", participantId, requestId, outcome: "created",
    });
    const updateRow = await RequestUpdateOperation.create({
      operationId: "upd-1", participantId, requestId, kind: "withdraw", resultingRevision: 2,
    });

    const outcome = await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());
    expect(outcome).toBe("completed");

    const afterOp = await RequestOperation.findById(opRow._id)
      .select("+participantId +requestId +ownerDeleted").lean().exec();
    expect(afterOp).toMatchObject({ operationId: "op-1", outcome: "created", ownerDeleted: true });
    expect(afterOp!.participantId).toBeUndefined();
    expect(afterOp!.requestId).toBeUndefined();

    const afterUpdate = await RequestUpdateOperation.findById(updateRow._id)
      .select("+participantId +requestId +kind +resultingRevision +ownerDeleted").lean().exec();
    expect(afterUpdate).toMatchObject({ operationId: "upd-1", ownerDeleted: true });
    expect(afterUpdate!.participantId).toBeUndefined();
    expect(afterUpdate!.requestId).toBeUndefined();
    expect(afterUpdate!.kind).toBeUndefined();
    expect(afterUpdate!.resultingRevision).toBeUndefined();
  });

  it("deletes blocker-owned blocks and unlinks (never deletes) blocked-target rows, without touching another principal's data", async () => {
    const deletingEmail = "blocker-student@nyu.edu";
    const otherEmail = "other-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(deletingEmail);
    const otherId = await makeParticipant(otherEmail);

    const { blockSafetyIdentityFields } = await import("./participantIdentityMongoTestSupport.js");
    const ownedBlock = await ParticipantBlock.create({
      blockerParticipantId: participantId,
      blockedParticipantId: otherId,
      ...blockSafetyIdentityFields(otherEmail),
      blockedRole: "helper",
      diningLocation: "Kimmel",
      interactionAt: now,
    });
    const targetedBlock = await ParticipantBlock.create({
      blockerParticipantId: otherId,
      blockedParticipantId: participantId,
      ...blockSafetyIdentityFields(deletingEmail),
      blockedRole: "requester",
      diningLocation: "Kimmel",
      interactionAt: now,
    });

    const outcome = await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());
    expect(outcome).toBe("completed");

    expect(await ParticipantBlock.findById(ownedBlock._id).exec()).toBeNull();
    const survivingTargeted = await ParticipantBlock.findById(targetedBlock._id)
      .select("+blockerParticipantId +blockedParticipantId +blockedSafetyKeyVersion +blockedSafetyHmac")
      .lean().exec();
    expect(survivingTargeted).not.toBeNull();
    expect(survivingTargeted!.blockedParticipantId).toBeUndefined();
    expect(survivingTargeted!.blockerParticipantId).toEqual(otherId);
    expect(survivingTargeted!.blockedSafetyKeyVersion).toBe(blockSafetyIdentityFields(deletingEmail).blockedSafetyKeyVersion);

    // The other principal's own account/identity is completely untouched.
    expect(await Participant.findById(otherId).exec()).not.toBeNull();
  });

  it("confirms a usable safety identity in-transaction and still removes the ordinary account", async () => {
    const email = "safety-linked-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const { identityId } = await runModerationTransaction((session) =>
      ensureSafetyIdentity(safetyKeyring, email, session)
    );
    await Participant.updateOne({ _id: participantId }, { $set: { safetyIdentityRef: identityId } }).exec();
    const beforeSerial = (await SafetyIdentity.findById(identityId).select("serial").lean().exec())!.serial;

    const outcome = await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());
    expect(outcome).toBe("completed");

    expect(await Participant.findById(participantId).exec()).toBeNull();
    const identity = await SafetyIdentity.findById(identityId).select("serial").lean().exec();
    expect(identity).not.toBeNull();
    expect(identity!.serial).toBeGreaterThan(beforeSerial);
  });

  it("fails closed with no partial effect when the referenced safety identity cannot be confirmed under the current keyring", async () => {
    const email = "safety-unusable-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const { identityId } = await runModerationTransaction((session) =>
      ensureSafetyIdentity(unusableSafetyKeyring, email, session)
    );
    await Participant.updateOne({ _id: participantId }, { $set: { safetyIdentityRef: identityId } }).exec();

    // completeParticipantDeletionOperation reads the live SAFETY_IDENTITY_KEYRING_ENV
    // through tryReadSafetyIdentityKeyring, so point the environment at the
    // unusable configuration for this one call, then restore the
    // suite-wide usable configuration stubbed in beforeAll.
    vi.stubEnv(
      SAFETY_IDENTITY_KEYRING_ENV,
      JSON.stringify({ current: "kY", keys: { kY: Buffer.alloc(32, 0x55).toString("base64url") } })
    );
    try {
      const outcome = await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());
      expect(outcome).toBe("safetyIdentityUnavailable");
    } finally {
      vi.stubEnv(
        SAFETY_IDENTITY_KEYRING_ENV,
        JSON.stringify({ current: "k1", keys: { k1: safetyKey.toString("base64url") } })
      );
    }

    // Nothing committed: the account, its deletion operation, and the
    // identity reference are all exactly as they were.
    expect(await Participant.findById(participantId).exec()).not.toBeNull();
    const op = await readParticipantDeletionStatus(owner, dependencies());
    expect(op).toMatchObject({ phase: "authorized" });
  });

  it("refuses a presented capability that does not match the one minted at authorization", async () => {
    const email = "wrong-capability-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const tampered = recoveryCapability.slice(0, -1) + (recoveryCapability.endsWith("A") ? "B" : "A");

    const outcome = await completeParticipantDeletionOperation(owner, 1, tampered, dependencies());
    expect(outcome).toBe("invalidCapability");
    expect(await Participant.findById(participantId).exec()).not.toBeNull();
  });

  it("refuses completion once the five-minute authorization has lapsed", async () => {
    const email = "expired-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    now = new Date(now.getTime() + 6 * 60 * 1000);

    // The pre-check's own evaluator already calls readParticipantDeletionStatus
    // internally, which self-heals a lapsed "authorized" phase back to "ready"
    // the moment anything reads it (the accepted "expired challenge/auth
    // returns safely to ready" rule) — so by the time the transaction's own
    // phase check runs, the row is no longer "authorized" at all.
    const outcome = await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());
    expect(outcome).toBe("notAuthorized");
    expect(await Participant.findById(participantId).exec()).not.toBeNull();
  });

  it("refuses completion of an operation that was never challenged/redeemed", async () => {
    const email = "never-authorized-student@nyu.edu";
    const participantId = await makeParticipant(email);
    const created = await createOrResolveParticipantDeletionOperation(
      { participantId, canonicalEmail: email, authorityVersion: 1, initialPhase: "ready" },
      dependencies()
    );
    const owner: DeletionOwner = {
      operationId: created.status.operationId, participantId, canonicalEmail: email, authorityVersion: 1,
      namespaceBinding: created.status.namespaceBinding,
    };

    const outcome = await completeParticipantDeletionOperation(owner, 1, "not-a-real-capability", dependencies());
    expect(outcome).toBe("notAuthorized");
    expect(await Participant.findById(participantId).exec()).not.toBeNull();
  });

  it("refuses a stale readiness generation", async () => {
    const email = "stale-gen-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);
    const outcome = await completeParticipantDeletionOperation(owner, 5, recoveryCapability, dependencies());
    expect(outcome).toBe("stale");
    expect(await Participant.findById(participantId).exec()).not.toBeNull();
  });

  it("layer 1 (the pre-check) alone completes when the deleting participant genuinely owns and holds nothing", async () => {
    // Baseline for the next test: with no request, claim, or reservation at
    // all, the pre-check must observe "ready" and completion must succeed
    // with no intervention.
    const email = "race-baseline-helper@nyu.edu";
    const { owner, recoveryCapability } = await authorizedOperation(email);
    const outcome = await completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies());
    expect(outcome).toBe("completed");
  });

  it("a claim the deleting participant acquires strictly after layer 1's own read is still caught by layer 2's in-transaction recheck, not merely re-observed by layer 1 itself", async () => {
    const requesterEmail = "race-other-requester@nyu.edu";
    const helperEmail = "race-helper@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(helperEmail);
    const requesterId = await makeParticipant(requesterEmail);
    // `claimRequest` (the real route, invoked inside the hook below) judges
    // expiry against the real wall clock, not this file's fixed `now` used
    // only for the P2 deletion functions' own dependency injection — so this
    // fixture's timestamps are relative to `Date.now()`, unlike every other
    // fixture in this file.
    const wallNow = Date.now();
    const request = await MealRequest.create({
      vendor: "Crave NYU", food: "Rice bowl", pickupWindowText: "ASAP",
      menuPath: "meal-exchange", mealSwipes: 1, mealItems: [{ name: "Rice bowl" }],
      email: requesterEmail, status: "open", requesterParticipantId: requesterId,
      visibleFrom: new Date(wallNow - 1000), contentRevision: 1, notificationGeneration: 1,
      expiresAt: new Date(wallNow + 3 * 60 * 60 * 1000),
      deleteAt: new Date(wallNow + 24 * 60 * 60 * 1000),
    });

    // The previous test proves layer 1 alone would see this deleting
    // participant (who, at that point, holds nothing at all) as clear and
    // let completion through. Here the `afterPreCheck` test hook commits a
    // brand-new claim *by the deleting participant itself* strictly after
    // layer 1's own read already found the operation "ready" — a blocker
    // that provably did not exist anywhere for layer 1 to see. Only layer 2,
    // reading inside the final transaction's own snapshot, can observe it.
    // If layer 2 were dead code, this would incorrectly complete and delete
    // the Participant out from under an active claim it now holds.
    let claimed = false;
    const outcome = await completeParticipantDeletionOperation(
      owner,
      1,
      recoveryCapability,
      dependencies(),
      {
        afterPreCheck: async () => {
          const claim = claimContext(request._id, participantId);
          await claimRequest(claim.req, claim.res);
          expect(claim.status).toBe(200);
          claimed = true;
        },
      }
    );
    expect(claimed).toBe(true);
    expect(outcome).toBe("blocked");
    expect(await Participant.findById(participantId).exec()).not.toBeNull();
    const status = await readParticipantDeletionStatus(owner, dependencies());
    expect(status).toMatchObject({ phase: "waiting" });
    // And the claim itself committed and is not somehow rolled back or
    // orphaned by the aborted deletion transaction.
    const claimedRequest = await MealRequest.findById(request._id).select("+helperParticipantId").lean().exec();
    expect(String(claimedRequest!.helperParticipantId)).toBe(String(participantId));
  });

  it("only one of two concurrent completion calls on the same authorized operation wins; the loser sees a defined refusal with no partial effect", async () => {
    const email = "duplicate-complete-student@nyu.edu";
    const { owner, participantId, recoveryCapability } = await authorizedOperation(email);

    const [first, second] = await Promise.all([
      completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies()),
      completeParticipantDeletionOperation(owner, 1, recoveryCapability, dependencies()),
    ]);
    const completedCount = [first, second].filter((o) => o === "completed").length;
    expect(completedCount).toBe(1);
    const loser = first === "completed" ? second : first;
    expect(["notAuthorized", "stale", "notOwned"]).toContain(loser);
    expect(await Participant.findById(participantId).exec()).toBeNull();
  });
});
