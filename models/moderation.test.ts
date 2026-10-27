import mongoose from "mongoose";
import { describe, expect, it } from "vitest";
import {
  MODERATION_MODELS,
  ModerationAuditEvent,
  ModerationReport,
  ReportCountBinding,
  ReportEvidence,
  ReportSubmissionLedger,
  RetentionHold,
  SafetyIdentity,
  Suspension,
  SuspensionRationale,
} from "./moderation.js";
import { REPORT_LEDGER_RETENTION_SECONDS } from "../src/moderationConstants.js";

const id = () => new mongoose.Types.ObjectId();
const hex = (char: string) => char.repeat(64);

function indexes(model: { schema: mongoose.Schema }) {
  return model.schema.indexes().map(([fields, options]) => ({
    fields: fields as Record<string, unknown>,
    options: options as Record<string, unknown>,
  }));
}

function paths(model: { schema: mongoose.Schema }): string[] {
  const out: string[] = [];
  model.schema.eachPath((path) => out.push(path));
  return out;
}

describe("moderation schemas: privacy by construction", () => {
  const FORBIDDEN =
    /email|principal|reporter(?!Binding)|participantId|userId|installation|displayName|name$|phone|token|secret|password/i;

  it.each(MODERATION_MODELS.map((model) => [model.modelName, model] as const))(
    "%s has no field that can hold an email, participant ID, reporter or credential",
    (_name, model) => {
      for (const path of paths(model)) {
        expect(path, `${model.modelName}.${path}`).not.toMatch(FORBIDDEN);
      }
    }
  );

  it("keeps the ledger and the case record unjoinable", () => {
    const ledger = paths(ReportSubmissionLedger).join(" ");
    expect(ledger).not.toMatch(/report(Id|Ref)|case|safetyIdentity|suspension/i);
    const bindings = paths(ReportCountBinding).join(" ");
    expect(bindings).not.toMatch(/report(Id|Ref)|case|safetyIdentity|suspension/i);
    for (const model of [ModerationReport, ReportEvidence, Suspension, RetentionHold]) {
      expect(paths(model).join(" ")).not.toMatch(/ledger|operation|handoff|binding/i);
    }
  });

  it("rejects fields outside the schema (strict mode)", () => {
    const report = new ModerationReport({ reporterEmail: "x@nyu.edu" } as never);
    expect((report.toObject() as unknown as Record<string, unknown>).reporterEmail).toBeUndefined();
  });

  it("holds no raw email or participant ID in a safety identity", () => {
    expect(paths(SafetyIdentity).sort()).toEqual(
      ["__v", "_id", "createdAt", "entries", "serial"].sort()
    );
    expect(Object.keys(SafetyIdentity.schema.path("entries").schema!.paths).sort()).toEqual(
      ["digest", "keyId"]
    );
  });
});

describe("TTL and uniqueness index definitions", () => {
  it.each([
    ["ModerationReport", ModerationReport, "moderation_report_deleteAt_ttl"],
    ["ReportEvidence", ReportEvidence, "report_evidence_deleteAt_ttl"],
    ["Suspension", Suspension, "suspension_deleteAt_ttl"],
    ["SuspensionRationale", SuspensionRationale, "suspension_rationale_deleteAt_ttl"],
    ["RetentionHold", RetentionHold, "retention_hold_deleteAt_ttl"],
    ["ModerationAuditEvent", ModerationAuditEvent, "moderation_audit_deleteAt_ttl"],
  ] as const)("%s expires on its own deleteAt with expireAfterSeconds 0", (_n, model, name) => {
    const ttl = indexes(model).find((entry) => entry.options.name === name);
    expect(ttl?.fields).toEqual({ deleteAt: 1 });
    expect(ttl?.options.expireAfterSeconds).toBe(0);
  });

  it.each([
    ["ReportSubmissionLedger", ReportSubmissionLedger, "report_ledger_createdAt_ttl"],
    ["ReportCountBinding", ReportCountBinding, "report_count_binding_createdAt_ttl"],
  ] as const)("%s expires at R from server creation", (_n, model, name) => {
    const ttl = indexes(model).find((entry) => entry.options.name === name);
    expect(ttl?.fields).toEqual({ createdAt: 1 });
    expect(ttl?.options.expireAfterSeconds).toBe(REPORT_LEDGER_RETENTION_SECONDS);
    expect(REPORT_LEDGER_RETENTION_SECONDS).toBe(48 * 60 * 60);
  });

  it("makes the active-suspension-per-identity index partial and unique", () => {
    const entry = indexes(Suspension).find(
      (candidate) => candidate.options.name === "suspension_active_identity_unique"
    );
    expect(entry?.fields).toEqual({ safetyIdentityRef: 1 });
    expect(entry?.options.unique).toBe(true);
    expect(entry?.options.partialFilterExpression).toEqual({ state: "active" });
  });

  it("makes operation and handoff digests unique", () => {
    const list = indexes(ReportSubmissionLedger);
    expect(list.find((e) => e.options.name === "report_ledger_operation_unique")?.options.unique).toBe(true);
    const handoff = list.find((e) => e.options.name === "report_ledger_handoff_unique");
    expect(handoff?.options.unique).toBe(true);
    expect(handoff?.options.partialFilterExpression).toEqual({ handoffDigests: { $exists: true } });
  });

  it("gives every detail and history record a deleteAt TTL, none on the identity", () => {
    expect(indexes(SafetyIdentity).some((e) => e.options.expireAfterSeconds !== undefined)).toBe(false);
  });
});

describe("document invariants", () => {
  it("keeps an open report free of outcome, closedAt and deleteAt", async () => {
    await expect(new ModerationReport({}).validate()).resolves.toBeUndefined();
    await expect(
      new ModerationReport({ deleteAt: new Date() }).validate()
    ).rejects.toThrow(/open report/);
    await expect(
      new ModerationReport({ state: "closed", outcome: "no-action" }).validate()
    ).rejects.toThrow(/closed report/);
    await expect(
      new ModerationReport({
        state: "closed",
        outcome: "no-action",
        closedAt: new Date(),
      }).validate()
    ).resolves.toBeUndefined();
  });

  it("accepts exactly the four outcomes", async () => {
    await expect(
      new ModerationReport({ state: "closed", outcome: "banned", closedAt: new Date() }).validate()
    ).rejects.toThrow();
  });

  it("requires an identity for an active suspension and none once lifted", async () => {
    await expect(
      new Suspension({ origin: "manual" }).validate()
    ).rejects.toThrow(/active suspension/);
    await expect(
      new Suspension({ origin: "manual", safetyIdentityRef: id() }).validate()
    ).resolves.toBeUndefined();
    await expect(
      new Suspension({
        origin: "manual",
        state: "lifted",
        liftedAt: new Date(),
        safetyIdentityRef: id(),
      }).validate()
    ).rejects.toThrow(/lifted suspension/);
    await expect(
      new Suspension({ origin: "report", safetyIdentityRef: id() }).validate()
    ).rejects.toThrow(/links its report/);
    await expect(
      new Suspension({ origin: "report", safetyIdentityRef: id(), reportIds: [id(), id()] }).validate()
    ).resolves.toBeUndefined();
    await expect(
      new Suspension({ origin: "manual", safetyIdentityRef: id(), reportIds: [id()] }).validate()
    ).rejects.toThrow(/starts with no report/);
  });

  it("trims a suspension rationale and rejects a blank or whitespace-only one", async () => {
    const suspensionId = id();
    const rationale = new SuspensionRationale({ suspensionId, text: "  Verified concern.  " });
    await rationale.validate();
    expect(rationale.text).toBe("Verified concern.");
    for (const text of ["", "   ", "\n\t "]) {
      await expect(new SuspensionRationale({ suspensionId, text }).validate(), JSON.stringify(text)).rejects.toThrow();
    }
    await expect(
      new SuspensionRationale({ suspensionId, text: "x".repeat(1001) }).validate()
    ).rejects.toThrow();
  });

  it("requires a safety identity to carry at least one keyed digest", async () => {
    await expect(new SafetyIdentity({ entries: [] }).validate()).rejects.toThrow(/at least one/);
    await expect(
      new SafetyIdentity({ entries: [{ keyId: "k1", digest: "not-hex" }] }).validate()
    ).rejects.toThrow();
    await expect(
      new SafetyIdentity({ entries: [{ keyId: "k1", digest: hex("a") }] }).validate()
    ).resolves.toBeUndefined();
  });

  it("limits the explanation to 250 characters and requires a reason", async () => {
    const base = { reportId: id(), kind: "explanation", reason: "Other concern" };
    await expect(new ReportEvidence({ ...base, text: "x".repeat(250) }).validate()).resolves.toBeUndefined();
    await expect(new ReportEvidence({ ...base, text: "x".repeat(251) }).validate()).rejects.toThrow();
    await expect(
      new ReportEvidence({ reportId: id(), kind: "explanation" }).validate()
    ).rejects.toThrow();
    await expect(
      new ReportEvidence({ ...base, reason: "Something else" }).validate()
    ).rejects.toThrow();
  });

  it("records complete-empty and incomplete message capture distinctly", async () => {
    const base = { reportId: id(), kind: "message-context" };
    await expect(
      new ReportEvidence({
        ...base,
        messageContext: { captureStatus: "complete", messages: [] },
      }).validate()
    ).resolves.toBeUndefined();
    await expect(
      new ReportEvidence({
        ...base,
        messageContext: {
          captureStatus: "incomplete",
          captureReason: "message-history-incomplete",
          messages: [],
        },
      }).validate()
    ).resolves.toBeUndefined();
    await expect(
      new ReportEvidence({
        ...base,
        messageContext: { captureStatus: "incomplete", messages: [] },
      }).validate()
    ).rejects.toThrow(/requires a reason/);
    await expect(
      new ReportEvidence({
        ...base,
        messageContext: {
          captureStatus: "complete",
          captureReason: "conversation-erased",
          messages: [],
        },
      }).validate()
    ).rejects.toThrow(/cannot carry an incomplete reason/);
    await expect(
      new ReportEvidence({
        ...base,
        messageContext: {
          captureStatus: "complete",
          messages: Array.from({ length: 11 }, (_, index) => ({
            sequence: index + 1,
            sender: "reporter",
            text: "message",
            createdAt: new Date(),
          })),
        },
      }).validate()
    ).rejects.toThrow();
  });

  it("requires a reason code, ending condition and reviewAt on every hold", async () => {
    const valid = {
      targetKind: "case",
      targetId: id(),
      holdClass: "legal-preservation",
      reasonCode: "legal-preservation",
      endingCondition: "Counsel confirms the preservation request is withdrawn.",
      reviewAt: new Date(),
    };
    await expect(new RetentionHold(valid).validate()).resolves.toBeUndefined();
    for (const missing of ["reasonCode", "endingCondition", "reviewAt"] as const) {
      const input: Record<string, unknown> = { ...valid };
      delete input[missing];
      await expect(new RetentionHold(input).validate(), missing).rejects.toThrow();
    }
    await expect(
      new RetentionHold({ ...valid, endingCondition: "   " }).validate()
    ).rejects.toThrow();
    await expect(
      new RetentionHold({ ...valid, reasonCode: "Not A Token!" }).validate()
    ).rejects.toThrow();
    await expect(
      new RetentionHold({ ...valid, holdClass: "overlapping-case" }).validate()
    ).rejects.toThrow(/related case/);
  });

  it("gives case events no clock and authentication / retention-run events a 90-day one", async () => {
    await expect(
      new ModerationAuditEvent({
        kind: "report-closed",
        subjectKind: "case",
        subjectId: id(),
      }).validate()
    ).resolves.toBeUndefined();
    await expect(
      new ModerationAuditEvent({
        kind: "report-closed",
        subjectKind: "case",
        subjectId: id(),
        deleteAt: new Date(),
      }).validate()
    ).rejects.toThrow(/no clock/);
    await expect(
      new ModerationAuditEvent({ kind: "report-closed", subjectKind: "suspension", subjectId: id() }).validate()
    ).rejects.toThrow();
    await expect(
      new ModerationAuditEvent({ kind: "moderator-authentication" }).validate()
    ).rejects.toThrow(/deleteAt/);
    await expect(
      new ModerationAuditEvent({ kind: "moderator-authentication", deleteAt: new Date() }).validate()
    ).resolves.toBeUndefined();
    await expect(
      new ModerationAuditEvent({ kind: "retention-run", deleteAt: new Date() }).validate()
    ).rejects.toThrow(/run summary/);
  });

  it("accepts only a hex fingerprint as an audit actor, never free text", async () => {
    await expect(
      new ModerationAuditEvent({
        kind: "moderator-authentication",
        deleteAt: new Date(),
        actor: "moderator@example.com",
      }).validate()
    ).rejects.toThrow();
    await expect(
      new ModerationAuditEvent({
        kind: "moderator-authentication",
        deleteAt: new Date(),
        actor: "a".repeat(32),
      }).validate()
    ).resolves.toBeUndefined();
  });

  it("requires keyed hex digests in the ledger and count bindings", async () => {
    await expect(
      new ReportSubmissionLedger({
        keyId: "k1",
        operationDigests: ["rp1.1.raw-operation-id"],
        participantBinding: hex("a"),
        outcome: "created",
      }).validate()
    ).rejects.toThrow();
    await expect(
      new ReportSubmissionLedger({
        keyId: "k1",
        operationDigests: [hex("b")],
        participantBinding: hex("a"),
        outcome: "created",
      }).validate()
    ).resolves.toBeUndefined();
    await expect(
      new ReportCountBinding({ keyId: "k1", reporterBinding: hex("a"), requestBinding: "x" }).validate()
    ).rejects.toThrow();
  });
});
