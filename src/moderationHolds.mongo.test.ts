import mongoose, { type ClientSession } from "mongoose";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  MODERATION_MODELS,
  ModerationAuditEvent,
  ModerationReport,
  ReportEvidence,
  RetentionHold,
  SafetyIdentity,
  establishModerationIndexes,
} from "../models/moderation.js";
import { DAY_MS } from "./moderationConstants.js";
import {
  RetentionHoldRefusal,
  createRetentionHold,
  raiseHoldReviewPrompt,
  releaseRetentionHold,
  reviewRetentionHold,
  type CreateRetentionHoldInput,
} from "./moderationHolds.js";
import {
  closeReportCase,
  getClosureOverlapIndicator,
  liftSuspension,
  recordReportCase,
  recordSuspension,
} from "./moderationRecords.js";
import { runModerationTransaction } from "./safetyIdentity.js";
import {
  SAFETY_IDENTITY_KEYRING_ENV,
  readSafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_moderation_holds`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const keyring = readSafetyIdentityKeyring({
  [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
    current: "k1",
    keys: { k1: Buffer.alloc(32, 0x41).toString("base64url") },
  }),
});

const T = new Date("2026-03-01T00:00:00Z");
const plusDays = (date: Date, days: number) => new Date(date.getTime() + days * DAY_MS);

const openCase = (email = "held@nyu.edu") =>
  runModerationTransaction((session) =>
    recordReportCase(session, {
      keyring,
      reportedEmail: email,
      snapshot: {
        requestId: new mongoose.Types.ObjectId(),
        reportedRole: "helper",
        requestStatus: "claimed",
        food: "soup",
      },
      reason: "Other concern",
    })
  );

const close = (reportId: mongoose.Types.ObjectId, when: Date) =>
  runModerationTransaction((session) =>
    closeReportCase(
      session,
      { reportId, outcome: "no-action", enforcementApplied: true, keyring },
      when
    )
  );

const baseHold = (
  targetId: mongoose.Types.ObjectId,
  overrides: Partial<CreateRetentionHoldInput> = {}
): CreateRetentionHoldInput => ({
  targetKind: "case",
  targetId,
  holdClass: "legal-preservation",
  reasonCode: "legal-preservation",
  note: "Counsel requested preservation.",
  endingCondition: "Counsel confirms the preservation request is withdrawn.",
  reviewAt: plusDays(T, 60),
  ...overrides,
});

const create = (input: CreateRetentionHoldInput, when = T) =>
  runModerationTransaction((session) => createRetentionHold(session, input, when));

describeMongo("retention holds (real MongoDB)", () => {
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

  describe("creation requires a reason, an ending condition and a review date", () => {
    it.each([
      ["a missing reason code", { reasonCode: "" }, "invalid-reason-code"],
      ["a reason code that is free text", { reasonCode: "Because I said so" }, "invalid-reason-code"],
      ["a missing ending condition", { endingCondition: "" }, "invalid-ending-condition"],
      ["a whitespace ending condition", { endingCondition: "   " }, "invalid-ending-condition"],
      ["an over-long ending condition", { endingCondition: "x".repeat(301) }, "invalid-ending-condition"],
      ["an over-long note", { note: "x".repeat(501) }, "invalid-note"],
      ["a reviewAt already past", { reviewAt: plusDays(T, -1) }, "invalid-review-at"],
      ["a reviewAt equal to now", { reviewAt: T }, "invalid-review-at"],
      ["a reviewAt over 90 days away", { reviewAt: plusDays(T, 91) }, "invalid-review-at"],
      ["an invalid reviewAt", { reviewAt: new Date("nope") }, "invalid-review-at"],
      [
        "an overlapping-case hold with no related case",
        { holdClass: "overlapping-case" as const },
        "related-case-required",
      ],
    ] as const)("rejects %s and writes nothing", async (_label, overrides, code) => {
      const { reportId } = await openCase();
      await expect(create(baseHold(reportId, overrides as never))).rejects.toMatchObject({ code });
      expect(await RetentionHold.countDocuments()).toBe(0);
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-created" })).toBe(0);
    });

    it("rejects a missing reviewAt", async () => {
      const { reportId } = await openCase();
      const input = baseHold(reportId) as Partial<CreateRetentionHoldInput>;
      delete input.reviewAt;
      await expect(create(input as CreateRetentionHoldInput)).rejects.toBeInstanceOf(RetentionHoldRefusal);
    });

    it("accepts a reviewAt exactly 90 days away", async () => {
      const { reportId } = await openCase();
      await expect(create(baseHold(reportId, { reviewAt: plusDays(T, 90) }))).resolves.toBeDefined();
    });

    it("refuses a target that does not exist or is already past its deadline", async () => {
      await expect(create(baseHold(new mongoose.Types.ObjectId()))).rejects.toMatchObject({
        code: "target-not-found",
      });

      const { reportId } = await openCase();
      await close(reportId, T);
      // The base deadline passed; a read treats the row as absent, so no hold can rescue it.
      await expect(create(baseHold(reportId, { reviewAt: plusDays(T, 500) }), plusDays(T, 470))).rejects.toMatchObject({
        code: "target-not-found",
      });
    });
  });

  describe("review is an audited re-set, never a release or a silent extension", () => {
    it("moves reviewAt, keeps the reason and ending condition, clears the prompt and audits", async () => {
      const { reportId } = await openCase();
      const { holdId } = await create(baseHold(reportId));
      await RetentionHold.updateOne({ _id: holdId }, { $set: { reviewPromptRaisedAt: T } });

      const reviewedAt = plusDays(T, 61);
      await runModerationTransaction((s) =>
        reviewRetentionHold(s, holdId, plusDays(reviewedAt, 45), reviewedAt)
      );

      const row = await RetentionHold.findById(holdId).lean();
      expect(row).toMatchObject({
        state: "active",
        reasonCode: "legal-preservation",
        endingCondition: "Counsel confirms the preservation request is withdrawn.",
      });
      expect(row?.reviewAt).toEqual(plusDays(reviewedAt, 45));
      expect(row?.lastReviewedAt).toEqual(reviewedAt);
      expect(row?.reviewPromptRaisedAt).toBeUndefined();
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-reviewed" })).toBe(1);
    });

    it("refuses a review beyond 90 days, of a released hold, and of a missing hold", async () => {
      const { reportId } = await openCase();
      const { holdId } = await create(baseHold(reportId));
      await expect(
        runModerationTransaction((s) => reviewRetentionHold(s, holdId, plusDays(T, 200), T))
      ).rejects.toMatchObject({ code: "invalid-review-at" });

      await runModerationTransaction((s) =>
        releaseRetentionHold(s, holdId, { endingConditionMet: true }, plusDays(T, 5), keyring)
      );
      await expect(
        runModerationTransaction((s) => reviewRetentionHold(s, holdId, plusDays(T, 40), plusDays(T, 6)))
      ).rejects.toMatchObject({ code: "not-active" });
      await expect(
        runModerationTransaction((s) =>
          reviewRetentionHold(s, new mongoose.Types.ObjectId(), plusDays(T, 40), T)
        )
      ).rejects.toMatchObject({ code: "not-active" });
    });
  });

  describe("a passed reviewAt raises a prompt and releases nothing", () => {
    it("never releases, never deletes, and raises its prompt once", async () => {
      const { reportId } = await openCase();
      await close(reportId, T);
      const { holdId } = await create(baseHold(reportId), plusDays(T, 1));

      // Ten years later: far past reviewAt, the base deadline and any plausible clock.
      const farFuture = plusDays(T, 3650);
      const first = await runModerationTransaction((s) => raiseHoldReviewPrompt(s, holdId, farFuture));
      const second = await runModerationTransaction((s) => raiseHoldReviewPrompt(s, holdId, farFuture));
      expect([first, second]).toEqual([true, false]);

      const hold = await RetentionHold.findById(holdId).lean();
      expect(hold).toMatchObject({ state: "active" });
      expect(hold?.reviewPromptRaisedAt).toEqual(farFuture);
      expect(hold?.endedAt).toBeUndefined();
      expect(hold?.deleteAt).toBeUndefined();

      // The held target is untouched: no deadline appeared.
      expect((await ModerationReport.findById(reportId).lean())?.deleteAt).toBeUndefined();
      expect((await ReportEvidence.find({ reportId }).lean()).every((row) => !row.deleteAt)).toBe(true);
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-review-prompted" })).toBe(1);
    });

    it("does not prompt before reviewAt", async () => {
      const { reportId } = await openCase();
      const { holdId } = await create(baseHold(reportId));
      expect(await runModerationTransaction((s) => raiseHoldReviewPrompt(s, holdId, plusDays(T, 59)))).toBe(false);
    });
  });

  describe("release is an explicit, audited act", () => {
    const release = (holdId: mongoose.Types.ObjectId, when: Date, endingConditionMet: unknown = true) =>
      runModerationTransaction((s) =>
        releaseRetentionHold(s, holdId, { endingConditionMet } as never, when, keyring)
      );

    it("refuses without the ending-condition assertion, however late", async () => {
      const { reportId } = await openCase();
      const { holdId } = await create(baseHold(reportId));
      for (const claim of [false, null, "true", 1]) {
        await expect(release(holdId, plusDays(T, 4000), claim)).rejects.toMatchObject({ code: "ending-condition-not-met" });
      }
      expect(await RetentionHold.findById(holdId).lean()).toMatchObject({ state: "active" });
    });

    it("releases once, records its end and basis, audits, and schedules the row's own deletion", async () => {
      const { reportId } = await openCase();
      const { holdId } = await create(baseHold(reportId));
      const at = plusDays(T, 20);
      await release(holdId, at);
      await expect(release(holdId, plusDays(at, 1))).rejects.toMatchObject({ code: "not-active" });

      const row = await RetentionHold.findById(holdId).lean();
      expect(row).toMatchObject({ state: "released", releaseBasis: "ending-condition-met" });
      expect(row?.endedAt).toEqual(at);
      expect(row?.deleteAt).toEqual(plusDays(at, 90));
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-released" })).toBe(1);
    });

    it("lets two concurrent releases resolve to one winner", async () => {
      const { reportId } = await openCase();
      const { holdId } = await create(baseHold(reportId));
      const results = await Promise.allSettled([release(holdId, plusDays(T, 2)), release(holdId, plusDays(T, 3))]);
      expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(1);
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-released" })).toBe(1);
    });
  });

  describe("structural holds are state, not rows", () => {
    it("holds an Open case and an Active suspension with no hold row and no deadline", async () => {
      const { reportId } = await openCase("structural@nyu.edu");
      const { suspensionId } = await runModerationTransaction((s) =>
        recordSuspension(s, {
          keyring,
          suspendedEmail: "other.structural@nyu.edu",
          origin: "manual",
          rationale: "Private rationale.",
        })
      );
      expect(await RetentionHold.countDocuments()).toBe(0);
      expect((await ModerationReport.findById(reportId).lean())?.deleteAt).toBeUndefined();
      expect((await mongoose.connection.collection("suspensions").findOne({ _id: suspensionId }))?.deleteAt).toBeUndefined();
    });
  });

  describe("identity-bearing holds", () => {
    it("keeps the identity through closure and releases it with the hold", async () => {
      const { reportId, identityId } = await openCase("keep@nyu.edu");
      const { holdId } = await create(baseHold(reportId, { keepSafetyIdentity: true }));
      await close(reportId, plusDays(T, 3));
      expect(await SafetyIdentity.countDocuments()).toBe(1);

      await runModerationTransaction((s) =>
        releaseRetentionHold(s, holdId, { endingConditionMet: true }, plusDays(T, 30), keyring)
      );
      expect(await SafetyIdentity.findById(identityId).lean()).toBeNull();
      expect((await RetentionHold.findById(holdId).lean())?.safetyIdentityRef).toBeUndefined();
    });

    it("cannot keep an identity the case already detached (a released identity is not recreatable)", async () => {
      const { reportId } = await openCase("late@nyu.edu");
      await close(reportId, T);
      await expect(
        create(baseHold(reportId, { keepSafetyIdentity: true }), plusDays(T, 1))
      ).rejects.toMatchObject({ code: "identity-detached" });
      expect(await RetentionHold.countDocuments()).toBe(0);
    });

    it("releases the identity at hold release only when nothing else references it", async () => {
      const { reportId } = await openCase("shared@nyu.edu");
      await openCase("shared@nyu.edu"); // a second Open report on the same identity
      const { holdId } = await create(baseHold(reportId, { keepSafetyIdentity: true }));
      await close(reportId, T);
      await runModerationTransaction((s) =>
        releaseRetentionHold(s, holdId, { endingConditionMet: true }, plusDays(T, 10), keyring)
      );
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });
  });

  describe("attaching a hold to an identity serializes on the identity record", () => {
    const isWriteConflict = (error: unknown) =>
      (error as { codeName?: string })?.codeName === "WriteConflict" ||
      (error as { hasErrorLabel?: (l: string) => boolean })?.hasErrorLabel?.("TransientTransactionError") === true;

    /** `second` runs while `first`'s writes are uncommitted; returns the loser's error, if any. */
    async function interleave(
      first: (session: ClientSession) => Promise<unknown>,
      second: (session: ClientSession) => Promise<unknown>
    ) {
      const a = await mongoose.startSession();
      const b = await mongoose.startSession();
      try {
        a.startTransaction();
        b.startTransaction();
        await first(a);
        let failure: unknown;
        try {
          await second(b);
        } catch (error) {
          failure = error;
        }
        await a.commitTransaction();
        if (failure) await b.abortTransaction();
        else await b.commitTransaction();
        return failure;
      } finally {
        await a.endSession();
        await b.endSession();
      }
    }

    const keepHold = (targetKind: "case" | "suspension", targetId: mongoose.Types.ObjectId) =>
      baseHold(targetId, { targetKind, keepSafetyIdentity: true });

    it("conflicts with a concurrent report closure that releases the identity", async () => {
      const { reportId, identityId } = await openCase("attach.close@nyu.edu");
      const failure = await interleave(
        (s) => closeReportCase(s, { reportId, outcome: "no-action", enforcementApplied: true, keyring }, plusDays(T, 1)),
        (s) => createRetentionHold(s, keepHold("case", reportId), T)
      );
      expect(isWriteConflict(failure)).toBe(true);
      // The closure won and released the identity; no hold was created on it.
      expect(await SafetyIdentity.findById(identityId).lean()).toBeNull();
      expect(await RetentionHold.countDocuments()).toBe(0);
    });

    it("conflicts the other way: a closure begun after the hold is attached keeps the identity", async () => {
      const { reportId, identityId } = await openCase("attach.first@nyu.edu");
      const failure = await interleave(
        (s) => createRetentionHold(s, keepHold("case", reportId), T),
        (s) => closeReportCase(s, { reportId, outcome: "no-action", enforcementApplied: true, keyring }, plusDays(T, 1))
      );
      expect(isWriteConflict(failure)).toBe(true);
      expect(await RetentionHold.countDocuments({ safetyIdentityRef: identityId })).toBe(1);
      expect(await SafetyIdentity.findById(identityId).lean()).not.toBeNull();
      // Replayed against the committed hold, the closure now finds the identity referenced.
      await close(reportId, plusDays(T, 1));
      expect(await SafetyIdentity.findById(identityId).lean()).not.toBeNull();
    });

    it("conflicts with a concurrent suspension lift that releases the identity", async () => {
      const { suspensionId, identityId } = await runModerationTransaction((s) =>
        recordSuspension(s, { keyring, suspendedEmail: "attach.lift@nyu.edu", origin: "manual", rationale: "Private rationale." })
      );
      const failure = await interleave(
        (s) => liftSuspension(s, { suspensionId, keyring }, plusDays(T, 1)),
        (s) => createRetentionHold(s, keepHold("suspension", suspensionId), T)
      );
      expect(isWriteConflict(failure)).toBe(true);
      expect(await SafetyIdentity.findById(identityId).lean()).toBeNull();
      expect(await RetentionHold.countDocuments()).toBe(0);
    });

    it("conflicts the other way for a lift begun after the hold is attached", async () => {
      const { suspensionId, identityId } = await runModerationTransaction((s) =>
        recordSuspension(s, { keyring, suspendedEmail: "attach.lift2@nyu.edu", origin: "manual", rationale: "Private rationale." })
      );
      const failure = await interleave(
        (s) => createRetentionHold(s, keepHold("suspension", suspensionId), T),
        (s) => liftSuspension(s, { suspensionId, keyring }, plusDays(T, 1))
      );
      expect(isWriteConflict(failure)).toBe(true);
      expect(await RetentionHold.countDocuments({ safetyIdentityRef: identityId })).toBe(1);
      expect(await SafetyIdentity.findById(identityId).lean()).not.toBeNull();
    });

    it("never leaves an active hold on a missing identity when creation races closure", async () => {
      for (let attempt = 0; attempt < 15; attempt += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        const { reportId } = await openCase(`holdrace${attempt}@nyu.edu`);
        const outcomes = await Promise.allSettled([
          close(reportId, plusDays(T, 1)),
          create(keepHold("case", reportId), T),
        ]);
        for (const hold of await RetentionHold.find({ state: "active" }).lean()) {
          expect(hold.safetyIdentityRef, `attempt ${attempt}`).toBeDefined();
          expect(await SafetyIdentity.findById(hold.safetyIdentityRef).lean(), `attempt ${attempt}`).not.toBeNull();
        }
        // Either the hold won (and pins the identity) or it was refused as detached.
        const created = outcomes[1].status === "fulfilled";
        expect(await RetentionHold.countDocuments()).toBe(created ? 1 : 0);
        if (!created) {
          expect((outcomes[1] as PromiseRejectedResult).reason).toMatchObject({ code: "identity-detached" });
        }
      }
    }, 90_000);

    it("never leaves an active hold on a missing identity when creation races a lift", async () => {
      for (let attempt = 0; attempt < 15; attempt += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        const { suspensionId } = await runModerationTransaction((s) =>
          recordSuspension(s, { keyring, suspendedEmail: `liftrace${attempt}@nyu.edu`, origin: "manual", rationale: "Private rationale." })
        );
        const outcomes = await Promise.allSettled([
          runModerationTransaction((s) => liftSuspension(s, { suspensionId, keyring }, plusDays(T, 1))),
          create(keepHold("suspension", suspensionId), T),
        ]);
        for (const hold of await RetentionHold.find({ state: "active" }).lean()) {
          expect(await SafetyIdentity.findById(hold.safetyIdentityRef).lean(), `attempt ${attempt}`).not.toBeNull();
        }
        const created = outcomes[1].status === "fulfilled";
        expect(await RetentionHold.countDocuments()).toBe(created ? 1 : 0);
        if (!created) {
          expect((outcomes[1] as PromiseRejectedResult).reason).toMatchObject({ code: "identity-detached" });
        }
      }
    }, 90_000);

    it("refuses and rolls back when the target's identity no longer exists", async () => {
      const { reportId, identityId } = await openCase("stale.identity@nyu.edu");
      // A stale reference: the identity record is gone though the case still names it.
      await SafetyIdentity.deleteOne({ _id: identityId });
      const events = await ModerationAuditEvent.countDocuments({ kind: "hold-created" });

      await expect(create(keepHold("case", reportId))).rejects.toMatchObject({ code: "identity-detached" });

      expect(await RetentionHold.countDocuments()).toBe(0);
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-created" })).toBe(events);
      expect((await ModerationReport.findById(reportId).lean())?.deleteAt).toBeUndefined();
    });

    it("rolls back the identity bump and the hold together if a later step fails", async () => {
      const { reportId, identityId } = await openCase("rollback@nyu.edu");
      const before = (await SafetyIdentity.findById(identityId).lean())?.serial;
      await expect(
        runModerationTransaction(async (s) => {
          await createRetentionHold(s, keepHold("case", reportId), T);
          throw new Error("later step failed");
        })
      ).rejects.toThrow("later step failed");
      expect(await RetentionHold.countDocuments()).toBe(0);
      expect((await SafetyIdentity.findById(identityId).lean())?.serial).toBe(before);
    });

    it("leaves hold-release authority and retention deadlines as they were", async () => {
      const { reportId, identityId } = await openCase("authority@nyu.edu");
      const { holdId } = await create(keepHold("case", reportId));
      await close(reportId, plusDays(T, 3));
      // Held: no deadline appears, the identity is pinned, and only an explicit release ends it.
      expect((await ModerationReport.findById(reportId).lean())?.deleteAt).toBeUndefined();
      await expect(
        runModerationTransaction((s) =>
          releaseRetentionHold(s, holdId, { endingConditionMet: false } as never, plusDays(T, 400), keyring)
        )
      ).rejects.toMatchObject({ code: "ending-condition-not-met" });
      const released = plusDays(T, 30);
      await runModerationTransaction((s) =>
        releaseRetentionHold(s, holdId, { endingConditionMet: true }, released, keyring)
      );
      expect(await SafetyIdentity.findById(identityId).lean()).toBeNull();
      expect((await ModerationReport.findById(reportId).lean())?.deleteAt).toEqual(
        new Date(Date.UTC(2027, 2, 4))
      );
    });
  });

  describe("an overlapping-case hold", () => {
    it("ends with the related case's closure, which is Faith's own audited act", async () => {
      const first = await openCase("overlap@nyu.edu");
      await close(first.reportId, T);
      const second = await openCase("overlap@nyu.edu");

      const { holdId } = await create(
        baseHold(first.reportId, {
          holdClass: "overlapping-case",
          reasonCode: "overlapping-case",
          relatedReportId: second.reportId,
          endingCondition: "The related open case is closed.",
        }),
        plusDays(T, 2)
      );
      expect((await ModerationReport.findById(first.reportId).lean())?.deleteAt).toBeUndefined();

      const closure = plusDays(T, 40);
      await close(second.reportId, closure);

      const hold = await RetentionHold.findById(holdId).lean();
      expect(hold).toMatchObject({ state: "released", releaseBasis: "related-case-closed" });
      expect(hold?.endedAt).toEqual(closure);
      // The first case's clocks resume by the formula: closure + base, hold end earlier.
      expect((await ModerationReport.findById(first.reportId).lean())?.deleteAt).toEqual(
        new Date(Date.UTC(2027, 2, 1))
      );
      expect((await ReportEvidence.findOne({ reportId: first.reportId }).lean())?.deleteAt).toEqual(
        plusDays(T, 90)
      );
    });

    it("never lets a report closure release a legal-preservation hold, even one that names the case (F4)", async () => {
      const preserved = await openCase("legal@nyu.edu");
      await close(preserved.reportId, T);
      const related = await openCase("legal@nyu.edu");

      const { holdId } = await create(
        baseHold(preserved.reportId, { relatedReportId: related.reportId }),
        plusDays(T, 2)
      );
      await close(related.reportId, plusDays(T, 40));

      expect(await RetentionHold.findById(holdId).lean()).toMatchObject({
        state: "active",
        holdClass: "legal-preservation",
      });
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-released" })).toBe(0);
      expect((await ModerationReport.findById(preserved.reportId).lean())?.deleteAt).toBeUndefined();
      expect((await ReportEvidence.findOne({ reportId: preserved.reportId }).lean())?.deleteAt).toBeUndefined();

      // Only an authorized, audited release after the ending condition ends it.
      const released = plusDays(T, 120);
      await runModerationTransaction((s) =>
        releaseRetentionHold(s, holdId, { endingConditionMet: true }, released, keyring)
      );
      expect((await RetentionHold.findById(holdId).lean())?.releaseBasis).toBe("ending-condition-met");
      expect((await ReportEvidence.findOne({ reportId: preserved.reportId }).lean())?.deleteAt).toEqual(released);
    });

    it("releases only the overlapping-case hold when both classes name the closing case", async () => {
      const target = await openCase("both@nyu.edu");
      await close(target.reportId, T);
      const related = await openCase("both@nyu.edu");
      const legal = await create(
        baseHold(target.reportId, { relatedReportId: related.reportId }),
        plusDays(T, 2)
      );
      const overlap = await create(
        baseHold(target.reportId, {
          holdClass: "overlapping-case",
          reasonCode: "overlapping-case",
          relatedReportId: related.reportId,
          endingCondition: "The related open case is closed.",
        }),
        plusDays(T, 2)
      );
      await close(related.reportId, plusDays(T, 30));

      expect((await RetentionHold.findById(overlap.holdId).lean())?.state).toBe("released");
      expect((await RetentionHold.findById(legal.holdId).lean())?.state).toBe("active");
      // The legal hold alone still holds the target.
      expect((await ModerationReport.findById(target.reportId).lean())?.deleteAt).toBeUndefined();
    });

    it("shows a content-free indicator of another open case or active suspension", async () => {
      const first = await openCase("indicator@nyu.edu");
      expect(await getClosureOverlapIndicator(first.reportId)).toEqual({
        otherOpenReport: false,
        activeSuspension: false,
      });

      const second = await openCase("indicator@nyu.edu");
      expect(await getClosureOverlapIndicator(first.reportId)).toEqual({
        otherOpenReport: true,
        activeSuspension: false,
      });

      await close(second.reportId, T);
      await runModerationTransaction((s) =>
        recordSuspension(s, {
          keyring,
          suspendedEmail: "indicator@nyu.edu",
          origin: "manual",
          rationale: "Private rationale.",
        })
      );
      expect(await getClosureOverlapIndicator(first.reportId)).toEqual({
        otherOpenReport: false,
        activeSuspension: true,
      });
      // A closed case has detached its identity: nothing to indicate.
      expect(await getClosureOverlapIndicator(second.reportId)).toBeNull();
    });

    it("does not retain a closed case's evidence merely because another case is open", async () => {
      const first = await openCase("noauto@nyu.edu");
      await openCase("noauto@nyu.edu");
      await close(first.reportId, T);
      expect((await ReportEvidence.findOne({ reportId: first.reportId }).lean())?.deleteAt).toEqual(
        plusDays(T, 90)
      );
    });
  });
});
