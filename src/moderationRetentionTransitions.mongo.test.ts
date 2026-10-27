import mongoose from "mongoose";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  MODERATION_MODELS,
  ModerationAuditEvent,
  ModerationReport,
  ReportEvidence,
  RetentionHold,
  SafetyIdentity,
  Suspension,
  SuspensionRationale,
  establishModerationIndexes,
} from "../models/moderation.js";
import { DAY_MS } from "./moderationConstants.js";
import { createRetentionHold, releaseRetentionHold } from "./moderationHolds.js";
import { notPastDeleteAt } from "./moderationRetention.js";
import {
  ModerationTransitionRefusal,
  closeReportCase,
  liftSuspension,
  recordReportCase,
  recordSuspension,
} from "./moderationRecords.js";
import { runModerationTransaction } from "./safetyIdentity.js";
import {
  SAFETY_IDENTITY_KEYRING_ENV,
  readSafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";

vi.mock("./moderationAudit.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./moderationAudit.js")>();
  return { ...actual, appendSubjectAudit: vi.fn(actual.appendSubjectAudit) };
});
vi.mock("./moderationClocks.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./moderationClocks.js")>();
  return {
    ...actual,
    recomputeCaseClocks: vi.fn(actual.recomputeCaseClocks),
    recomputeSuspensionClocks: vi.fn(actual.recomputeSuspensionClocks),
  };
});
import { appendSubjectAudit } from "./moderationAudit.js";
import { recomputeCaseClocks, recomputeSuspensionClocks } from "./moderationClocks.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_moderation_transitions`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const keyring = readSafetyIdentityKeyring({
  [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
    current: "k1",
    keys: { k1: Buffer.alloc(32, 0x31).toString("base64url") },
  }),
});

const snapshot = () => ({
  requestId: new mongoose.Types.ObjectId(),
  reportedRole: "requester" as const,
  requestStatus: "open" as const,
  food: "soup",
});

const at = (iso: string) => new Date(iso);
const plusDays = (date: Date, days: number) => new Date(date.getTime() + days * DAY_MS);
const plusYear = (date: Date) => {
  const result = new Date(date.getTime());
  result.setUTCFullYear(result.getUTCFullYear() + 1);
  return result;
};

const openCase = (email = "subject@nyu.edu") =>
  runModerationTransaction((session) =>
    recordReportCase(session, {
      keyring,
      reportedEmail: email,
      snapshot: snapshot(),
      reason: "Threats or unsafe behavior",
      explanation: "A concern.",
    })
  );

const suspend = (
  origin: "report" | "manual",
  email = "subject@nyu.edu",
  reportId?: mongoose.Types.ObjectId
) =>
  runModerationTransaction((session) =>
    recordSuspension(session, {
      keyring,
      suspendedEmail: email,
      origin,
      reportId,
      rationale: "Private rationale.",
    })
  );

const close = (
  reportId: mongoose.Types.ObjectId,
  outcome: Parameters<typeof closeReportCase>[1]["outcome"],
  when: Date
) =>
  runModerationTransaction((session) =>
    closeReportCase(session, { reportId, outcome, enforcementApplied: true, keyring }, when)
  );

const lift = (suspensionId: mongoose.Types.ObjectId, when: Date) =>
  runModerationTransaction((session) =>
    liftSuspension(session, { suspensionId, keyring }, when)
  );

async function clocks(reportId?: mongoose.Types.ObjectId, suspensionId?: mongoose.Types.ObjectId) {
  const out: Record<string, Date | undefined | null> = {};
  if (reportId) {
    out.caseHistory = (await ModerationReport.findById(reportId).lean())?.deleteAt;
    const evidence = await ReportEvidence.find({ reportId }).lean();
    expect(evidence).toHaveLength(2);
    expect(new Set(evidence.map((row) => String(row.deleteAt))).size).toBe(1);
    out.caseEvidence = evidence[0].deleteAt;
  }
  if (suspensionId) {
    out.suspensionHistory = (await Suspension.findById(suspensionId).lean())?.deleteAt;
    out.rationale = (await SuspensionRationale.findOne({ suspensionId }).lean())?.deleteAt;
  }
  return out;
}

describeMongo("moderation retention transitions (real MongoDB)", () => {
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
    vi.mocked(appendSubjectAudit).mockClear();
  });

  describe("the one formula, by state", () => {
    const T = at("2026-03-01T00:00:00Z");

    it("an Open report holds everything: no deleteAt anywhere", async () => {
      const { reportId } = await openCase();
      expect(await clocks(reportId)).toEqual({ caseHistory: undefined, caseEvidence: undefined });
    });

    it("Closed, No action: evidence at closure + 90 days, history at closure + 1 year", async () => {
      const { reportId } = await openCase();
      await close(reportId, "no-action", T);
      expect(await clocks(reportId)).toEqual({
        caseHistory: plusYear(T),
        caseEvidence: plusDays(T, 90),
      });
    });

    it("Closed on February 29: history clamps to February 28, evidence stays 90 fixed days (F7)", async () => {
      const leapDay = at("2028-02-29T12:00:00Z");
      const { reportId } = await openCase();
      await close(reportId, "no-action", leapDay);
      expect(await clocks(reportId)).toEqual({
        caseHistory: at("2029-02-28T12:00:00Z"),
        caseEvidence: at("2028-05-29T12:00:00Z"),
      });
    });

    it("Reinstated on February 29: suspension history clamps to February 28 (F7)", async () => {
      const { suspensionId } = await suspend("manual");
      await lift(suspensionId, at("2028-02-29T00:00:00Z"));
      expect(await clocks(undefined, suspensionId)).toEqual({
        suspensionHistory: at("2029-02-28T00:00:00Z"),
        rationale: at("2028-05-29T00:00:00Z"),
      });
    });

    it("Closed, removal only (Decision 14): the same clocks as No action", async () => {
      const { reportId } = await openCase();
      await close(reportId, "request-removed", T);
      expect(await clocks(reportId)).toEqual({
        caseHistory: plusYear(T),
        caseEvidence: plusDays(T, 90),
      });
    });

    it("Closed with an Active suspension: held until reinstatement, then anchored at the later of both", async () => {
      const { reportId } = await openCase();
      const { suspensionId } = await suspend("report", "subject@nyu.edu", reportId);
      await close(reportId, "participant-suspended", T);

      // A case closed while its suspension is active has every clock absent.
      expect(await clocks(reportId, suspensionId)).toEqual({
        caseHistory: undefined,
        caseEvidence: undefined,
        suspensionHistory: undefined,
        rationale: undefined,
      });

      const L = at("2026-05-15T00:00:00Z");
      await lift(suspensionId, L);
      expect(await clocks(reportId, suspensionId)).toEqual({
        caseHistory: plusYear(L),
        caseEvidence: plusDays(L, 90),
        suspensionHistory: plusYear(L),
        rationale: plusDays(L, 90),
      });
    });

    it("Manual suspension: rationale at reinstatement + 90 days, history at + 1 year", async () => {
      const { suspensionId } = await suspend("manual");
      expect(await clocks(undefined, suspensionId)).toEqual({
        suspensionHistory: undefined,
        rationale: undefined,
      });
      const L = at("2026-06-01T00:00:00Z");
      await lift(suspensionId, L);
      expect(await clocks(undefined, suspensionId)).toEqual({
        suspensionHistory: plusYear(L),
        rationale: plusDays(L, 90),
      });
    });

    it("Reinstatement before closure: the Open linked case keeps everything held until its later closure", async () => {
      const { reportId } = await openCase();
      const { suspensionId } = await suspend("report", "subject@nyu.edu", reportId);
      const L = at("2026-04-01T00:00:00Z");
      await lift(suspensionId, L);

      // The linked case is another active investigation: nothing starts yet.
      expect(await clocks(reportId, suspensionId)).toEqual({
        caseHistory: undefined,
        caseEvidence: undefined,
        suspensionHistory: undefined,
        rationale: undefined,
      });

      const C = at("2026-04-20T00:00:00Z");
      await close(reportId, "participant-suspended", C);
      expect(await clocks(reportId, suspensionId)).toEqual({
        caseHistory: plusYear(C),
        caseEvidence: plusDays(C, 90),
        suspensionHistory: plusYear(C),
        rationale: plusDays(C, 90),
      });
    });
  });

  describe("holds interact with the formula", () => {
    const T = at("2026-03-01T00:00:00Z");
    const hold = (reportId: mongoose.Types.ObjectId, when: Date, keepSafetyIdentity = false) =>
      runModerationTransaction((session) =>
        createRetentionHold(
          session,
          {
            targetKind: "case",
            targetId: reportId,
            holdClass: "legal-preservation",
            reasonCode: "legal-preservation",
            endingCondition: "Counsel withdraws the preservation request.",
            reviewAt: plusDays(when, 60),
            keepSafetyIdentity,
          },
          when
        )
      );
    const release = (holdId: mongoose.Types.ObjectId, when: Date) =>
      runModerationTransaction((session) =>
        releaseRetentionHold(session, holdId, { endingConditionMet: true }, when, keyring)
      );

    it("release after the base deadline makes deletion due at the hold end", async () => {
      const { reportId } = await openCase();
      await close(reportId, "no-action", T);
      const held = await hold(reportId, plusDays(T, 10));
      expect(await clocks(reportId)).toEqual({ caseHistory: undefined, caseEvidence: undefined });

      const released = plusDays(T, 200);
      await release(held.holdId, released);
      expect(await clocks(reportId)).toEqual({
        caseHistory: plusYear(T),
        caseEvidence: released,
      });
    });

    it("release before the base deadline leaves the base deadlines unchanged", async () => {
      const { reportId } = await openCase();
      await close(reportId, "no-action", T);
      const held = await hold(reportId, plusDays(T, 10));
      await release(held.holdId, plusDays(T, 30));
      expect(await clocks(reportId)).toEqual({
        caseHistory: plusYear(T),
        caseEvidence: plusDays(T, 90),
      });
    });

    it("a hold on an Open case changes nothing until closure, then the formula applies", async () => {
      const { reportId } = await openCase();
      const held = await hold(reportId, T);
      await close(reportId, "no-action", plusDays(T, 5));
      expect(await clocks(reportId)).toEqual({ caseHistory: undefined, caseEvidence: undefined });
      await release(held.holdId, plusDays(T, 40));
      expect(await clocks(reportId)).toEqual({
        caseHistory: plusYear(plusDays(T, 5)),
        caseEvidence: plusDays(T, 95),
      });
    });
  });

  describe("conditional, audited transitions", () => {
    const T = at("2026-03-01T00:00:00Z");

    it("refuses to close while enforcement is not applied, and writes nothing", async () => {
      const { reportId } = await openCase();
      for (const enforcementApplied of [false, undefined, "yes", 1]) {
        await expect(
          runModerationTransaction((session) =>
            closeReportCase(
              session,
              { reportId, outcome: "request-removed", enforcementApplied: enforcementApplied as never, keyring },
              T
            )
          )
        ).rejects.toMatchObject({ code: "enforcement-not-applied" });
      }
      expect(await ModerationReport.findById(reportId).lean()).toMatchObject({ state: "open" });
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });

    it("refuses a suspension outcome with no suspension, and an unknown outcome", async () => {
      const { reportId } = await openCase();
      await expect(close(reportId, "participant-suspended", T)).rejects.toMatchObject({
        code: "suspension-required",
      });
      await expect(close(reportId, "request-removed-and-participant-suspended", T)).rejects.toBeInstanceOf(
        ModerationTransitionRefusal
      );
      await expect(close(reportId, "banned" as never, T)).rejects.toMatchObject({
        code: "invalid-outcome",
      });
      expect(await ModerationReport.findById(reportId).lean()).toMatchObject({ state: "open" });
    });

    it("closes once: a second closure and a concurrent pair resolve to one winner", async () => {
      const { reportId } = await openCase();
      const results = await Promise.all([
        close(reportId, "no-action", T),
        close(reportId, "request-removed", plusDays(T, 1)),
      ]);
      expect(results.map((r) => r.status).sort()).toEqual(["closed", "not-open"]);
      const row = await ModerationReport.findById(reportId).lean();
      expect(row?.state).toBe("closed");
      expect(await ModerationAuditEvent.countDocuments({ kind: "report-closed" })).toBe(1);
    });

    it("lifts once, and an already-lifted suspension is a no-op", async () => {
      const { suspensionId } = await suspend("manual");
      const results = await Promise.all([lift(suspensionId, T), lift(suspensionId, plusDays(T, 1))]);
      expect(results.map((r) => r.status).sort()).toEqual(["lifted", "not-active"]);
      expect(await ModerationAuditEvent.countDocuments({ kind: "suspension-lifted" })).toBe(1);
    });

    it("makes a second suspension for one identity an idempotent no-op, including under concurrency", async () => {
      const first = await suspend("manual");
      const again = await suspend("manual");
      expect(first.created).toBe(true);
      expect(again).toMatchObject({ created: false });
      expect(String(again.suspensionId)).toBe(String(first.suspensionId));

      await Suspension.deleteMany({});
      await SuspensionRationale.deleteMany({});
      const burst = await Promise.all(Array.from({ length: 6 }, () => suspend("manual", "burst@nyu.edu")));
      expect(burst.filter((r) => r.created)).toHaveLength(1);
      expect(await Suspension.countDocuments({ state: "active" })).toBe(1);
      expect(await SuspensionRationale.countDocuments()).toBe(1);
    }, 30_000);

    it("lets a lifted identity be suspended again as a new row", async () => {
      const first = await suspend("manual");
      await lift(first.suspensionId, T);
      const second = await suspend("manual");
      expect(second.created).toBe(true);
      expect(String(second.suspensionId)).not.toBe(String(first.suspensionId));
    });

    it("attaches a report-origin suspension only to an Open case for the same identity", async () => {
      const { reportId } = await openCase("one@nyu.edu");
      await expect(suspend("report", "two@nyu.edu", reportId)).rejects.toMatchObject({
        code: "identity-mismatch",
      });
      await expect(
        suspend("report", "one@nyu.edu", new mongoose.Types.ObjectId())
      ).rejects.toMatchObject({ code: "report-not-open" });
      await close(reportId, "no-action", T);
      await expect(suspend("report", "one@nyu.edu", reportId)).rejects.toMatchObject({
        code: "report-not-open",
      });
    });
  });

  describe("several reports about one participant (F3)", () => {
    const T = at("2026-03-01T00:00:00Z");

    it("links each report to the one Active suspension without a second row or rationale", async () => {
      const first = await openCase("multi@nyu.edu");
      const second = await openCase("multi@nyu.edu");
      const created = await suspend("report", "multi@nyu.edu", first.reportId);
      const linked = await suspend("report", "multi@nyu.edu", second.reportId);

      expect(created.created).toBe(true);
      expect(linked).toMatchObject({ created: false });
      expect(String(linked.suspensionId)).toBe(String(created.suspensionId));
      expect(await Suspension.countDocuments()).toBe(1);
      expect(await SuspensionRationale.countDocuments()).toBe(1);
      const row = await Suspension.findById(created.suspensionId).lean();
      expect(row?.reportIds?.map(String).sort()).toEqual(
        [String(first.reportId), String(second.reportId)].sort()
      );
      // Re-presenting a report that is already linked changes nothing.
      await suspend("report", "multi@nyu.edu", second.reportId);
      expect((await Suspension.findById(created.suspensionId).lean())?.reportIds).toHaveLength(2);
    });

    it("lets every linked report close with a truthful suspension outcome", async () => {
      const first = await openCase("truth@nyu.edu");
      const second = await openCase("truth@nyu.edu");
      const { suspensionId } = await suspend("report", "truth@nyu.edu", first.reportId);
      await suspend("report", "truth@nyu.edu", second.reportId);

      await expect(close(first.reportId, "participant-suspended", T)).resolves.toEqual({ status: "closed" });
      await expect(
        close(second.reportId, "request-removed-and-participant-suspended", plusDays(T, 1))
      ).resolves.toEqual({ status: "closed" });

      expect((await ModerationReport.findById(second.reportId).lean())?.outcome).toBe(
        "request-removed-and-participant-suspended"
      );
      // Everything stays held while the one suspension is active.
      expect(await clocks(first.reportId, suspensionId)).toEqual({
        caseHistory: undefined,
        caseEvidence: undefined,
        suspensionHistory: undefined,
        rationale: undefined,
      });
      expect(await clocks(second.reportId)).toEqual({ caseHistory: undefined, caseEvidence: undefined });

      const L = at("2026-05-01T00:00:00Z");
      await lift(suspensionId, L);
      for (const reportId of [first.reportId, second.reportId]) {
        expect(await clocks(reportId)).toEqual({ caseHistory: plusYear(L), caseEvidence: plusDays(L, 90) });
      }
      expect(await clocks(undefined, suspensionId)).toEqual({
        suspensionHistory: plusYear(L),
        rationale: plusDays(L, 90),
      });
    });

    it("holds the suspension's evidence until the last linked report closes", async () => {
      const first = await openCase("last@nyu.edu");
      const second = await openCase("last@nyu.edu");
      const { suspensionId } = await suspend("report", "last@nyu.edu", first.reportId);
      await suspend("report", "last@nyu.edu", second.reportId);
      await close(first.reportId, "participant-suspended", T);
      const L = plusDays(T, 5);
      await lift(suspensionId, L);

      // First case has closed and the suspension lifted: its clocks start. The
      // second is still Open, so the suspension's own evidence is still held.
      expect(await clocks(first.reportId)).toEqual({
        caseHistory: plusYear(L),
        caseEvidence: plusDays(L, 90),
      });
      expect(await clocks(second.reportId)).toEqual({ caseHistory: undefined, caseEvidence: undefined });
      expect(await clocks(undefined, suspensionId)).toEqual({
        suspensionHistory: undefined,
        rationale: undefined,
      });

      const C2 = plusDays(T, 20);
      await close(second.reportId, "no-action", C2);
      expect(await clocks(second.reportId)).toEqual({
        caseHistory: plusYear(C2),
        caseEvidence: plusDays(C2, 90),
      });
      expect(await clocks(undefined, suspensionId)).toEqual({
        suspensionHistory: plusYear(C2),
        rationale: plusDays(C2, 90),
      });
    });

    it("links a report to an Active manual suspension and keeps its manual origin", async () => {
      const manual = await suspend("manual", "manual.then.report@nyu.edu");
      const report = await openCase("manual.then.report@nyu.edu");
      const linked = await suspend("report", "manual.then.report@nyu.edu", report.reportId);
      expect(linked).toMatchObject({ created: false });
      expect(String(linked.suspensionId)).toBe(String(manual.suspensionId));
      expect(await Suspension.findById(manual.suspensionId).lean()).toMatchObject({ origin: "manual" });
      await expect(close(report.reportId, "participant-suspended", T)).resolves.toEqual({
        status: "closed",
      });
    });

    it("links two reports racing for the same participant to exactly one suspension", async () => {
      for (let attempt = 0; attempt < 8; attempt += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        const email = `racemulti${attempt}@nyu.edu`;
        const first = await openCase(email);
        const second = await openCase(email);
        await Promise.all([
          suspend("report", email, first.reportId),
          suspend("report", email, second.reportId),
        ]);
        expect(await Suspension.countDocuments({ state: "active" }), `attempt ${attempt}`).toBe(1);
        expect(await SuspensionRationale.countDocuments()).toBe(1);
        const row = await Suspension.findOne({}).lean();
        expect(row?.reportIds, `attempt ${attempt}`).toHaveLength(2);
      }
    }, 60_000);

    it("still refuses a suspension outcome for a report no suspension is linked to", async () => {
      const first = await openCase("unlinked@nyu.edu");
      const second = await openCase("unlinked@nyu.edu");
      await suspend("report", "unlinked@nyu.edu", first.reportId);
      await expect(close(second.reportId, "participant-suspended", T)).rejects.toMatchObject({
        code: "suspension-required",
      });
    });
  });

  describe("the suspension rationale (F9)", () => {
    it("trims what it stores", async () => {
      const { suspensionId } = await runModerationTransaction((session) =>
        recordSuspension(session, {
          keyring,
          suspendedEmail: "trim@nyu.edu",
          origin: "manual",
          rationale: "  Verified safety concern.\n ",
        })
      );
      expect((await SuspensionRationale.findOne({ suspensionId }).lean())?.text).toBe(
        "Verified safety concern."
      );
    });

    it.each(["", "   ", "\n\t ", undefined, null, 42])(
      "refuses %j before any write, creating no identity or suspension",
      async (rationale) => {
        await expect(
          runModerationTransaction((session) =>
            recordSuspension(session, {
              keyring,
              suspendedEmail: "blank@nyu.edu",
              origin: "manual",
              rationale: rationale as never,
            })
          )
        ).rejects.toMatchObject({ code: "invalid-rationale" });
        expect(await Suspension.countDocuments()).toBe(0);
        expect(await SuspensionRationale.countDocuments()).toBe(0);
        expect(await SafetyIdentity.countDocuments()).toBe(0);
      }
    );

    it("refuses a rationale over the limit after trimming", async () => {
      await expect(
        runModerationTransaction((session) =>
          recordSuspension(session, {
            keyring,
            suspendedEmail: "long@nyu.edu",
            origin: "manual",
            rationale: " " + "x".repeat(1001),
          })
        )
      ).rejects.toMatchObject({ code: "invalid-rationale" });
      await expect(
        runModerationTransaction((session) =>
          recordSuspension(session, {
            keyring,
            suspendedEmail: "limit@nyu.edu",
            origin: "manual",
            rationale: "x".repeat(1000),
          })
        )
      ).resolves.toMatchObject({ created: true });
    });

    it("rejects a blank rationale at the persistence boundary as well", async () => {
      const suspension = await Suspension.create({ origin: "manual", safetyIdentityRef: new mongoose.Types.ObjectId() });
      await expect(
        SuspensionRationale.create({ suspensionId: suspension._id, text: "   " })
      ).rejects.toThrow();
      expect(await SuspensionRationale.countDocuments()).toBe(0);
    });
  });

  describe("atomicity under injected failure", () => {
    const T = at("2026-03-01T00:00:00Z");

    it("a failed audit leaves a closing case exactly as it was", async () => {
      const { reportId } = await openCase();
      vi.mocked(appendSubjectAudit).mockRejectedValueOnce(new Error("audit store unavailable"));
      await expect(close(reportId, "no-action", T)).rejects.toThrow("audit store unavailable");

      expect(await ModerationReport.findById(reportId).lean()).toMatchObject({ state: "open" });
      expect((await ModerationReport.findById(reportId).lean())?.closedAt).toBeUndefined();
      expect(await clocks(reportId)).toEqual({ caseHistory: undefined, caseEvidence: undefined });
      // No state with a detached identity and no live reference.
      expect((await ModerationReport.findById(reportId).lean())?.safetyIdentityRef).toBeDefined();
      expect(await SafetyIdentity.countDocuments()).toBe(1);
      expect(await ModerationAuditEvent.countDocuments({ kind: "report-closed" })).toBe(0);

      // Retrying after the failure succeeds from a clean state.
      expect((await close(reportId, "no-action", T)).status).toBe("closed");
    });

    it("a failure between the conditional update and the clock write rolls the whole closure back", async () => {
      const { reportId } = await openCase();
      vi.mocked(recomputeCaseClocks).mockRejectedValueOnce(new Error("clock write failed"));
      await expect(close(reportId, "no-action", T)).rejects.toThrow("clock write failed");

      const row = await ModerationReport.findById(reportId).lean();
      expect(row).toMatchObject({ state: "open" });
      expect(row?.outcome).toBeUndefined();
      expect(row?.safetyIdentityRef).toBeDefined();
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });

    it("a failed audit leaves a lifting suspension Active with its identity attached", async () => {
      const { suspensionId } = await suspend("manual");
      vi.mocked(appendSubjectAudit).mockRejectedValueOnce(new Error("audit store unavailable"));
      await expect(lift(suspensionId, T)).rejects.toThrow("audit store unavailable");

      const row = await Suspension.findById(suspensionId).lean();
      expect(row).toMatchObject({ state: "active" });
      expect(row?.safetyIdentityRef).toBeDefined();
      expect(row?.liftedAt).toBeUndefined();
      expect(await clocks(undefined, suspensionId)).toEqual({
        suspensionHistory: undefined,
        rationale: undefined,
      });
    });

    it("a failure writing the suspension clocks rolls the lift back", async () => {
      const { suspensionId } = await suspend("manual");
      vi.mocked(recomputeSuspensionClocks).mockRejectedValueOnce(new Error("clock write failed"));
      await expect(lift(suspensionId, T)).rejects.toThrow("clock write failed");
      expect(await Suspension.findById(suspensionId).lean()).toMatchObject({ state: "active" });
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });

    it("a failed audit creates no case, no evidence and no identity", async () => {
      vi.mocked(appendSubjectAudit).mockRejectedValueOnce(new Error("audit store unavailable"));
      await expect(openCase("new@nyu.edu")).rejects.toThrow("audit store unavailable");
      expect(await ModerationReport.countDocuments()).toBe(0);
      expect(await ReportEvidence.countDocuments()).toBe(0);
      expect(await SafetyIdentity.countDocuments()).toBe(0);
    });

    it("a failed audit creates no suspension, no rationale and no identity", async () => {
      vi.mocked(appendSubjectAudit).mockRejectedValueOnce(new Error("audit store unavailable"));
      await expect(suspend("manual", "new@nyu.edu")).rejects.toThrow("audit store unavailable");
      expect(await Suspension.countDocuments()).toBe(0);
      expect(await SuspensionRationale.countDocuments()).toBe(0);
      expect(await SafetyIdentity.countDocuments()).toBe(0);
    });

    it("a failed audit rolls back hold creation and leaves the target's clocks alone", async () => {
      const { reportId } = await openCase();
      await close(reportId, "no-action", T);
      const before = await clocks(reportId);
      vi.mocked(appendSubjectAudit).mockRejectedValueOnce(new Error("audit store unavailable"));
      await expect(
        runModerationTransaction((session) =>
          createRetentionHold(
            session,
            {
              targetKind: "case",
              targetId: reportId,
              holdClass: "legal-preservation",
              reasonCode: "legal-preservation",
              endingCondition: "Counsel withdraws the preservation request.",
              reviewAt: plusDays(T, 30),
            },
            plusDays(T, 1)
          )
        )
      ).rejects.toThrow("audit store unavailable");
      expect(await RetentionHold.countDocuments()).toBe(0);
      expect(await clocks(reportId)).toEqual(before);
    });
  });

  describe("audit and history content", () => {
    it("records references and kinds only: no email, text, reporter or participant ID", async () => {
      const { reportId } = await openCase("audit.subject@nyu.edu");
      const { suspensionId } = await suspend("report", "audit.subject@nyu.edu", reportId);
      await close(reportId, "participant-suspended", at("2026-03-01T00:00:00Z"));
      await lift(suspensionId, at("2026-04-01T00:00:00Z"));

      const events = await ModerationAuditEvent.collection.find({}).toArray();
      expect(events.map((e) => e.kind).sort()).toEqual([
        "report-closed",
        "report-created",
        "suspension-created",
        "suspension-lifted",
      ]);
      for (const event of events) {
        expect(Object.keys(event).sort()).toEqual(
          ["__v", "_id", "createdAt", "kind", "subjectId", "subjectKind"].sort()
        );
        // Cascading events carry no clock of their own.
        expect(event.deleteAt).toBeUndefined();
      }

      // The minimal rows hold no reporter, email or text once closed and lifted.
      const report = await ModerationReport.collection.findOne({ _id: reportId });
      const suspension = await Suspension.collection.findOne({ _id: suspensionId });
      for (const row of [report, suspension]) {
        const text = JSON.stringify(row);
        expect(text).not.toContain("nyu.edu");
        expect(text).not.toContain("Private rationale");
        expect(row!.safetyIdentityRef).toBeUndefined();
      }
      expect(Object.keys(report!).sort()).toEqual(
        [
          "__v",
          "_id",
          "alertStatus",
          "closedAt",
          "createdAt",
          "deleteAt",
          "origin",
          "outcome",
          "ref",
          "state",
        ].sort()
      );
    });

    it("reads treat a record past its deleteAt as absent while the row still exists", async () => {
      const { reportId } = await openCase();
      await close(reportId, "no-action", at("2026-03-01T00:00:00Z"));
      const when = at("2026-03-01T00:00:00Z");

      const stillThere = await ModerationReport.find({ _id: reportId, ...notPastDeleteAt(when) }).lean();
      expect(stillThere).toHaveLength(1);

      const afterDeadline = plusYear(when);
      afterDeadline.setUTCDate(afterDeadline.getUTCDate() + 1);
      expect(await ModerationReport.countDocuments({ _id: reportId })).toBe(1);
      expect(
        await ModerationReport.find({ _id: reportId, ...notPastDeleteAt(afterDeadline) }).lean()
      ).toHaveLength(0);
    });
  });
});
