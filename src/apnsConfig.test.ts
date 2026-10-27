import { generateKeyPairSync } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  APNS_AUTH_KEY_P8_ENV,
  APNS_BUNDLE_ID_ENV,
  APNS_DEVELOPMENT_HOST,
  APNS_KEY_ID_ENV,
  APNS_PRODUCTION_HOST,
  APNS_TEAM_ID_ENV,
  ApnsConfigurationError,
  apnsHostForEnvironment,
  apnsOriginForEnvironment,
  assertApnsConfigurationForActivation,
  isApnsEnvironment,
  readApnsConfiguration,
} from "./apnsConfig.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";

/**
 * Environments are described as plain objects rather than by mutating the
 * process, so no case can leak configuration into another — the same shape
 * `unsubscribeCredential.test.ts` uses for the activation rule it owns.
 */
const { privateKey: ecPrivateKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});
const { privateKey: rsaPrivateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

const TEAM_ID = "ABCDE12345";
const KEY_ID = "KEY1234567";
const BUNDLE_ID = "org.commonplatenyu.CommonPlateios";

function validEnvironment(
  overrides: Record<string, string | undefined> = {}
): NodeJS.ProcessEnv {
  return {
    [APNS_TEAM_ID_ENV]: TEAM_ID,
    [APNS_KEY_ID_ENV]: KEY_ID,
    [APNS_BUNDLE_ID_ENV]: BUNDLE_ID,
    [APNS_AUTH_KEY_P8_ENV]: ecPrivateKey,
    ...overrides,
  } as NodeJS.ProcessEnv;
}

describe("APNs host selection is per stored installation environment", () => {
  it("maps each accepted environment to Apple's matching host", () => {
    expect(apnsHostForEnvironment("development")).toBe(APNS_DEVELOPMENT_HOST);
    expect(apnsHostForEnvironment("production")).toBe(APNS_PRODUCTION_HOST);
    expect(apnsOriginForEnvironment("development")).toBe(
      `https://${APNS_DEVELOPMENT_HOST}:443`
    );
    expect(apnsOriginForEnvironment("production")).toBe(
      `https://${APNS_PRODUCTION_HOST}:443`
    );
  });

  it.each([
    undefined,
    null,
    "",
    "Development",
    "PRODUCTION",
    "sandbox",
    "staging",
    7,
    {},
  ])("never defaults an unusable environment %j", (environment) => {
    // Guessing would submit a sandbox token to production, or the reverse,
    // and produce a spurious terminal token rejection.
    expect(apnsHostForEnvironment(environment)).toBeNull();
    expect(apnsOriginForEnvironment(environment)).toBeNull();
    expect(isApnsEnvironment(environment)).toBe(false);
  });

  it("recognizes exactly the two stored environments", () => {
    expect(isApnsEnvironment("development")).toBe(true);
    expect(isApnsEnvironment("production")).toBe(true);
  });
});

describe("APNs configuration reading", () => {
  it("reads all four values from a valid environment", () => {
    const configuration = readApnsConfiguration(validEnvironment());

    expect(configuration.teamId).toBe(TEAM_ID);
    expect(configuration.keyId).toBe(KEY_ID);
    expect(configuration.bundleId).toBe(BUNDLE_ID);
    expect(configuration.authKeyPem).toContain("BEGIN PRIVATE KEY");
  });

  it("trims surrounding whitespace on the identifiers", () => {
    const configuration = readApnsConfiguration(
      validEnvironment({
        [APNS_TEAM_ID_ENV]: `  ${TEAM_ID}\n`,
        [APNS_BUNDLE_ID_ENV]: ` ${BUNDLE_ID} `,
      })
    );

    expect(configuration.teamId).toBe(TEAM_ID);
    expect(configuration.bundleId).toBe(BUNDLE_ID);
  });

  it("restores escaped newlines in a single-line .p8 variable", () => {
    // The ordinary shape of a key set through a one-line deployment variable.
    const escaped = ecPrivateKey.replace(/\n/g, "\\n");
    const configuration = readApnsConfiguration(
      validEnvironment({ [APNS_AUTH_KEY_P8_ENV]: escaped })
    );

    expect(configuration.authKeyPem).toBe(ecPrivateKey);
  });

  it.each([
    APNS_TEAM_ID_ENV,
    APNS_KEY_ID_ENV,
    APNS_BUNDLE_ID_ENV,
    APNS_AUTH_KEY_P8_ENV,
  ])("refuses a missing %s", (name) => {
    for (const value of [undefined, "", "   "]) {
      const environment = validEnvironment({ [name]: value });
      expect(() => readApnsConfiguration(environment)).toThrow(
        ApnsConfigurationError
      );
      expect(() => readApnsConfiguration(environment)).toThrow(name);
    }
  });

  it.each([APNS_TEAM_ID_ENV, APNS_KEY_ID_ENV])(
    "refuses a malformed %s",
    (name) => {
      for (const value of ["SHORT", "ELEVENCHARS", "ABCDE-1234", "ABCDE 1234"]) {
        expect(() =>
          readApnsConfiguration(validEnvironment({ [name]: value }))
        ).toThrow(ApnsConfigurationError);
      }
    }
  );

  it("refuses a malformed bundle identifier", () => {
    for (const value of [".leading.dot", "has space", "-leading-dash"]) {
      expect(() =>
        readApnsConfiguration(validEnvironment({ [APNS_BUNDLE_ID_ENV]: value }))
      ).toThrow(ApnsConfigurationError);
    }
  });

  it.each([
    ["not a key at all", "plainly-not-a-key"],
    ["a truncated PEM", ecPrivateKey.slice(0, 60)],
    ["an RSA key", rsaPrivateKey],
  ])("refuses %s for the signing key", (_label, value) => {
    expect(() =>
      readApnsConfiguration(validEnvironment({ [APNS_AUTH_KEY_P8_ENV]: value }))
    ).toThrow(ApnsConfigurationError);
  });

  it("never echoes a configured value in a failure message", () => {
    const secretish = [
      ecPrivateKey,
      "ABCDE-1234",
      "an-embarrassing-bundle-id value",
    ];
    const environments = [
      validEnvironment({ [APNS_TEAM_ID_ENV]: "ABCDE-1234" }),
      validEnvironment({ [APNS_BUNDLE_ID_ENV]: "an-embarrassing-bundle-id value" }),
      validEnvironment({ [APNS_AUTH_KEY_P8_ENV]: ecPrivateKey.slice(0, 80) }),
      // A well-formed EC key refused for a different reason still must not be
      // repeated back: only the variable name is reportable.
      validEnvironment({ [APNS_KEY_ID_ENV]: ecPrivateKey }),
    ];

    for (const environment of environments) {
      let message = "";
      try {
        readApnsConfiguration(environment);
      } catch (error) {
        message = error instanceof Error ? error.message : String(error);
      }

      expect(message).not.toBe("");
      for (const value of secretish) {
        expect(message).not.toContain(value);
      }
      expect(message).not.toContain("BEGIN PRIVATE KEY");
    }
  });
});

describe("APNs provider configuration as an activation prerequisite", () => {
  it.each([
    ["absent", {}],
    ["explicitly on", { [PUBLIC_ACTIONS_PAUSED_ENV]: "true" }],
    ["an unrecognized value", { [PUBLIC_ACTIONS_PAUSED_ENV]: "maybe" }],
  ])("reads nothing while paused with the pause %s", (_label, pause) => {
    // A paused local or test process is not asked for provider configuration
    // no paused path can use — the same rule the unsubscribe secret follows.
    const read: string[] = [];
    const environment = new Proxy({ ...pause } as NodeJS.ProcessEnv, {
      get(target, property: string) {
        read.push(property);
        return target[property];
      },
    });

    expect(() => assertApnsConfigurationForActivation(environment)).not.toThrow();
    expect(read).toEqual([PUBLIC_ACTIONS_PAUSED_ENV]);
  });

  it("accepts a complete unpaused configuration", () => {
    expect(() =>
      assertApnsConfigurationForActivation(
        validEnvironment({ [PUBLIC_ACTIONS_PAUSED_ENV]: "false" })
      )
    ).not.toThrow();
  });

  it.each([
    APNS_TEAM_ID_ENV,
    APNS_KEY_ID_ENV,
    APNS_BUNDLE_ID_ENV,
    APNS_AUTH_KEY_P8_ENV,
  ])("refuses an unpaused process missing %s", (name) => {
    expect(() =>
      assertApnsConfigurationForActivation(
        validEnvironment({
          [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
          [name]: undefined,
        })
      )
    ).toThrow(name);
  });

  it("returns the verified configuration to nobody", () => {
    // It exists to fail closed at boot, not to become a second holder of key
    // material: every delivery path reads the configuration where it needs it.
    expect(
      assertApnsConfigurationForActivation(
        validEnvironment({ [PUBLIC_ACTIONS_PAUSED_ENV]: "false" })
      )
    ).toBeUndefined();
  });
});
