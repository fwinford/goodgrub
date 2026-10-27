import { execFile, spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createConnection, createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  MODERATION_MODELS,
  ModerationAuditEvent,
  ModerationReport,
  ReportCountBinding,
  ReportEvidence,
  ReportSubmissionLedger,
  RetentionAlertState,
  RetentionHold,
  SafetyIdentity,
  Suspension,
  SuspensionRationale,
  establishModerationIndexes,
} from "../models/moderation.js";
import { DAY_MS, HOUR_MS, MINUTE_MS, REPORT_LEDGER_RETENTION_MS } from "./moderationConstants.js";
import {
  getRetentionHealth,
  runRetentionSweep,
  startRetentionSweep,
} from "./moderationRetentionSweep.js";
import { createRetentionHold } from "./moderationHolds.js";
import { closeReportCase, liftSuspension, recordReportCase, recordSuspension } from "./moderationRecords.js";
import { runModerationTransaction } from "./safetyIdentity.js";
import { deliverRetentionAlert } from "./retentionAlertDelivery.js";
import {
  SAFETY_IDENTITY_KEYRING_ENV,
  readSafetyIdentityKeyring,
  type SafetyIdentityKeyring,
  type SafetyIdentityKeyringInspection,
} from "./safetyIdentityKeyring.js";

/**
 * Deletion proof for the moderation foundation (boundary contract RH).
 *
 * This file runs against a **dedicated, throwaway single-node replica set that
 * it starts itself**, with `ttlMonitorSleepSecs=1`, instead of the runner's
 * shared instance. MongoDB's TTL monitor is server-wide, so a reduced interval
 * on the shared instance would delete other suites' expired fixtures mid-test,
 * and the default 60-second monitor would race the sweep's backstop tests. The
 * monitor is toggled with `ttlMonitorEnabled` on this private instance only:
 * - the sweep tests turn it OFF so the sweep, not the monitor, is what deletes;
 * - the monitor tests turn it ON and never run the sweep, so a disappearing row
 *   is proof the real TTL monitor did it.
 *
 * It needs `mongod` and `mongosh` on PATH, the same prerequisite as
 * `npm run test:mongo`, and runs only when `MONGO_INTEGRATION_URI` is set.
 */
const execFileAsync = promisify(execFile);
const enabled = Boolean(process.env.MONGO_INTEGRATION_URI);
const describeMongo = enabled ? describe : describe.skip;

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => (error ? reject(error) : resolve(port)));
    });
  });
}

function waitForPort(port: number, child: ChildProcess): Promise<void> {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 20_000;
    const attempt = () => {
      if (child.exitCode !== null) return reject(new Error("mongod exited early"));
      const socket = createConnection({ port, host: "127.0.0.1" }, () => {
        socket.destroy();
        resolve();
      });
      socket.once("error", () => {
        socket.destroy();
        if (Date.now() >= deadline) reject(new Error("timed out waiting for mongod"));
        else setTimeout(attempt, 100);
      });
    };
    attempt();
  });
}

let mongod: ChildProcess | undefined;
let dbPath = "";
let uri = "";

async function startDedicatedMongod(): Promise<string> {
  dbPath = await mkdtemp(path.join(tmpdir(), "commonplate-retention-"));
  const port = await freePort();
  const replicaSet = "retentionTestReplica";
  mongod = spawn(
    "mongod",
    [
      "--dbpath", dbPath,
      "--port", String(port),
      "--bind_ip", "127.0.0.1",
      "--replSet", replicaSet,
      "--setParameter", "ttlMonitorSleepSecs=1",
      "--quiet",
    ],
    { stdio: ["ignore", "ignore", "ignore"] }
  );
  await waitForPort(port, mongod);
  const admin = `mongodb://127.0.0.1:${port}/admin`;
  await execFileAsync("mongosh", [
    admin,
    "--quiet",
    "--eval",
    `rs.initiate({_id: "${replicaSet}", members: [{_id: 0, host: "127.0.0.1:${port}"}]})`,
  ]);
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      const { stdout } = await execFileAsync("mongosh", [admin, "--quiet", "--eval", "db.hello().isWritablePrimary"]);
      if (stdout.trim() === "true") break;
    } catch {
      // The single member is still electing itself.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return `mongodb://127.0.0.1:${port}/commonplate_retention?replicaSet=${replicaSet}`;
}

async function stopDedicatedMongod(): Promise<void> {
  if (mongod && mongod.exitCode === null) {
    const exited = new Promise((resolve) => mongod!.once("exit", resolve));
    mongod.kill("SIGTERM");
    await exited;
  }
  if (dbPath) await rm(dbPath, { recursive: true, force: true });
}

async function setTtlMonitor(on: boolean): Promise<void> {
  await mongoose.connection.db!.admin().command({ setParameter: 1, ttlMonitorEnabled: on });
  const result = await mongoose.connection.db!.admin().command({ getParameter: 1, ttlMonitorEnabled: 1 });
  expect(result.ttlMonitorEnabled).toBe(on);
}

const keyring = readSafetyIdentityKeyring({
  [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
    current: "k1",
    keys: { k1: Buffer.alloc(32, 0x61).toString("base64url") },
  }),
});

const ok = (ring: SafetyIdentityKeyring): SafetyIdentityKeyringInspection => ({
  state: "ok",
  keyring: ring,
});
const absent: SafetyIdentityKeyringInspection = { state: "absent", keyring: null };
const invalid: SafetyIdentityKeyringInspection = { state: "invalid", keyring: null };
const ringOf = (current: string, keys: Record<string, number>) =>
  readSafetyIdentityKeyring({
    [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
      current,
      keys: Object.fromEntries(
        Object.entries(keys).map(([keyId, byte]) => [keyId, Buffer.alloc(32, byte).toString("base64url")])
      ),
    }),
  });

const id = () => new mongoose.Types.ObjectId();
const ago = (base: Date, ms: number) => new Date(base.getTime() - ms);
const ahead = (base: Date, ms: number) => new Date(base.getTime() + ms);

/** A closed case with both evidence items, all carrying `deleteAt` (or held when null). */
async function seedClosedCase(deleteAt: Date | null) {
  const clock = deleteAt ? { deleteAt } : {};
  const report = await ModerationReport.create({
    state: "closed",
    outcome: "no-action",
    closedAt: new Date(),
    ...clock,
  });
  await ReportEvidence.create([
    {
      reportId: report._id,
      kind: "request-snapshot",
      snapshot: { requestId: id(), reportedRole: "helper", requestStatus: "claimed" },
      ...clock,
    },
    { reportId: report._id, kind: "explanation", reason: "Other concern", ...clock },
  ]);
  return report;
}

async function seedLiftedSuspension(deleteAt: Date | null) {
  const clock = deleteAt ? { deleteAt } : {};
  const suspension = await Suspension.create({
    origin: "manual",
    state: "lifted",
    liftedAt: new Date(),
    ...clock,
  });
  await SuspensionRationale.create({ suspensionId: suspension._id, text: "Private rationale.", ...clock });
  return suspension;
}

async function seedReleasedHold(targetId: mongoose.Types.ObjectId, deleteAt: Date) {
  return RetentionHold.create({
    targetKind: "case",
    targetId,
    holdClass: "legal-preservation",
    reasonCode: "legal-preservation",
    endingCondition: "Counsel withdraws the request.",
    reviewAt: new Date(),
    state: "released",
    endedAt: new Date(),
    releaseBasis: "ending-condition-met",
    deleteAt,
  });
}

const clockedAudit = (deleteAt: Date) =>
  ModerationAuditEvent.create({ kind: "moderator-authentication", deleteAt });

describeMongo("retention deletion proof on a dedicated MongoDB (real TTL monitor and sweep)", () => {
  beforeAll(async () => {
    uri = await startDedicatedMongod();
    await mongoose.connect(uri);
    await establishModerationIndexes();
  }, 90_000);

  afterAll(async () => {
    await mongoose.disconnect();
    await stopDedicatedMongod();
  }, 30_000);

  beforeEach(async () => {
    for (const model of MODERATION_MODELS) await model.deleteMany({});
  });

  describe("the sweep (the TTL monitor is off, so the sweep is what deletes)", () => {
    beforeAll(async () => {
      await setTtlMonitor(false);
    });

    afterEach(() => {
      vi.restoreAllMocks();
      vi.unstubAllEnvs();
    });

    const sweep = (now: Date, inspection: SafetyIdentityKeyringInspection = ok(keyring)) =>
      runRetentionSweep({ now: () => now, inspectKeyring: () => inspection });

    it("deletes what is overdue beyond the grace interval and nothing else", async () => {
      const base = new Date();
      const overdue = ago(base, 2 * HOUR_MS);
      const withinGrace = ago(base, 30 * 60_000);
      const future = ahead(base, 30 * DAY_MS);

      const doomedCase = await seedClosedCase(overdue);
      const graceCase = await seedClosedCase(withinGrace);
      const futureCase = await seedClosedCase(future);
      const heldOpen = await ModerationReport.create({});
      await ReportEvidence.create({
        reportId: heldOpen._id,
        kind: "explanation",
        reason: "Other concern",
      });
      const doomedSuspension = await seedLiftedSuspension(overdue);
      await seedLiftedSuspension(future);
      await seedReleasedHold(futureCase._id as mongoose.Types.ObjectId, overdue);
      await seedReleasedHold(futureCase._id as mongoose.Types.ObjectId, future);
      await clockedAudit(overdue);
      await clockedAudit(withinGrace);
      await clockedAudit(future);
      const row = (createdAt: Date, tag: string) => ({
        keyId: "k1",
        operationDigests: [tag.repeat(64)],
        participantBinding: "a".repeat(64),
        outcome: "created" as const,
        createdAt,
      });
      await ReportSubmissionLedger.create([
        row(ago(base, REPORT_LEDGER_RETENTION_MS + 2 * HOUR_MS), "1"),
        row(ago(base, REPORT_LEDGER_RETENTION_MS + 30 * 60_000), "2"),
        row(base, "3"),
      ]);
      const binding = (createdAt: Date) => ({
        keyId: "k1",
        reporterBinding: "b".repeat(64),
        requestBinding: "c".repeat(64),
        createdAt,
      });
      await ReportCountBinding.create([
        binding(ago(base, REPORT_LEDGER_RETENTION_MS + 2 * HOUR_MS)),
        binding(base),
      ]);

      const summary = await sweep(base);

      expect(summary).toMatchObject({
        status: "succeeded",
        failedSteps: [],
        deletedEvidence: 2,
        deletedCaseHistory: 1,
        deletedRationales: 1,
        deletedSuspensionHistory: 1,
        deletedHolds: 1,
        deletedAuditEvents: 1,
        deletedExpiredLedger: 1,
        deletedExpiredCountBindings: 1,
        overdueAfterDelete: 0,
        invariantViolations: 0,
      });
      expect(await ModerationReport.findById(doomedCase._id).lean()).toBeNull();
      expect(await Suspension.findById(doomedSuspension._id).lean()).toBeNull();
      // Within grace, in the future and held by live state: all untouched.
      expect(await ModerationReport.exists({ _id: graceCase._id })).not.toBeNull();
      expect(await ReportEvidence.countDocuments({ reportId: graceCase._id })).toBe(2);
      expect(await ReportEvidence.countDocuments({ reportId: futureCase._id })).toBe(2);
      expect(await ModerationReport.exists({ _id: heldOpen._id })).not.toBeNull();
      expect(await ReportEvidence.countDocuments({ reportId: heldOpen._id })).toBe(1);
      expect(await ModerationAuditEvent.countDocuments({ kind: "moderator-authentication" })).toBe(2);
      expect(await ReportSubmissionLedger.countDocuments()).toBe(2);
      expect(await ReportCountBinding.countDocuments()).toBe(1);
    });

    it("appends exactly one content-free retention-run event as proof, with a 90-day clock", async () => {
      const base = new Date();
      await seedClosedCase(ago(base, 2 * HOUR_MS));
      const summary = await sweep(base);

      const events = await ModerationAuditEvent.collection.find({ kind: "retention-run" }).toArray();
      expect(events).toHaveLength(1);
      const [event] = events;
      expect(Object.keys(event).sort()).toEqual(["__v", "_id", "createdAt", "deleteAt", "kind", "run"]);
      expect(event.deleteAt).toEqual(ago(summary.finishedAt, -90 * DAY_MS));
      // Counts, a status, timestamps and step names: nothing that can carry a reference or text.
      for (const [key, value] of Object.entries(event.run)) {
        expect(["number", "string", "object"], key).toContain(typeof value);
        if (typeof value === "string") expect(["succeeded", "failed", "ok", "absent", "invalid"]).toContain(value);
      }
      expect(JSON.stringify(event)).not.toMatch(/nyu\.edu|@|Private rationale/);
    });

    it("never releases a hold or deletes held records on a date", async () => {
      const base = new Date();
      const report = await seedClosedCase(null);
      const { holdId } = await runModerationTransaction((session) =>
        createRetentionHold(
          session,
          {
            targetKind: "case",
            targetId: report._id as mongoose.Types.ObjectId,
            holdClass: "legal-preservation",
            reasonCode: "legal-preservation",
            endingCondition: "Counsel withdraws the request.",
            reviewAt: ahead(base, 30 * DAY_MS),
          },
          base
        )
      );
      const openCase = await ModerationReport.create({});
      const farFuture = ahead(base, 3650 * DAY_MS);

      const first = await sweep(farFuture);
      const second = await sweep(farFuture);

      expect(first.holdReviewPromptsRaised).toBe(1);
      expect(second.holdReviewPromptsRaised).toBe(0);
      expect(await RetentionHold.findById(holdId).lean()).toMatchObject({ state: "active" });
      expect(await ModerationReport.exists({ _id: report._id })).not.toBeNull();
      expect(await ReportEvidence.countDocuments({ reportId: report._id })).toBe(2);
      expect(await ModerationReport.exists({ _id: openCase._id })).not.toBeNull();
      expect(first.invariantViolations).toBe(0);
      expect(first.deletedHolds + first.deletedCaseHistory + first.deletedEvidence).toBe(0);
    });

    it("raises one review prompt even when runs overlap, and deletes each overdue row once", async () => {
      const base = new Date();
      const report = await seedClosedCase(null);
      await runModerationTransaction((session) =>
        createRetentionHold(
          session,
          {
            targetKind: "case",
            targetId: report._id as mongoose.Types.ObjectId,
            holdClass: "legal-preservation",
            reasonCode: "legal-preservation",
            endingCondition: "Counsel withdraws the request.",
            reviewAt: ahead(base, DAY_MS),
          },
          base
        )
      );
      for (let i = 0; i < 6; i += 1) await seedClosedCase(ago(base, 2 * HOUR_MS));

      const later = ahead(base, 2 * DAY_MS);
      const runs = await Promise.all([sweep(later), sweep(later), sweep(later)]);

      expect(runs.every((run) => run.status === "succeeded")).toBe(true);
      expect(runs.reduce((sum, run) => sum + run.holdReviewPromptsRaised, 0)).toBe(1);
      expect(runs.reduce((sum, run) => sum + run.deletedCaseHistory, 0)).toBe(6);
      expect(runs.reduce((sum, run) => sum + run.deletedEvidence, 0)).toBe(12);
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-review-prompted" })).toBe(1);
      expect(await ModerationReport.countDocuments()).toBe(1);
    }, 30_000);

    it("cascades orphaned evidence, rationales and audit events, but not holds", async () => {
      const base = new Date();
      const parent = await seedClosedCase(ahead(base, 30 * DAY_MS));
      const suspension = await seedLiftedSuspension(ahead(base, 30 * DAY_MS));
      const hold = await seedReleasedHold(parent._id as mongoose.Types.ObjectId, ahead(base, 30 * DAY_MS));
      await ModerationAuditEvent.create([
        { kind: "report-created", subjectKind: "case", subjectId: parent._id },
        { kind: "suspension-lifted", subjectKind: "suspension", subjectId: suspension._id },
        { kind: "hold-released", subjectKind: "hold", subjectId: hold._id },
      ]);

      // The parents disappear (a TTL deletion elsewhere, or a manual repair).
      await ModerationReport.collection.deleteOne({ _id: parent._id as mongoose.Types.ObjectId });
      await Suspension.collection.deleteOne({ _id: suspension._id as mongoose.Types.ObjectId });

      const summary = await sweep(base);

      expect(summary.deletedOrphanEvidence).toBe(2);
      expect(summary.deletedOrphanRationales).toBe(1);
      // A hold is never cascaded: the released one keeps its own deadline (F5).
      expect(summary.deletedHolds).toBe(0);
      expect(summary.deletedAuditEvents).toBe(2);
      expect(await ReportEvidence.countDocuments()).toBe(0);
      expect(await SuspensionRationale.countDocuments()).toBe(0);
      expect(await RetentionHold.exists({ _id: hold._id })).not.toBeNull();
      // Only the surviving hold's own event remains.
      expect(await ModerationAuditEvent.countDocuments({ kind: { $ne: "retention-run" } })).toBe(1);
    });

    it("keeps a child whose parent is present", async () => {
      const base = new Date();
      const parent = await seedClosedCase(ahead(base, 30 * DAY_MS));
      await ModerationAuditEvent.create({ kind: "report-created", subjectKind: "case", subjectId: parent._id });
      const summary = await sweep(base);
      expect(summary.deletedOrphanEvidence).toBe(0);
      expect(await ReportEvidence.countDocuments({ reportId: parent._id })).toBe(2);
      expect(await ModerationAuditEvent.countDocuments({ kind: "report-created" })).toBe(1);
    });

    it("surfaces an invariant violation as an incident and neither deletes nor fixes it", async () => {
      const base = new Date();
      // Closed, held, and nothing live explains why.
      const unexplained = await seedClosedCase(null);
      // A live record that carries a deadline would be deleted by TTL.
      const liveWithDeadline = await ModerationReport.collection.insertOne({
        ref: "live-with-deadline",
        origin: "report",
        state: "open",
        deleteAt: ahead(base, 30 * DAY_MS),
        createdAt: base,
      });
      // Detail held while its parent carries a deadline.
      const mismatched = await ModerationReport.create({
        state: "closed",
        outcome: "no-action",
        closedAt: base,
        deleteAt: ahead(base, 30 * DAY_MS),
      });
      await ReportEvidence.create({ reportId: mismatched._id, kind: "explanation", reason: "Other concern" });

      const summary = await sweep(base);

      expect(summary.invariantViolations).toBe(3);
      expect(summary.status).toBe("succeeded");
      expect(await ModerationReport.findById(unexplained._id).lean()).toMatchObject({ state: "closed" });
      expect((await ModerationReport.findById(unexplained._id).lean())?.deleteAt).toBeUndefined();
      expect(await ModerationReport.exists({ _id: liveWithDeadline.insertedId })).not.toBeNull();
      expect(await ReportEvidence.countDocuments({ reportId: mismatched._id })).toBe(1);

      const health = await getRetentionHealth(base, ago(base, HOUR_MS));
      expect(health.invariantViolationsLastRun).toBe(3);
      expect(health.alertNeeded).toBe(true);
      expect(health.alertReasons).toContain("invariant-violation");
    });

    it("treats live state as a valid reason: a closed case with an active hold is not a violation", async () => {
      const base = new Date();
      const report = await seedClosedCase(null);
      await runModerationTransaction((session) =>
        createRetentionHold(
          session,
          {
            targetKind: "case",
            targetId: report._id as mongoose.Types.ObjectId,
            holdClass: "legal-preservation",
            reasonCode: "legal-preservation",
            endingCondition: "Counsel withdraws the request.",
            reviewAt: ahead(base, 30 * DAY_MS),
          },
          base
        )
      );
      expect((await sweep(base)).invariantViolations).toBe(0);
    });

    describe("cleanup failure", () => {
      it("leaves the record overdue, visible and retried; never extends retention or creates a hold", async () => {
        const base = new Date();
        const overdue = ago(base, 2 * HOUR_MS);
        // Evidence overdue under a parent that is not, so only the evidence class is in play.
        const stuck = await seedClosedCase(ahead(base, 30 * DAY_MS));
        await ReportEvidence.updateMany({ reportId: stuck._id }, { $set: { deleteAt: overdue } });
        const other = await seedLiftedSuspension(overdue);

        vi.spyOn(ReportEvidence, "deleteMany").mockRejectedValueOnce(new Error("delete failed"));
        const failed = await sweep(base);

        expect(failed.status).toBe("failed");
        expect(failed.failedSteps).toEqual(["evidence"]);
        // Other classes still ran; the stuck evidence is still there and still overdue.
        expect(await Suspension.exists({ _id: other._id })).toBeNull();
        expect(await ReportEvidence.countDocuments({ reportId: stuck._id })).toBe(2);
        expect(failed.overdueAfterDelete).toBeGreaterThan(0);
        // No implicit extension, no hold, no changed deadline.
        expect(await RetentionHold.countDocuments()).toBe(0);
        const evidence = await ReportEvidence.find({ reportId: stuck._id }).lean();
        expect(evidence.every((row) => row.deleteAt?.getTime() === overdue.getTime())).toBe(true);

        const health = await getRetentionHealth(base, ago(base, HOUR_MS));
        expect(health.lastRunStatus).toBe("failed");
        expect(health.overdueNow).toBeGreaterThan(0);
        expect(health.alertNeeded).toBe(true);
        expect(health.alertReasons).toEqual(expect.arrayContaining(["last-run-failed", "overdue-records"]));

        // The next run retries it and clears the incident.
        const retried = await sweep(ahead(base, HOUR_MS));
        expect(retried.status).toBe("succeeded");
        expect(await ReportEvidence.countDocuments({ reportId: stuck._id })).toBe(0);
        const recovered = await getRetentionHealth(ahead(base, HOUR_MS), ago(base, HOUR_MS));
        expect(recovered).toMatchObject({ overdueNow: 0, lastRunStatus: "succeeded", alertNeeded: false });
      });

      it("reports a stale run when no run has succeeded for three hours", async () => {
        const base = new Date();
        const boot = ago(base, 4 * HOUR_MS);
        expect(await getRetentionHealth(base, boot)).toMatchObject({
          lastSuccessAt: null,
          stale: true,
          alertNeeded: true,
        });
        expect((await getRetentionHealth(base, ago(base, HOUR_MS))).stale).toBe(false);

        await sweep(ago(base, 2 * HOUR_MS));
        const fresh = await getRetentionHealth(base, boot);
        expect(fresh.stale).toBe(false);
        expect(fresh.alertNeeded).toBe(false);

        const aged = await getRetentionHealth(ahead(base, 2 * HOUR_MS), boot);
        expect(aged.stale).toBe(true);
        expect(aged.alertReasons).toContain("stale-run");
      });

      it("surfaces an overdue record even when no run ever recorded it", async () => {
        const base = new Date();
        await seedClosedCase(ago(base, 2 * HOUR_MS));
        const health = await getRetentionHealth(base, ago(base, HOUR_MS));
        expect(health.overdueNow).toBe(3);
        expect(health.alertReasons).toContain("overdue-records");
      });

      it("propagates a failure to record proof, so the last-success clock stops advancing", async () => {
        const base = new Date();
        vi.spyOn(ModerationAuditEvent, "create").mockRejectedValueOnce(new Error("event store down"));
        await expect(sweep(base)).rejects.toThrow("event store down");
        expect(await ModerationAuditEvent.countDocuments({ kind: "retention-run" })).toBe(0);
        expect((await getRetentionHealth(ahead(base, 4 * HOUR_MS), base)).stale).toBe(true);
      });

      it("keeps the scheduled entry point total and logs an error class, never a value", async () => {
        const logged: string[] = [];
        vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
          logged.push(args.map(String).join(" "));
        });
        vi.spyOn(ModerationAuditEvent, "create").mockRejectedValueOnce(
          Object.assign(new Error("secret-value-must-not-be-logged"), { name: "MongoServerError" })
        );
        await expect(startRetentionSweep()).resolves.toBeUndefined();
        expect(logged.join("\n")).toContain("MongoServerError");
        expect(logged.join("\n")).not.toContain("secret-value-must-not-be-logged");
      });
    });

    describe("identity release retry", () => {
      it("releases an unreferenced identity through the guarded transaction", async () => {
        await SafetyIdentity.create({ entries: [{ keyId: "k1", digest: "d".repeat(64) }] });
        const summary = await sweep(new Date());
        expect(summary.identitiesReleased).toBe(1);
        expect(await SafetyIdentity.countDocuments()).toBe(0);
      });

      it("keeps and reports an unreferenced identity whose key is unavailable", async () => {
        await SafetyIdentity.create({ entries: [{ keyId: "k1", digest: "d".repeat(64) }] });
        const summary = await sweep(new Date(), absent);
        expect(summary).toMatchObject({ identitiesReleased: 0, identitiesKept: 1, status: "succeeded" });
        expect(await SafetyIdentity.countDocuments()).toBe(1);
        expect((await getRetentionHealth(new Date(), ago(new Date(), HOUR_MS))).identitiesKeptLastRun).toBe(1);
      });

      it("never releases an identity an Open report still references", async () => {
        await runModerationTransaction((session) =>
          recordReportCase(session, {
            keyring,
            reportedEmail: "sweep.open@nyu.edu",
            snapshot: { requestId: id(), reportedRole: "helper", requestStatus: "claimed" },
            reason: "Other concern",
          })
        );
        const summary = await sweep(new Date());
        expect(summary.identitiesReleased).toBe(0);
        expect(await SafetyIdentity.countDocuments()).toBe(1);
      });
    });

    describe("orphaned holds (F5)", () => {
      const activeHold = (targetKind: "case" | "suspension", targetId: mongoose.Types.ObjectId, extra = {}) =>
        RetentionHold.create({
          targetKind,
          targetId,
          holdClass: "legal-preservation",
          reasonCode: "legal-preservation",
          endingCondition: "Counsel withdraws the request.",
          reviewAt: new Date(Date.now() + 30 * DAY_MS),
          ...extra,
        });

      it("never deletes an active hold whose target is missing; it surfaces a retention incident", async () => {
        const base = new Date();
        const missingCase = await activeHold("case", id());
        const missingSuspension = await activeHold("suspension", id());

        const summary = await sweep(base);

        expect(summary.deletedHolds).toBe(0);
        expect(await RetentionHold.exists({ _id: missingCase._id })).not.toBeNull();
        expect(await RetentionHold.exists({ _id: missingSuspension._id })).not.toBeNull();
        expect(await RetentionHold.countDocuments({ state: "active" })).toBe(2);
        expect(summary.invariantViolations).toBe(2);
        const health = await getRetentionHealth(base, ago(base, HOUR_MS), ok(keyring));
        expect(health.alertReasons).toContain("invariant-violation");
      });

      it("keeps evidence and a rationale an active hold still names under a missing parent, and reports them", async () => {
        const base = new Date();
        const missingCaseId = id();
        const missingSuspensionId = id();
        await activeHold("case", missingCaseId);
        await activeHold("suspension", missingSuspensionId);
        await ReportEvidence.create({ reportId: missingCaseId, kind: "explanation", reason: "Other concern" });
        await SuspensionRationale.create({ suspensionId: missingSuspensionId, text: "Private rationale." });
        // An orphan nothing preserves is still cascaded.
        await ReportEvidence.create({ reportId: id(), kind: "explanation", reason: "Other concern" });

        const summary = await sweep(base);

        expect(summary.deletedOrphanEvidence).toBe(1);
        expect(summary.deletedOrphanRationales).toBe(0);
        expect(await ReportEvidence.countDocuments({ reportId: missingCaseId })).toBe(1);
        expect(await SuspensionRationale.countDocuments({ suspensionId: missingSuspensionId })).toBe(1);
        // Two orphan holds plus the two preserved children.
        expect(summary.invariantViolations).toBe(4);
      });

      it("keeps a released hold until its own deadline, even when its target is gone", async () => {
        const base = new Date();
        const gone = id();
        const future = await seedReleasedHold(gone, ahead(base, 30 * DAY_MS));
        const overdue = await seedReleasedHold(gone, ago(base, 2 * HOUR_MS));

        const summary = await sweep(base);

        expect(await RetentionHold.exists({ _id: future._id })).not.toBeNull();
        expect(await RetentionHold.exists({ _id: overdue._id })).toBeNull();
        expect(summary.deletedHolds).toBe(1);
        expect(summary.invariantViolations).toBe(0);
      });

      it("never releases a safety identity an active orphan hold still references", async () => {
        const base = new Date();
        const identity = await SafetyIdentity.create({ entries: [{ keyId: "k1", digest: "e".repeat(64) }] });
        await activeHold("case", id(), { safetyIdentityRef: identity._id });

        const summary = await sweep(base);

        expect(summary.identitiesReleased).toBe(0);
        expect(await SafetyIdentity.exists({ _id: identity._id })).not.toBeNull();
        expect(await RetentionHold.countDocuments({ state: "active" })).toBe(1);
      });
    });

    describe("the invariant honours a case's linked suspensions (reportIds)", () => {
      const snapshot = () => ({ requestId: id(), reportedRole: "helper" as const, requestStatus: "claimed" as const });
      const openFor = (email: string) =>
        runModerationTransaction((session) =>
          recordReportCase(session, { keyring, reportedEmail: email, snapshot: snapshot(), reason: "Other concern" })
        );
      const suspendFor = (email: string, reportId: mongoose.Types.ObjectId) =>
        runModerationTransaction((session) =>
          recordSuspension(session, {
            keyring,
            suspendedEmail: email,
            origin: "report",
            reportId,
            rationale: "Private rationale.",
          })
        );
      const closeWith = (reportId: mongoose.Types.ObjectId, outcome: Parameters<typeof closeReportCase>[1]["outcome"], when: Date) =>
        runModerationTransaction((session) =>
          closeReportCase(session, { reportId, outcome, enforcementApplied: true, keyring }, when)
        );

      it("reports zero violations for a closed case retained under its active linked suspension", async () => {
        const base = new Date();
        const report = await openFor("linked@nyu.edu");
        await suspendFor("linked@nyu.edu", report.reportId);
        await closeWith(report.reportId, "participant-suspended", base);

        // Held by live state: no deadline anywhere, and that is legitimate.
        expect((await ModerationReport.findById(report.reportId).lean())?.deleteAt).toBeUndefined();
        const summary = await sweep(base);
        expect(summary.invariantViolations).toBe(0);
        const health = await getRetentionHealth(base, ago(base, HOUR_MS), ok(keyring));
        expect(health.alertReasons).not.toContain("invariant-violation");
      });

      it("reports zero violations when several reports share one active suspension", async () => {
        const base = new Date();
        const first = await openFor("shared@nyu.edu");
        const second = await openFor("shared@nyu.edu");
        const third = await openFor("shared@nyu.edu");
        await suspendFor("shared@nyu.edu", first.reportId);
        await suspendFor("shared@nyu.edu", second.reportId);
        await suspendFor("shared@nyu.edu", third.reportId);
        await closeWith(first.reportId, "participant-suspended", base);
        await closeWith(second.reportId, "request-removed-and-participant-suspended", base);
        // The third stays Open: an Open case is held by its own state.

        expect(await Suspension.countDocuments({ state: "active" })).toBe(1);
        const summary = await sweep(base);
        expect(summary.invariantViolations).toBe(0);
        expect(summary.deletedCaseHistory + summary.deletedEvidence + summary.deletedSuspensionHistory).toBe(0);
      });

      it("reports a genuine violation for a closed case held with no suspension, hold or deadline", async () => {
        const base = new Date();
        const report = await openFor("bare@nyu.edu");
        await closeWith(report.reportId, "no-action", base);
        await ModerationReport.updateOne({ _id: report.reportId }, { $unset: { deleteAt: 1 } });

        const summary = await sweep(base);
        expect(summary.invariantViolations).toBe(1);
        // Surfaced, never deleted and never silently repaired.
        expect(await ModerationReport.exists({ _id: report.reportId })).not.toBeNull();
        expect((await ModerationReport.findById(report.reportId).lean())?.deleteAt).toBeUndefined();
        const health = await getRetentionHealth(base, ago(base, HOUR_MS), ok(keyring));
        expect(health.alertReasons).toContain("invariant-violation");
      });

      it("still reports a violation once the linked suspension has lifted but the case stays held", async () => {
        const base = new Date();
        const report = await openFor("lifted@nyu.edu");
        const { suspensionId } = await suspendFor("lifted@nyu.edu", report.reportId);
        await closeWith(report.reportId, "participant-suspended", base);
        await runModerationTransaction((session) =>
          liftSuspension(session, { suspensionId, keyring }, ahead(base, DAY_MS))
        );
        // Clocks should now exist; remove the case's to model a lost write.
        expect((await ModerationReport.findById(report.reportId).lean())?.deleteAt).toBeDefined();
        await ModerationReport.updateOne({ _id: report.reportId }, { $unset: { deleteAt: 1 } });

        expect((await sweep(ahead(base, DAY_MS))).invariantViolations).toBe(1);
      });

      it("counts only the unlinked case when its sibling is legitimately held", async () => {
        const base = new Date();
        const linked = await openFor("sibling@nyu.edu");
        await suspendFor("sibling@nyu.edu", linked.reportId);
        const unlinked = await openFor("sibling@nyu.edu");
        await closeWith(linked.reportId, "participant-suspended", base);
        await closeWith(unlinked.reportId, "no-action", base);
        // The unlinked case closed with a deadline; strip it to model the lost write.
        await ModerationReport.updateOne({ _id: unlinked.reportId }, { $unset: { deleteAt: 1 } });
        await ReportEvidence.updateMany({ reportId: unlinked.reportId }, { $unset: { deleteAt: 1 } });

        // The active suspension is linked to `linked` only (and `unlinked`, via the
        // second call's idempotent link, was never made), so only `unlinked` violates.
        const summary = await sweep(base);
        expect(summary.invariantViolations).toBe(1);
        expect(await ModerationReport.exists({ _id: linked.reportId })).not.toBeNull();
      });
    });

    describe("key availability health (F8)", () => {
      const keyMaterial = [
        ...[0x11, 0x22, 0x99].map((byte) => Buffer.alloc(32, byte).toString("base64url")),
      ];
      const ringK1 = ringOf("k1", { k1: 0x11 });
      const ringK2 = ringOf("k2", { k2: 0x22 });
      const ringK1Reused = ringOf("k1", { k1: 0x99 });
      const ledgerRow = (keyId: string, tag: string) => ({
        keyId,
        operationDigests: [tag.repeat(64)],
        participantBinding: "a".repeat(64),
        outcome: "created" as const,
        createdAt: new Date(),
      });

      async function seedIdentity(ring: SafetyIdentityKeyring, email: string) {
        return runModerationTransaction((session) =>
          recordReportCase(session, {
            keyring: ring,
            reportedEmail: email,
            snapshot: { requestId: id(), reportedRole: "helper", requestStatus: "claimed" },
            reason: "Other concern",
          })
        );
      }

      it("raises no alert for an unconfigured keyring that nothing depends on", async () => {
        const base = new Date();
        const health = await getRetentionHealth(base, ago(base, HOUR_MS), absent);
        expect(health.keyIssuesNow).toBe(0);
        expect(health.alertReasons).not.toContain("key-unavailable");
        expect((await sweep(base, absent)).keyringState).toBe("absent");
      });

      it("always alerts for a configured but invalid keyring", async () => {
        const base = new Date();
        const summary = await sweep(base, invalid);
        expect(summary).toMatchObject({ keyringState: "invalid", keyUnavailableCount: 1 });
        const health = await getRetentionHealth(base, ago(base, HOUR_MS), invalid);
        expect(health.alertNeeded).toBe(true);
        expect(health.alertReasons).toContain("key-unavailable");
      });

      it("alerts when a live identity has no usable key, with the keyring absent or the key retired", async () => {
        const base = new Date();
        await seedIdentity(ringK1, "needs.key@nyu.edu");

        for (const inspection of [absent, ok(ringK2)]) {
          const summary = await sweep(base, inspection);
          expect(summary.keyUnavailableCount, inspection.state).toBe(1);
          const health = await getRetentionHealth(base, ago(base, HOUR_MS), inspection);
          expect(health.keyIssuesNow).toBe(1);
          expect(health.alertReasons).toContain("key-unavailable");
        }
        // Nothing was released or deleted on the way.
        expect(await SafetyIdentity.countDocuments()).toBe(1);

        // Restoring the key clears the condition.
        const restored = await getRetentionHealth(base, ago(base, HOUR_MS), ok(ringK1));
        expect(restored.keyIssuesNow).toBe(0);
        expect(restored.alertReasons).not.toContain("key-unavailable");
      });

      it("alerts when a live submission-ledger row was minted under a key that is no longer configured", async () => {
        const base = new Date();
        await ReportSubmissionLedger.create(ledgerRow("k1", "1"));
        const health = await getRetentionHealth(base, ago(base, HOUR_MS), ok(ringK2));
        expect(health.keyIssuesNow).toBe(1);
        expect(health.alertReasons).toContain("key-unavailable");
        expect((await sweep(base, ok(ringK2))).keyUnavailableCount).toBe(1);
        expect((await getRetentionHealth(base, ago(base, HOUR_MS), ok(ringK1))).keyIssuesNow).toBe(0);
      });

      it("alerts when a key id is reused with different material", async () => {
        const base = new Date();
        await seedIdentity(ringK1, "reuse.health@nyu.edu");
        const health = await getRetentionHealth(base, ago(base, HOUR_MS), ok(ringK1Reused));
        // The reused id is unusable (its recorded check differs), stranding its identity.
        expect(health.keyIssuesNow).toBeGreaterThanOrEqual(2);
        expect(health.alertReasons).toContain("key-unavailable");
        expect((await sweep(base, ok(ringK1Reused))).keyUnavailableCount).toBeGreaterThanOrEqual(2);
        // And the sweep did not release the identity with the unusable key.
        expect(await SafetyIdentity.countDocuments()).toBe(1);
      });

      it("exposes no key material, digest, key id or reference in the run proof or the health", async () => {
        const base = new Date();
        await seedIdentity(ringK1, "redact@nyu.edu");
        await ReportSubmissionLedger.create(ledgerRow("k1", "7"));
        const summary = await sweep(base, ok(ringK2));
        const health = await getRetentionHealth(base, ago(base, HOUR_MS), ok(ringK2));
        const event = await ModerationAuditEvent.collection.findOne({ kind: "retention-run" });

        const everything = JSON.stringify([summary, health, event]);
        for (const secret of keyMaterial) expect(everything).not.toContain(secret);
        expect(everything).not.toContain("redact@nyu.edu");
        expect(everything).not.toMatch(/"k1"|"k2"|[0-9a-f]{64}/);
        expect(Object.keys(health).sort()).toEqual(
          [
            "alertNeeded",
            "alertDeliveryStatus",
            "alertLastAttemptAt",
            "alertReasons",
            "dueHoldReviews",
            "identitiesKeptLastRun",
            "invariantViolationsLastRun",
            "keyIssuesNow",
            "lastRunAt",
            "lastRunStatus",
            "lastSuccessAt",
            "overdueNow",
            "stale",
          ].sort()
        );
      });

      it("surfaces due hold reviews in health as a content-free alert condition", async () => {
        const now = new Date();
        const report = await seedClosedCase(null);
        const holdRef = "due-review-hold-reference";
        await RetentionHold.create({
          ref: holdRef,
          targetKind: "case",
          targetId: report._id,
          holdClass: "legal-preservation",
          reasonCode: "legal-preservation",
          note: "Private preservation note.",
          endingCondition: "Counsel confirms preservation has ended.",
          reviewAt: ago(now, HOUR_MS),
          reviewPromptRaisedAt: ago(now, MINUTE_MS),
        });

        const health = await getRetentionHealth(now, now, ok(keyring));
        expect(health.dueHoldReviews).toBe(1);
        expect(health.alertReasons).toContain("hold-review-due");
        expect(health.alertNeeded).toBe(true);
        expect(JSON.stringify(health)).not.toContain(holdRef);
        expect(JSON.stringify(health)).not.toContain("Private preservation note.");
        expect(JSON.stringify(health)).not.toContain("Counsel confirms preservation");
      });

      it("deduplicates accepted retention alerts, retries failures, and exposes submission state", async () => {
        const now = new Date();
        const ringJson = JSON.stringify({
          current: "k1",
          keys: { k1: Buffer.alloc(32, 0x62).toString("base64url") },
        });
        vi.stubEnv("RESEND_API_KEY", "re_cp3_retention_test_placeholder");
        vi.stubEnv("MODERATOR_ORIGIN", "https://moderator.example");
        vi.stubEnv(
          "MODERATOR_PASSPHRASE_HASH",
          `scrypt-v1$16384$8$1$${Buffer.alloc(16, 0x63).toString("base64url")}$${Buffer.alloc(32, 0x64).toString("base64url")}`
        );
        vi.stubEnv("MODERATOR_TOTP_SECRET", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ");
        vi.stubEnv("REPORT_ALERT_RECIPIENT", "moderator@example.org");
        vi.stubEnv("SUPPORT_EMAIL", "support@example.org");
        vi.stubEnv(SAFETY_IDENTITY_KEYRING_ENV, ringJson);

        const sender = vi
          .fn<(
            recipient: string,
            content: { subject: string; text: string }
          ) => Promise<void>>()
          .mockRejectedValueOnce(new Error("provider response contains private data"))
          .mockResolvedValue(undefined);
        await deliverRetentionAlert(["overdue-records"], now, sender);
        let state = await RetentionAlertState.findOne({ scope: "global" }).lean().exec();
        expect(state).toMatchObject({
          currentStatus: "failed",
          lastAttemptStatus: "failed",
          currentReasons: ["overdue-records"],
        });
        expect((await getRetentionHealth(now)).alertDeliveryStatus).toBe("failed");

        await deliverRetentionAlert(["overdue-records"], ahead(now, 60_000), sender);
        expect(sender).toHaveBeenCalledTimes(2);
        expect(sender.mock.calls[0]![1].subject).toBe("Retention health needs review");
        expect(sender.mock.calls[0]![1].text).toContain("Conditions: overdue-records");
        expect(sender.mock.calls[0]![1].text).not.toMatch(/email|report|request|participant/i);
        state = await RetentionAlertState.findOne({ scope: "global" }).lean().exec();
        expect(state).toMatchObject({
          currentStatus: "submitted",
          lastAttemptStatus: "submitted",
        });
        expect((await getRetentionHealth(now)).alertDeliveryStatus).toBe("submitted");

        await deliverRetentionAlert(["overdue-records"], ahead(now, 120_000), sender);
        expect(sender).toHaveBeenCalledTimes(2);
        await deliverRetentionAlert([], ahead(now, 180_000), sender);
        expect((await RetentionAlertState.findOne({ scope: "global" }).lean().exec())?.currentStatus)
          .toBe("resolved");
        await deliverRetentionAlert(["overdue-records"], ahead(now, 240_000), sender);
        expect(sender).toHaveBeenCalledTimes(3);

        await deliverRetentionAlert(["hold-review-due"], ahead(now, 300_000), sender);
        expect(sender).toHaveBeenCalledTimes(4);
        expect(sender.mock.calls[3]![1].text).toContain("Conditions: hold-review-due");
        expect(sender.mock.calls[3]![1].text).not.toMatch(/Counsel|preservation note|due-review-hold-reference/i);
      });
    });

    it("runs end to end on real transitions: a closed case is deleted only after its deadline plus grace", async () => {
      const closedAt = new Date("2026-03-01T00:00:00Z");
      const { reportId } = await runModerationTransaction((session) =>
        recordReportCase(session, {
          keyring,
          reportedEmail: "e2e@nyu.edu",
          snapshot: { requestId: id(), reportedRole: "helper", requestStatus: "claimed" },
          reason: "Other concern",
          explanation: "text",
        })
      );
      await runModerationTransaction((session) =>
        closeReportCase(session, { reportId, outcome: "no-action", enforcementApplied: true, keyring }, closedAt)
      );

      const evidenceDue = ahead(closedAt, 90 * DAY_MS);
      const justBefore = await sweep(ahead(evidenceDue, 30 * 60_000));
      expect(justBefore.deletedEvidence).toBe(0);
      const afterGrace = await sweep(ahead(evidenceDue, 61 * 60_000));
      expect(afterGrace.deletedEvidence).toBe(2);
      expect(await ModerationReport.exists({ _id: reportId })).not.toBeNull();

      const historyDue = new Date(Date.UTC(2027, 2, 1));
      expect((await sweep(ahead(historyDue, 61 * 60_000))).deletedCaseHistory).toBe(1);
      expect(await ModerationReport.exists({ _id: reportId })).toBeNull();
      // Its audit events cascade on the following run.
      await sweep(ahead(historyDue, 2 * HOUR_MS));
      expect(await ModerationAuditEvent.countDocuments({ kind: { $in: ["report-created", "report-closed"] } })).toBe(0);
    });
  });

  describe("the real TTL monitor (reduced to one-second sweeps; the sweep never runs here)", () => {
    beforeAll(async () => {
      await setTtlMonitor(true);
      const result = await mongoose.connection.db!.admin().command({
        getParameter: 1,
        ttlMonitorSleepSecs: 1,
      });
      expect(result.ttlMonitorSleepSecs).toBe(1);
    });

    afterAll(async () => {
      await setTtlMonitor(false);
    });

    async function waitUntil(condition: () => Promise<boolean>, timeoutMs = 60_000): Promise<void> {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (await condition()) return;
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
      throw new Error("the TTL monitor did not delete the expected documents in time");
    }

    it("deletes overdue documents in every TTL collection and leaves everything else", async () => {
      const base = new Date();
      const overdue = ago(base, 5_000);
      const future = ahead(base, DAY_MS);

      const doomedCase = await seedClosedCase(overdue);
      const futureCase = await seedClosedCase(future);
      const heldCase = await seedClosedCase(null);
      const openCase = await ModerationReport.create({});
      const doomedSuspension = await seedLiftedSuspension(overdue);
      const futureSuspension = await seedLiftedSuspension(future);
      const heldSuspension = await seedLiftedSuspension(null);
      const doomedHold = await seedReleasedHold(futureCase._id as mongoose.Types.ObjectId, overdue);
      const futureHold = await seedReleasedHold(futureCase._id as mongoose.Types.ObjectId, future);
      const doomedAudit = await clockedAudit(overdue);
      const futureAudit = await clockedAudit(future);
      const ledgerRow = (createdAt: Date, tag: string) => ({
        keyId: "k1",
        operationDigests: [tag.repeat(64)],
        participantBinding: "a".repeat(64),
        outcome: "created" as const,
        createdAt,
      });
      const doomedLedger = await ReportSubmissionLedger.create(
        ledgerRow(ago(base, REPORT_LEDGER_RETENTION_MS + 60_000), "1")
      );
      const freshLedger = await ReportSubmissionLedger.create(ledgerRow(ago(base, HOUR_MS), "2"));
      const bindingRow = (createdAt: Date) => ({
        keyId: "k1",
        reporterBinding: "b".repeat(64),
        requestBinding: "c".repeat(64),
        createdAt,
      });
      const doomedBinding = await ReportCountBinding.create(
        bindingRow(ago(base, REPORT_LEDGER_RETENTION_MS + 60_000))
      );
      const freshBinding = await ReportCountBinding.create(bindingRow(ago(base, HOUR_MS)));

      await waitUntil(async () => {
        const remaining = await Promise.all([
          ModerationReport.exists({ _id: doomedCase._id }),
          ReportEvidence.exists({ reportId: doomedCase._id }),
          Suspension.exists({ _id: doomedSuspension._id }),
          SuspensionRationale.exists({ suspensionId: doomedSuspension._id }),
          RetentionHold.exists({ _id: doomedHold._id }),
          ModerationAuditEvent.exists({ _id: doomedAudit._id }),
          ReportSubmissionLedger.exists({ _id: doomedLedger._id }),
          ReportCountBinding.exists({ _id: doomedBinding._id }),
        ]);
        return remaining.every((value) => value === null);
      });

      // Let several more monitor cycles pass, then prove nothing else was touched.
      await new Promise((resolve) => setTimeout(resolve, 4_000));
      expect(await ModerationReport.exists({ _id: futureCase._id })).not.toBeNull();
      expect(await ReportEvidence.countDocuments({ reportId: futureCase._id })).toBe(2);
      expect(await ModerationReport.exists({ _id: heldCase._id })).not.toBeNull();
      expect(await ReportEvidence.countDocuments({ reportId: heldCase._id })).toBe(2);
      expect(await ModerationReport.exists({ _id: openCase._id })).not.toBeNull();
      expect(await Suspension.exists({ _id: futureSuspension._id })).not.toBeNull();
      expect(await SuspensionRationale.exists({ suspensionId: futureSuspension._id })).not.toBeNull();
      expect(await Suspension.exists({ _id: heldSuspension._id })).not.toBeNull();
      expect(await SuspensionRationale.exists({ suspensionId: heldSuspension._id })).not.toBeNull();
      expect(await RetentionHold.exists({ _id: futureHold._id })).not.toBeNull();
      expect(await ModerationAuditEvent.exists({ _id: futureAudit._id })).not.toBeNull();
      expect(await ReportSubmissionLedger.exists({ _id: freshLedger._id })).not.toBeNull();
      expect(await ReportCountBinding.exists({ _id: freshBinding._id })).not.toBeNull();
      // The sweep never ran: no proof event exists, so the monitor alone did this.
      expect(await ModerationAuditEvent.countDocuments({ kind: "retention-run" })).toBe(0);
    }, 120_000);

    it("keeps the report ledger's actual index configuration at R and under it for W", async () => {
      const indexes = await ReportSubmissionLedger.collection.indexes();
      const ttl = indexes.find((index) => index.name === "report_ledger_createdAt_ttl");
      expect(ttl?.expireAfterSeconds).toBe(REPORT_LEDGER_RETENTION_MS / 1000);
      expect(ttl?.expireAfterSeconds).toBeGreaterThan(24 * 3600 + 5 * 60);
    });
  });
});
