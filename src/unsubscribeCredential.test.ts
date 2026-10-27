import { createHmac } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  assertUnsubscribeSigningSecretForActivation,
  INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES,
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
  UNSUBSCRIBE_SIGNING_SECRET_ENV,
  UnsubscribeCredentialConfigurationError,
  UnsubscribeCredentialError,
  buildUnsubscribeUrl,
  readUnsubscribeSigningSecret,
  resolveUnsubscribeCredentialVersion,
  signUnsubscribeCredential,
  unsubscribeCredentialFor,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";

// Every secret here is supplied directly. The process environment is touched
// only by the cases that exist to describe configuration reading.
const SECRET = Buffer.alloc(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES, 1);
const OTHER_SECRET = Buffer.alloc(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES, 2);

const SUBSCRIBER_ID = "64b000000000000000000001";
const OTHER_SUBSCRIBER_ID = "64b000000000000000000002";

function credential(
  subscriberId = SUBSCRIBER_ID,
  version: number = INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  secret = SECRET
): string {
  return signUnsubscribeCredential(subscriberId, version, secret);
}

function parts(value: string): [string, string, string] {
  const split = value.split(".");
  expect(split).toHaveLength(3);
  return split as [string, string, string];
}

/**
 * A tampered copy of an authentic credential, guaranteed to differ from it.
 *
 * Overwriting the last signature character with one fixed letter is not enough:
 * when the authentic signature already ends in that letter, the "tampered"
 * fixture is the original credential and still verifies, so the case silently
 * proves nothing. Choosing between two letters guarantees a change.
 *
 * Both are canonical trailing base64url characters — the last character of a
 * 43-character signature carries only four significant bits — so the tampered
 * credential stays well formed and is refused by the signature comparison
 * rather than by the parser.
 */
function tamperCredentialSignature(value: string): string {
  const last = value.slice(-1);
  return `${value.slice(0, -1)}${last === "A" ? "E" : "A"}`;
}

/**
 * The first subscriber id, counting deterministically from a fixed prefix,
 * whose authentic signature ends in the requested character. No randomness and
 * no probabilistic sampling: the same secret and the same prefix always produce
 * the same fixture.
 */
function credentialWithFinalCharacter(
  matches: (finalCharacter: string) => boolean,
  secret = SECRET
): { subscriberId: string; value: string } {
  for (let counter = 1; counter <= 4096; counter++) {
    const subscriberId = `64b00000000000000000${counter
      .toString(16)
      .padStart(4, "0")}`;
    const value = signUnsubscribeCredential(subscriberId, 1, secret);
    if (matches(value.slice(-1))) return { subscriberId, value };
  }

  throw new Error("no credential with the requested final character was found");
}

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("unsubscribe signing secret configuration", () => {
  it("reads its own dedicated variable", () => {
    const configured = "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES);
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, configured);

    expect(readUnsubscribeSigningSecret()).toEqual(
      Buffer.from(configured, "utf8")
    );
  });

  it.each([
    ["missing", undefined],
    ["empty", ""],
    ["too short", "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES - 1)],
  ])("refuses a %s secret", (_label, configured) => {
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, configured);

    expect(() => readUnsubscribeSigningSecret()).toThrow(
      UnsubscribeCredentialConfigurationError
    );
  });

  it("never reuses another credential's secret or digest", () => {
    // Reading the claim-token secret or a stored confirmation digest here
    // would let one credential's compromise forge the other.
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "c".repeat(64));
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, "u".repeat(64));

    expect(readUnsubscribeSigningSecret()).toEqual(
      Buffer.from("u".repeat(64), "utf8")
    );
  });
});

describe("activation validation of the signing secret", () => {
  // Environments are described as plain objects rather than stubbed process
  // variables, so no case can leak configuration into another. The two cases
  // that exist to prove the default source are the exception.
  const PAUSED = { [PUBLIC_ACTIONS_PAUSED_ENV]: "true" };
  const UNPAUSED = { [PUBLIC_ACTIONS_PAUSED_ENV]: "false" };

  const EXACTLY_32_BYTES = "u".repeat(
    MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES
  );
  const MORE_THAN_32_BYTES = "u".repeat(
    MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES + 1
  );
  const THIRTY_ONE_BYTES = "u".repeat(
    MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES - 1
  );

  it.each([
    ["absent", {}],
    ["valid", { [UNSUBSCRIBE_SIGNING_SECRET_ENV]: EXACTLY_32_BYTES }],
  ])("lets a paused process start with a %s secret", (_label, secret) => {
    expect(() =>
      assertUnsubscribeSigningSecretForActivation({ ...PAUSED, ...secret })
    ).not.toThrow();
  });

  it("lets a paused process start when the pause variable is absent", () => {
    // The repository's existing reading: anything but an explicit `false` or
    // `0` is paused, including no value at all.
    expect(() =>
      assertUnsubscribeSigningSecretForActivation({})
    ).not.toThrow();
  });

  it("does not read the secret at all while paused", () => {
    // A getter rather than a value: a paused start must not consult the
    // variable, so local and test processes are never asked for a secret they
    // cannot use.
    let reads = 0;
    const environment = {
      ...PAUSED,
      get [UNSUBSCRIBE_SIGNING_SECRET_ENV]() {
        reads++;
        return EXACTLY_32_BYTES;
      },
    } as unknown as NodeJS.ProcessEnv;

    assertUnsubscribeSigningSecretForActivation(environment);

    expect(reads).toBe(0);
  });

  it.each([
    ["absent", {}],
    ["empty", { [UNSUBSCRIBE_SIGNING_SECRET_ENV]: "" }],
    [
      "shorter than 32 UTF-8 bytes",
      { [UNSUBSCRIBE_SIGNING_SECRET_ENV]: THIRTY_ONE_BYTES },
    ],
  ])("refuses to activate with a %s secret", (_label, secret) => {
    expect(() =>
      assertUnsubscribeSigningSecretForActivation({ ...UNPAUSED, ...secret })
    ).toThrow(UnsubscribeCredentialConfigurationError);
  });

  it.each([
    ["exactly 32 UTF-8 bytes", EXACTLY_32_BYTES],
    ["more than 32 UTF-8 bytes", MORE_THAN_32_BYTES],
  ])("activates with a secret of %s", (_label, configured) => {
    expect(() =>
      assertUnsubscribeSigningSecretForActivation({
        ...UNPAUSED,
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: configured,
      })
    ).not.toThrow();
  });

  it("counts UTF-8 bytes rather than JavaScript characters", () => {
    // 16 characters, 32 bytes: a character count would refuse this, and the
    // credential contract is specified in bytes because that is what the HMAC
    // key actually is.
    const sixteenTwoByteCharacters = "é".repeat(16);
    expect(sixteenTwoByteCharacters).toHaveLength(16);
    expect(Buffer.byteLength(sixteenTwoByteCharacters, "utf8")).toBe(
      MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES
    );

    expect(() =>
      assertUnsubscribeSigningSecretForActivation({
        ...UNPAUSED,
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: sixteenTwoByteCharacters,
      })
    ).not.toThrow();
  });

  it("still refuses a value whose character count only looks long enough", () => {
    // 31 characters and 31 bytes. The counterpart of the case above: the two
    // together are what distinguish a byte count from a character count.
    expect(THIRTY_ONE_BYTES).toHaveLength(
      MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES - 1
    );
    expect(Buffer.byteLength(THIRTY_ONE_BYTES, "utf8")).toBeLessThan(
      MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES
    );

    expect(() =>
      assertUnsubscribeSigningSecretForActivation({
        ...UNPAUSED,
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: THIRTY_ONE_BYTES,
      })
    ).toThrow(/at least 32 UTF-8 bytes/);
  });

  it("never puts the configured value in the failure it reports", () => {
    // The caller logs this message and exits, so anything it carries reaches
    // the deployment log.
    const configured = "short-but-secret-material";

    try {
      assertUnsubscribeSigningSecretForActivation({
        ...UNPAUSED,
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: configured,
      });
      expect.unreachable("a short secret must refuse activation");
    } catch (error) {
      const reported = String(
        error instanceof Error ? error.message : error
      );
      expect(reported).toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      expect(reported).not.toContain(configured);
    }
  });

  it("substitutes no other configured secret for a missing one", () => {
    expect(() =>
      assertUnsubscribeSigningSecretForActivation({
        ...UNPAUSED,
        CLAIM_TOKEN_HMAC_SECRET: "c".repeat(64),
        BASE_URL: "https://commonplate.test",
      })
    ).toThrow(/Missing required environment variable/);
  });

  it("reads the process environment by default", () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, undefined);

    expect(() => assertUnsubscribeSigningSecretForActivation()).toThrow(
      UnsubscribeCredentialConfigurationError
    );

    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, EXACTLY_32_BYTES);

    expect(() => assertUnsubscribeSigningSecretForActivation()).not.toThrow();
  });

  it("returns nothing, so no caller can hold the key material it checked", () => {
    expect(
      assertUnsubscribeSigningSecretForActivation({
        ...UNPAUSED,
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: EXACTLY_32_BYTES,
      })
    ).toBeUndefined();
  });
});

describe("unsubscribe credential generation", () => {
  it("uses the accepted format and canonical signed input", () => {
    const value = credential(SUBSCRIBER_ID, 3);
    const [id, version, signature] = parts(value);

    expect(id).toBe(SUBSCRIBER_ID);
    expect(version).toBe("3");
    expect(signature).toBe(
      createHmac("sha256", SECRET)
        .update(`commonplate:unsubscribe:v1:${SUBSCRIBER_ID}:3`, "utf8")
        .digest("base64url")
    );
    expect(signature).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });

  it("is stable for the same subscriber, version, and secret", () => {
    // Nothing random and nothing time-based: this is what lets an emailed
    // link keep working indefinitely.
    expect(credential()).toBe(credential());
    expect(credential(SUBSCRIBER_ID, 7)).toBe(credential(SUBSCRIBER_ID, 7));
  });

  it("differs for a different subscriber", () => {
    expect(credential(SUBSCRIBER_ID)).not.toBe(credential(OTHER_SUBSCRIBER_ID));
  });

  it("differs for a different credential version", () => {
    expect(credential(SUBSCRIBER_ID, 1)).not.toBe(
      credential(SUBSCRIBER_ID, 2)
    );
  });

  it("differs under a different secret", () => {
    expect(credential(SUBSCRIBER_ID, 1, SECRET)).not.toBe(
      credential(SUBSCRIBER_ID, 1, OTHER_SECRET)
    );
  });

  it("treats a subscriber with no stored version as the initial version", () => {
    // Documents written before the field existed have never been revoked.
    expect(
      unsubscribeCredentialFor({ _id: SUBSCRIBER_ID }, SECRET)
    ).toBe(credential(SUBSCRIBER_ID, INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION));
  });

  it("refuses to sign for a subscriber whose stored version is null", () => {
    // A physically absent field is a legacy row; a stored `null` is malformed
    // state, and signing it as version 1 would guess at a revocation state
    // nothing recorded.
    expect(() =>
      unsubscribeCredentialFor(
        { _id: SUBSCRIBER_ID, unsubscribeCredentialVersion: null },
        SECRET
      )
    ).toThrow(UnsubscribeCredentialError);
  });

  it("reads only the identity fields off a subscriber", () => {
    expect(
      unsubscribeCredentialFor(
        {
          _id: SUBSCRIBER_ID,
          unsubscribeCredentialVersion: 5,
          // Anything else on the document is irrelevant to the signature.
          ...({ email: "helper@example.edu", status: "confirmed" } as object),
        },
        SECRET
      )
    ).toBe(credential(SUBSCRIBER_ID, 5));
  });

  it.each([
    ["a missing id", undefined],
    ["an empty id", ""],
    ["a short id", "64b0000000000000000000"],
    ["an uppercase id", SUBSCRIBER_ID.toUpperCase()],
    ["a non-hexadecimal id", "z".repeat(24)],
  ])("refuses to sign %s", (_label, subscriberId) => {
    expect(() =>
      signUnsubscribeCredential(subscriberId, 1, SECRET)
    ).toThrow(UnsubscribeCredentialError);
  });

  it.each([
    ["zero", 0],
    ["null", null],
    ["a negative version", -1],
    ["a fractional version", 1.5],
    ["a non-numeric version", "1"],
    ["a version past the ceiling", MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION + 1],
  ])("refuses to sign %s", (_label, version) => {
    expect(() =>
      signUnsubscribeCredential(SUBSCRIBER_ID, version, SECRET)
    ).toThrow(UnsubscribeCredentialError);
  });

  it("refuses a signing secret below the required length", () => {
    expect(() =>
      signUnsubscribeCredential(SUBSCRIBER_ID, 1, Buffer.alloc(31, 1))
    ).toThrow(UnsubscribeCredentialConfigurationError);
  });

  it("performs no database work", async () => {
    // Imported for its side effect only: if the module reached Mongoose, this
    // spy on the Subscriber model would record it.
    const { Subscriber } = await import("../models/db.js");
    const find = vi.spyOn(Subscriber, "findOne");
    const exists = vi.spyOn(Subscriber, "exists");

    credential();
    verifyUnsubscribeCredential(credential(), SECRET);

    expect(find).not.toHaveBeenCalled();
    expect(exists).not.toHaveBeenCalled();
    vi.restoreAllMocks();
  });
});

describe("stored version resolution", () => {
  it("resolves a physically absent version to the initial version", () => {
    expect(resolveUnsubscribeCredentialVersion(undefined)).toBe(
      INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION
    );
    expect(INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION).toBe(1);
    // A lean read of a document written before the field existed produces
    // exactly this: the property is missing, not null.
    expect(
      resolveUnsubscribeCredentialVersion(
        ({} as { unsubscribeCredentialVersion?: unknown })
          .unsubscribeCredentialVersion
      )
    ).toBe(INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION);
  });

  it("rejects a stored null rather than treating it as legacy absence", () => {
    expect(() => resolveUnsubscribeCredentialVersion(null)).toThrow(
      UnsubscribeCredentialError
    );
  });

  it.each([
    ["zero", 0],
    ["a negative version", -1],
    ["a fractional version", 1.5],
    ["a numeric string", "1"],
    ["NaN", Number.NaN],
    ["a version past the ceiling", MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION + 1],
    ["an empty string", ""],
    ["false", false],
    ["an object", {}],
  ])("rejects %s", (_label, value) => {
    expect(() => resolveUnsubscribeCredentialVersion(value)).toThrow(
      UnsubscribeCredentialError
    );
  });

  it.each([
    ["the initial version", INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION],
    ["a rotated version", 2],
    ["the ceiling", MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION],
  ])("returns %s unchanged", (_label, value) => {
    // A new Mongoose document receives the schema default of 1 and must keep
    // resolving to it.
    expect(resolveUnsubscribeCredentialVersion(value)).toBe(value);
  });
});

/**
 * The fixture helper the route and primitive suites use to tamper with an
 * authentic credential. Its own correctness is proved here, once, against both
 * shapes of authentic signature.
 */
describe("tampered-credential fixtures", () => {
  const endingInA = credentialWithFinalCharacter((character) => character === "A");
  const notEndingInA = credentialWithFinalCharacter(
    (character) => character !== "A"
  );

  it("covers both an authentic signature ending in A and one that does not", () => {
    expect(endingInA.value.endsWith("A")).toBe(true);
    expect(notEndingInA.value.endsWith("A")).toBe(false);
    // Deterministic fixtures, not sampled ones: the search is a fixed walk over
    // a fixed prefix under a fixed secret.
    expect(endingInA.subscriberId).not.toBe(notEndingInA.subscriberId);
    expect(verifyUnsubscribeCredential(endingInA.value, SECRET)).toEqual({
      subscriberId: endingInA.subscriberId,
      credentialVersion: 1,
    });
    expect(verifyUnsubscribeCredential(notEndingInA.value, SECRET)).toEqual({
      subscriberId: notEndingInA.subscriberId,
      credentialVersion: 1,
    });
  });

  it.each([
    ["a signature ending in A", () => endingInA.value],
    ["a signature not ending in A", () => notEndingInA.value],
  ])("always changes %s and always fails verification", (_label, build) => {
    const authentic = build();
    const tampered = tamperCredentialSignature(authentic);

    expect(tampered).not.toBe(authentic);
    expect(tampered).toHaveLength(authentic.length);
    expect(verifyUnsubscribeCredential(tampered, SECRET)).toBeNull();
    // The identity segments are untouched, so what fails is the signature.
    expect(tampered.split(".").slice(0, 2)).toEqual(
      authentic.split(".").slice(0, 2)
    );
  });

  it("is what the old fixture was not: replacing the final character with a fixed letter can be a no-op", () => {
    // The defect this helper exists to close. `slice(0, -1) + "A"` returned the
    // authentic credential unchanged whenever the signature already ended in A,
    // so the case that believed it was submitting a tampered link submitted a
    // valid one.
    expect(`${endingInA.value.slice(0, -1)}A`).toBe(endingInA.value);
    expect(tamperCredentialSignature(endingInA.value)).not.toBe(endingInA.value);
  });
});

describe("unsubscribe credential verification", () => {
  it("accepts a credential it signed and reports its subject", () => {
    expect(verifyUnsubscribeCredential(credential(SUBSCRIBER_ID, 6), SECRET)).toEqual({
      subscriberId: SUBSCRIBER_ID,
      credentialVersion: 6,
    });
  });

  it("still accepts a credential signed at an older version", () => {
    // Cryptographic verification does not decide currency: a redemption route
    // compares the verified version against the stored one.
    expect(
      verifyUnsubscribeCredential(credential(SUBSCRIBER_ID, 1), SECRET)
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 1 });
  });

  it("rejects a modified subscriber id", () => {
    const [, version, signature] = parts(credential(SUBSCRIBER_ID, 2));

    expect(
      verifyUnsubscribeCredential(
        `${OTHER_SUBSCRIBER_ID}.${version}.${signature}`,
        SECRET
      )
    ).toBeNull();
  });

  it("rejects a modified credential version", () => {
    const [id, , signature] = parts(credential(SUBSCRIBER_ID, 2));

    expect(
      verifyUnsubscribeCredential(`${id}.3.${signature}`, SECRET)
    ).toBeNull();
  });

  it("rejects a modified signature", () => {
    const [id, version, signature] = parts(credential(SUBSCRIBER_ID, 2));
    const flipped = `${signature[0] === "A" ? "B" : "A"}${signature.slice(1)}`;

    expect(
      verifyUnsubscribeCredential(`${id}.${version}.${flipped}`, SECRET)
    ).toBeNull();
  });

  it("rejects a credential signed with another secret", () => {
    expect(
      verifyUnsubscribeCredential(
        credential(SUBSCRIBER_ID, 1, OTHER_SECRET),
        SECRET
      )
    ).toBeNull();
  });

  it.each([
    ["a non-string", 12345],
    ["null", null],
    ["undefined", undefined],
    ["an object", { credential: "x" }],
    ["an empty string", ""],
    ["no separators", "notacredential"],
    ["too few segments", `${SUBSCRIBER_ID}.1`],
    ["too many segments", `${SUBSCRIBER_ID}.1.aaa.bbb`],
    ["an empty signature", `${SUBSCRIBER_ID}.1.`],
    ["a short signature", `${SUBSCRIBER_ID}.1.${"a".repeat(42)}`],
    ["an over-long signature", `${SUBSCRIBER_ID}.1.${"a".repeat(44)}`],
    ["a non-base64url signature", `${SUBSCRIBER_ID}.1.${"a".repeat(42)}+`],
    ["a zero version", `${SUBSCRIBER_ID}.0.${"a".repeat(43)}`],
    ["a leading-zero version", `${SUBSCRIBER_ID}.01.${"a".repeat(43)}`],
    ["a signed version", `${SUBSCRIBER_ID}.+1.${"a".repeat(43)}`],
    ["a spaced version", `${SUBSCRIBER_ID}. 1.${"a".repeat(43)}`],
    ["a fractional version", `${SUBSCRIBER_ID}.1.5.${"a".repeat(43)}`],
    ["an enormous version", `${SUBSCRIBER_ID}.9999999999.${"a".repeat(43)}`],
    ["an uppercase id", `${SUBSCRIBER_ID.toUpperCase()}.1.${"a".repeat(43)}`],
    ["a short id", `64b0.1.${"a".repeat(43)}`],
  ])("fails safely on %s", (_label, candidate) => {
    expect(() =>
      expect(verifyUnsubscribeCredential(candidate, SECRET)).toBeNull()
    ).not.toThrow();
  });

  it("rejects a non-canonical spelling of a valid signature", () => {
    const [id, version, signature] = parts(credential(SUBSCRIBER_ID, 1));
    // Same 32 bytes, different text: one signature must have exactly one
    // accepted form, or two distinct credential strings would both verify.
    const padded = `${signature}=`;

    expect(
      verifyUnsubscribeCredential(`${id}.${version}.${padded}`, SECRET)
    ).toBeNull();
  });
});

describe("unsubscribe URL", () => {
  it("uses the configured public base URL and the accepted shape", () => {
    vi.stubEnv("BASE_URL", "https://commonplate.test/");

    const url = new URL(
      buildUnsubscribeUrl({ _id: SUBSCRIBER_ID, unsubscribeCredentialVersion: 2 }, SECRET)
    );

    expect(url.origin).toBe("https://commonplate.test");
    expect(url.pathname).toBe(UNSUBSCRIBE_ROUTE_PATH);
    expect([...url.searchParams.keys()]).toEqual([
      UNSUBSCRIBE_CREDENTIAL_PARAMETER,
    ]);
    expect(
      verifyUnsubscribeCredential(
        url.searchParams.get(UNSUBSCRIBE_CREDENTIAL_PARAMETER),
        SECRET
      )
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 2 });
  });

  it("falls back to the configured signing secret when none is supplied", () => {
    vi.stubEnv("BASE_URL", "https://commonplate.test");
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, SECRET.toString("utf8"));

    expect(buildUnsubscribeUrl({ _id: SUBSCRIBER_ID })).toBe(
      buildUnsubscribeUrl({ _id: SUBSCRIBER_ID }, SECRET)
    );
  });
});
