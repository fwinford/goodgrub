import { createPrivateKey } from "node:crypto";
import { isPublicActionsPaused } from "./publicActionsPause.js";

/**
 * APNs provider configuration for helper new-request push delivery
 * (Week 3 Day 6 Slice 6D).
 *
 * Token-based provider authentication needs four values, and none of them may
 * ever be echoed back: `APNS_AUTH_KEY_P8` is signing key material, and the
 * three identifiers are deployment configuration. Every failure below names
 * the variable it refused and nothing else, because the caller logs the
 * message and exits.
 */
export const APNS_TEAM_ID_ENV = "APNS_TEAM_ID";
export const APNS_KEY_ID_ENV = "APNS_KEY_ID";
export const APNS_BUNDLE_ID_ENV = "APNS_BUNDLE_ID";
export const APNS_AUTH_KEY_P8_ENV = "APNS_AUTH_KEY_P8";

export type ApnsEnvironment = "development" | "production";

/**
 * Host selection is per installation, from the environment that installation
 * stored when it registered. Nothing here reads the server's own deployment
 * mode: a sandbox token submitted to production (or the reverse) produces a
 * spurious `BadDeviceToken`, which the delivery contract treats as a terminal
 * token rejection.
 */
export const APNS_DEVELOPMENT_HOST = "api.sandbox.push.apple.com";
export const APNS_PRODUCTION_HOST = "api.push.apple.com";

const HOSTS: Record<ApnsEnvironment, string> = {
  development: APNS_DEVELOPMENT_HOST,
  production: APNS_PRODUCTION_HOST,
};

export function isApnsEnvironment(value: unknown): value is ApnsEnvironment {
  return value === "development" || value === "production";
}

/** `null` for a missing or unrecognized value. Never defaulted, never guessed. */
export function apnsHostForEnvironment(environment: unknown): string | null {
  return isApnsEnvironment(environment) ? HOSTS[environment] : null;
}

/** The HTTP/2 origin for {@link apnsHostForEnvironment}. */
export function apnsOriginForEnvironment(environment: unknown): string | null {
  const host = apnsHostForEnvironment(environment);
  return host === null ? null : `https://${host}:443`;
}

export class ApnsConfigurationError extends Error {}

export interface ApnsConfiguration {
  /** JWT `iss`. */
  teamId: string;
  /** JWT `kid`. */
  keyId: string;
  /** `apns-topic`. */
  bundleId: string;
  /** PEM contents of the `.p8` EC P-256 signing key. */
  authKeyPem: string;
}

/** Apple issues 10-character alphanumeric team and key identifiers. */
const APPLE_IDENTIFIER_PATTERN = /^[A-Za-z0-9]{10}$/;
/** Reverse-DNS bundle identifier characters, bounded so a topic stays sane. */
const BUNDLE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/;

function readVariable(
  environment: NodeJS.ProcessEnv,
  name: string
): string {
  const configured = environment[name];
  if (typeof configured !== "string" || configured.trim() === "") {
    throw new ApnsConfigurationError(
      `Missing required environment variable: ${name}`
    );
  }
  return configured.trim();
}

function readIdentifier(
  environment: NodeJS.ProcessEnv,
  name: string
): string {
  const value = readVariable(environment, name);
  if (!APPLE_IDENTIFIER_PATTERN.test(value)) {
    throw new ApnsConfigurationError(
      `${name} must be a 10-character alphanumeric Apple identifier`
    );
  }
  return value;
}

/**
 * A `.p8` set through a single-line deployment variable commonly arrives with
 * its newlines escaped. Restoring them here keeps that ordinary deployment
 * shape usable without any caller having to know about it.
 */
function normalizePem(value: string): string {
  return value.includes("\\n") ? value.replace(/\\n/g, "\n") : value;
}

/**
 * Shape only: that the value parses as an EC private key. Nothing about the
 * caught parsing error is propagated — the message is fixed, so no part of the
 * key can reach a log through a provider or OpenSSL error string.
 */
function readAuthKey(environment: NodeJS.ProcessEnv): string {
  const authKeyPem = normalizePem(readVariable(environment, APNS_AUTH_KEY_P8_ENV));

  let keyType: string | null;
  try {
    keyType = createPrivateKey(authKeyPem).asymmetricKeyType ?? null;
  } catch {
    throw new ApnsConfigurationError(
      `${APNS_AUTH_KEY_P8_ENV} must contain a PEM-encoded EC private key`
    );
  }
  if (keyType !== "ec") {
    throw new ApnsConfigurationError(
      `${APNS_AUTH_KEY_P8_ENV} must contain a PEM-encoded EC private key`
    );
  }

  return authKeyPem;
}

export function readApnsConfiguration(
  environment: NodeJS.ProcessEnv = process.env
): ApnsConfiguration {
  const teamId = readIdentifier(environment, APNS_TEAM_ID_ENV);
  const keyId = readIdentifier(environment, APNS_KEY_ID_ENV);
  const bundleId = readVariable(environment, APNS_BUNDLE_ID_ENV);
  if (!BUNDLE_ID_PATTERN.test(bundleId)) {
    throw new ApnsConfigurationError(
      `${APNS_BUNDLE_ID_ENV} must be a bundle identifier`
    );
  }

  return { teamId, keyId, bundleId, authKeyPem: readAuthKey(environment) };
}

/**
 * Activation prerequisite, checked once at startup, exactly like
 * `assertUnsubscribeSigningSecretForActivation`.
 *
 * An installation can already turn push on through the Slice 6A endpoint, and
 * "push alerts are on" means CommonPlate is configured to submit through APNs.
 * An unpaused deployment without provider configuration would show that
 * on-state to installations it can never submit for, so provider configuration
 * gates activation rather than being discovered at the first send.
 *
 * A paused process reads nothing: local and test processes still start without
 * any APNs configuration, mirroring the paused delivery paths, which refuse
 * before touching this configuration at all.
 *
 * The verified configuration is deliberately discarded rather than cached
 * here. The dispatcher reads it where it is needed; this exists to fail closed
 * at boot, not to become a second holder of key material.
 */
export function assertApnsConfigurationForActivation(
  environment: NodeJS.ProcessEnv = process.env
): void {
  if (isPublicActionsPaused(environment)) return;
  readApnsConfiguration(environment);
}
