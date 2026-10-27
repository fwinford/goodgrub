import { describe, expect, it } from "vitest";
import { ALLOWED_EMAIL_DOMAINS } from "./allowedEmailDomains.js";
import {
  PARTICIPANT_PRINCIPAL_MAX_LENGTH,
  isParticipantPrincipal,
  normalizeParticipantPrincipal,
} from "./participantIdentity.js";

describe("participant principal", () => {
  it.each([
    ["requester@nyu.edu", "requester@nyu.edu"],
    ["  REQUESTER@NYU.EDU  ", "requester@nyu.edu"],
    ["\tStudent@Stern.NYU.EDU\n", "student@stern.nyu.edu"],
  ])("normalizes %j to %j", (value, expected) => {
    expect(normalizeParticipantPrincipal(value)).toBe(expected);
    expect(isParticipantPrincipal(value)).toBe(true);
  });

  it("uses the one shared allowlist rather than a second copy", () => {
    for (const domain of ALLOWED_EMAIL_DOMAINS) {
      expect(normalizeParticipantPrincipal(`student@${domain}`)).toBe(
        `student@${domain}`
      );
    }
  });

  it.each([
    [undefined],
    [null],
    [42],
    [{}],
    [""],
    ["   "],
    ["not-an-email"],
    ["requester@"],
    ["@nyu.edu"],
    ["requester@@nyu.edu"],
    ["requester @nyu.edu"],
    ["requester@gmail.com"],
    ["requester@law.nyu.edu"],
    ["requester@sps.nyu.edu"],
    ["requester@fake-nyu.edu"],
    ["requester@nyu.edu.fake"],
    ["requester@nyu.edu.example.com"],
    ["requester@notnyu.edu"],
    ["requester@nyu.education"],
  ])("refuses %j", (value) => {
    expect(normalizeParticipantPrincipal(value)).toBeNull();
    expect(isParticipantPrincipal(value)).toBe(false);
  });

  it("bounds the length before anything hashes or stores it", () => {
    const local = "a".repeat(PARTICIPANT_PRINCIPAL_MAX_LENGTH);
    expect(normalizeParticipantPrincipal(`${local}@nyu.edu`)).toBeNull();
  });

  it.each([
    ["requester@nyu.edu", "requester+food@nyu.edu"],
    ["requester@nyu.edu", "r.equester@nyu.edu"],
    ["requester@nyu.edu", "requester@stern.nyu.edu"],
  ])(
    "keeps %j and %j as two distinct principals",
    (first, second) => {
      // Load-bearing, and deliberately not a convenience gap. CommonPlate has
      // no way to know two NYU addresses belong to one human; canonicalizing
      // them would silently merge two people's requests and reservations, and
      // alias-to-human identification is explicitly out of scope.
      expect(normalizeParticipantPrincipal(first)).not.toBe(
        normalizeParticipantPrincipal(second)
      );
    }
  );

  it("is idempotent, so a stored principal re-normalizes to itself", () => {
    // Every gated request re-normalizes the persisted address; if that were not
    // stable, a verified identity would stop matching itself on second use.
    for (const value of [
      "requester@nyu.edu",
      "student@stern.nyu.edu",
      "requester+food@nyu.edu",
    ]) {
      const once = normalizeParticipantPrincipal(value);
      expect(once).not.toBeNull();
      expect(normalizeParticipantPrincipal(once)).toBe(once);
    }
  });
});
