import { describe, expect, it } from "vitest";
import {
  APPROVED_PRODUCTION_EMAIL_SENDER,
  DEVELOPMENT_EMAIL_SENDER,
  emailSender,
} from "./emailSender.js";

describe("email sender configuration", () => {
  it("uses only the approved sender in production", () => {
    expect(
      emailSender({
        NODE_ENV: "production",
        FROM_EMAIL: APPROVED_PRODUCTION_EMAIL_SENDER,
      })
    ).toBe(APPROVED_PRODUCTION_EMAIL_SENDER);
  });

  it.each([undefined, "", "CommonPlate <onboarding@resend.dev>"])(
    "fails closed in production when the approved sender is unavailable: %s",
    (sender) => {
      expect(() =>
        emailSender({ NODE_ENV: "production", FROM_EMAIL: sender })
      ).toThrow("Approved production email sender is unavailable");
    }
  );

  it("keeps the development fallback outside production", () => {
    expect(emailSender({ NODE_ENV: "development" })).toBe(
      DEVELOPMENT_EMAIL_SENDER
    );
  });

  it("allows an explicit non-production sender", () => {
    expect(
      emailSender({
        NODE_ENV: "test",
        FROM_EMAIL: "Test Sender <test@example.invalid>",
      })
    ).toBe("Test Sender <test@example.invalid>");
  });
});
