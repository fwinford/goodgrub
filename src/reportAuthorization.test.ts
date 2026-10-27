import { describe, expect, it } from "vitest";
import { mintReportAuthorization, isValidReportAuthorization } from "./reportAuthorization.js";
import { readSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";

const participantId = "64e0000000000000000000a1";
const requestId = "64e0000000000000000000b2";
const keyring = readSafetyIdentityKeyring({
  SAFETY_IDENTITY_KEYRING: JSON.stringify({
    current: "k1",
    keys: { k1: Buffer.alloc(32, 0x11).toString("base64url") },
  }),
});

describe("post-Block report authorization", () => {
  it("is opaque, caller- and request-bound, and expires within the handoff lifetime", () => {
    const now = new Date("2026-10-20T12:00:00.000Z");
    const token = mintReportAuthorization(keyring, participantId, requestId, now);
    expect(token).not.toContain(participantId);
    expect(token).not.toContain(requestId);
    expect(isValidReportAuthorization(token, keyring, participantId, requestId, now)).toBe(true);
    expect(
      isValidReportAuthorization(token, keyring, "64e0000000000000000000c3", requestId, now)
    ).toBe(false);
    expect(
      isValidReportAuthorization(token, keyring, participantId, "64e0000000000000000000c4", now)
    ).toBe(false);
    expect(
      isValidReportAuthorization(
        token,
        keyring,
        participantId,
        requestId,
        new Date(now.getTime() + 10 * 60 * 1000)
      )
    ).toBe(false);
  });

  it("rejects tampering, malformed values, and expiry extensions", () => {
    const now = new Date("2026-10-20T12:00:00.000Z");
    const token = mintReportAuthorization(keyring, participantId, requestId, now);
    const [, keyId, expiry, nonce, mac] = token.split(".");
    const tamperedMac = `${mac!.slice(0, -1)}${mac!.endsWith("0") ? "1" : "0"}`;
    expect(
      isValidReportAuthorization(
        `ra1.${keyId}.${expiry}.${nonce}.${tamperedMac}`,
        keyring,
        participantId,
        requestId,
        now
      )
    ).toBe(false);
    expect(
      isValidReportAuthorization(
        `ra1.${keyId}.${now.getTime() + 60 * 60 * 1000}.${nonce}.${mac}`,
        keyring,
        participantId,
        requestId,
        now
      )
    ).toBe(false);
    expect(isValidReportAuthorization("malformed", keyring, participantId, requestId, now)).toBe(
      false
    );
  });
});
