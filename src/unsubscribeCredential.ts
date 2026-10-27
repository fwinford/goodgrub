import { createHmac, timingSafeEqual } from "node:crypto";
import { publicBaseOrigin } from "./publicBaseUrl.js";
import { isPublicActionsPaused } from "./publicActionsPause.js";

/**
 * Stable, authentic unsubscribe credentials.
 *
 * Unlike the confirmation token, nothing about an unsubscribe link is stored:
 * the credential is a signature over identity the Subscriber document already
 * carries, recomputed on demand whenever an alert or digest is built. That is
 * what makes an emailed unsubscribe link keep working indefinitely — across
 * unsubscribe, re-signup, and reconfirmation — instead of dying with a
 * rotated confirmation lifecycle, and it is why building an email performs no
 * database work at all.
 *
 * `unsubscribeCredentialVersion` is the revocation lever: raising it on a
 * document invalidates every credential signed at the previous version. This
 * slice never raises it; the redemption route that would is not implemented.
 */
export const UNSUBSCRIBE_SIGNING_SECRET_ENV = "UNSUBSCRIBE_SIGNING_SECRET";
export const MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES = 32;

/** Accepted public shape: `/unsubscribe?credential=<credential>`. */
export const UNSUBSCRIBE_ROUTE_PATH = "/unsubscribe";
export const UNSUBSCRIBE_CREDENTIAL_PARAMETER = "credential";

export const INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION = 1;
/**
 * Bounded so a stored or submitted version is always a small, comparable
 * integer. Revocation is a rare operator action, so this ceiling cannot be
 * reached by ordinary use, and it keeps a hostile version string from
 * reaching numeric edges.
 */
export const MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION = 1_000_000;

/**
 * Domain-separated and version-tagged, so a signature produced here can never
 * be replayed as some other CommonPlate credential, and so a future canonical
 * format cannot be confused with this one.
 */
const CANONICAL_PREFIX = "commonplate:unsubscribe:v1";

const SUBSCRIBER_ID_PATTERN = /^[0-9a-f]{24}$/;
// No leading zeros, no sign, no whitespace, no exponent: exactly one spelling
// of a version, so two different credential strings cannot verify alike.
const CREDENTIAL_VERSION_PATTERN = /^[1-9][0-9]{0,9}$/;
const SIGNATURE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const SIGNATURE_BYTES = 32;

export class UnsubscribeCredentialConfigurationError extends Error {}
export class UnsubscribeCredentialError extends Error {}

/**
 * A dedicated secret. Reusing the claim-token secret or a confirmation digest
 * would let one credential's compromise forge the other, and would tie the
 * lifetime of a permanent unsubscribe link to an unrelated rotation policy.
 */
export function readUnsubscribeSigningSecret(
  environment: NodeJS.ProcessEnv = process.env
): Buffer {
  const configured = environment[UNSUBSCRIBE_SIGNING_SECRET_ENV];
  if (!configured) {
    throw new UnsubscribeCredentialConfigurationError(
      `Missing required environment variable: ${UNSUBSCRIBE_SIGNING_SECRET_ENV}`
    );
  }

  const secret = Buffer.from(configured, "utf8");
  assertSigningSecret(secret);
  return secret;
}

function assertSigningSecret(secret: Buffer): void {
  if (
    !Buffer.isBuffer(secret) ||
    secret.byteLength < MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES
  ) {
    throw new UnsubscribeCredentialConfigurationError(
      `${UNSUBSCRIBE_SIGNING_SECRET_ENV} must contain at least ${MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES} UTF-8 bytes`
    );
  }
}

/**
 * Activation prerequisite, checked once at startup.
 *
 * An unpaused process must not be able to reach a public action at all without
 * a usable signing secret. Every surface that depends on one — signup and its
 * confirmation email, the confirmation routes, real-time alerts, the hourly
 * digest, and both unsubscribe verbs — becomes reachable only when the pause is
 * off, so the pause is also the condition under which the secret becomes
 * required. Without this check a deployment could accept signups and confirm
 * addresses for hours before the first alert discovered, at send time, that no
 * unsubscribe link could be signed.
 *
 * Paused startup reads nothing: the environment variable is not consulted, so a
 * local or test process serving unrelated functionality is not asked for a
 * secret it cannot use. That ordering is deliberate — it mirrors the paused
 * request paths, which refuse before touching this configuration.
 *
 * The verified secret is deliberately discarded rather than returned or cached.
 * Every signing and verification path already reads it where it is needed, and
 * this exists to fail closed at boot, not to become a second source of key
 * material. Both failure messages name the variable only; neither can carry its
 * value, because the caller logs the message and exits.
 */
export function assertUnsubscribeSigningSecretForActivation(
  environment: NodeJS.ProcessEnv = process.env
): void {
  if (isPublicActionsPaused(environment)) return;
  readUnsubscribeSigningSecret(environment);
}

export function isValidUnsubscribeCredentialVersion(
  value: unknown
): value is number {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION &&
    value <= MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION
  );
}

/**
 * A document written before this field existed carries no version at all and
 * has never been revoked, so it is at the initial version.
 *
 * That physical absence is the only legacy case. A persisted `null` is
 * malformed state rather than an old row — nothing in the schema or in any
 * write path produces one — so resolving it to version 1 would let a version-1
 * credential redeem against a document whose real revocation state nobody
 * knows. It is rejected like any other out-of-range value, which must not be
 * signed or matched as if it were version 1 either.
 */
export function resolveUnsubscribeCredentialVersion(value: unknown): number {
  if (value === undefined) {
    return INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION;
  }
  if (!isValidUnsubscribeCredentialVersion(value)) {
    throw new UnsubscribeCredentialError(
      `unsubscribeCredentialVersion must be an integer between ${INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION} and ${MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION}`
    );
  }
  return value;
}

function canonicalInput(subscriberId: string, credentialVersion: number): string {
  return `${CANONICAL_PREFIX}:${subscriberId}:${credentialVersion}`;
}

function signature(
  subscriberId: string,
  credentialVersion: number,
  secret: Buffer
): string {
  return createHmac("sha256", secret)
    .update(canonicalInput(subscriberId, credentialVersion), "utf8")
    .digest("base64url");
}

/** `<subscriberId>.<credentialVersion>.<signature>` */
export function signUnsubscribeCredential(
  subscriberId: unknown,
  credentialVersion: unknown,
  secret: Buffer
): string {
  assertSigningSecret(secret);
  const id = String(subscriberId ?? "");
  if (!SUBSCRIBER_ID_PATTERN.test(id)) {
    throw new UnsubscribeCredentialError(
      "an unsubscribe credential requires a 24-character hexadecimal subscriber id"
    );
  }
  const version = resolveUnsubscribeCredentialVersion(credentialVersion);
  return `${id}.${version}.${signature(id, version, secret)}`;
}

/** The Subscriber fields a credential is derived from. Nothing else is read. */
export interface UnsubscribeCredentialSubject {
  _id?: unknown;
  unsubscribeCredentialVersion?: unknown;
}

export function unsubscribeCredentialFor(
  subject: UnsubscribeCredentialSubject,
  secret: Buffer = readUnsubscribeSigningSecret()
): string {
  return signUnsubscribeCredential(
    subject?._id,
    subject?.unsubscribeCredentialVersion,
    secret
  );
}

export interface VerifiedUnsubscribeCredential {
  subscriberId: string;
  credentialVersion: number;
}

/**
 * Parses strictly and compares in constant time. A malformed credential is
 * answered from its shape alone: nothing here reads the database, so a
 * redemption route decides separately whether the verified version still
 * matches the stored one.
 */
export function verifyUnsubscribeCredential(
  candidate: unknown,
  secret: Buffer
): VerifiedUnsubscribeCredential | null {
  assertSigningSecret(secret);
  if (typeof candidate !== "string") return null;

  const parts = candidate.split(".");
  if (parts.length !== 3) return null;
  const [subscriberId, versionText, submittedSignature] = parts;

  if (!SUBSCRIBER_ID_PATTERN.test(subscriberId)) return null;
  if (!CREDENTIAL_VERSION_PATTERN.test(versionText)) return null;
  const credentialVersion = Number(versionText);
  if (!isValidUnsubscribeCredentialVersion(credentialVersion)) return null;
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
    signature(subscriberId, credentialVersion, secret),
    "base64url"
  );
  if (!timingSafeEqual(expected, submitted)) return null;

  return { subscriberId, credentialVersion };
}

/**
 * The emailed link. Built from trusted configuration and the subscriber's own
 * identity, with no database read and no stored raw credential.
 */
export function buildUnsubscribeUrl(
  subject: UnsubscribeCredentialSubject,
  secret?: Buffer
): string {
  const credential = unsubscribeCredentialFor(subject, secret);
  return `${publicBaseOrigin()}${UNSUBSCRIBE_ROUTE_PATH}?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${encodeURIComponent(credential)}`;
}
