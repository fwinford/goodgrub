import { createHmac } from "node:crypto";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import {
  generateVerificationCode,
  isValidParticipantAuthorityVersion,
  isValidRawVerificationCode,
} from "./participantCredentials.js";
import { MINIMUM_IDENTITY_KEY_BYTES } from "./participantIdentityKeys.js";

export const DELETION_CHALLENGE_LIFETIME_MS = 10 * 60 * 1000;
export const DELETION_CHALLENGE_RESEND_COOLDOWN_MS = 60 * 1000;
export const DELETION_CHALLENGE_MAXIMUM_ATTEMPTS = 5;
export const DELETION_AUTHORIZATION_LIFETIME_MS = 5 * 60 * 1000;

const EMAIL_BINDING_PREFIX = "commonplate:participant-deletion-email-binding:v1";
const CHALLENGE_PREFIX = "commonplate:participant-deletion-challenge:v1";
const OBJECT_ID_PATTERN = /^[0-9a-f]{24}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function canonicalDeletionEmail(value: unknown): string {
  const normalized = normalizeParticipantPrincipal(value);
  if (normalized === null) throw new Error("participant deletion requires a canonical NYU participant email");
  return normalized;
}

export function deletionEmailBinding(email: unknown, secret: Buffer): string {
  assertDeletionSecret(secret);
  return createHmac("sha256", secret)
    .update(`${EMAIL_BINDING_PREFIX}:${canonicalDeletionEmail(email)}`, "utf8")
    .digest("hex");
}

export interface DeletionChallengeBinding {
  operationId: string;
  participantId: string;
  emailBinding: string;
  authorityVersion: number;
  readinessGeneration: number;
  challengeGeneration: number;
}

function canonicalChallengeBinding(binding: DeletionChallengeBinding): string {
  if (!UUID_PATTERN.test(binding.operationId)) throw new Error("invalid deletion operation id");
  if (!OBJECT_ID_PATTERN.test(binding.participantId)) throw new Error("invalid deletion participant id");
  if (!/^[0-9a-f]{64}$/.test(binding.emailBinding)) throw new Error("invalid deletion email binding");
  if (!isValidParticipantAuthorityVersion(binding.authorityVersion)) throw new Error("invalid deletion authority version");
  if (!Number.isInteger(binding.readinessGeneration) || binding.readinessGeneration < 1) throw new Error("invalid deletion readiness generation");
  if (!Number.isInteger(binding.challengeGeneration) || binding.challengeGeneration < 1) throw new Error("invalid deletion challenge generation");
  return [
    CHALLENGE_PREFIX,
    binding.operationId,
    binding.participantId,
    binding.emailBinding,
    binding.authorityVersion,
    binding.readinessGeneration,
    binding.challengeGeneration,
  ].join(":");
}

export function digestDeletionChallenge(
  binding: DeletionChallengeBinding,
  code: string,
  secret: Buffer
): string {
  assertDeletionSecret(secret);
  if (!isValidRawVerificationCode(code)) throw new Error("invalid deletion challenge code");
  return createHmac("sha256", secret)
    .update(`${canonicalChallengeBinding(binding)}:${code}`, "utf8")
    .digest("hex");
}

export { generateVerificationCode as generateDeletionChallengeCode, isValidRawVerificationCode as isValidDeletionChallengeCode };

function assertDeletionSecret(secret: Buffer): void {
  if (!Buffer.isBuffer(secret) || secret.byteLength < MINIMUM_IDENTITY_KEY_BYTES) {
    throw new Error("participant deletion signing secret is unavailable");
  }
}
