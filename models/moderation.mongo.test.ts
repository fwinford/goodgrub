import mongoose from "mongoose";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  MODERATION_MODELS,
  ModerationReport,
  ReportSubmissionLedger,
  Suspension,
  SafetyIdentity,
  establishModerationIndexes,
} from "./moderation.js";
import { REPORT_LEDGER_RETENTION_SECONDS } from "../src/moderationConstants.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_moderation_schema`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const id = () => new mongoose.Types.ObjectId();
const hex = (c: string) => c.repeat(64);

async function indexOf(model: { collection: mongoose.Collection }, name: string) {
  const indexes = await model.collection.indexes();
  return indexes.find((index) => index.name === name);
}

describeMongo("moderation indexes on the real collections", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
    await establishModerationIndexes();
  });

  afterAll(async () => {
    await mongoose.connection.dropDatabase();
    await mongoose.disconnect();
  });

  beforeEach(async () => {
    for (const model of MODERATION_MODELS) await model.deleteMany({});
  });

  it.each([
    ["moderationreports", "moderation_report_deleteAt_ttl"],
    ["reportevidences", "report_evidence_deleteAt_ttl"],
    ["suspensions", "suspension_deleteAt_ttl"],
    ["suspensionrationales", "suspension_rationale_deleteAt_ttl"],
    ["retentionholds", "retention_hold_deleteAt_ttl"],
    ["moderationauditevents", "moderation_audit_deleteAt_ttl"],
  ])("%s carries a deleteAt TTL index with expireAfterSeconds 0", async (collection, name) => {
    const model = MODERATION_MODELS.find((m) => m.collection.name === collection)!;
    const index = await indexOf(model, name);
    expect(index?.key).toEqual({ deleteAt: 1 });
    expect(index?.expireAfterSeconds).toBe(0);
  });

  it("expires the ledger and counting bindings at R (48 hours) from creation", async () => {
    for (const [collection, name] of [
      ["reportsubmissionledgers", "report_ledger_createdAt_ttl"],
      ["reportcountbindings", "report_count_binding_createdAt_ttl"],
    ]) {
      const model = MODERATION_MODELS.find((m) => m.collection.name === collection)!;
      const index = await indexOf(model, name);
      expect(index?.key).toEqual({ createdAt: 1 });
      expect(index?.expireAfterSeconds).toBe(REPORT_LEDGER_RETENTION_SECONDS);
    }
  });

  it("puts no TTL on the safety identity: it is released by state, not time", async () => {
    const indexes = await SafetyIdentity.collection.indexes();
    expect(indexes.some((index) => index.expireAfterSeconds !== undefined)).toBe(false);
  });

  it("enforces one identity per digest across all keys", async () => {
    await SafetyIdentity.create({ entries: [{ keyId: "k1", digest: hex("a") }] });
    await expect(
      SafetyIdentity.create({ entries: [{ keyId: "k1", digest: hex("a") }] })
    ).rejects.toMatchObject({ code: 11000 });
    // Sharing any one digest, whatever its key id, is the same principal.
    await expect(
      SafetyIdentity.create({ entries: [{ keyId: "k2", digest: hex("a") }] })
    ).rejects.toMatchObject({ code: 11000 });
    await expect(
      SafetyIdentity.create({ entries: [{ keyId: "k2", digest: hex("b") }] })
    ).resolves.toBeDefined();
  });

  it("allows one Active suspension per identity but any number of lifted ones", async () => {
    const identity = id();
    await Suspension.create({ origin: "manual", safetyIdentityRef: identity });
    await expect(Suspension.create({ origin: "manual", safetyIdentityRef: identity })).rejects.toMatchObject({
      code: 11000,
    });
    await Suspension.create([
      { origin: "manual", state: "lifted", liftedAt: new Date() },
      { origin: "manual", state: "lifted", liftedAt: new Date() },
    ]);
    // A different identity may be Active at the same time.
    await expect(Suspension.create({ origin: "manual", safetyIdentityRef: id() })).resolves.toBeDefined();
    const index = await indexOf(Suspension, "suspension_active_identity_unique");
    expect(index?.partialFilterExpression).toEqual({ state: "active" });
  });

  it("makes the opaque refs unique", async () => {
    await ModerationReport.create({ ref: "same" });
    await expect(ModerationReport.create({ ref: "same" })).rejects.toMatchObject({ code: 11000 });
  });

  it("makes operation and handoff digests unique, with a partial handoff index", async () => {
    const row = (operationDigest: string, handoffDigest?: string) => ({
      keyId: "k1",
      operationDigests: [operationDigest],
      participantBinding: hex("9"),
      handoffDigests: handoffDigest ? [handoffDigest] : undefined,
      outcome: "created" as const,
    });
    await ReportSubmissionLedger.create(row(hex("1"), hex("e")));
    await expect(ReportSubmissionLedger.create(row(hex("1")))).rejects.toMatchObject({ code: 11000 });
    await expect(ReportSubmissionLedger.create(row(hex("2"), hex("e")))).rejects.toMatchObject({
      code: 11000,
    });
    await ReportSubmissionLedger.create([row(hex("3")), row(hex("4"))]);
    expect(await ReportSubmissionLedger.countDocuments()).toBe(3);
  });
});
