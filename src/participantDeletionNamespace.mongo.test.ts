import { randomUUID } from "node:crypto";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  Participant,
  ParticipantDeletionOperation,
  RequestOperationAuthority,
} from "../models/db.js";
import { establishRequestOperationLedger } from "./requestOperationAuthority.js";
import {
  DeletionNamespaceUnavailable,
  deletionNamespaceBinding,
  fenceDeletionNamespace,
} from "./participantDeletionNamespace.js";
import { createOrResolveParticipantDeletionOperation } from "./participantDeletionOperations.js";
import { compareDeletionRecordedLedger } from "./participantDeletionProvenance.js";
import {
  deletionRecoveryCapabilityDigest,
  generateDeletionRecoveryCapability,
  readCompletedDeletionRecovery,
  scrubExpiredDeletionRecoveryReceipts,
} from "./participantDeletionRecovery.js";

const base = process.env.MONGO_INTEGRATION_URI;
const uri = base ? new URL(base) : undefined;
if (uri) uri.pathname += "_deletion_namespace";
const describeMongo = uri ? describe : describe.skip;
const secret = Buffer.alloc(32, 0x41);
let ledger: string;
let binding: string;
const authorityRow = { _id: "request-operation-ledger" };

async function start(email = "namespace@nyu.edu") {
  const participant = await Participant.create({ email, authorityVersion: 1, verifiedAt: new Date() });
  const result = await createOrResolveParticipantDeletionOperation({
    participantId: String(participant._id),
    canonicalEmail: email,
    authorityVersion: 1,
    initialPhase: "ready",
  }, { readSecret: () => secret });
  return { participant, ...result };
}

async function receipt(namespaceBinding: string | undefined = binding) {
  const operationId = randomUUID();
  const capability = generateDeletionRecoveryCapability();
  const expires = new Date(Date.now() + 60_000);
  await ParticipantDeletionOperation.collection.insertOne({
    operationId,
    ...(namespaceBinding === undefined ? {} : { namespaceBinding }),
    phase: "completed",
    completedAt: new Date(),
    recoveryExpiresAt: expires,
    recoveryCapabilityDigest: deletionRecoveryCapabilityDigest(capability),
  });
  return { operationId, capability, expires };
}

describeMongo("P2 atomic serving namespace binding (real replica set)", () => {
  beforeAll(async () => {
    await mongoose.connect(uri!.toString());
    await ParticipantDeletionOperation.createIndexes();
  });
  beforeEach(async () => {
    ledger = await establishRequestOperationLedger();
    binding = deletionNamespaceBinding(ledger);
  });
  afterEach(async () => {
    await ParticipantDeletionOperation.deleteMany({});
    await Participant.deleteMany({});
    await RequestOperationAuthority.deleteMany({});
  });
  afterAll(async () => { await mongoose.disconnect(); });

  it("attests only a matching recorded ledger for the exact authenticated operation", async () => {
    const first = await start();
    const owner = {
      operationId: first.status.operationId, namespaceBinding: binding,
      participantId: String(first.participant._id),
      canonicalEmail: first.participant.email, authorityVersion: 1,
    };
    const overrides = { readSecret: () => secret };
    expect(await compareDeletionRecordedLedger(owner, ledger, overrides)).toBe(true);
    expect(await compareDeletionRecordedLedger(owner, randomUUID(), overrides)).toBe(false);
    await expect(compareDeletionRecordedLedger(
      { ...owner, operationId: randomUUID() }, ledger, overrides
    )).rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
    await expect(compareDeletionRecordedLedger(owner, "invalid", overrides))
      .rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
    await RequestOperationAuthority.updateOne(authorityRow, { $set: { authorityId: randomUUID() } });
    await expect(compareDeletionRecordedLedger(owner, ledger, overrides))
      .rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
  });

  it.each(["null", "empty-array", "matching-array", "object"])(
    "never attests malformed persisted operation provenance (%j)", async (malformed) => {
      const first = await start();
      const value = malformed === "null" ? null :
        malformed === "empty-array" ? [] :
        malformed === "matching-array" ? [binding] : { value: binding };
      await ParticipantDeletionOperation.collection.updateOne(
        { operationId: first.status.operationId }, { $set: { namespaceBinding: value } }
      );
      await expect(compareDeletionRecordedLedger({
        operationId: first.status.operationId, namespaceBinding: binding,
        participantId: String(first.participant._id),
        canonicalEmail: first.participant.email, authorityVersion: 1,
      }, ledger, { readSecret: () => secret })).rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
    }
  );

  it("binds an authenticated operation at creation and keeps idempotent starts on that binding", async () => {
    const first = await start();
    expect(first.status.namespaceBinding).toBe(binding);
    const again = await createOrResolveParticipantDeletionOperation({
      participantId: String(first.participant._id),
      canonicalEmail: first.participant.email,
      authorityVersion: 1,
      initialPhase: "ready",
    }, { readSecret: () => secret });
    expect(again.outcome).toBe("existing");
    expect(again.status.namespaceBinding).toBe(binding);
    expect(await ParticipantDeletionOperation.collection.findOne({
      operationId: first.status.operationId,
    })).toMatchObject({ namespaceBinding: binding });
    expect(JSON.stringify(first.status)).not.toContain(ledger);
  });

  it("refuses an existing operation after same-origin authority replacement, without rebinding it", async () => {
    const first = await start();
    await RequestOperationAuthority.updateOne(authorityRow, { $set: { authorityId: randomUUID() } });
    await expect(createOrResolveParticipantDeletionOperation({
      participantId: String(first.participant._id),
      canonicalEmail: first.participant.email,
      authorityVersion: 1,
      initialPhase: "ready",
    }, { readSecret: () => secret })).rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
    expect(await ParticipantDeletionOperation.collection.findOne({
      operationId: first.status.operationId,
    })).toMatchObject({ namespaceBinding: binding, phase: "ready" });
  });

  it("does not backfill a legacy operation's missing namespace", async () => {
    const first = await start();
    await ParticipantDeletionOperation.collection.updateOne(
      { operationId: first.status.operationId }, { $unset: { namespaceBinding: "" } }
    );
    await expect(createOrResolveParticipantDeletionOperation({
      participantId: String(first.participant._id),
      canonicalEmail: first.participant.email,
      authorityVersion: 1,
      initialPhase: "ready",
    }, { readSecret: () => secret })).rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
  });

  it("fails closed if the serving authority is absent", async () => {
    await RequestOperationAuthority.deleteMany({});
    await expect(start()).rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
    expect(await ParticipantDeletionOperation.countDocuments()).toBe(0);
  });

  it("aborts all transaction work when the expected namespace does not match", async () => {
    const session = await mongoose.startSession();
    try {
      await expect(session.withTransaction(async () => {
        await fenceDeletionNamespace(session, deletionNamespaceBinding(randomUUID()));
        await Participant.create([{ email: "must-not-exist@nyu.edu" }], { session });
      })).rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
      expect(await Participant.countDocuments()).toBe(0);
    } finally { await session.endSession(); }
  });

  it("concurrent starts and authority replacement never persist a mixed operation binding", async () => {
    const replacement = randomUUID();
    const participant = await Participant.create({
      email: "race@nyu.edu", authorityVersion: 1, verifiedAt: new Date(),
    });
    const results = await Promise.allSettled([
      createOrResolveParticipantDeletionOperation({
        participantId: String(participant._id), canonicalEmail: participant.email,
        authorityVersion: 1, initialPhase: "ready",
      }, { readSecret: () => secret }),
      RequestOperationAuthority.updateOne(authorityRow, { $set: { authorityId: replacement } }).exec(),
    ]);
    const created = results[0];
    expect(created.status).toBe("fulfilled");
    if (created.status !== "fulfilled") throw created.reason;
    const stored = await ParticipantDeletionOperation.collection.findOne({
      operationId: created.value.status.operationId,
    });
    expect(stored?.namespaceBinding).toBe(created.value.status.namespaceBinding);
    expect([binding, deletionNamespaceBinding(replacement)]).toContain(stored?.namespaceBinding);
    // The two writes serialize: a start that preceded replacement is not
    // silently rebound and cannot later pass the new authority check.
    const session = await mongoose.startSession();
    try {
      if (stored?.namespaceBinding === binding) {
        await expect(session.withTransaction(() => fenceDeletionNamespace(session, binding)))
          .rejects.toBeInstanceOf(DeletionNamespaceUnavailable);
      }
    } finally { await session.endSession(); }
  });

  it("returns completion only for matching capability, receipt and serving namespace", async () => {
    const r = await receipt();
    expect(await readCompletedDeletionRecovery(r.operationId, r.capability, binding))
      .toEqual({ outcome: "completed" });
    for (const invalid of [undefined, "", ledger, deletionNamespaceBinding(randomUUID())]) {
      expect(await readCompletedDeletionRecovery(r.operationId, r.capability, invalid))
        .toEqual({ outcome: "unavailable" });
    }
    expect(await readCompletedDeletionRecovery(r.operationId, generateDeletionRecoveryCapability(), binding))
      .toEqual({ outcome: "unavailable" });
    expect(await readCompletedDeletionRecovery(randomUUID(), r.capability, binding))
      .toEqual({ outcome: "unavailable" });
    const after = await ParticipantDeletionOperation.collection.findOne({ operationId: r.operationId });
    expect(after?.recoveryExpiresAt).toEqual(r.expires);
    expect(after).not.toHaveProperty("participantId");
    expect(after).not.toHaveProperty("authorityId");
  });

  it("rejects a copied receipt/capability after ledger replacement for either submitted namespace", async () => {
    const r = await receipt();
    const replacement = randomUUID();
    await RequestOperationAuthority.updateOne(authorityRow, { $set: { authorityId: replacement } });
    for (const candidate of [binding, deletionNamespaceBinding(replacement)]) {
      expect(await readCompletedDeletionRecovery(r.operationId, r.capability, candidate))
        .toEqual({ outcome: "unavailable" });
    }
    await RequestOperationAuthority.deleteMany({});
    expect(await readCompletedDeletionRecovery(r.operationId, r.capability, binding))
      .toEqual({ outcome: "unavailable" });
  });

  it("never treats an unbound legacy receipt as cleanup authority", async () => {
    const r = await receipt();
    await ParticipantDeletionOperation.collection.updateOne(
      { operationId: r.operationId }, { $unset: { namespaceBinding: "" } }
    );
    expect(await readCompletedDeletionRecovery(r.operationId, r.capability, binding))
      .toEqual({ outcome: "unavailable" });
  });

  it.each(["array", "multipleNamespaces", "object", "number", "null"])(
    "refuses a malformed stored receipt namespace (%s), including Mongo array equality matches",
    async (kind) => {
      const r = await receipt();
      const malformed: unknown = kind === "array" ? [binding]
        : kind === "multipleNamespaces" ? [binding, deletionNamespaceBinding(randomUUID())]
        : kind === "object" ? { value: binding }
        : kind === "number" ? 123 : null;
      await ParticipantDeletionOperation.collection.updateOne(
        { operationId: r.operationId },
        [{ $set: { namespaceBinding: { $literal: malformed } } }]
      );
      expect(await readCompletedDeletionRecovery(r.operationId, r.capability, binding))
        .toEqual({ outcome: "unavailable" });
    }
  );

  it("cannot combine an old namespace read with a receipt inserted after authority replacement", async () => {
    const operationId = randomUUID();
    const capability = generateDeletionRecoveryCapability();
    const outcome = await readCompletedDeletionRecovery(operationId, capability, binding, {
      afterNamespaceRead: async () => {
        await RequestOperationAuthority.updateOne(
          authorityRow, { $set: { authorityId: randomUUID() } }
        );
        await ParticipantDeletionOperation.collection.insertOne({
          operationId, namespaceBinding: binding, phase: "completed",
          completedAt: new Date(), recoveryExpiresAt: new Date(Date.now() + 60_000),
          recoveryCapabilityDigest: deletionRecoveryCapabilityDigest(capability),
        });
      },
    });
    expect(outcome).toEqual({ outcome: "unavailable" });
  });

  it("scrubs the non-personal binding at the existing expiry without freeing operation identity", async () => {
    const r = await receipt();
    await ParticipantDeletionOperation.collection.updateOne(
      { operationId: r.operationId }, { $set: { recoveryExpiresAt: new Date(0) } }
    );
    expect(await readCompletedDeletionRecovery(r.operationId, r.capability, binding))
      .toEqual({ outcome: "unavailable" });
    await scrubExpiredDeletionRecoveryReceipts();
    const stored = await ParticipantDeletionOperation.collection.findOne({ operationId: r.operationId });
    expect(Object.keys(stored!).sort()).toEqual(["_id", "operationId"]);
  });
});
