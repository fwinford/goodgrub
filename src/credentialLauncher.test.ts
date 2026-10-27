import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  RUNTIME_CREDENTIAL_NAMES,
  readRuntimeCredentials,
} from "./credentialLauncher.js";

const temporaryDirectories: string[] = [];

async function createCredentialDirectory(
  overrides: Partial<Record<(typeof RUNTIME_CREDENTIAL_NAMES)[number], string>> = {}
): Promise<string> {
  const directory = await mkdtemp(path.join(tmpdir(), "commonplate-credentials-"));
  temporaryDirectories.push(directory);
  await Promise.all(
    RUNTIME_CREDENTIAL_NAMES.map((name) =>
      writeFile(path.join(directory, name), overrides[name] ?? "", {
        mode: 0o600,
      })
    )
  );
  return directory;
}

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((directory) =>
      rm(directory, { recursive: true, force: true })
    )
  );
});

describe("systemd runtime credential injection", () => {
  it("loads only database and claim credentials for review, never provider or student signing keys", async () => {
    const directory = await createCredentialDirectory({
      MONGO_URI: "mongodb://localhost/commonplate_review",
      CLAIM_TOKEN_HMAC_SECRET: "review-claim-secret-with-more-than-32-bytes",
      RESEND_API_KEY: "must-not-be-inherited",
      PARTICIPANT_SIGNING_SECRET: "must-not-be-inherited",
      PARTICIPATION_HMAC_KEYRING: "must-not-be-inherited",
      BLOCK_SAFETY_HMAC_KEYRING: "must-not-be-inherited",
      PARTICIPANT_DELETION_SIGNING_SECRET: "must-not-be-inherited",
    });
    const credentials = await readRuntimeCredentials(directory, { NODE_ENV: "review" });
    expect(credentials.MONGO_URI).toContain("commonplate_review");
    expect(credentials.CLAIM_TOKEN_HMAC_SECRET).toContain("review-claim");
    expect(credentials.RESEND_API_KEY).toBe("");
    expect(credentials.PARTICIPANT_SIGNING_SECRET).toBe("");
    expect(credentials.PARTICIPATION_HMAC_KEYRING).toBe("");
    expect(credentials.BLOCK_SAFETY_HMAC_KEYRING).toBe("");
    expect(credentials.PARTICIPANT_DELETION_SIGNING_SECRET).toBe("");
    expect(credentials.APNS_AUTH_KEY_P8).toBe("");
    expect(credentials.OPENAI_API_KEY).toBe("");
  });
  it("loads the allowlisted credential files without trimming their values", async () => {
    const secret = "opaque+runtime-secret\n";
    const credentials = await readRuntimeCredentials(
      await createCredentialDirectory({
        MONGO_URI: "mongodb+srv://runtime:password@example.test/db",
        RESEND_API_KEY: "resend-test-key",
        CLAIM_TOKEN_HMAC_SECRET: "claim-secret-with-more-than-32-bytes",
        APNS_AUTH_KEY_P8: secret,
      })
    );

    expect(credentials.MONGO_URI).toBe(
      "mongodb+srv://runtime:password@example.test/db"
    );
    expect(credentials.APNS_AUTH_KEY_P8).toBe(secret);
    expect(credentials.OPENAI_API_KEY).toBe("");
  });

  it("loads the encrypted participant identity credentials for production", async () => {
    const credentials = await readRuntimeCredentials(
      await createCredentialDirectory({
        MONGO_URI: "mongodb://example.test/commonplate_production",
        RESEND_API_KEY: "resend-test-key",
        CLAIM_TOKEN_HMAC_SECRET: "claim-test-secret",
        PARTICIPATION_HMAC_KEYRING: "participation-keyring-fixture",
        BLOCK_SAFETY_HMAC_KEYRING: "block-safety-keyring-fixture",
        PARTICIPANT_DELETION_SIGNING_SECRET: "participant-deletion-secret-fixture",
      }),
      { NODE_ENV: "production" }
    );

    expect(credentials.PARTICIPATION_HMAC_KEYRING).toBe(
      "participation-keyring-fixture"
    );
    expect(credentials.BLOCK_SAFETY_HMAC_KEYRING).toBe(
      "block-safety-keyring-fixture"
    );
    expect(credentials.PARTICIPANT_DELETION_SIGNING_SECRET).toBe(
      "participant-deletion-secret-fixture"
    );
  });

  it("fails closed when a required credential is missing or blank", async () => {
    await expect(readRuntimeCredentials(undefined)).rejects.toThrow(
      "systemd credential directory unavailable"
    );

    const directory = await createCredentialDirectory({
      MONGO_URI: "mongodb+srv://runtime:password@example.test/db",
      RESEND_API_KEY: "   ",
      CLAIM_TOKEN_HMAC_SECRET: "claim-secret-with-more-than-32-bytes",
    });
    await expect(readRuntimeCredentials(directory)).rejects.toThrow(
      "required runtime credential unavailable"
    );
  });

  it("permits absent optional credentials so paused startup remains available", async () => {
    const directory = await createCredentialDirectory({
      MONGO_URI: "mongodb+srv://runtime:password@example.test/db",
      RESEND_API_KEY: "resend-test-key",
      CLAIM_TOKEN_HMAC_SECRET: "claim-secret-with-more-than-32-bytes",
    });
    await rm(path.join(directory, "APNS_AUTH_KEY_P8"));

    const credentials = await readRuntimeCredentials(directory);
    expect(credentials.APNS_AUTH_KEY_P8).toBe("");
  });

  it("does not copy an unavailable or unsafe value into environment output", async () => {
    const directory = await createCredentialDirectory({
      MONGO_URI: "mongodb+srv://runtime:password@example.test/db",
      RESEND_API_KEY: "resend-test-key",
      CLAIM_TOKEN_HMAC_SECRET: "claim-secret-with-more-than-32-bytes",
      APNS_AUTH_KEY_P8: "key-material\u0000suffix",
    });

    await expect(readRuntimeCredentials(directory)).rejects.toThrow(
      "runtime credential invalid"
    );
  });
});
