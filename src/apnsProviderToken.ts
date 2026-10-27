import { createPrivateKey, sign } from "node:crypto";
import {
  readApnsConfiguration,
  type ApnsConfiguration,
} from "./apnsConfig.js";

/**
 * The ES256 provider JWT APNs authenticates every submission with, minted on
 * `node:crypto` rather than through a new dependency, matching how this
 * repository already implements its claim-token, unsubscribe, and installation
 * credential primitives.
 *
 * Apple refuses a provider token regenerated more often than once every 20
 * minutes and rejects one older than an hour, so the token is cached between
 * dispatches. The refresh interval below sits inside both bounds.
 *
 * Nothing here logs, persists, or returns the signing key, and the minted
 * token never leaves the `authorization` header of a submission.
 */
export const APNS_PROVIDER_TOKEN_MINIMUM_REFRESH_MS = 20 * 60 * 1000;
export const APNS_PROVIDER_TOKEN_MAXIMUM_AGE_MS = 60 * 60 * 1000;
/** Comfortably inside both of Apple's bounds. */
export const APNS_PROVIDER_TOKEN_REFRESH_MS = 45 * 60 * 1000;

function encodeSegment(value: object): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

/**
 * ES256 signatures must be the JOSE fixed-width `r || s` pair; Node's default
 * DER encoding would be rejected by APNs as an invalid provider token.
 */
export function mintApnsProviderToken(
  configuration: ApnsConfiguration,
  issuedAtSeconds: number
): string {
  const header = encodeSegment({ alg: "ES256", kid: configuration.keyId });
  const payload = encodeSegment({
    iss: configuration.teamId,
    iat: Math.floor(issuedAtSeconds),
  });
  const signingInput = `${header}.${payload}`;
  const signature = sign(
    "sha256",
    Buffer.from(signingInput, "utf8"),
    {
      key: createPrivateKey(configuration.authKeyPem),
      dsaEncoding: "ieee-p1363",
    }
  );
  return `${signingInput}.${signature.toString("base64url")}`;
}

export interface ApnsProviderTokenSourceOptions {
  readConfiguration?: () => ApnsConfiguration;
  now?: () => number;
  refreshIntervalMs?: number;
}

export interface ApnsProviderTokenSource {
  /** The cached token, minting a replacement only when it is due. */
  current(): string;
}

export function createApnsProviderTokenSource(
  options: ApnsProviderTokenSourceOptions = {}
): ApnsProviderTokenSource {
  const readConfiguration = options.readConfiguration ?? (() => readApnsConfiguration());
  const now = options.now ?? (() => Date.now());
  const refreshIntervalMs = Math.min(
    Math.max(
      options.refreshIntervalMs ?? APNS_PROVIDER_TOKEN_REFRESH_MS,
      APNS_PROVIDER_TOKEN_MINIMUM_REFRESH_MS
    ),
    APNS_PROVIDER_TOKEN_MAXIMUM_AGE_MS
  );

  let cachedToken: string | null = null;
  let cachedAt = 0;
  let cachedKeyId: string | null = null;

  return {
    current(): string {
      const configuration = readConfiguration();
      const currentTime = now();
      const age = currentTime - cachedAt;
      if (
        cachedToken !== null &&
        cachedKeyId === configuration.keyId &&
        age >= 0 &&
        age < refreshIntervalMs
      ) {
        return cachedToken;
      }

      cachedToken = mintApnsProviderToken(
        configuration,
        Math.floor(currentTime / 1000)
      );
      cachedAt = currentTime;
      cachedKeyId = configuration.keyId;
      return cachedToken;
    },
  };
}

/**
 * Process-wide cache. Dispatch is per created request, so a source built per
 * dispatch would mint a JWT far more often than Apple permits.
 */
export const apnsProviderTokenSource = createApnsProviderTokenSource();
