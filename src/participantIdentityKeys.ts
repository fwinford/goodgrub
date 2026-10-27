import { createHmac, timingSafeEqual } from "node:crypto";
import type { ClientSession } from "mongoose";
import { ParticipantIdentityKeyVersion } from "../models/db.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import { isPublicActionsPaused } from "./publicActionsPause.js";

export const PARTICIPATION_HMAC_KEYRING_ENV = "PARTICIPATION_HMAC_KEYRING";
export const BLOCK_SAFETY_HMAC_KEYRING_ENV = "BLOCK_SAFETY_HMAC_KEYRING";
export const PARTICIPANT_DELETION_SIGNING_SECRET_ENV =
  "PARTICIPANT_DELETION_SIGNING_SECRET";
export const PARTICIPANT_IDENTITY_NORMALIZATION_VERSION = 1;
export const MINIMUM_IDENTITY_KEY_BYTES = 32;
export const PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS = 5_000;

export type ParticipantIdentityPurpose = "participation" | "block-safety";

export interface ParticipantIdentityKeyRing {
  currentVersion: number;
  keys: ReadonlyMap<number, Buffer>;
}

export interface ParticipantIdentityAlias {
  version: number;
  digest: string;
}

export class ParticipantIdentityConfigurationError extends Error {}

const PURPOSE_CONFIG: Record<
  ParticipantIdentityPurpose,
  { environmentName: string; domain: string }
> = {
  participation: {
    environmentName: PARTICIPATION_HMAC_KEYRING_ENV,
    domain: "commonplate:request-participation:v1",
  },
  "block-safety": {
    environmentName: BLOCK_SAFETY_HMAC_KEYRING_ENV,
    domain: "commonplate:participant-block-safety:v1",
  },
};

function invalidConfiguration(): never {
  throw new ParticipantIdentityConfigurationError(
    "Participant identity key configuration is unavailable"
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseKeyRing(
  purpose: ParticipantIdentityPurpose,
  environment: NodeJS.ProcessEnv
): ParticipantIdentityKeyRing {
  const raw = environment[PURPOSE_CONFIG[purpose].environmentName];
  if (typeof raw !== "string" || raw.length === 0) return invalidConfiguration();
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    return invalidConfiguration();
  }
  if (!isRecord(decoded) || !isRecord(decoded.keys)) return invalidConfiguration();
  const currentVersion = decoded.currentVersion;
  if (
    typeof currentVersion !== "number" ||
    !Number.isSafeInteger(currentVersion) ||
    currentVersion < 1
  ) {
    return invalidConfiguration();
  }
  const keys = new Map<number, Buffer>();
  for (const [versionText, encoded] of Object.entries(decoded.keys)) {
    if (!/^[1-9][0-9]*$/.test(versionText) || typeof encoded !== "string") {
      return invalidConfiguration();
    }
    const version = Number(versionText);
    if (!Number.isSafeInteger(version)) return invalidConfiguration();
    const key = Buffer.from(encoded, "base64");
    if (
      key.byteLength < MINIMUM_IDENTITY_KEY_BYTES ||
      key.toString("base64") !== encoded
    ) {
      return invalidConfiguration();
    }
    keys.set(version, key);
  }
  if (!keys.has(currentVersion)) return invalidConfiguration();
  return { currentVersion, keys };
}

function sameSecret(first: Buffer, second: Buffer): boolean {
  return (
    first.byteLength === second.byteLength && timingSafeEqual(first, second)
  );
}

function assertIndependentKeyMaterial(
  participation: ParticipantIdentityKeyRing,
  blockSafety: ParticipantIdentityKeyRing,
  environment: NodeJS.ProcessEnv
): void {
  const configuredSecrets = [
    environment.PARTICIPANT_SIGNING_SECRET,
    environment[PARTICIPANT_DELETION_SIGNING_SECRET_ENV],
    environment.CLAIM_TOKEN_HMAC_SECRET,
    environment.UNSUBSCRIBE_SIGNING_SECRET,
  ]
    .filter((secret): secret is string => typeof secret === "string" && secret.length > 0)
    .map((secret) => Buffer.from(secret, "utf8"));
  const allKeys = [
    ...participation.keys.values(),
    ...blockSafety.keys.values(),
  ];
  for (let left = 0; left < allKeys.length; left += 1) {
    for (let right = left + 1; right < allKeys.length; right += 1) {
      if (sameSecret(allKeys[left], allKeys[right])) return invalidConfiguration();
    }
    if (configuredSecrets.some((secret) => sameSecret(allKeys[left], secret))) {
      return invalidConfiguration();
    }
  }
  for (let left = 0; left < configuredSecrets.length; left += 1) {
    for (let right = left + 1; right < configuredSecrets.length; right += 1) {
      if (sameSecret(configuredSecrets[left], configuredSecrets[right])) {
        return invalidConfiguration();
      }
    }
  }
}

export function readParticipantIdentityKeyRing(
  purpose: ParticipantIdentityPurpose,
  environment: NodeJS.ProcessEnv = process.env
): ParticipantIdentityKeyRing {
  const participation = parseKeyRing("participation", environment);
  const blockSafety = parseKeyRing("block-safety", environment);
  assertIndependentKeyMaterial(participation, blockSafety, environment);
  return purpose === "participation" ? participation : blockSafety;
}

export function readParticipantDeletionSigningSecret(
  environment: NodeJS.ProcessEnv = process.env
): Buffer {
  const configured = environment[PARTICIPANT_DELETION_SIGNING_SECRET_ENV];
  if (typeof configured !== "string" || configured.length === 0) {
    return invalidConfiguration();
  }
  const secret = Buffer.from(configured, "utf8");
  if (secret.byteLength < MINIMUM_IDENTITY_KEY_BYTES) {
    return invalidConfiguration();
  }
  const participation = parseKeyRing("participation", environment);
  const blockSafety = parseKeyRing("block-safety", environment);
  assertIndependentKeyMaterial(participation, blockSafety, environment);
  return secret;
}

export function assertParticipantIdentityCredentialsForActivation(
  environment: NodeJS.ProcessEnv = process.env
): void {
  if (isPublicActionsPaused(environment)) return;
  readParticipantIdentityKeyRing("participation", environment);
  readParticipantDeletionSigningSecret(environment);
}

export interface ParticipantIdentityManifestEntry {
  purpose: ParticipantIdentityPurpose;
  version: number;
  normalizationVersion: number;
}

export async function loadParticipantIdentityManifest(
  purpose: ParticipantIdentityPurpose,
  session?: ClientSession,
  environment: NodeJS.ProcessEnv = process.env
): Promise<{
  ring: ParticipantIdentityKeyRing;
  entries: ParticipantIdentityManifestEntry[];
}> {
  const ring = readParticipantIdentityKeyRing(purpose, environment);
  const query = ParticipantIdentityKeyVersion.find({ purpose });
  if (session) query.session(session);
  const rows = await query
    .maxTimeMS(PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS)
    .select("purpose version normalizationVersion")
    .lean<ParticipantIdentityManifestEntry[]>()
    .exec();
  if (rows.length === 0) return invalidConfiguration();
  const entries = rows.map((row) => {
    if (
      row.purpose !== purpose ||
      !Number.isSafeInteger(row.version) ||
      row.version < 1 ||
      row.normalizationVersion !== PARTICIPANT_IDENTITY_NORMALIZATION_VERSION ||
      !ring.keys.has(row.version)
    ) {
      return invalidConfiguration();
    }
    return row;
  });
  if (!entries.some((entry) => entry.version === ring.currentVersion)) {
    return invalidConfiguration();
  }
  return { ring, entries };
}

export function deriveParticipantIdentityAlias(
  purpose: ParticipantIdentityPurpose,
  version: number,
  key: Buffer,
  requestId: string | null,
  principalValue: unknown
): ParticipantIdentityAlias {
  const principal = normalizeParticipantPrincipal(principalValue);
  if (
    principal === null ||
    !Number.isSafeInteger(version) ||
    version < 1 ||
    key.byteLength < MINIMUM_IDENTITY_KEY_BYTES
  ) {
    return invalidConfiguration();
  }
  const domain = PURPOSE_CONFIG[purpose].domain;
  const fields =
    purpose === "participation"
      ? `${requestId ?? ""}\0${principal}`
      : principal;
  if (purpose === "participation" && !/^[0-9a-f]{24}$/.test(requestId ?? "")) {
    return invalidConfiguration();
  }
  const digest = createHmac("sha256", key)
    .update(domain, "utf8")
    .update(Buffer.from([0]))
    .update(fields, "utf8")
    .digest("hex");
  return { version, digest };
}

export function deriveParticipantIdentityAliases(
  purpose: ParticipantIdentityPurpose,
  ring: ParticipantIdentityKeyRing,
  entries: ParticipantIdentityManifestEntry[],
  requestId: string | null,
  principal: unknown
): ParticipantIdentityAlias[] {
  return entries.map((entry) => {
    const key = ring.keys.get(entry.version);
    if (!key) return invalidConfiguration();
    return deriveParticipantIdentityAlias(
      purpose,
      entry.version,
      key,
      requestId,
      principal
    );
  });
}

export function hasOnlyKnownIdentityVersions(
  values: Array<{ version?: unknown; digest?: unknown }>,
  entries: ParticipantIdentityManifestEntry[]
): boolean {
  const versions = new Set(entries.map((entry) => entry.version));
  return values.every(
    (value) =>
      Number.isSafeInteger(value.version) &&
      versions.has(value.version as number) &&
      typeof value.digest === "string" &&
      /^[0-9a-f]{64}$/.test(value.digest)
  );
}
