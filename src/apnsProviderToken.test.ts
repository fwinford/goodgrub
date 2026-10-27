import {
  createPublicKey,
  generateKeyPairSync,
  verify as verifySignature,
} from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import type { ApnsConfiguration } from "./apnsConfig.js";
import {
  APNS_PROVIDER_TOKEN_MAXIMUM_AGE_MS,
  APNS_PROVIDER_TOKEN_MINIMUM_REFRESH_MS,
  APNS_PROVIDER_TOKEN_REFRESH_MS,
  createApnsProviderTokenSource,
  mintApnsProviderToken,
} from "./apnsProviderToken.js";

const { privateKey, publicKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: privateKey,
};

function decodeSegment(segment: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));
}

describe("APNs provider token minting", () => {
  it("carries the configured kid and iss with an ES256 header", () => {
    const token = mintApnsProviderToken(configuration, 1_770_000_000);
    const [header, payload] = token.split(".");

    expect(decodeSegment(header)).toEqual({
      alg: "ES256",
      kid: configuration.keyId,
    });
    expect(decodeSegment(payload)).toEqual({
      iss: configuration.teamId,
      iat: 1_770_000_000,
    });
  });

  it("produces three base64url segments and no key material", () => {
    const token = mintApnsProviderToken(configuration, 1_770_000_000);

    expect(token.split(".")).toHaveLength(3);
    expect(token).toMatch(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    expect(token).not.toContain("BEGIN PRIVATE KEY");
    expect(token).not.toContain(privateKey.slice(30, 60));
  });

  it("signs the header and payload with the configured key, in JOSE form", () => {
    // A DER-encoded ECDSA signature — Node's default — is what APNs rejects as
    // an invalid provider token, so the fixed 64-byte r||s form is the point.
    const token = mintApnsProviderToken(configuration, 1_770_000_000);
    const [header, payload, signature] = token.split(".");
    const signatureBytes = Buffer.from(signature, "base64url");

    expect(signatureBytes).toHaveLength(64);
    expect(
      verifySignature(
        "sha256",
        Buffer.from(`${header}.${payload}`, "utf8"),
        { key: createPublicKey(publicKey), dsaEncoding: "ieee-p1363" },
        signatureBytes
      )
    ).toBe(true);
  });

  it("floors a fractional issued-at into whole seconds", () => {
    const token = mintApnsProviderToken(configuration, 1_770_000_000.87);

    expect(decodeSegment(token.split(".")[1]).iat).toBe(1_770_000_000);
  });
});

describe("APNs provider token caching", () => {
  function source(startAt: number) {
    let clock = startAt;
    const readConfiguration = vi.fn(() => configuration);
    const provider = createApnsProviderTokenSource({
      readConfiguration,
      now: () => clock,
    });
    return {
      provider,
      readConfiguration,
      advance(ms: number) {
        clock += ms;
      },
    };
  }

  it("reuses one token across dispatches", () => {
    // Apple refuses a provider token regenerated more often than once every
    // 20 minutes, so a token minted per created request would be rejected.
    const { provider, advance } = source(1_770_000_000_000);
    const first = provider.current();
    advance(60_000);

    expect(provider.current()).toBe(first);
  });

  it("refreshes inside Apple's bounds, never sooner than 20 minutes and never past an hour", () => {
    expect(APNS_PROVIDER_TOKEN_REFRESH_MS).toBeGreaterThanOrEqual(
      APNS_PROVIDER_TOKEN_MINIMUM_REFRESH_MS
    );
    expect(APNS_PROVIDER_TOKEN_REFRESH_MS).toBeLessThan(
      APNS_PROVIDER_TOKEN_MAXIMUM_AGE_MS
    );

    const { provider, advance } = source(1_770_000_000_000);
    const first = provider.current();

    advance(APNS_PROVIDER_TOKEN_REFRESH_MS - 1_000);
    expect(provider.current()).toBe(first);

    advance(2_000);
    const refreshed = provider.current();
    expect(refreshed).not.toBe(first);
    expect(decodeSegment(refreshed.split(".")[1]).iat).toBe(
      Math.floor(
        (1_770_000_000_000 + APNS_PROVIDER_TOKEN_REFRESH_MS + 1_000) / 1000
      )
    );
  });

  it("clamps a configured refresh interval into Apple's bounds", () => {
    let eagerClock = 1_770_000_000_000;
    const eager = createApnsProviderTokenSource({
      readConfiguration: () => configuration,
      now: () => eagerClock,
      refreshIntervalMs: 1_000,
    });
    const eagerFirst = eager.current();
    // A one-second interval would breach Apple's 20-minute minimum, so the
    // cached token is kept well past it.
    eagerClock += 10 * 60 * 1000;
    expect(eager.current()).toBe(eagerFirst);

    let patientClock = 1_770_000_000_000;
    const patient = createApnsProviderTokenSource({
      readConfiguration: () => configuration,
      now: () => patientClock,
      refreshIntervalMs: 6 * 60 * 60 * 1000,
    });
    const patientFirst = patient.current();
    // A six-hour interval would reuse a token past Apple's one-hour ceiling.
    patientClock += APNS_PROVIDER_TOKEN_MAXIMUM_AGE_MS;
    expect(patient.current()).not.toBe(patientFirst);
  });

  it("mints a replacement when the configured key identifier changes", () => {
    let current = configuration;
    let clock = 1_770_000_000_000;
    const provider = createApnsProviderTokenSource({
      readConfiguration: () => current,
      now: () => clock,
    });
    const first = provider.current();

    current = { ...configuration, keyId: "KEY7654321" };
    clock += 1_000;
    const second = provider.current();

    expect(second).not.toBe(first);
    expect(decodeSegment(second.split(".")[0]).kid).toBe("KEY7654321");
  });

  it("reads configuration on every request rather than holding key material", () => {
    const { provider, readConfiguration } = source(1_770_000_000_000);
    provider.current();
    provider.current();

    expect(readConfiguration).toHaveBeenCalledTimes(2);
  });
});
