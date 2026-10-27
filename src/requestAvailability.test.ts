import { describe, expect, it } from "vitest";
import {
  CLAIM_MINIMUM_REMAINING_MS,
  buildEffectiveAvailabilityFilter,
  buildMinimumRemainingTimeFilter,
  buildVisibleNowFilter,
  hasMinimumRemainingTime,
  isEffectivelyAvailable,
  isStoppedAfterAffirmedOrder,
  isVisibleNow,
} from "./requestAvailability.js";

// One captured instant, as every caller supplies. Nothing here reads the clock,
// so the boundary cases cannot drift into flakiness.
const now = new Date("2026-07-30T16:00:00.000Z");
const exactlyFiveMinutesLeft = new Date(
  now.getTime() + CLAIM_MINIMUM_REMAINING_MS
);
const oneMillisecondShort = new Date(
  exactlyFiveMinutesLeft.getTime() - 1
);

describe("the shared minimum-remaining-time rule", () => {
  it("is five full minutes measured from the captured instant", () => {
    expect(CLAIM_MINIMUM_REMAINING_MS).toBe(5 * 60 * 1000);
    expect(buildMinimumRemainingTimeFilter(now)).toEqual({
      $gt: now,
      $gte: exactlyFiveMinutesLeft,
    });
  });

  it("accepts exactly five minutes and rejects one millisecond less", () => {
    expect(hasMinimumRemainingTime(exactlyFiveMinutesLeft, now)).toBe(true);
    expect(hasMinimumRemainingTime(oneMillisecondShort, now)).toBe(false);
  });

  it("keeps the in-memory rule identical to the database bound", () => {
    // Advertising and claiming disagree the moment these two drift apart.
    const bound = buildMinimumRemainingTimeFilter(now).$gte.getTime();

    for (const offset of [-1, 0, 1, 60_000, -60_000]) {
      const expiresAt = new Date(bound + offset);
      expect(hasMinimumRemainingTime(expiresAt, now)).toBe(
        expiresAt.getTime() >= bound
      );
    }
  });

  it("fails closed on a missing or unparseable expiration", () => {
    expect(hasMinimumRemainingTime(null, now)).toBe(false);
    expect(hasMinimumRemainingTime(undefined, now)).toBe(false);
    expect(hasMinimumRemainingTime("not a date", now)).toBe(false);
  });
});

describe("the shared start-of-visibility rule", () => {
  it("is an inclusive bound written so a missing start still matches", () => {
    // `$not: { $gt: now }` and not `$lte: now`. Requests written before
    // `visibleFrom` existed carry no value at all, and `$lte` would hide every
    // one of them the moment this clause was added.
    expect(buildVisibleNowFilter(now)).toEqual({ $not: { $gt: now } });
  });

  it("shows a request exactly at its start and not one millisecond before", () => {
    expect(isVisibleNow(now, now)).toBe(true);
    expect(isVisibleNow(new Date(now.getTime() + 1), now)).toBe(false);
    expect(isVisibleNow(new Date(now.getTime() - 1), now)).toBe(true);
  });

  it("treats a request with no recorded start as visible from creation", () => {
    // The legacy allowance, and the only one: these rows were visible before
    // the field existed and no slice migrates them.
    expect(isVisibleNow(null, now)).toBe(true);
    expect(isVisibleNow(undefined, now)).toBe(true);
  });

  it("fails closed on an unparseable start", () => {
    // Not a legacy absence — a value that cannot be read is not evidence the
    // request may be shown.
    expect(isVisibleNow("not a date", now)).toBe(false);
  });
});

describe("buildEffectiveAvailabilityFilter", () => {
  it("advertises only what a claim could still win", () => {
    expect(buildEffectiveAvailabilityFilter(now)).toEqual({
      visibleFrom: { $not: { $gt: now } },
      expiresAt: { $gt: now, $gte: exactlyFiveMinutesLeft },
      // W4-U1.3: a request carrying the post-Yes external-order-risk authority
      // is never advertised again; `$ne: true` leaves every ordinary request,
      // including rows that never had the field, untouched.
      externalOrderAffirmed: { $ne: true },
      // W4-U1.2 (boundary contract EO): M and L are top-level beside E for the
      // same reason, and `$ne: true` leaves every ordinary request untouched.
      moderationUnavailable: { $ne: true },
      reservationLapseHold: { $ne: true },
      $or: [
        { status: "open" },
        { status: "claimed", claimExpiresAt: { $lte: now } },
      ],
    });
  });

  it("derives the start bound from the same captured instant", () => {
    const other = new Date("2026-07-30T18:30:00.000Z");

    expect(buildEffectiveAvailabilityFilter(other).visibleFrom).toEqual(
      buildVisibleNowFilter(other)
    );
  });

  it("derives both bounds from the instant the caller captured", () => {
    const other = new Date("2026-07-30T18:30:00.000Z");
    const filter = buildEffectiveAvailabilityFilter(other);

    expect(filter.expiresAt.$gte).toEqual(
      new Date(other.getTime() + CLAIM_MINIMUM_REMAINING_MS)
    );
    // `$or[1]` is the claimed branch, which the filter above always builds
    // with a `claimExpiresAt` bound.
    expect(filter.$or[1].claimExpiresAt!.$lte).toEqual(other);
  });
});

describe("isEffectivelyAvailable", () => {
  it("advertises an open request with exactly the minimum remaining", () => {
    expect(
      isEffectivelyAvailable(
        { status: "open", expiresAt: exactlyFiveMinutesLeft },
        now
      )
    ).toBe(true);
  });

  it("withholds an open request one millisecond short of the minimum", () => {
    expect(
      isEffectivelyAvailable(
        { status: "open", expiresAt: oneMillisecondShort },
        now
      )
    ).toBe(false);
  });

  it("reopens an expired claim that still has the minimum remaining", () => {
    expect(
      isEffectivelyAvailable(
        {
          status: "claimed",
          expiresAt: exactlyFiveMinutesLeft,
          claimExpiresAt: new Date(now.getTime() - 1),
        },
        now
      )
    ).toBe(true);
  });

  it("does not reopen an expired claim that ran out of runway", () => {
    expect(
      isEffectivelyAvailable(
        {
          status: "claimed",
          expiresAt: oneMillisecondShort,
          claimExpiresAt: new Date(now.getTime() - 1),
        },
        now
      )
    ).toBe(false);
  });

  it("withholds a scheduled request until its start arrives", () => {
    const startsInAnHour = new Date(now.getTime() + 60 * 60 * 1000);

    expect(
      isEffectivelyAvailable(
        {
          status: "open",
          visibleFrom: startsInAnHour,
          expiresAt: new Date(startsInAnHour.getTime() + 3 * 60 * 60 * 1000),
        },
        now
      )
    ).toBe(false);
  });

  it("advertises a scheduled request at exactly its start", () => {
    expect(
      isEffectivelyAvailable(
        {
          status: "open",
          visibleFrom: now,
          expiresAt: new Date(now.getTime() + 3 * 60 * 60 * 1000),
        },
        now
      )
    ).toBe(true);
  });

  it("withholds a scheduled request one millisecond before its start", () => {
    const start = new Date(now.getTime() + 1);

    expect(
      isEffectivelyAvailable(
        {
          status: "open",
          visibleFrom: start,
          expiresAt: new Date(start.getTime() + 3 * 60 * 60 * 1000),
        },
        now
      )
    ).toBe(false);
  });

  it("still applies the five-minute threshold inside a started window", () => {
    // The two rules compose: having begun is not the same as having time left.
    const startedAnHourAgo = new Date(now.getTime() - 60 * 60 * 1000);

    expect(
      isEffectivelyAvailable(
        {
          status: "open",
          visibleFrom: startedAnHourAgo,
          expiresAt: oneMillisecondShort,
        },
        now
      )
    ).toBe(false);
    expect(
      isEffectivelyAvailable(
        {
          status: "open",
          visibleFrom: startedAnHourAgo,
          expiresAt: exactlyFiveMinutesLeft,
        },
        now
      )
    ).toBe(true);
  });

  it("does not reopen an expired claim on a request that has not started", () => {
    const startsInAnHour = new Date(now.getTime() + 60 * 60 * 1000);

    expect(
      isEffectivelyAvailable(
        {
          status: "claimed",
          visibleFrom: startsInAnHour,
          expiresAt: new Date(startsInAnHour.getTime() + 3 * 60 * 60 * 1000),
          claimExpiresAt: new Date(now.getTime() - 1),
        },
        now
      )
    ).toBe(false);
  });

  it("withholds an active claim regardless of remaining time", () => {
    expect(
      isEffectivelyAvailable(
        {
          status: "claimed",
          expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
          claimExpiresAt: new Date(now.getTime() + 1),
        },
        now
      )
    ).toBe(false);
  });
});

describe("the W4-U1.3 post-Yes external-order-risk authority", () => {
  const lapsed = new Date(now.getTime() - 1000);

  it("never reopens a lapsed claim that carries the authority, while an ordinary lapse still reopens", () => {
    const base = {
      status: "claimed",
      expiresAt: exactlyFiveMinutesLeft,
      claimExpiresAt: lapsed,
    };

    expect(isEffectivelyAvailable(base, now)).toBe(true);
    expect(
      isEffectivelyAvailable({ ...base, externalOrderAffirmed: true }, now)
    ).toBe(false);
    // An absent, null, or false marker is "not established" and changes nothing.
    for (const marker of [undefined, null, false]) {
      expect(
        isEffectivelyAvailable({ ...base, externalOrderAffirmed: marker }, now)
      ).toBe(true);
    }
  });

  it("fails closed even for a marked row that reads open", () => {
    expect(
      isEffectivelyAvailable(
        {
          status: "open",
          expiresAt: exactlyFiveMinutesLeft,
          externalOrderAffirmed: true,
        },
        now
      )
    ).toBe(false);
  });

  it("identifies only a claimed, marked request that has no reservation deadline", () => {
    const stopped = {
      status: "claimed",
      externalOrderAffirmed: true,
      claimExpiresAt: undefined,
    };

    expect(isStoppedAfterAffirmedOrder(stopped)).toBe(true);
    expect(isStoppedAfterAffirmedOrder({ ...stopped, claimExpiresAt: null })).toBe(
      true
    );
    // A live or lapsed reservation of a marked request is not "stopped".
    expect(
      isStoppedAfterAffirmedOrder({ ...stopped, claimExpiresAt: lapsed })
    ).toBe(false);
    expect(isStoppedAfterAffirmedOrder({ ...stopped, status: "placed" })).toBe(false);
    expect(isStoppedAfterAffirmedOrder({ ...stopped, status: "open" })).toBe(false);
    // Without the marker an absent deadline is not enough.
    expect(
      isStoppedAfterAffirmedOrder({ status: "claimed", claimExpiresAt: undefined })
    ).toBe(false);
  });
});
