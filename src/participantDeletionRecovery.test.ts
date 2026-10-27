import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  DELETION_RECOVERY_MAX_LIFETIME_MS,
  deletionRecoveryCapabilityDigest,
  generateDeletionRecoveryCapability,
  participantDeletionCompletionReceiptPipeline,
} from "./participantDeletionRecovery.js";

describe("W4-P2 deletion completion recovery primitives", () => {
  it("generates an opaque 32-byte capability and stores only a purpose-separated digest", () => {
    const capability = generateDeletionRecoveryCapability();
    expect(Buffer.from(capability, "base64url")).toHaveLength(32);

    const digest = deletionRecoveryCapabilityDigest(capability);
    expect(digest).toMatch(/^[0-9a-f]{64}$/);
    expect(digest).not.toBe(
      createHash("sha256").update(capability, "utf8").digest("hex")
    );
    expect(() => deletionRecoveryCapabilityDigest("invalid")).toThrow();
  });

  it("sets exactly a seven-day completion receipt and never removes its operation ID", () => {
    expect(DELETION_RECOVERY_MAX_LIFETIME_MS).toBe(7 * 24 * 60 * 60 * 1000);
    const pipeline = participantDeletionCompletionReceiptPipeline();
    expect(pipeline[0]).toMatchObject({
      $set: {
        phase: "completed",
        completedAt: "$$NOW",
        recoveryExpiresAt: {
          $add: ["$$NOW", 7 * 24 * 60 * 60 * 1000],
        },
      },
    });
    const removed = pipeline[1]?.$unset as string[];
    expect(removed).toContain("participantId");
    expect(removed).toContain("emailBinding");
    expect(removed).not.toContain("operationId");
  });
});
