import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Request as MealRequest, type IRequest } from "../models/db.js";
import {
  CLOSING_SOON_WINDOW_MS,
  MAXIMUM_CLOSING_SOON_REQUESTS_PER_SWEEP,
  runClosingSoonNotificationSweep,
} from "./closingSoonNotificationSweep.js";
import type { HelperNotificationInitiation } from "./helperNotificationInitiation.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";

/**
 * Modeled on `eligibilityNotificationSweep.test.ts`'s stubbing approach.
 * Real persistence/concurrency belongs in a future `.mongo.test.ts`
 * companion.
 */
const sweepInstant = new Date("2026-08-09T18:00:00.000Z");

function requestId(index: number): mongoose.Types.ObjectId {
  return new mongoose.Types.ObjectId(
    `64e${index.toString(16).padStart(21, "0")}`
  );
}

function closingSoonRequest(index = 1, overrides: Record<string, unknown> = {}): IRequest {
  return {
    _id: requestId(index),
    vendor: "Crave NYU",
    status: "open",
    expiresAt: new Date(sweepInstant.getTime() + 10 * 60 * 1000),
    closingSoonNotification: "awaiting",
    mealSwipes: 1,
    ...overrides,
  } as unknown as IRequest;
}

let find: ReturnType<typeof vi.spyOn>;
let updateOne: ReturnType<typeof vi.spyOn>;
let selectionFilter: Record<string, unknown> | undefined;
let selectionSort: unknown;
let selectionLimit: number | undefined;
let updateCalls: unknown[] = [];

function stubCandidates(rows: IRequest[]): void {
  find.mockImplementation((filter: unknown) => {
    selectionFilter = filter as Record<string, unknown>;
    return {
      sort(order: unknown) {
        selectionSort = order;
        return this;
      },
      limit(count: number) {
        selectionLimit = count;
        return this;
      },
      exec: async () => rows,
    };
  });
}

function dependencies(overrides: Record<string, unknown> = {}) {
  return {
    now: () => sweepInstant,
    isPaused: () => false,
    dispatchPush: vi.fn(
      async (): Promise<HelperNotificationInitiation> => "processed"
    ),
    maximumRequests: MAXIMUM_CLOSING_SOON_REQUESTS_PER_SWEEP,
    ...overrides,
  };
}

beforeEach(() => {
  selectionFilter = undefined;
  selectionSort = undefined;
  selectionLimit = undefined;
  updateCalls = [];
  find = vi.spyOn(MealRequest, "find") as ReturnType<typeof vi.spyOn>;
  updateOne = vi.spyOn(MealRequest, "updateOne") as ReturnType<typeof vi.spyOn>;
  updateOne.mockImplementation((filter: unknown, update: unknown) => {
    updateCalls.push({ filter, update });
    return { exec: async () => ({ modifiedCount: 1 }) } as never;
  });
  stubCandidates([]);
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("closing-soon candidate selection", () => {
  it("selects effectively-available requests within the T-15 window, awaiting or legacy-absent", async () => {
    await runClosingSoonNotificationSweep(dependencies());

    const windowEnd = new Date(sweepInstant.getTime() + CLOSING_SOON_WINDOW_MS);
    expect(selectionFilter).toEqual({
      $and: [
        buildEffectiveAvailabilityFilter(sweepInstant),
        { expiresAt: { $lte: windowEnd } },
        {
          $or: [
            { closingSoonNotification: "awaiting" },
            { closingSoonNotification: { $exists: false } },
          ],
        },
      ],
    });
  });

  it("orders by expiresAt, the deadline this notification is relative to", async () => {
    await runClosingSoonNotificationSweep(dependencies());
    expect(selectionSort).toEqual({ expiresAt: 1 });
  });

  it("bounds the run to the configured maximum", async () => {
    await runClosingSoonNotificationSweep(dependencies({ maximumRequests: 7 }));
    expect(selectionLimit).toBe(7);
  });
});

describe("closing-soon initiation", () => {
  it("records closing-soon initiated only when the push channel processed it", async () => {
    stubCandidates([closingSoonRequest(1)]);
    const dispatchPush = vi.fn(async () => "processed" as const);

    const summary = await runClosingSoonNotificationSweep(
      dependencies({ dispatchPush })
    );

    expect(summary.initiated).toBe(1);
    expect(summary.deferred).toBe(0);
    expect(updateOne).toHaveBeenCalledTimes(1);
    const call = updateCalls[0] as { update: Record<string, unknown> };
    expect(call.update).toEqual({ $set: { closingSoonNotification: "initiated" } });
  });

  it("leaves the request awaiting (no state change) when the push channel is retryable", async () => {
    stubCandidates([closingSoonRequest(1)]);
    const dispatchPush = vi.fn(async () => "retryable" as const);

    const summary = await runClosingSoonNotificationSweep(
      dependencies({ dispatchPush })
    );

    expect(summary.initiated).toBe(0);
    expect(summary.deferred).toBe(1);
    expect(updateOne).not.toHaveBeenCalled();
  });

  it("fences the conditional update by the generation the dispatch ran for", async () => {
    stubCandidates([closingSoonRequest(1, { notificationGeneration: 3 })]);

    await runClosingSoonNotificationSweep(dependencies());

    const call = updateCalls[0] as { filter: { $and: Record<string, unknown>[] } };
    expect(call.filter.$and[1]).toEqual({ notificationGeneration: 3 });
  });

  it("does not re-initiate for one request's failure if another request in the batch succeeds", async () => {
    stubCandidates([closingSoonRequest(1), closingSoonRequest(2)]);
    const dispatchPush = vi
      .fn()
      .mockResolvedValueOnce("retryable")
      .mockResolvedValueOnce("processed");

    const summary = await runClosingSoonNotificationSweep(
      dependencies({ dispatchPush })
    );

    expect(summary.candidates).toBe(2);
    expect(summary.initiated).toBe(1);
    expect(summary.deferred).toBe(1);
  });

  it("treats a thrown dispatch as retryable rather than crashing the sweep", async () => {
    stubCandidates([closingSoonRequest(1)]);
    const dispatchPush = vi.fn().mockRejectedValue(new Error("apns down"));

    const summary = await runClosingSoonNotificationSweep(
      dependencies({ dispatchPush })
    );

    expect(summary.deferred).toBe(1);
    expect(updateOne).not.toHaveBeenCalled();
  });
});

describe("closing-soon sweep guards", () => {
  it("does not select or initiate while paused", async () => {
    stubCandidates([closingSoonRequest(1)]);
    const dispatchPush = vi.fn();

    const summary = await runClosingSoonNotificationSweep(
      dependencies({ isPaused: () => true, dispatchPush })
    );

    expect(summary.stop).toBe("paused");
    expect(find).not.toHaveBeenCalled();
    expect(dispatchPush).not.toHaveBeenCalled();
  });

  it("guards against overlapping itself", async () => {
    stubCandidates([closingSoonRequest(1)]);
    let release: () => void = () => {};
    const dispatchPush = vi.fn(
      () =>
        new Promise<HelperNotificationInitiation>((resolve) => {
          release = () => resolve("processed");
        })
    );

    const first = runClosingSoonNotificationSweep(dependencies({ dispatchPush }));
    const second = await runClosingSoonNotificationSweep(dependencies({ dispatchPush }));

    expect(second.stop).toBe("overlapping");
    release();
    await first;
  });
});
