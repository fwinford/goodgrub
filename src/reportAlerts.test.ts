import { describe, expect, it, vi } from "vitest";

vi.mock("./emailHelpers.js", () => ({ sendEmailSafe: vi.fn() }));

vi.mock("./moderatorSecurity.js", () => ({
  readModeratorConfig: () => ({ origin: "https://moderator.example" }),
}));

const { buildReportAlertContent, buildRetentionAlertContent } = await import("./reportAlerts.js");

describe("moderator alert email links", () => {
  it("links a new-report alert to that report's detail page", () => {
    const content = buildReportAlertContent("abcDEF123_-abcDEF123_-ab", "Other concern", new Date("2026-10-21T12:00:00Z"));
    expect(content.text).toContain(
      "Moderator dashboard: https://moderator.example/moderation/reports/abcDEF123_-abcDEF123_-ab"
    );
    expect(content.text).not.toContain("@");
  });

  it("links a retention alert to the unlisted health page and names only approved conditions", () => {
    const content = buildRetentionAlertContent(
      ["stale-run", "overdue-records"],
      new Date("2026-10-21T12:00:00Z")
    );
    expect(content.subject).toBe("Retention health needs review");
    expect(content.text).toContain("Moderator dashboard: https://moderator.example/moderation/health");
    expect(content.text).toContain("Conditions: stale-run, overdue-records");
  });

  it("refuses a retention alert with no approved condition", () => {
    expect(() => buildRetentionAlertContent([], new Date())).toThrow();
  });
});
