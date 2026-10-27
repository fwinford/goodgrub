import { scryptSync } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  matchTotpStep,
  readModeratorConfig,
  verifyModeratorPassphrase,
} from "./moderatorSecurity.js";

const passphrase = "a-long-test-moderator-passphrase";
const salt = Buffer.alloc(16, 0x22);
const passphraseHash = scryptSync(passphrase, salt, 32, { N: 16_384, r: 8, p: 1 });
const keyBytes = Buffer.alloc(32, 0x11);
const totpSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

function validEnvironment(): NodeJS.ProcessEnv {
  return {
    MODERATOR_ORIGIN: "https://moderator.example",
    MODERATOR_PASSPHRASE_HASH: [
      "scrypt-v1",
      16_384,
      8,
      1,
      salt.toString("base64url"),
      passphraseHash.toString("base64url"),
    ].join("$"),
    MODERATOR_TOTP_SECRET: totpSecret,
    REPORT_ALERT_RECIPIENT: "moderator@example.org",
    SUPPORT_EMAIL: "support@example.org",
    SAFETY_IDENTITY_KEYRING: JSON.stringify({
      current: "k1",
      keys: { k1: keyBytes.toString("base64url") },
    }),
  };
}

describe("moderator configuration and credentials", () => {
  it("fails closed for absent and malformed moderator configuration", () => {
    expect(readModeratorConfig({})).toBeNull();
    expect(
      readModeratorConfig({
        ...validEnvironment(),
        MODERATOR_ORIGIN: "http://moderator.example",
      })
    ).toBeNull();
    expect(
      readModeratorConfig({
        ...validEnvironment(),
        MODERATOR_PASSPHRASE_HASH: "plaintext",
      })
    ).toBeNull();
    expect(
      readModeratorConfig({
        ...validEnvironment(),
        MODERATOR_TOTP_SECRET: "not-base32",
      })
    ).toBeNull();
    expect(
      readModeratorConfig({
        ...validEnvironment(),
        SUPPORT_EMAIL: "",
      })
    ).toBeNull();
  });

  it("accepts a separated valid configuration without returning raw encoded secrets", () => {
    const config = readModeratorConfig(validEnvironment());
    expect(config).not.toBeNull();
    expect(config).toMatchObject({
      origin: "https://moderator.example",
      alertRecipient: "moderator@example.org",
      supportEmail: "support@example.org",
    });
    expect(JSON.stringify(config)).not.toContain(passphraseHash.toString("base64url"));
    expect(JSON.stringify(config)).not.toContain(totpSecret);
  });

  it("verifies the salted scrypt passphrase and rejects an incorrect value", async () => {
    const config = readModeratorConfig(validEnvironment());
    expect(config).not.toBeNull();
    expect(await verifyModeratorPassphrase(passphrase, config!.passphraseHash)).toBe(true);
    expect(await verifyModeratorPassphrase("incorrect", config!.passphraseHash)).toBe(false);
    expect(await verifyModeratorPassphrase(undefined, config!.passphraseHash)).toBe(false);
  });

  it("accepts RFC 6238 codes only within one step and returns one matching step", () => {
    const secret = Buffer.from("12345678901234567890");
    expect(matchTotpStep("287082", secret, new Date(59_000))).toBe(1);
    expect(matchTotpStep("287082", secret, new Date(89_000))).toBe(1);
    expect(matchTotpStep("287082", secret, new Date(149_000))).toBeNull();
    expect(matchTotpStep("28708x", secret, new Date(59_000))).toBeNull();
  });
});
