import { describe, expect, it } from "vitest";
import {
  MAXIMUM_SAFETY_IDENTITY_KEYS,
  SAFETY_IDENTITY_KEYRING_ENV,
  SafetyIdentityKeyringError,
  deriveKeyedDigest,
  deriveKeyedDigests,
  deriveSafetyIdentityDigests,
  readSafetyIdentityKeyring,
  tryReadSafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";

const keyA = Buffer.alloc(32, 0xa1).toString("base64url");
const keyB = Buffer.alloc(32, 0xb2).toString("base64url");

const env = (value: unknown): NodeJS.ProcessEnv => ({
  [SAFETY_IDENTITY_KEYRING_ENV]: typeof value === "string" ? value : JSON.stringify(value),
});

const ring = (overrides: Record<string, unknown> = {}) =>
  env({ current: "k2", keys: { k1: keyA, k2: keyB }, ...overrides });

describe("keyring configuration (fail closed)", () => {
  it("reads a valid versioned keyring", () => {
    const keyring = readSafetyIdentityKeyring(ring());
    expect(keyring.currentKeyId).toBe("k2");
    expect([...keyring.keys.keys()].sort()).toEqual(["k1", "k2"]);
  });

  it.each([
    ["missing", {}],
    ["blank", env("   ")],
    ["not JSON", env("not json")],
    ["a JSON array", env([1, 2])],
    ["no current", env({ keys: { k1: keyA } })],
    ["no keys", env({ current: "k1" })],
    ["empty keys", env({ current: "k1", keys: {} })],
    ["current not among keys", env({ current: "k9", keys: { k1: keyA } })],
    ["key too short", env({ current: "k1", keys: { k1: Buffer.alloc(31, 1).toString("base64url") } })],
    ["key not a string", env({ current: "k1", keys: { k1: 12345 } })],
    ["bad key id", env({ current: "bad id", keys: { "bad id": keyA } })],
    ["duplicate key material", env({ current: "k1", keys: { k1: keyA, k2: keyA } })],
    [
      "too many keys",
      env({
        current: "k0",
        keys: Object.fromEntries(
          Array.from({ length: MAXIMUM_SAFETY_IDENTITY_KEYS + 1 }, (_, i) => [
            `k${i}`,
            Buffer.alloc(32, i + 1).toString("base64url"),
          ])
        ),
      }),
    ],
  ])("refuses a %s keyring", (_label, source) => {
    expect(() => readSafetyIdentityKeyring(source as NodeJS.ProcessEnv)).toThrow(
      SafetyIdentityKeyringError
    );
    expect(tryReadSafetyIdentityKeyring(source as NodeJS.ProcessEnv)).toBeNull();
  });

  it("never puts key material in an error", () => {
    for (const source of [ring({ keys: { k1: keyA, k2: keyA } }), env("not json")]) {
      try {
        readSafetyIdentityKeyring(source);
        throw new Error("expected a refusal");
      } catch (error) {
        const text = String((error as Error).message);
        expect(text).not.toContain(keyA);
        expect(text).not.toContain(keyB);
      }
    }
  });
});

describe("credential namespace separation", () => {
  it.each([
    "PARTICIPANT_SIGNING_SECRET",
    "CLAIM_TOKEN_HMAC_SECRET",
    "UNSUBSCRIBE_SIGNING_SECRET",
  ])("refuses a key equal to %s", (name) => {
    const shared = Buffer.alloc(32, "s");
    const source = {
      ...ring({ keys: { k1: shared.toString("base64url"), k2: keyB } }),
      [name]: shared.toString("utf8"),
    };
    expect(() => readSafetyIdentityKeyring(source)).toThrow(SafetyIdentityKeyringError);
  });

  it("refuses a key equal to any other environment variable, named or not", () => {
    const shared = Buffer.alloc(32, "q");
    const source = {
      ...ring({ keys: { k1: shared.toString("base64url"), k2: keyB } }),
      SOME_FUTURE_SIGNING_SECRET: shared.toString("utf8"),
    };
    expect(() => readSafetyIdentityKeyring(source)).toThrow(SafetyIdentityKeyringError);
  });

  describe("realistic configured representations of another credential", () => {
    // 32 random-looking bytes, as an operator would generate a real secret.
    const secretBytes = Buffer.from("7f3a9c1e5b2d48a6c0e1f7d93b5a2c4e8d6f1a0b9c3e5d7f2a4b6c8d0e1f3a5b", "hex");
    const secretAsBase64Url = secretBytes.toString("base64url");
    const secretAsBase64 = secretBytes.toString("base64");
    const secretAsHex = secretBytes.toString("hex");

    const reuse = (keyringValue: string, otherName: string, otherValue: string) => ({
      ...ring({ keys: { k1: keyringValue, k2: keyB } }),
      [otherName]: otherValue,
    });

    it.each([
      ["base64url secret reused verbatim as the key", secretAsBase64Url, secretAsBase64Url],
      ["base64url secret with a trailing newline from a secret file", secretAsBase64Url, `${secretAsBase64Url}\n`],
      ["standard base64 (padded, +/ alphabet) secret", secretAsBase64Url, secretAsBase64],
      ["hexadecimal secret whose bytes are the key", secretAsBase64Url, secretAsHex],
      ["upper-case hexadecimal secret", secretAsBase64Url, secretAsHex.toUpperCase()],
      ["raw text secret of the same bytes", Buffer.alloc(32, "T").toString("base64url"), "T".repeat(32)],
    ])("refuses %s", (_label, keyringValue, otherValue) => {
      for (const name of ["PARTICIPANT_SIGNING_SECRET", "CLAIM_TOKEN_HMAC_SECRET", "SOME_FUTURE_SECRET"]) {
        expect(() =>
          readSafetyIdentityKeyring(reuse(keyringValue, name, otherValue))
        ).toThrow(SafetyIdentityKeyringError);
      }
    });

    it("refuses reuse of a non-current key as well, and says nothing about the value", () => {
      const source = reuse(secretAsBase64Url, "UNSUBSCRIBE_SIGNING_SECRET", secretAsHex);
      try {
        readSafetyIdentityKeyring({ ...source, [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({ current: "k2", keys: { k1: secretAsBase64Url, k2: keyB } }) });
        throw new Error("expected a refusal");
      } catch (error) {
        expect(error).toBeInstanceOf(SafetyIdentityKeyringError);
        const message = String((error as Error).message);
        for (const leaked of [secretAsBase64Url, secretAsBase64, secretAsHex, keyB]) {
          expect(message).not.toContain(leaked);
        }
      }
    });

    it("accepts a keyring whose keys differ from every other credential in every representation", () => {
      const other = Buffer.from("0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0", "hex");
      const source = {
        ...ring(),
        PARTICIPANT_SIGNING_SECRET: other.toString("base64url"),
        CLAIM_TOKEN_HMAC_SECRET: other.toString("hex"),
        UNSUBSCRIBE_SIGNING_SECRET: "an-entirely-different-unsubscribe-secret",
        NODE_ENV: "test",
        PORT: "3000",
        CRON_ENABLED: "true",
        EMPTY: "",
      };
      expect(() => readSafetyIdentityKeyring(source)).not.toThrow();
    });

    it("does not treat the keyring's own variable as another credential", () => {
      expect(() => readSafetyIdentityKeyring(ring())).not.toThrow();
    });

    it("keeps key rotation and fail-closed behavior: a distinct added key still loads", () => {
      const rotated = readSafetyIdentityKeyring({
        ...env({ current: "k3", keys: { k1: keyA, k2: keyB, k3: Buffer.alloc(32, 0xd4).toString("base64url") } }),
        PARTICIPANT_SIGNING_SECRET: secretAsBase64Url,
      });
      expect(rotated.currentKeyId).toBe("k3");
    });
  });

  it("accepts a keyring that differs from every other secret", () => {
    const source = {
      ...ring(),
      PARTICIPANT_SIGNING_SECRET: "participant-signing-secret-of-32-bytes!",
      CLAIM_TOKEN_HMAC_SECRET: "claim-token-hmac-secret-of-32-bytes!!!",
    };
    expect(() => readSafetyIdentityKeyring(source)).not.toThrow();
  });
});

describe("keyed derivation", () => {
  const keyring = readSafetyIdentityKeyring(ring());

  it("is deterministic and keyed", () => {
    const [first] = deriveSafetyIdentityDigests(keyring, "ada@nyu.edu")!;
    const [again] = deriveSafetyIdentityDigests(keyring, "ada@nyu.edu")!;
    expect(first).toEqual(again);
    expect(first.digest).toMatch(/^[0-9a-f]{64}$/);

    const other = readSafetyIdentityKeyring(
      ring({ keys: { k1: keyA, k2: Buffer.alloc(32, 0xe5).toString("base64url") } })
    );
    expect(deriveSafetyIdentityDigests(other, "ada@nyu.edu")![0].digest).not.toBe(first.digest);
  });

  it("tries the current key first and then every other configured key", () => {
    const digests = deriveSafetyIdentityDigests(keyring, "ada@nyu.edu")!;
    expect(digests.map((entry) => entry.keyId)).toEqual(["k2", "k1"]);
    expect(digests[0].digest).not.toBe(digests[1].digest);
  });

  it("normalizes exactly like the participant principal and folds nothing", () => {
    const plain = deriveSafetyIdentityDigests(keyring, "ada@nyu.edu")![0].digest;
    expect(deriveSafetyIdentityDigests(keyring, "  ADA@NYU.EDU ")![0].digest).toBe(plain);
    expect(deriveSafetyIdentityDigests(keyring, "ada+tag@nyu.edu")![0].digest).not.toBe(plain);
    expect(deriveSafetyIdentityDigests(keyring, "a.da@nyu.edu")![0].digest).not.toBe(plain);
  });

  it("mints no digest for a value that is not an eligible principal", () => {
    expect(deriveSafetyIdentityDigests(keyring, "ada@example.com")).toBeNull();
    expect(deriveSafetyIdentityDigests(keyring, "not an email")).toBeNull();
    expect(deriveSafetyIdentityDigests(keyring, 42)).toBeNull();
    expect(deriveSafetyIdentityDigests(keyring, undefined)).toBeNull();
  });

  it("separates purposes so one digest can never stand in for another", () => {
    const value = "same-input";
    const purposes = [
      "safety-identity",
      "report-operation",
      "report-participant",
      "report-request",
      "report-handoff",
    ] as const;
    const seen = new Set(purposes.map((purpose) => deriveKeyedDigest(keyring, "k2", purpose, value)));
    expect(seen.size).toBe(purposes.length);
  });

  it("fails closed for a key id that is not configured", () => {
    expect(() => deriveKeyedDigest(keyring, "k9", "safety-identity", "x")).toThrow(
      SafetyIdentityKeyringError
    );
  });

  it("keeps a digest stable when a key is added or the current key changes", () => {
    const rotated = readSafetyIdentityKeyring(
      env({ current: "k3", keys: { k1: keyA, k2: keyB, k3: Buffer.alloc(32, 0xd4).toString("base64url") } })
    );
    const before = deriveKeyedDigests(keyring, "safety-identity", "ada@nyu.edu");
    const after = deriveKeyedDigests(rotated, "safety-identity", "ada@nyu.edu");
    for (const entry of before) {
      expect(after.find((candidate) => candidate.keyId === entry.keyId)?.digest).toBe(entry.digest);
    }
  });
});
