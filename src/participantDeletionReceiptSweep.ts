import { scrubExpiredDeletionRecoveryReceipts } from "./participantDeletionRecovery.js";
import { registerScheduledJob } from "./scheduledJobs.js";

export const PARTICIPANT_DELETION_RECEIPT_SWEEP_CRON = "*/15 * * * *";

export async function startParticipantDeletionReceiptSweep(): Promise<void> {
  try {
    const scrubbed = await scrubExpiredDeletionRecoveryReceipts();
    console.log(`[participant-deletion] recovery receipt sweep succeeded; scrubbed=${scrubbed}`);
  } catch (error) {
    console.error(
      `[participant-deletion] recovery receipt sweep failed: ${error instanceof Error ? error.name : "unknown"}`
    );
  }
}

export function scheduleParticipantDeletionReceiptSweep(): void {
  registerScheduledJob(
    PARTICIPANT_DELETION_RECEIPT_SWEEP_CRON,
    startParticipantDeletionReceiptSweep
  );
}
