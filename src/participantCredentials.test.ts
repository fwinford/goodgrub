import { readFileSync, readdirSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  INITIAL_PARTICIPANT_AUTHORITY_VERSION,
  MAXIMUM_PARTICIPANT_AUTHORITY_VERSION,
  MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES,
  PARTICIPANT_SIGNING_SECRET_ENV,
  ParticipantCredentialConfigurationError,
  ParticipantCredentialError,
  VERIFICATION_CODE_DIGITS,
  assertParticipantSigningSecretForActivation,
  digestVerificationCode,
  generateVerificationCode,
  isValidRawVerificationCode,
  readParticipantSigningSecret,
  signParticipantAuthority,
  verifyParticipantAuthority,
} from "./participantCredentials.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";

const secret = Buffer.from("p".repeat(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES));
const otherSecret = Buffer.from(
  "q".repeat(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES)
);
const participantId = "64c0000000000000000000a1";
const otherParticipantId = "64c0000000000000000000a2";

describe("participant signing secret", () => {
  it("requires the variable to be present", () => {
    expect(() => readParticipantSigningSecret({})).toThrow(
      ParticipantCredentialConfigurationError
    );
    expect(() => readParticipantSigningSecret({})).toThrow(
      `Missing required environment variable: ${PARTICIPANT_SIGNING_SECRET_ENV}`
    );
  });

  it.each([[""], ["short"], ["p".repeat(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES - 1)]])(
    "refuses a secret of %j",
    (configured) => {
      expect(() =>
        readParticipantSigningSecret({
          [PARTICIPANT_SIGNING_SECRET_ENV]: configured,
        })
      ).toThrow(ParticipantCredentialConfigurationError);
    }
  );

  it("never puts the configured value in the failure message", () => {
    const configured = "short-but-distinctive-secret";
    try {
      readParticipantSigningSecret({
        [PARTICIPANT_SIGNING_SECRET_ENV]: configured,
      });
      expect.unreachable("a short secret must be refused");
    } catch (error) {
      expect((error as Error).message).toContain(
        PARTICIPANT_SIGNING_SECRET_ENV
      );
      expect((error as Error).message).not.toContain(configured);
    }
  });

  it("accepts exactly the minimum length", () => {
    const configured = "p".repeat(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES);
    expect(
      readParticipantSigningSecret({
        [PARTICIPANT_SIGNING_SECRET_ENV]: configured,
      }).byteLength
    ).toBe(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES);
  });

  it("reads nothing while public actions are paused", () => {
    // Nobody can verify and nobody can act while paused, so a local or test
    // process must not be asked for a secret no paused path can use.
    expect(() =>
      assertParticipantSigningSecretForActivation({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
      })
    ).not.toThrow();
    expect(() => assertParticipantSigningSecretForActivation({})).not.toThrow();
  });

  it("requires the secret once public actions are unpaused", () => {
    expect(() =>
      assertParticipantSigningSecretForActivation({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      })
    ).toThrow(ParticipantCredentialConfigurationError);
  });

  it("does not share a namespace with any other CommonPlate credential", () => {
    // The one structural guarantee behind "purpose-bound": participant identity
    // is a person's proof of mailbox control, and a compromise of a subscriber,
    // installation, or claim credential must not forge one.
    const source = readFileSync(
      new URL("./participantCredentials.ts", import.meta.url),
      "utf8"
    );
    for (const foreign of [
      "UNSUBSCRIBE_SIGNING_SECRET",
      "CLAIM_TOKEN_HMAC_SECRET",
      "APNS_AUTH_KEY_P8",
      "RESEND_API_KEY",
    ]) {
      expect(source).not.toContain(foreign);
    }
  });
});

describe("verification codes", () => {
  it("generates a fixed-width numeric code", () => {
    for (let attempt = 0; attempt < 200; attempt += 1) {
      const code = generateVerificationCode();
      expect(code).toHaveLength(VERIFICATION_CODE_DIGITS);
      expect(code).toMatch(/^[0-9]{6}$/);
      expect(isValidRawVerificationCode(code)).toBe(true);
    }
  });

  it("can produce a code with leading zeroes rather than a shorter one", () => {
    // Padding matters: a code rendered as "1234" would not match what the
    // digest was computed over, so the participant could never redeem it.
    const codes = new Set<string>();
    for (let attempt = 0; attempt < 5_000; attempt += 1) {
      codes.add(generateVerificationCode());
    }
    expect([...codes].every((code) => code.length === 6)).toBe(true);
    // Not a distribution test — just that the space is genuinely being used.
    expect(codes.size).toBeGreaterThan(2_000);
  });

  it.each([
    [undefined],
    [null],
    [123456],
    [""],
    ["12345"],
    ["1234567"],
    ["12345a"],
    [" 123456"],
    ["123456 "],
    ["+12345"],
    ["１２３４５６"],
  ])("rejects %j as a raw code", (value) => {
    expect(isValidRawVerificationCode(value)).toBe(false);
  });

  it("binds a code digest to the address it was mailed to", () => {
    // A code observed for one participant must not verify against another
    // participant's live challenge.
    const code = "424242";
    expect(digestVerificationCode("a@nyu.edu", code, secret)).not.toBe(
      digestVerificationCode("b@nyu.edu", code, secret)
    );
  });

  it("produces a different digest under a different secret", () => {
    const code = "424242";
    expect(digestVerificationCode("a@nyu.edu", code, secret)).not.toBe(
      digestVerificationCode("a@nyu.edu", code, otherSecret)
    );
  });

  it("is a keyed digest, not a bare hash of the code", () => {
    // A plain SHA-256 of six digits is reversible by exhaustion in
    // milliseconds, so a leaked `codeDigest` would leak the code itself. The
    // server secret is the only thing preventing that.
    const digest = digestVerificationCode("a@nyu.edu", "424242", secret);
    expect(digest).toMatch(/^[a-f0-9]{64}$/);
    expect(digest).not.toContain("424242");
  });

  it("refuses to digest with an unusable secret", () => {
    expect(() =>
      digestVerificationCode("a@nyu.edu", "424242", Buffer.from("too-short"))
    ).toThrow(ParticipantCredentialConfigurationError);
  });
});

describe("participant authority credentials", () => {
  it("round-trips a signed credential", () => {
    const credential = signParticipantAuthority(participantId, 1, secret);

    expect(credential.startsWith(`${participantId}.1.`)).toBe(true);
    expect(verifyParticipantAuthority(credential, secret)).toEqual({
      participantId,
      authorityVersion: 1,
    });
  });

  it("carries no email address", () => {
    // The principal is read from the Participant row on every use, so a stale
    // credential cannot assert an address the backend no longer associates with
    // it, and no address sits in device storage as a bearer value.
    const credential = signParticipantAuthority(participantId, 1, secret);
    expect(credential).not.toContain("@");
  });

  it("rejects a credential signed by another deployment", () => {
    const credential = signParticipantAuthority(participantId, 1, otherSecret);
    expect(verifyParticipantAuthority(credential, secret)).toBeNull();
  });

  it("rejects a credential whose participant or version was edited", () => {
    const credential = signParticipantAuthority(participantId, 1, secret);
    const [, , signature] = credential.split(".");

    expect(
      verifyParticipantAuthority(`${otherParticipantId}.1.${signature}`, secret)
    ).toBeNull();
    expect(
      verifyParticipantAuthority(`${participantId}.2.${signature}`, secret)
    ).toBeNull();
  });

  it("binds a version to its own signature", () => {
    // Revocation works only because a version-1 signature cannot be presented
    // as version 2 and vice versa.
    const first = signParticipantAuthority(participantId, 1, secret);
    const second = signParticipantAuthority(participantId, 2, secret);
    expect(first).not.toBe(second);
    expect(verifyParticipantAuthority(second, secret)).toEqual({
      participantId,
      authorityVersion: 2,
    });
  });

  it.each([
    [undefined],
    [null],
    [42],
    [""],
    ["not-a-credential"],
    [`${participantId}.1`],
    [`${participantId}.1.short`],
    [`${participantId}.1.${"A".repeat(44)}`],
    [`${participantId}.0.${"A".repeat(43)}`],
    [`${participantId}.01.${"A".repeat(43)}`],
    [`${participantId}.-1.${"A".repeat(43)}`],
    [`${participantId}. 1.${"A".repeat(43)}`],
    [`${participantId.toUpperCase()}.1.${"A".repeat(43)}`],
    [`${participantId}.1.${"A".repeat(43)}.extra`],
  ])("rejects the malformed credential %j from shape alone", (candidate) => {
    expect(verifyParticipantAuthority(candidate, secret)).toBeNull();
  });

  it("accepts exactly one text form of a signature", () => {
    const credential = signParticipantAuthority(participantId, 1, secret);
    const [id, version, signature] = credential.split(".");
    // Standard-base64 spellings decode to the same bytes; re-encoding is what
    // stops two different credential strings from verifying alike.
    const standard = signature.replace(/-/g, "+").replace(/_/g, "/");
    if (standard !== signature) {
      expect(
        verifyParticipantAuthority(`${id}.${version}.${standard}`, secret)
      ).toBeNull();
    }
    expect(
      verifyParticipantAuthority(`${id}.${version}.${signature}=`, secret)
    ).toBeNull();
  });

  it("refuses to sign or verify with an unusable secret", () => {
    const short = Buffer.from("too-short");
    expect(() => signParticipantAuthority(participantId, 1, short)).toThrow(
      ParticipantCredentialConfigurationError
    );
    expect(() => verifyParticipantAuthority("anything", short)).toThrow(
      ParticipantCredentialConfigurationError
    );
  });

  it.each([
    [undefined],
    [null],
    [""],
    ["not-an-object-id"],
    ["64c0000000000000000000"],
    ["64C0000000000000000000A1"],
  ])("refuses to sign for the participant id %j", (id) => {
    expect(() => signParticipantAuthority(id, 1, secret)).toThrow(
      ParticipantCredentialError
    );
  });

  it.each([
    [0],
    [-1],
    [1.5],
    ["1"],
    [MAXIMUM_PARTICIPANT_AUTHORITY_VERSION + 1],
    [undefined],
  ])("refuses to sign at the authority version %j", (version) => {
    expect(() =>
      signParticipantAuthority(participantId, version, secret)
    ).toThrow(ParticipantCredentialError);
  });

  it("signs at both ends of the accepted version range", () => {
    for (const version of [
      INITIAL_PARTICIPANT_AUTHORITY_VERSION,
      MAXIMUM_PARTICIPANT_AUTHORITY_VERSION,
    ]) {
      const credential = signParticipantAuthority(
        participantId,
        version,
        secret
      );
      expect(verifyParticipantAuthority(credential, secret)).toEqual({
        participantId,
        authorityVersion: version,
      });
    }
  });
});

describe("no raw participant secret reaches a browser bundle", () => {
  it("keeps the participant modules out of client source", () => {
    // Browser bundles are built from `src/client`. A participant signing
    // secret, a code digest, or an authority signer has no business in one.
    const clientSources = readdirSync(
      new URL("./client", import.meta.url),
      { withFileTypes: true }
    )
      .filter((entry) => entry.isFile() && entry.name.endsWith(".ts"))
      .map((entry) =>
        readFileSync(new URL(`./client/${entry.name}`, import.meta.url), "utf8")
      );

    for (const source of clientSources) {
      expect(source).not.toContain("participantCredentials");
      expect(source).not.toContain(PARTICIPANT_SIGNING_SECRET_ENV);
    }
  });
});
