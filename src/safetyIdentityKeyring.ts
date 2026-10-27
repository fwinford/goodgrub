import { createHmac, timingSafeEqual } from "node:crypto";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";

/**
 * The restricted safety-identity keyring and its keyed derivations (W4-U1.2,
 * P2 fixed mechanism items 2 and 9).
 *
 * ## Namespace
 *
 * `SAFETY_IDENTITY_KEYRING` is its own configuration variable. Nothing here is
 * derived from, shared with, or interchangeable with any other credential
 * namespace (the participant, claim-token and unsubscribe signing secrets, P2's
 * deletion-binding material, `authorityVersion` or operation IDs). This module
 * names none of them:
 * a keyring whose key bytes equal the value of **any other environment variable**
 * is refused, which covers every present and future secret, so a copy-paste of
 * one secret into another namespace fails visibly instead of silently coupling
 * two namespaces.
 *
 * ## Format
 *
 * ```json
 * { "current": "k2", "keys": { "k1": "<base64url>", "k2": "<base64url>" } }
 * ```
 *
 * Each key decodes to at least 32 bytes. `current` signs new identities;
 * every configured key is tried on lookup, so superseded keys stay configured
 * while any live identity references them. Rotating or adding a key never lifts
 * a suspension. A missing, malformed or unreadable keyring **fails closed**: the
 * reader throws, and callers treat that as "unavailable", never as "no
 * restriction".
 *
 * Key material never appears in an error message, a log line or a return value
 * other than the keyring object itself.
 */
export const SAFETY_IDENTITY_KEYRING_ENV = "SAFETY_IDENTITY_KEYRING";
export const MINIMUM_SAFETY_IDENTITY_KEY_BYTES = 32;
export const MAXIMUM_SAFETY_IDENTITY_KEYS = 8;

const KEY_ID_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;

export class SafetyIdentityKeyringError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SafetyIdentityKeyringError";
  }
}

export interface SafetyIdentityKeyring {
  readonly currentKeyId: string;
  readonly keys: ReadonlyMap<string, Buffer>;
}

function decodeKey(value: unknown): Buffer | null {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+={0,2}$/.test(value)) {
    return null;
  }
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= MINIMUM_SAFETY_IDENTITY_KEY_BYTES ? bytes : null;
}

/**
 * Every byte string a configured credential value plausibly stands for. Secrets
 * are configured as text, so the same key material appears as its raw UTF-8
 * bytes, as base64 / base64url of the bytes, or as hexadecimal of the bytes; a
 * comparison of decoded keyring bytes against UTF-8 alone would accept a
 * base64url or hex secret pasted into the keyring. Surrounding whitespace (a
 * trailing newline from a secret file) is ignored.
 */
function representationsOf(value: string): Buffer[] {
  const text = value.trim();
  if (text === "") return [];
  const candidates = [Buffer.from(text, "utf8")];
  if (/^[A-Za-z0-9+/_-]+={0,2}$/.test(text)) candidates.push(Buffer.from(text, "base64"));
  if (/^(?:[0-9a-fA-F]{2})+$/.test(text)) candidates.push(Buffer.from(text, "hex"));
  return candidates;
}

function equalsSecret(key: Buffer, secret: string | undefined): boolean {
  if (!secret) return false;
  return representationsOf(secret).some(
    (candidate) => candidate.length === key.length && timingSafeEqual(candidate, key)
  );
}

/**
 * The configured keyring. Throws `SafetyIdentityKeyringError` with a message
 * that names the problem class only (never a value) when the variable is
 * absent, malformed, or violates namespace separation.
 */
export function readSafetyIdentityKeyring(
  env: NodeJS.ProcessEnv = process.env
): SafetyIdentityKeyring {
  const raw = env[SAFETY_IDENTITY_KEYRING_ENV];
  if (typeof raw !== "string" || raw.trim() === "") {
    throw new SafetyIdentityKeyringError("The safety-identity keyring is not configured.");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new SafetyIdentityKeyringError("The safety-identity keyring is malformed.");
  }
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    Array.isArray(parsed) ||
    typeof (parsed as { current?: unknown }).current !== "string" ||
    typeof (parsed as { keys?: unknown }).keys !== "object" ||
    (parsed as { keys?: unknown }).keys === null ||
    Array.isArray((parsed as { keys?: unknown }).keys)
  ) {
    throw new SafetyIdentityKeyringError("The safety-identity keyring is malformed.");
  }

  const { current, keys: rawKeys } = parsed as {
    current: string;
    keys: Record<string, unknown>;
  };
  const entries = Object.entries(rawKeys);
  if (entries.length === 0 || entries.length > MAXIMUM_SAFETY_IDENTITY_KEYS) {
    throw new SafetyIdentityKeyringError("The safety-identity keyring is malformed.");
  }

  const keys = new Map<string, Buffer>();
  for (const [keyId, value] of entries) {
    const bytes = decodeKey(value);
    if (!KEY_ID_PATTERN.test(keyId) || bytes === null) {
      throw new SafetyIdentityKeyringError("The safety-identity keyring is malformed.");
    }
    for (const [, existing] of keys) {
      if (existing.equals(bytes)) {
        throw new SafetyIdentityKeyringError("The safety-identity keyring is malformed.");
      }
    }
    for (const [name, other] of Object.entries(env)) {
      if (name !== SAFETY_IDENTITY_KEYRING_ENV && equalsSecret(bytes, other)) {
        throw new SafetyIdentityKeyringError(
          "The safety-identity keyring must not share key material with another credential namespace."
        );
      }
    }
    keys.set(keyId, bytes);
  }
  if (!keys.has(current)) {
    throw new SafetyIdentityKeyringError("The safety-identity keyring is malformed.");
  }
  return { currentKeyId: current, keys };
}

export type SafetyIdentityKeyringInspection =
  | { state: "ok"; keyring: SafetyIdentityKeyring }
  | { state: "absent" | "invalid"; keyring: null };

/**
 * The keyring and *why* it is unavailable, if it is. Health and alerting need
 * the distinction: an unconfigured keyring on a deployment that holds nothing
 * keyed is normal (the moderation surface simply is not operable), while a
 * configured-but-malformed keyring is always an incident. No value is returned
 * or logged either way.
 */
export function inspectSafetyIdentityKeyring(
  env: NodeJS.ProcessEnv = process.env
): SafetyIdentityKeyringInspection {
  const raw = env[SAFETY_IDENTITY_KEYRING_ENV];
  if (typeof raw !== "string" || raw.trim() === "") return { state: "absent", keyring: null };
  try {
    return { state: "ok", keyring: readSafetyIdentityKeyring(env) };
  } catch {
    return { state: "invalid", keyring: null };
  }
}

/** The keyring, or `null` when it is unavailable. Never throws. */
export function tryReadSafetyIdentityKeyring(
  env: NodeJS.ProcessEnv = process.env
): SafetyIdentityKeyring | null {
  try {
    return readSafetyIdentityKeyring(env);
  } catch {
    return null;
  }
}

/**
 * Purposes are domain-separated inside the MAC input, so a digest minted for
 * one purpose can never be presented as another's.
 */
export type KeyedDigestPurpose =
  | "safety-identity"
  | "report-operation"
  | "report-participant"
  | "report-request"
  | "report-handoff"
  | "report-authorization";

function keyedDigest(
  keyring: SafetyIdentityKeyring,
  keyId: string,
  purpose: KeyedDigestPurpose,
  value: string
): string {
  const key = keyring.keys.get(keyId);
  if (!key) {
    throw new SafetyIdentityKeyringError("The safety-identity key is unavailable.");
  }
  return createHmac("sha256", key)
    .update(`commonplate:${purpose}:v1\0`)
    .update(value, "utf8")
    .digest("hex");
}

/**
 * A non-secret check value for one key: a MAC of a fixed constant under it.
 * Recorded once per key id, it detects a key id later reused with different key
 * material, which would otherwise make every digest minted under the original
 * material silently unfindable.
 */
export function deriveKeyCheck(keyring: SafetyIdentityKeyring, keyId: string): string {
  const key = keyring.keys.get(keyId);
  if (!key) throw new SafetyIdentityKeyringError("The safety-identity key is unavailable.");
  return createHmac("sha256", key).update("commonplate:key-check:v1\0").digest("hex");
}

export interface KeyedDigest {
  keyId: string;
  digest: string;
}

/**
 * The digest of `value` under every configured key, current key first. Lookup
 * tries each; creation uses the first.
 */
export function deriveKeyedDigests(
  keyring: SafetyIdentityKeyring,
  purpose: KeyedDigestPurpose,
  value: string
): KeyedDigest[] {
  const ordered = [
    keyring.currentKeyId,
    ...[...keyring.keys.keys()].filter((id) => id !== keyring.currentKeyId),
  ];
  return ordered.map((keyId) => ({
    keyId,
    digest: keyedDigest(keyring, keyId, purpose, value),
  }));
}

export function deriveKeyedDigest(
  keyring: SafetyIdentityKeyring,
  keyId: string,
  purpose: KeyedDigestPurpose,
  value: string
): string {
  return keyedDigest(keyring, keyId, purpose, value);
}

/**
 * The safety-identity digests for a verified email, current key first. The
 * email is normalized exactly as the participant principal is (no alias, `+tag`
 * or domain folding); a value that is not an allowed principal yields `null`
 * so no digest of an arbitrary string can be minted.
 */
export function deriveSafetyIdentityDigests(
  keyring: SafetyIdentityKeyring,
  email: unknown
): KeyedDigest[] | null {
  const principal = normalizeParticipantPrincipal(email);
  if (principal === null) return null;
  return deriveKeyedDigests(keyring, "safety-identity", principal);
}
