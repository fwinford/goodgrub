import { describe, expect, it } from "vitest";
import { formatModeratorDate } from "./moderatorDates.js";

describe("formatModeratorDate", () => {
  it("renders Eastern Daylight Time with an explicit label", () => {
    expect(formatModeratorDate(new Date("2026-10-19T18:32:07.000Z"))).toBe(
      "Oct 19, 2026 · 2:32 PM EDT"
    );
  });

  it("renders Eastern Standard Time after the November change", () => {
    expect(formatModeratorDate(new Date("2026-11-02T18:32:07.000Z"))).toBe(
      "Nov 2, 2026 · 1:32 PM EST"
    );
  });

  it("handles the midnight boundary and the DST transition instant", () => {
    expect(formatModeratorDate(new Date("2026-10-26T04:00:00.000Z"))).toBe(
      "Oct 26, 2026 · 12:00 AM EDT"
    );
    expect(formatModeratorDate(new Date("2026-11-01T06:00:00.000Z"))).toBe(
      "Nov 1, 2026 · 1:00 AM EST"
    );
  });

  it("returns an empty string for missing or invalid values", () => {
    expect(formatModeratorDate(undefined)).toBe("");
    expect(formatModeratorDate(null)).toBe("");
    expect(formatModeratorDate("2026-10-19")).toBe("");
    expect(formatModeratorDate(new Date("nope"))).toBe("");
  });
});
