import { describe, it, expect } from "vitest";
import { formatMealRequestWindow, startOfCampusDay } from "./date.js";

describe("formatMealRequestWindow", () => {
  it("formats a same-day start/end window in America/New_York time", () => {
    const start = "2026-07-13T17:00:00.000Z"; // 1:00 PM ET
    const end = "2026-07-13T18:00:00.000Z"; // 2:00 PM ET
    const result = formatMealRequestWindow(start, end);
    expect(result).toBe("Jul 13, 1:00 PM – 2:00 PM");
  });

  it("falls back to the provided text when no start/end is given", () => {
    expect(formatMealRequestWindow(undefined, undefined, "ASAP")).toBe("ASAP");
  });
});

describe("startOfCampusDay", () => {
  it("resolves the NYU midnight instant during EDT (UTC-4)", () => {
    // 2026-07-27T23:59:00Z ET is still July 27 in New York (EDT).
    expect(
      startOfCampusDay(new Date("2026-07-28T03:59:00.000Z")).toISOString()
    ).toBe("2026-07-27T04:00:00.000Z");

    // The boundary instant itself belongs to the day it starts.
    expect(
      startOfCampusDay(new Date("2026-07-28T04:00:00.000Z")).toISOString()
    ).toBe("2026-07-28T04:00:00.000Z");

    // One minute later is still that same campus day.
    expect(
      startOfCampusDay(new Date("2026-07-28T04:01:00.000Z")).toISOString()
    ).toBe("2026-07-28T04:00:00.000Z");
  });

  it("resolves the NYU midnight instant during EST (UTC-5)", () => {
    expect(
      startOfCampusDay(new Date("2026-01-15T12:00:00.000Z")).toISOString()
    ).toBe("2026-01-15T05:00:00.000Z");
  });

  it("uses the correct offset on both sides of the fall-back DST transition", () => {
    // Clocks fall back at 2 AM ET on 2026-11-01, so New York is still EDT at
    // its own midnight that day, and EST by the following midnight — an
    // asymmetric one-hour swing that only a DST-aware conversion gets right.
    expect(
      startOfCampusDay(new Date("2026-11-01T12:00:00.000Z")).toISOString()
    ).toBe("2026-11-01T04:00:00.000Z");
    expect(
      startOfCampusDay(new Date("2026-11-02T12:00:00.000Z")).toISOString()
    ).toBe("2026-11-02T05:00:00.000Z");
  });

  it("does not depend on the host process's local timezone", () => {
    const originalTZ = process.env.TZ;
    try {
      const instant = new Date("2026-07-28T12:00:00.000Z");

      process.env.TZ = "America/Los_Angeles";
      const fromPacific = startOfCampusDay(instant).toISOString();

      process.env.TZ = "Asia/Tokyo";
      const fromTokyo = startOfCampusDay(instant).toISOString();

      expect(fromPacific).toBe("2026-07-28T04:00:00.000Z");
      expect(fromTokyo).toBe("2026-07-28T04:00:00.000Z");
    } finally {
      process.env.TZ = originalTZ;
    }
  });
});
