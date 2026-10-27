import { describe, expect, it } from "vitest";
import {
  DELETION_AUTHORIZATION_LIFETIME_MS,
  DELETION_CHALLENGE_LIFETIME_MS,
  DELETION_CHALLENGE_MAXIMUM_ATTEMPTS,
  DELETION_CHALLENGE_RESEND_COOLDOWN_MS,
  deletionEmailBinding,
  digestDeletionChallenge,
  isValidDeletionChallengeCode,
} from "./participantDeletionSecurity.js";

const secret = Buffer.from("d".repeat(32));
const binding = {
  operationId: "11111111-1111-4111-8111-111111111111",
  participantId: "64e0000000000000000000a1",
  emailBinding: deletionEmailBinding("student@nyu.edu", secret),
  authorityVersion: 1,
  readinessGeneration: 1,
  challengeGeneration: 1,
};

describe("W4-P2 deletion-specific challenge security", () => {
  it("uses the accepted time/attempt bounds", () => {
    expect(DELETION_CHALLENGE_LIFETIME_MS).toBe(10 * 60 * 1000);
    expect(DELETION_CHALLENGE_RESEND_COOLDOWN_MS).toBe(60 * 1000);
    expect(DELETION_CHALLENGE_MAXIMUM_ATTEMPTS).toBe(5);
    expect(DELETION_AUTHORIZATION_LIFETIME_MS).toBe(5 * 60 * 1000);
  });

  it("requires a strict six-digit code", () => {
    expect(isValidDeletionChallengeCode("000000")).toBe(true);
    for (const malformed of ["12345", "1234567", "12x456", " 123456", 123456, null]) {
      expect(isValidDeletionChallengeCode(malformed)).toBe(false);
    }
  });

  it("purpose-separates email and challenge bindings from every other operation dimension", () => {
    const digest = digestDeletionChallenge(binding, "424242", secret);
    expect(deletionEmailBinding(" STUDENT@NYU.EDU ", secret)).toBe(binding.emailBinding);
    expect(digest).not.toContain("424242");
    for (const changed of [
      { operationId: "22222222-2222-4222-8222-222222222222" },
      { participantId: "64e0000000000000000000b2" },
      { emailBinding: deletionEmailBinding("other@nyu.edu", secret) },
      { authorityVersion: 2 },
      { readinessGeneration: 2 },
      { challengeGeneration: 2 },
    ]) {
      expect(digestDeletionChallenge({ ...binding, ...changed }, "424242", secret)).not.toBe(digest);
    }
  });
});
