import { describe, expect, it } from "vitest";
import {
  INSTALLATION_CREDENTIAL_BYTES,
  digestInstallationCredential,
  generateInstallationCredential,
  isValidRawInstallationCredential,
} from "./installationCredential.js";

describe("installation credential shape and digest", () => {
  it("generates exactly 32 random bytes encoded as canonical base64url", () => {
    const first = generateInstallationCredential();
    const second = generateInstallationCredential();

    expect(first).toHaveLength(43);
    expect(Buffer.from(first, "base64url")).toHaveLength(
      INSTALLATION_CREDENTIAL_BYTES
    );
    expect(isValidRawInstallationCredential(first)).toBe(true);
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
    123,
    {},
  ])("rejects malformed raw credential %j", (value) => {
    expect(isValidRawInstallationCredential(value)).toBe(false);
  });

  it("digests to a deterministic SHA-256 hex value that never contains the raw credential", () => {
    const credential = generateInstallationCredential();
    const digest = digestInstallationCredential(credential);

    expect(digest).toMatch(/^[a-f0-9]{64}$/);
    expect(digest).not.toContain(credential);
    expect(digestInstallationCredential(credential)).toBe(digest);
  });

  it("produces different digests for different credentials", () => {
    const a = digestInstallationCredential(generateInstallationCredential());
    const b = digestInstallationCredential(generateInstallationCredential());
    expect(a).not.toBe(b);
  });
});
