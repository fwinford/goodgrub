import { createHash, randomBytes } from "node:crypto";

/**
 * Shape and hashing for the opaque, high-entropy credential one CommonPlate
 * app installation generates for itself and reuses for the lifetime of that
 * installation. Like the subscriber confirmation token, only its SHA-256
 * digest is ever persisted; the raw value exists only in the request body
 * sent from the device. It proves only continuity of calls from the same
 * installation — never a person, account, or email identity.
 */
export const INSTALLATION_CREDENTIAL_BYTES = 32;

export function generateInstallationCredential(): string {
  return randomBytes(INSTALLATION_CREDENTIAL_BYTES).toString("base64url");
}

export function digestInstallationCredential(rawCredential: string): string {
  return createHash("sha256").update(rawCredential).digest("hex");
}

/**
 * Rejects anything that cannot be a credential this shape describes, so a
 * malformed request is answered from shape alone and never reaches the
 * database.
 */
export function isValidRawInstallationCredential(
  value: unknown
): value is string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    return false;
  }

  try {
    const decoded = Buffer.from(value, "base64url");
    return (
      decoded.byteLength === INSTALLATION_CREDENTIAL_BYTES &&
      decoded.toString("base64url") === value
    );
  } catch {
    return false;
  }
}
