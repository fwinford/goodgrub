import { createHash, createHmac, scrypt as scryptCallback, timingSafeEqual } from "node:crypto";
import { readSafetyIdentityKeyring, type SafetyIdentityKeyring } from "./safetyIdentityKeyring.js";

const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export interface ModeratorConfig {
  origin: string;
  passphraseHash: {
    cost: number;
    blockSize: number;
    parallelization: number;
    salt: Buffer;
    hash: Buffer;
  };
  totpSecret: Buffer;
  keyring: SafetyIdentityKeyring;
  alertRecipient: string;
  supportEmail: string;
  fingerprint: string;
}

function decodeBase32(value: string): Buffer | null {
  const normalized = value.replace(/=+$/, "").toUpperCase();
  if (!/^[A-Z2-7]{32,128}$/.test(normalized)) return null;
  let buffer = 0;
  let bits = 0;
  const bytes: number[] = [];
  for (const character of normalized) {
    const index = BASE32.indexOf(character);
    if (index < 0) return null;
    buffer = (buffer << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bytes.push((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(bytes);
}

function parsePassphraseHash(value: string) {
  const match = /^scrypt-v1\$(\d{4,7})\$(\d{1,2})\$(\d{1,2})\$([A-Za-z0-9_-]{22,})\$([A-Za-z0-9_-]{43,})$/.exec(value);
  if (!match) return null;
  const cost = Number(match[1]);
  const blockSize = Number(match[2]);
  const parallelization = Number(match[3]);
  const salt = Buffer.from(match[4], "base64url");
  const hash = Buffer.from(match[5], "base64url");
  if (
    !Number.isSafeInteger(cost) ||
    cost < 16_384 ||
    cost > 262_144 ||
    (cost & (cost - 1)) !== 0 ||
    blockSize < 8 ||
    blockSize > 16 ||
    parallelization < 1 ||
    parallelization > 4 ||
    salt.length < 16 ||
    hash.length < 32 ||
    hash.length > 64
  ) {
    return null;
  }
  return { cost, blockSize, parallelization, salt, hash };
}

function isEmailAddress(value: string): boolean {
  return value.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

export function readModeratorConfig(env: NodeJS.ProcessEnv = process.env): ModeratorConfig | null {
  const originValue = env.MODERATOR_ORIGIN;
  const passphraseValue = env.MODERATOR_PASSPHRASE_HASH;
  const totpValue = env.MODERATOR_TOTP_SECRET;
  const recipientValue = env.REPORT_ALERT_RECIPIENT;
  const supportValue = env.SUPPORT_EMAIL;
  if (
    !originValue ||
    !passphraseValue ||
    !totpValue ||
    !recipientValue ||
    !supportValue ||
    !isEmailAddress(recipientValue) ||
    !isEmailAddress(supportValue)
  ) {
    return null;
  }

  let origin: string;
  let keyring: SafetyIdentityKeyring;
  const passphraseHash = parsePassphraseHash(passphraseValue);
  const totpSecret = decodeBase32(totpValue);
  try {
    const parsedOrigin = new URL(originValue);
    if (
      parsedOrigin.protocol !== "https:" ||
      parsedOrigin.origin !== originValue ||
      parsedOrigin.username ||
      parsedOrigin.password
    ) {
      return null;
    }
    origin = parsedOrigin.origin;
    keyring = readSafetyIdentityKeyring(env);
  } catch {
    return null;
  }
  if (!passphraseHash || !totpSecret || totpSecret.length < 20) return null;

  const fingerprint = createHash("sha256")
    .update(
      [
        origin,
        passphraseValue,
        totpValue,
        env.SAFETY_IDENTITY_KEYRING ?? "",
        recipientValue,
        supportValue,
      ].join("\0")
    )
    .digest("hex");

  return {
    origin,
    passphraseHash,
    totpSecret,
    keyring,
    alertRecipient: recipientValue,
    supportEmail: supportValue,
    fingerprint,
  };
}

export async function verifyModeratorPassphrase(
  passphrase: unknown,
  encoded: ModeratorConfig["passphraseHash"]
): Promise<boolean> {
  if (typeof passphrase !== "string" || passphrase.length < 1 || passphrase.length > 1024) {
    return false;
  }
  const actual = await new Promise<Buffer>((resolve, reject) => {
    scryptCallback(
      passphrase,
      encoded.salt,
      encoded.hash.length,
      {
        N: encoded.cost,
        r: encoded.blockSize,
        p: encoded.parallelization,
        maxmem: Math.max(64 * 1024 * 1024, 256 * encoded.cost * encoded.blockSize),
      },
      (error, key) => (error ? reject(error) : resolve(key))
    );
  });
  return actual.length === encoded.hash.length && timingSafeEqual(actual, encoded.hash);
}

function totpAt(secret: Buffer, step: number): string {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const digest = createHmac("sha1", secret).update(counter).digest();
  const offset = digest[digest.length - 1]! & 0x0f;
  const value =
    ((digest[offset]! & 0x7f) << 24) |
    ((digest[offset + 1]! & 0xff) << 16) |
    ((digest[offset + 2]! & 0xff) << 8) |
    (digest[offset + 3]! & 0xff);
  return String(value % 1_000_000).padStart(6, "0");
}

export function matchTotpStep(
  token: unknown,
  secret: Buffer,
  now: Date
): number | null {
  if (typeof token !== "string" || !/^\d{6}$/.test(token)) return null;
  const current = Math.floor(now.getTime() / 30_000);
  const supplied = Buffer.from(token);
  const matches: number[] = [];
  for (const step of [current - 1, current, current + 1]) {
    const expected = Buffer.from(totpAt(secret, step));
    if (timingSafeEqual(supplied, expected)) matches.push(step);
  }
  return matches.length > 0 ? matches[matches.length - 1]! : null;
}
