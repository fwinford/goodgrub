import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import cron from "node-cron";
import { afterEach, describe, expect, it, vi } from "vitest";

const recovery = vi.hoisted(() => ({
  scrubExpiredDeletionRecoveryReceipts: vi.fn<() => Promise<number>>(),
}));

vi.mock("./participantDeletionRecovery.js", () => recovery);

import {
  PARTICIPANT_DELETION_RECEIPT_SWEEP_CRON,
  scheduleParticipantDeletionReceiptSweep,
  startParticipantDeletionReceiptSweep,
} from "./participantDeletionReceiptSweep.js";

describe("participant deletion receipt sweep", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    recovery.scrubExpiredDeletionRecoveryReceipts.mockReset();
  });

  it("schedules the production privacy sweep independently of optional cleanup", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SCHEDULER_ENABLED", "true");
    vi.stubEnv("CRON_ENABLED", "false");
    const schedule = vi.spyOn(cron, "schedule").mockImplementation(() => undefined as never);
    recovery.scrubExpiredDeletionRecoveryReceipts.mockResolvedValue(0);

    scheduleParticipantDeletionReceiptSweep();

    expect(PARTICIPANT_DELETION_RECEIPT_SWEEP_CRON).toBe("*/15 * * * *");
    expect(schedule).toHaveBeenCalledWith(
      PARTICIPANT_DELETION_RECEIPT_SWEEP_CRON,
      expect.any(Function),
      { noOverlap: true }
    );
    await (schedule.mock.calls[0][1] as () => Promise<void>)();
    expect(recovery.scrubExpiredDeletionRecoveryReceipts).toHaveBeenCalledOnce();
  });

  it("does not schedule or run the privacy sweep in the review environment", () => {
    vi.stubEnv("NODE_ENV", "review");
    vi.stubEnv("SCHEDULER_ENABLED", "false");
    const schedule = vi.spyOn(cron, "schedule");

    scheduleParticipantDeletionReceiptSweep();

    expect(schedule).not.toHaveBeenCalled();
    expect(recovery.scrubExpiredDeletionRecoveryReceipts).not.toHaveBeenCalled();
  });

  it("logs each successful run and its scrub count", async () => {
    recovery.scrubExpiredDeletionRecoveryReceipts.mockResolvedValue(3);
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await startParticipantDeletionReceiptSweep();

    expect(recovery.scrubExpiredDeletionRecoveryReceipts).toHaveBeenCalledOnce();
    expect(log).toHaveBeenCalledWith(
      "[participant-deletion] recovery receipt sweep succeeded; scrubbed=3"
    );
  });

  it("logs failures without exposing error messages", async () => {
    recovery.scrubExpiredDeletionRecoveryReceipts.mockRejectedValue(
      new Error("sensitive operation data")
    );
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await startParticipantDeletionReceiptSweep();

    expect(error).toHaveBeenCalledWith(
      "[participant-deletion] recovery receipt sweep failed: Error"
    );
    expect(error.mock.calls.flat().join(" ")).not.toContain("sensitive operation data");
  });

  it("registers once after database/index startup and before listening", () => {
    const app = readFileSync(fileURLToPath(new URL("../app.ts", import.meta.url)), "utf8");
    const registration = app.indexOf("scheduleParticipantDeletionReceiptSweep();");

    expect(app.match(/scheduleParticipantDeletionReceiptSweep\(\);/g)).toHaveLength(1);
    expect(app).toMatch(
      /import \{ scheduleParticipantDeletionReceiptSweep \} from "\.\/src\/participantDeletionReceiptSweep\.js";/
    );
    expect(registration).toBeGreaterThan(app.indexOf("await establishModerationIndexes();"));
    expect(registration).toBeLessThan(app.indexOf("app.listen("));
    expect(app.slice(0, registration)).toContain("await ParticipantDeletionOperation.createIndexes();");
  });
});
