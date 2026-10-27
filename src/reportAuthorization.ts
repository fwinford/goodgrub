import { randomBytes, timingSafeEqual } from "node:crypto";
import {
  REPORT_HANDOFF_LIFETIME_MS,
} from "./moderationConstants.js";
import {
  deriveKeyedDigest,
  type SafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";

const TOKEN_PATTERN = /^ra1\.([A-Za-z0-9_-]{1,32})\.(\d{13})\.([A-Za-z0-9_-]{32})\.([0-9a-f]{64})$/;

function authorizationMac(
  keyring: SafetyIdentityKeyring,
  keyId: string,
  expiresAt: number,
  nonce: string,
  participantId: string,
  requestId: string,
  counterpartId?: string
): string {
  // A counterpart-bound token never validates without that exact counterpart,
  // and an unbound token never validates with one.
  const counterpart = counterpartId === undefined ? "" : `\0${counterpartId}`;
  return deriveKeyedDigest(
    keyring,
    keyId,
    "report-authorization",
    `ra1\0${expiresAt}\0${nonce}\0${participantId}\0${requestId}${counterpart}`
  );
}

/** Minted only after the Block transaction confirms a newly inserted row. */
export function mintReportAuthorization(
  keyring: SafetyIdentityKeyring,
  participantId: string,
  requestId: string,
  now: Date,
  nonce = randomBytes(24).toString("base64url"),
  counterpartId?: string
): string {
  const expiresAt = now.getTime() + REPORT_HANDOFF_LIFETIME_MS;
  const keyId = keyring.currentKeyId;
  const mac = authorizationMac(keyring, keyId, expiresAt, nonce, participantId, requestId, counterpartId);
  return `ra1.${keyId}.${expiresAt}.${nonce}.${mac}`;
}

/** Opaque, request- and caller-bound, time-limited token; it carries no identity. */
export function isValidReportAuthorization(
  token: unknown,
  keyring: SafetyIdentityKeyring,
  participantId: string,
  requestId: string,
  now: Date,
  counterpartId?: string
): boolean {
  if (typeof token !== "string") return false;
  const match = TOKEN_PATTERN.exec(token);
  if (!match) return false;
  const [, keyId, rawExpiry, nonce, suppliedMac] = match;
  const expiresAt = Number(rawExpiry);
  const key = keyring.keys.get(keyId);
  if (!key || !Number.isSafeInteger(expiresAt) || expiresAt <= now.getTime()) return false;
  if (expiresAt > now.getTime() + REPORT_HANDOFF_LIFETIME_MS) return false;
  const expected = authorizationMac(
    keyring, keyId, expiresAt, nonce, participantId, requestId, counterpartId
  );
  return timingSafeEqual(Buffer.from(suppliedMac, "hex"), Buffer.from(expected, "hex"));
}
