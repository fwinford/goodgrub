import { afterEach, describe, expect, it, vi } from "vitest";
import { Request as MealRequest } from "../models/db.js";
import {
  countTodaysRequests,
  DAILY_REQUEST_LIMIT,
  isUnderDailyLimit,
} from "./requestDailyQuota.js";

const PRINCIPAL = "quota-unit@nyu.edu";

function mockCount(value: number) {
  return vi.spyOn(MealRequest, "countDocuments").mockResolvedValue(value as never);
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("countTodaysRequests", () => {
  it("counts against the exact principal and the NYU campus-day boundary", async () => {
    const count = mockCount(0);
    // 2026-07-28T04:00:00Z is exactly 00:00:00 EDT: NYU campus midnight.
    const now = new Date("2026-07-28T10:00:00.000Z");

    await countTodaysRequests(PRINCIPAL, now);

    expect(count).toHaveBeenCalledExactlyOnceWith({
      email: PRINCIPAL,
      createdAt: { $gte: new Date("2026-07-28T04:00:00.000Z") },
    });
  });

  it("returns the exact count from the underlying query", async () => {
    mockCount(2);

    await expect(countTodaysRequests(PRINCIPAL, new Date())).resolves.toBe(2);
  });

  it("propagates a database failure rather than reporting a count", async () => {
    vi.spyOn(MealRequest, "countDocuments").mockRejectedValue(
      new Error("count unavailable")
    );

    await expect(
      countTodaysRequests(PRINCIPAL, new Date())
    ).rejects.toThrow("count unavailable");
  });
});

describe("isUnderDailyLimit", () => {
  it("is true below the threshold and false at/above it", () => {
    expect(isUnderDailyLimit(0)).toBe(true);
    expect(isUnderDailyLimit(DAILY_REQUEST_LIMIT - 1)).toBe(true);
    expect(isUnderDailyLimit(DAILY_REQUEST_LIMIT)).toBe(false);
    expect(isUnderDailyLimit(DAILY_REQUEST_LIMIT + 1)).toBe(false);
  });
});
