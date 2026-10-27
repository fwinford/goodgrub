import { describe, expect, it } from "vitest";
import { campusDayEnd, placedHomeVisibility } from "./placedHomeVisibility.js";

describe("campusDayEnd (America/New_York)", () => {
  it("ends an EDT day at 04:00Z the next day", () => {
    expect(campusDayEnd(new Date("2026-10-19T17:00:00.000Z"))).toEqual(
      new Date("2026-10-20T04:00:00.000Z")
    );
  });

  it("ends an EST day at 05:00Z the next day", () => {
    expect(campusDayEnd(new Date("2026-12-10T17:00:00.000Z"))).toEqual(
      new Date("2026-12-11T05:00:00.000Z")
    );
  });

  it("uses the campus day, not the UTC day, late in the evening", () => {
    // 23:30 EDT on Oct 19 is already Oct 20 in UTC.
    expect(campusDayEnd(new Date("2026-10-20T03:30:00.000Z"))).toEqual(
      new Date("2026-10-20T04:00:00.000Z")
    );
  });

  it("handles the spring-forward day (23-hour day)", () => {
    expect(campusDayEnd(new Date("2026-03-08T12:00:00.000Z"))).toEqual(
      new Date("2026-03-09T04:00:00.000Z")
    );
  });

  it("handles the fall-back day (25-hour day)", () => {
    expect(campusDayEnd(new Date("2026-11-01T12:00:00.000Z"))).toEqual(
      new Date("2026-11-02T05:00:00.000Z")
    );
  });
});

describe("placedHomeVisibility", () => {
  it("derives helper cutoff = ready + 1h and requester cutoff = end of campus day", () => {
    const result = placedHomeVisibility({
      placedAt: new Date("2026-10-19T16:30:00.000Z"),
      etaText: "30 minutes",
    });
    expect(result?.estimatedReadyAt).toEqual(new Date("2026-10-19T17:00:00.000Z"));
    expect(result?.helperVisibleUntil).toEqual(new Date("2026-10-19T18:00:00.000Z"));
    expect(result?.requesterVisibleUntil).toEqual(new Date("2026-10-20T04:00:00.000Z"));
  });

  it("uses the day containing estimatedReadyAt, not placedAt", () => {
    // Placed 23:50 EDT, ready after midnight -> requester day is the next day.
    const result = placedHomeVisibility({
      placedAt: new Date("2026-10-20T03:50:00.000Z"),
      etaText: "30 minutes",
    });
    expect(result?.requesterVisibleUntil).toEqual(new Date("2026-10-21T04:00:00.000Z"));
  });

  it.each([undefined, null, "", "soon", "toString"])(
    "fails closed (null) for ETA %s without substituting placedAt",
    (etaText) => {
      expect(
        placedHomeVisibility({
          placedAt: new Date("2026-10-19T16:30:00.000Z"),
          etaText,
        })
      ).toBeNull();
    }
  );

  it("fails closed when placedAt is missing or invalid", () => {
    expect(placedHomeVisibility({ placedAt: null, etaText: "ASAP" })).toBeNull();
    expect(placedHomeVisibility({ placedAt: "nope", etaText: "ASAP" })).toBeNull();
  });
});
