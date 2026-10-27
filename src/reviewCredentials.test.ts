import { describe, expect, it } from "vitest";
import {
  digestReviewSession, generateReviewSession, hashReviewPassword,
  isReviewPassword, isReviewSession, verifyReviewPassword,
} from "./reviewCredentials.js";
import { verifyParticipantAuthority } from "./participantCredentials.js";

const password = "fictional-test-credential-".repeat(2);

describe("review-only credential format", () => {
  it("stores a salted scrypt hash, not the password", async () => {
    const first = await hashReviewPassword(password);
    const second = await hashReviewPassword(password);
    expect(first).not.toBe(second);
    expect(first).not.toContain(password);
    expect(await verifyReviewPassword(password, first)).toBe(true);
    expect(await verifyReviewPassword("different-test-credential-".repeat(2), first)).toBe(false);
  });

  it.each(["", "short", "a".repeat(257), "a".repeat(32) + "\n", {}, null])(
    "refuses malformed credentials", async (value) => {
      expect(isReviewPassword(value)).toBe(false);
    }
  );

  it("rejects corrupted hashes rather than hiding storage corruption", async () => {
    await expect(verifyReviewPassword(password, "broken")).rejects.toThrow();
  });

  it("issues only opaque, random, digest-stored review sessions", () => {
    const first = generateReviewSession();
    const second = generateReviewSession();
    expect(isReviewSession(first)).toBe(true);
    expect(second).not.toBe(first);
    expect(digestReviewSession(first)).toMatch(/^[a-f0-9]{64}$/);
    expect(digestReviewSession(first)).not.toContain(first);
    expect(verifyParticipantAuthority(first, Buffer.alloc(32, "s"))).toBeNull();
    expect(isReviewSession("student@nyu.edu")).toBe(false);
    expect(isReviewSession(["ggreview_".padEnd(52, "a")])).toBe(false);
  });
});
