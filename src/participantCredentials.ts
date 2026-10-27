import { createHmac, randomInt, timingSafeEqual } from "node:crypto";
import { isPublicActionsPaused } from "./publicActionsPause.js";

/**
 * Every secret this slice needs, in one purpose-bound namespace.
 *
 * Participant identity is a person's proof of mailbox control. It must not
 * share key material with subscription confirmation, unsubscribe links,
 * installation credentials, or claim tokens: those answer different questions
 * about different subjects, and a compromise of one must not forge another.
 * `PARTICIPANT_SIGNING_SECRET` is therefore its own variable, read only here.
 *
 * The two things derived from it are separated again, by canonical prefix, so
 * an emailed verification code can never be replayed as a participant
 * authority credential and neither can be confused with a future format:
 *
 * - `commonplate:participant-code:v1:<principal>:<code>` — the stored digest of
 *   a live challenge. The code is bound to the address it was mailed to, so a
 *   code issued for one participant cannot verify another.
 * - `commonplate:participant-authority:v1:<participantId>:<version>` — the
 *   signature inside the credential the app holds after verifying.
 *
 * Nothing raw is persisted on either side: the challenge row stores only the
 * HMAC digest, and the authority credential is a signature over identity the
 * Participant document already carries, recomputed on demand.
 */
export const PARTICIPANT_SIGNING_SECRET_ENV = "PARTICIPANT_SIGNING_SECRET";
export const MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES = 32;

export class ParticipantCredentialConfigurationError extends Error {}
export class ParticipantCredentialError extends Error {}

/**
 * Six digits, because a person types this out of an email on a phone. Six
 * digits alone is a small space, which is exactly why every one of the four
 * bounds below is load-bearing rather than decorative: a ten-minute lifetime,
 * five attempts per challenge, a resend that supersedes rather than
 * accumulates, and a per-IP route limiter. Guessing needs ~200,000 tries on
 * average against a challenge that permits five and dies in ten minutes.
 *
 * The digest is an HMAC rather than a bare hash for the same reason: a plain
 * SHA-256 of a six-digit code is trivially reversed from a leaked database, so
 * the server secret is what keeps a stolen `codeDigest` from yielding the code.
 */
export const VERIFICATION_CODE_DIGITS = 6;
const VERIFICATION_CODE_EXCLUSIVE_MAXIMUM = 10 ** VERIFICATION_CODE_DIGITS;
const VERIFICATION_CODE_PATTERN = /^[0-9]{6}$/;

export const INITIAL_PARTICIPANT_AUTHORITY_VERSION = 1;
/**
 * Bounded like the unsubscribe credential version, and for the same reasons: a
 * stored or submitted version is always a small comparable integer, revocation
 * is a rare action that cannot reach this ceiling by ordinary use, and a
 * hostile version string cannot reach numeric edges.
 */
export const MAXIMUM_PARTICIPANT_AUTHORITY_VERSION = 1_000_000;

const CODE_CANONICAL_PREFIX = "commonplate:participant-code:v1";
const AUTHORITY_CANONICAL_PREFIX = "commonplate:participant-authority:v1";

const PARTICIPANT_ID_PATTERN = /^[0-9a-f]{24}$/;
// No leading zeros, no sign, no whitespace, no exponent: exactly one spelling
// of a version, so two different credential strings cannot verify alike.
const AUTHORITY_VERSION_PATTERN = /^[1-9][0-9]{0,9}$/;
const SIGNATURE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const SIGNATURE_BYTES = 32;

export function readParticipantSigningSecret(
  environment: NodeJS.ProcessEnv = process.env
): Buffer {
  const configured = environment[PARTICIPANT_SIGNING_SECRET_ENV];
  if (!configured) {
    throw new ParticipantCredentialConfigurationError(
      `Missing required environment variable: ${PARTICIPANT_SIGNING_SECRET_ENV}`
    );
  }

  const secret = Buffer.from(configured, "utf8");
  assertParticipantSigningSecret(secret);
  return secret;
}

/** Shared internal guard for purpose-separated participant-security helpers.
 * This module remains the sole place that knows the configured secret's
 * environment name or minimum policy. */
export function assertParticipantSigningSecret(secret: Buffer): void {
  if (
    !Buffer.isBuffer(secret) ||
    secret.byteLength < MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES
  ) {
    throw new ParticipantCredentialConfigurationError(
      `${PARTICIPANT_SIGNING_SECRET_ENV} must contain at least ${MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES} UTF-8 bytes`
    );
  }
}

/**
 * Activation prerequisite, checked once at startup beside the unsubscribe and
 * APNs checks.
 *
 * Once public actions are unpaused, no request can be created and no request
 * can be claimed without a participant credential, so a process that cannot
 * sign or verify one has nothing usable to offer: every participant action
 * would fail at its first attempt instead of at boot. Paused startup reads
 * nothing, exactly like the neighbouring checks, so a local or test process
 * serving unrelated functionality is not asked for a secret it cannot use.
 *
 * The verified secret is deliberately discarded rather than returned or cached:
 * every signing and verification path reads it where it is needed, and this
 * exists to fail closed at boot, not to become a second source of key material.
 */
export function assertParticipantSigningSecretForActivation(
  environment: NodeJS.ProcessEnv = process.env
): void {
  if (isPublicActionsPaused(environment)) return;
  readParticipantSigningSecret(environment);
}

/**
 * `randomInt` rather than `randomBytes % 1_000_000`: the modulo would make the
 * low codes measurably likelier, and a verification code's whole value is that
 * every one of them is equally unlikely.
 */
export function generateVerificationCode(): string {
  return String(randomInt(0, VERIFICATION_CODE_EXCLUSIVE_MAXIMUM)).padStart(
    VERIFICATION_CODE_DIGITS,
    "0"
  );
}

/**
 * Rejects anything that cannot be a code this service issued, so a malformed
 * redemption is answered from shape alone, spends no attempt, and never reaches
 * the database.
 */
export function isValidRawVerificationCode(value: unknown): value is string {
  return typeof value === "string" && VERIFICATION_CODE_PATTERN.test(value);
}

/**
 * Binds the code to the exact principal it was mailed to. Without the address
 * in the canonical input, a code observed for one participant could be replayed
 * against another participant's live challenge.
 */
export function digestVerificationCode(
  principal: string,
  code: string,
  secret: Buffer
): string {
  assertParticipantSigningSecret(secret);
  return createHmac("sha256", secret)
    .update(`${CODE_CANONICAL_PREFIX}:${principal}:${code}`, "utf8")
    .digest("hex");
}

export function isValidParticipantAuthorityVersion(
  value: unknown
): value is number {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= INITIAL_PARTICIPANT_AUTHORITY_VERSION &&
    value <= MAXIMUM_PARTICIPANT_AUTHORITY_VERSION
  );
}

function authorityCanonicalInput(
  participantId: string,
  authorityVersion: number
): string {
  return `${AUTHORITY_CANONICAL_PREFIX}:${participantId}:${authorityVersion}`;
}

function authoritySignature(
  participantId: string,
  authorityVersion: number,
  secret: Buffer
): string {
  return createHmac("sha256", secret)
    .update(authorityCanonicalInput(participantId, authorityVersion), "utf8")
    .digest("base64url");
}

/**
 * `<participantId>.<authorityVersion>.<signature>`
 *
 * Deliberately carries no email. The credential names a Participant row and the
 * revocation counter it was signed at; the principal is read from that row on
 * every use, so a stale credential can never assert an address the backend no
 * longer associates with it, and the address itself is not sitting in device
 * storage as a bearer value.
 */
export function signParticipantAuthority(
  participantId: unknown,
  authorityVersion: unknown,
  secret: Buffer
): string {
  assertParticipantSigningSecret(secret);
  const id = String(participantId ?? "");
  if (!PARTICIPANT_ID_PATTERN.test(id)) {
    throw new ParticipantCredentialError(
      "a participant authority requires a 24-character hexadecimal participant id"
    );
  }
  if (!isValidParticipantAuthorityVersion(authorityVersion)) {
    throw new ParticipantCredentialError(
      `authorityVersion must be an integer between ${INITIAL_PARTICIPANT_AUTHORITY_VERSION} and ${MAXIMUM_PARTICIPANT_AUTHORITY_VERSION}`
    );
  }
  return `${id}.${authorityVersion}.${authoritySignature(
    id,
    authorityVersion,
    secret
  )}`;
}

export interface VerifiedParticipantAuthority {
  participantId: string;
  authorityVersion: number;
}

/**
 * Parses strictly and compares in constant time. A malformed or unsigned
 * credential is answered from its shape alone: nothing here reads the database,
 * so the caller decides separately whether the named participant still exists
 * and whether the verified version still matches the stored one.
 */
export function verifyParticipantAuthority(
  candidate: unknown,
  secret: Buffer
): VerifiedParticipantAuthority | null {
  assertParticipantSigningSecret(secret);
  if (typeof candidate !== "string") return null;

  const parts = candidate.split(".");
  if (parts.length !== 3) return null;
  const [participantId, versionText, submittedSignature] = parts;

  if (!PARTICIPANT_ID_PATTERN.test(participantId)) return null;
  if (!AUTHORITY_VERSION_PATTERN.test(versionText)) return null;
  const authorityVersion = Number(versionText);
  if (!isValidParticipantAuthorityVersion(authorityVersion)) return null;
  if (!SIGNATURE_PATTERN.test(submittedSignature)) return null;

  const submitted = Buffer.from(submittedSignature, "base64url");
  // Re-encoding rejects the non-canonical base64url spellings that decode to
  // the same bytes, so one signature has exactly one accepted text form.
  if (
    submitted.byteLength !== SIGNATURE_BYTES ||
    submitted.toString("base64url") !== submittedSignature
  ) {
    return null;
  }

  const expected = Buffer.from(
    authoritySignature(participantId, authorityVersion, secret),
    "base64url"
  );
  if (!timingSafeEqual(expected, submitted)) return null;

  return { participantId, authorityVersion };
}
