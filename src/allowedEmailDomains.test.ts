import { describe, expect, it } from "vitest";
import {
  ALLOWED_EMAIL_DOMAINS,
  emailDomain,
  hasAllowedEmailDomain,
  normalizeEmail,
} from "./allowedEmailDomains.js";

describe("the allowlist itself", () => {
  it("is exactly the two accepted NYU domains", () => {
    expect([...ALLOWED_EMAIL_DOMAINS]).toEqual(["nyu.edu", "stern.nyu.edu"]);
  });
});

describe("normalization", () => {
  it.each([
    ["  student@nyu.edu  ", "student@nyu.edu"],
    ["STUDENT@NYU.EDU", "student@nyu.edu"],
    ["\tStudent@Stern.NYU.edu\n", "student@stern.nyu.edu"],
  ])("normalizes %s", (raw, expected) => {
    expect(normalizeEmail(raw)).toBe(expected);
  });

  it("reads the exact domain after the final @", () => {
    expect(emailDomain("student@nyu.edu")).toBe("nyu.edu");
    expect(emailDomain("  FAITH+alerts@NYU.EDU ")).toBe("nyu.edu");
    expect(emailDomain("student@nyu.edu.fake")).toBe("nyu.edu.fake");
  });

  it.each(["nyu.edu", "@nyu.edu", "student@", "   ", ""])(
    "reports no usable domain for %s",
    (value) => {
      expect(emailDomain(value)).toBeNull();
    }
  );
});

describe("exact-domain acceptance", () => {
  it.each([
    "student@nyu.edu",
    "student@stern.nyu.edu",
    "STUDENT@NYU.EDU",
    "  student@nyu.edu  ",
    "ada+alerts@nyu.edu",
    "Student+alerts@Stern.NYU.EDU",
  ])("accepts %s", (email) => {
    expect(hasAllowedEmailDomain(email)).toBe(true);
  });

  it.each([
    "student@example.com",
    "student@law.nyu.edu",
    "student@nyu.edu.fake",
    "student@fake-nyu.edu",
    "student@nyu.edu.example.com",
    "student@notnyu.edu",
    "student@nyu.education",
    "student@edu",
    "nyu.edu",
    "student@",
    "@nyu.edu",
    "",
  ])("rejects %s", (email) => {
    expect(hasAllowedEmailDomain(email)).toBe(false);
  });

  it("does not match a domain by suffix or substring", () => {
    // The two failures a `hasSuffix`/`includes` implementation would allow.
    expect(hasAllowedEmailDomain("student@evil-nyu.edu")).toBe(false);
    expect(hasAllowedEmailDomain("student@nyu.edu.evil.test")).toBe(false);
  });
});
