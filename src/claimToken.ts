import {
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

export const CLAIM_TOKEN_HMAC_SECRET_ENV = "CLAIM_TOKEN_HMAC_SECRET";
export const CLAIM_TOKEN_BYTES = 32;
export const MINIMUM_HMAC_SECRET_BYTES = 32;

export class ClaimTokenConfigurationError extends Error {}

export function readClaimTokenHmacSecret(
  environment: NodeJS.ProcessEnv = process.env
): Buffer {
  const configured = environment[CLAIM_TOKEN_HMAC_SECRET_ENV];
  if (!configured) {
    throw new ClaimTokenConfigurationError(
      `Missing required environment variable: ${CLAIM_TOKEN_HMAC_SECRET_ENV}`
    );
  }

  const secret = Buffer.from(configured, "utf8");
  if (secret.byteLength < MINIMUM_HMAC_SECRET_BYTES) {
    throw new ClaimTokenConfigurationError(
      `${CLAIM_TOKEN_HMAC_SECRET_ENV} must contain at least ${MINIMUM_HMAC_SECRET_BYTES} UTF-8 bytes`
    );
  }
  return secret;
}

export function generateClaimToken(): string {
  return randomBytes(CLAIM_TOKEN_BYTES).toString("base64url");
}

export function isValidRawClaimToken(value: unknown): value is string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    return false;
  }

  try {
    const decoded = Buffer.from(value, "base64url");
    return (
      decoded.byteLength === CLAIM_TOKEN_BYTES &&
      decoded.toString("base64url") === value
    );
  } catch {
    return false;
  }
}

export function digestClaimToken(rawToken: string, secret: Buffer): string {
  return createHmac("sha256", secret).update(rawToken, "utf8").digest("hex");
}

export function claimTokenDigestMatches(
  expectedDigest: unknown,
  submittedDigest: string
): boolean {
  if (
    typeof expectedDigest !== "string" ||
    !/^[a-f0-9]{64}$/.test(expectedDigest) ||
    !/^[a-f0-9]{64}$/.test(submittedDigest)
  ) {
    return false;
  }

  return timingSafeEqual(
    Buffer.from(expectedDigest, "hex"),
    Buffer.from(submittedDigest, "hex")
  );
}

