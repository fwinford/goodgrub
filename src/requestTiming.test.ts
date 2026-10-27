import { describe, expect, it } from "vitest";
import {
  NYU_TIME_ZONE,
  REQUEST_VISIBLE_DURATION_MS,
  isAcceptableScheduledStart,
  resolveAsapTiming,
  resolveScheduledTiming,
} from "./requestTiming.js";
import { isVisibleNow } from "./requestAvailability.js";
import { formatMealRequestWindow } from "./utils/date.js";

const THREE_HOURS_MS = 3 * 60 * 60 * 1000;

describe("the canonical product timezone", () => {
  it("is NYU campus time, named by IANA identifier rather than an offset", () => {
    // An offset would be wrong for half the year and silently so.
    expect(NYU_TIME_ZONE).toBe("America/New_York");
  });
});

describe("the request visibility duration", () => {
  it("is exactly three hours", () => {
    expect(REQUEST_VISIBLE_DURATION_MS).toBe(THREE_HOURS_MS);
  });
});

describe("resolveAsapTiming", () => {
  const createdAt = new Date("2026-07-28T16:00:00.000Z");

  it("is visible from the backend creation instant", () => {
    expect(resolveAsapTiming(createdAt).visibleFrom).toEqual(createdAt);
  });

  it("expires exactly three hours after the backend creation instant", () => {
    const { visibleFrom, expiresAt } = resolveAsapTiming(createdAt);

    expect(expiresAt).toEqual(new Date("2026-07-28T19:00:00.000Z"));
    expect(expiresAt.getTime() - visibleFrom.getTime()).toBe(THREE_HOURS_MS);
  });
});

describe("resolveScheduledTiming", () => {
  const windowStart = new Date("2026-07-28T22:30:00.000Z");

  it("is visible from the accepted start, not from creation", () => {
    expect(resolveScheduledTiming(windowStart).visibleFrom).toEqual(
      windowStart
    );
  });

  it("expires exactly three hours after that start", () => {
    const { visibleFrom, expiresAt } = resolveScheduledTiming(windowStart);

    expect(expiresAt).toEqual(new Date("2026-07-29T01:30:00.000Z"));
    expect(expiresAt.getTime() - visibleFrom.getTime()).toBe(THREE_HOURS_MS);
  });

  it("uses one and the same rule for ASAP and scheduled starts", () => {
    // Both are "three hours from when helpers begin seeing it". Only the start
    // differs, which is the whole distinction between the two timings.
    const instant = new Date("2026-07-28T16:00:00.000Z");

    expect(resolveScheduledTiming(instant)).toEqual(resolveAsapTiming(instant));
  });
});

describe("three hours means three real hours across a DST transition", () => {
  /**
   * These are the two nights a fixed-offset or wall-clock implementation gets
   * wrong. Availability is an absolute duration, so the New York clock reading
   * of the expiration is allowed to be two or four hours later — the instant
   * is not.
   */
  it("survives the spring-forward night, when 2 AM New York does not exist", () => {
    // 2027-03-14: EST -> EDT at 2:00 AM local (07:00Z).
    const start = new Date("2027-03-14T06:30:00.000Z"); // 1:30 AM EST
    const { expiresAt } = resolveScheduledTiming(start);

    expect(expiresAt.getTime() - start.getTime()).toBe(THREE_HOURS_MS);
    expect(expiresAt.toISOString()).toBe("2027-03-14T09:30:00.000Z");
    // Three real hours later the local clock reads 5:30 AM, not 4:30: an
    // implementation that added three wall-clock hours would be an hour early.
    expect(
      expiresAt.toLocaleTimeString("en-US", {
        timeZone: NYU_TIME_ZONE,
        hour: "numeric",
        minute: "2-digit",
      })
    ).toBe("5:30 AM");
  });

  it("survives the fall-back night, when 1 AM New York happens twice", () => {
    // 2027-11-07: EDT -> EST at 2:00 AM local (06:00Z).
    const start = new Date("2027-11-07T05:30:00.000Z"); // 1:30 AM EDT
    const { expiresAt } = resolveScheduledTiming(start);

    expect(expiresAt.getTime() - start.getTime()).toBe(THREE_HOURS_MS);
    expect(expiresAt.toISOString()).toBe("2027-11-07T08:30:00.000Z");
    // Three real hours later the local clock reads 3:30 AM, not 4:30.
    expect(
      expiresAt.toLocaleTimeString("en-US", {
        timeZone: NYU_TIME_ZONE,
        hour: "numeric",
        minute: "2-digit",
      })
    ).toBe("3:30 AM");
  });

  it("formats the resolved window in campus time, not in server time", () => {
    // The same instants a helper is shown. 6 PM EDT on a summer evening reads
    // as 6 PM regardless of what timezone the Node process runs in, because
    // the formatter is given the zone explicitly.
    const start = new Date("2026-07-28T22:00:00.000Z");
    const { visibleFrom, expiresAt } = resolveScheduledTiming(start);

    expect(formatMealRequestWindow(visibleFrom, expiresAt)).toBe(
      "Jul 28, 6:00 PM – 9:00 PM"
    );
  });
});

describe("isAcceptableScheduledStart", () => {
  const now = new Date("2026-07-28T16:00:00.000Z");

  it("accepts a start exactly at the backend's now", () => {
    // The accepted boundary, and the reason it is inclusive: this is the first
    // instant the request is visible, not the last instant before it.
    expect(isAcceptableScheduledStart(new Date(now), now)).toBe(true);
  });

  it("refuses a start one millisecond before the backend's now", () => {
    expect(
      isAcceptableScheduledStart(new Date(now.getTime() - 1), now)
    ).toBe(false);
  });

  it("refuses an elapsed start even while its three hours have time left", () => {
    // The case the earlier expiration-only rule accepted: a 3 PM pickup posted
    // at 4 PM still had two hours of lifetime, and would have been written as
    // a request helpers saw immediately, advertising a pickup an hour gone.
    const anHourAgo = new Date(now.getTime() - 60 * 60 * 1000);

    expect(resolveScheduledTiming(anHourAgo).expiresAt.getTime()).toBeGreaterThan(
      now.getTime()
    );
    expect(isAcceptableScheduledStart(anHourAgo, now)).toBe(false);
  });

  it("refuses a start whose whole three hours have already elapsed", () => {
    const exactlyThreeHoursAgo = new Date(now.getTime() - THREE_HOURS_MS);

    expect(isAcceptableScheduledStart(exactlyThreeHoursAgo, now)).toBe(false);
  });

  it("accepts a start that has not arrived yet", () => {
    const startsInSixHours = new Date(now.getTime() + 6 * 60 * 60 * 1000);

    expect(isAcceptableScheduledStart(startsInSixHours, now)).toBe(true);
  });

  it("refuses an unparseable start rather than reading it as zero", () => {
    expect(isAcceptableScheduledStart(new Date("not-a-date"), now)).toBe(false);
  });

  it("agrees with the visibility rule at the exact boundary instant", () => {
    // Creation and availability must draw the line at the same place: a start
    // accepted at `now` has to be a start `isVisibleNow` reports as visible at
    // `now`, or a request could be created into a gap it is not yet in.
    const start = new Date(now);

    expect(isAcceptableScheduledStart(start, now)).toBe(true);
    expect(isVisibleNow(resolveScheduledTiming(start).visibleFrom, now)).toBe(
      true
    );
  });
});
