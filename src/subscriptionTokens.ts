import { createHash, randomBytes } from "node:crypto";

/**
 * Shape and hashing shared by every subscriber credential: the confirmation
 * token issued at signup and the unsubscribe token issued at confirmation.
 *
 * Both raw values exist only inside an emailed link; the database stores only
 * a SHA-256 digest. Signup and confirmation must therefore agree on one
 * implementation, or a link issued by one could never be redeemed by the other.
 */
export const SUBSCRIPTION_TOKEN_BYTES = 32;

export function generateSubscriptionToken(): string {
  return randomBytes(SUBSCRIPTION_TOKEN_BYTES).toString("base64url");
}

export function digestSubscriptionToken(rawToken: string): string {
  return createHash("sha256").update(rawToken).digest("hex");
}

/**
 * Rejects anything that cannot be a token this service issued, so a malformed
 * redemption is answered from shape alone and never reaches the database.
 */
export function isValidRawSubscriptionToken(value: unknown): value is string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    return false;
  }

  try {
    const decoded = Buffer.from(value, "base64url");
    return (
      decoded.byteLength === SUBSCRIPTION_TOKEN_BYTES &&
      decoded.toString("base64url") === value
    );
  } catch {
    return false;
  }
}
