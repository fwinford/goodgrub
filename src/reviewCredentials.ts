import { createHash, randomBytes, scrypt, timingSafeEqual } from "node:crypto";

const COST = 16384;
const BLOCK_SIZE = 8;
const PARALLELISM = 1;
const KEY_BYTES = 32;

function derive(password: string, salt: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, KEY_BYTES, {
      N: COST, r: BLOCK_SIZE, p: PARALLELISM, maxmem: 32 * 1024 * 1024,
    }, (error, key) => error ? reject(error) : resolve(key));
  });
}

export function isReviewPassword(value: unknown): value is string {
  return typeof value === "string" && /^[\x21-\x7e]{32,256}$/.test(value);
}

export async function hashReviewPassword(password: string): Promise<string> {
  if (!isReviewPassword(password)) throw new Error("Invalid review credential");
  const salt = randomBytes(16);
  const key = await derive(password, salt);
  return `scrypt:${salt.toString("hex")}:${key.toString("hex")}`;
}

export async function verifyReviewPassword(
  password: string,
  encoded: string
): Promise<boolean> {
  if (!isReviewPassword(password)) return false;
  const match = /^scrypt:([a-f0-9]{32}):([a-f0-9]{64})$/.exec(encoded);
  if (!match) throw new Error("Invalid stored review credential");
  const key = await derive(password, Buffer.from(match[1], "hex"));
  return timingSafeEqual(key, Buffer.from(match[2], "hex"));
}

export function generateReviewSession(): string {
  return `ggreview_${randomBytes(32).toString("base64url")}`;
}

export function isReviewSession(value: unknown): value is string {
  return typeof value === "string" && /^ggreview_[A-Za-z0-9_-]{43}$/.test(value);
}

export function digestReviewSession(token: string): string {
  if (!isReviewSession(token)) throw new Error("Invalid review session");
  return createHash("sha256").update(token, "utf8").digest("hex");
}
