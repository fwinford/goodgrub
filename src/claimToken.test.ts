import { describe, expect, it } from "vitest";
import {
  CLAIM_TOKEN_BYTES,
  ClaimTokenConfigurationError,
  claimTokenDigestMatches,
  digestClaimToken,
  generateClaimToken,
  isValidRawClaimToken,
  readClaimTokenHmacSecret,
} from "./claimToken.js";

describe("claim token protection", () => {
  it("generates exactly 32 random bytes encoded as canonical base64url", () => {
    const first = generateClaimToken();
    const second = generateClaimToken();

    expect(first).toHaveLength(43);
    expect(Buffer.from(first, "base64url")).toHaveLength(CLAIM_TOKEN_BYTES);
    expect(isValidRawClaimToken(first)).toBe(true);
    expect(second).not.toBe(first);
  });

  it.each([
    undefined,
    null,
    "",
    "short",
    "contains+non_url/characters==",
    "a".repeat(42),
    "a".repeat(44),
  ])("rejects malformed raw token %j", (token) => {
    expect(isValidRawClaimToken(token)).toBe(false);
  });

  it("stores a deterministic HMAC-SHA-256 digest rather than the token", () => {
    const secret = Buffer.from("s".repeat(32));
    const token = generateClaimToken();
    const digest = digestClaimToken(token, secret);

    expect(digest).toMatch(/^[a-f0-9]{64}$/);
    expect(digest).not.toContain(token);
    expect(claimTokenDigestMatches(digest, digest)).toBe(true);
    expect(claimTokenDigestMatches(digest, "0".repeat(64))).toBe(false);
  });

  it("fails closed when the secret is absent or shorter than 32 bytes", () => {
    expect(() => readClaimTokenHmacSecret({})).toThrow(
      ClaimTokenConfigurationError
    );
    expect(() =>
      readClaimTokenHmacSecret({ CLAIM_TOKEN_HMAC_SECRET: "x".repeat(31) })
    ).toThrow("at least 32");
  });

  it("accepts an explicitly configured secret of at least 32 UTF-8 bytes", () => {
    expect(
      readClaimTokenHmacSecret({
        CLAIM_TOKEN_HMAC_SECRET: "development-secret-material-32bytes",
      })
    ).toEqual(Buffer.from("development-secret-material-32bytes"));
  });
});

