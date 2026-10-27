import { readFileSync } from "node:fs";
import cron from "node-cron";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Request as MealRequest, type IRequest } from "../models/db.js";

// `emailHelpers.ts` builds a Resend client at module scope, so importing the
// real email dispatcher needs an API key this suite has no business holding.
// Only that boundary is replaced: `notifySubscribersForRequest` itself stays
// real, so the module's default channel wiring is the production wiring.
vi.mock("./emailHelpers.js", () => ({ sendNewRequestAlert: vi.fn() }));

import {
  ELIGIBILITY_SWEEP_CRON,
  MAXIMUM_REQUESTS_PER_SWEEP,
  runEligibilityNotificationSweep,
  scheduleEligibilityNotificationSweep,
  startEligibilityNotificationSweep,
} from "./eligibilityNotificationSweep.js";
import type { HelperNotificationInitiation } from "./helperNotificationInitiation.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  buildEffectiveAvailabilityFilter,
  isEffectivelyAvailable,
} from "./requestAvailability.js";
import { buildNotificationGenerationFilter } from "./requestRevision.js";

/**
 * The eligibility sweep (W3-N3), exercised against stubbed models and injected
 * channel dispatchers. Nothing here contacts a provider or a database; the real
 * persistence, index, concurrency, and pre-`visibleFrom` withholding behavior
 * is proved in `src/eligibilityNotificationSweep.mongo.test.ts`.
 */
const sweepInstant = new Date("2026-08-09T18:00:00.000Z");

function requestId(index: number): mongoose.Types.ObjectId {
  return new mongoose.Types.ObjectId(
    `64d${index.toString(16).padStart(21, "0")}`
  );
}

/**
 * A Later request that became eligible at `sweepInstant` and was created nine
 * hours earlier — far outside both the one-hour digest lookback and any
 * plausible creation-time window.
 */
function laterRequest(index = 1): IRequest {
  return {
    _id: requestId(index),
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    pickupWindowText: "Aug 9, 2:00 PM – 5:00 PM",
    status: "open",
    createdAt: new Date(sweepInstant.getTime() - 9 * 60 * 60 * 1000),
    visibleFrom: sweepInstant,
    expiresAt: new Date(sweepInstant.getTime() + 3 * 60 * 60 * 1000),
    helperNotification: "awaiting-eligibility",
  } as unknown as IRequest;
}

let find: ReturnType<typeof vi.spyOn>;
let updateOne: ReturnType<typeof vi.spyOn>;
let selectionFilter: Record<string, unknown> | undefined;
let selectionSort: unknown;
let selectionLimit: number | undefined;

function stubCandidates(rows: IRequest[] | (() => Promise<IRequest[]>)): void {
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
      exec: async () => (typeof rows === "function" ? rows() : rows),
    };
  });
}

function stubUpdate(result: Promise<unknown> = Promise.resolve({})): void {
  updateOne.mockImplementation(() => ({ exec: () => result }));
}

function dependencies(overrides: Record<string, unknown> = {}) {
  return {
    now: () => sweepInstant,
    isPaused: () => false,
    notifySubscribers: vi.fn(
      async (): Promise<HelperNotificationInitiation> => "processed"
    ),
    dispatchPush: vi.fn(
      async (): Promise<HelperNotificationInitiation> => "processed"
    ),
    maximumRequests: MAXIMUM_REQUESTS_PER_SWEEP,
    ...overrides,
  };
}

beforeEach(() => {
  selectionFilter = undefined;
  selectionSort = undefined;
  selectionLimit = undefined;
  find = vi.spyOn(MealRequest, "find") as ReturnType<typeof vi.spyOn>;
  updateOne = vi.spyOn(MealRequest, "updateOne") as ReturnType<typeof vi.spyOn>;
  stubCandidates([]);
  stubUpdate();
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

/** The shared availability half of the selection filter. */
function availabilityClause(): Record<string, unknown> {
  const conjunction = selectionFilter?.$and as Record<string, unknown>[];
  return conjunction?.[0] ?? {};
}

/** The two ownership branches: creation-handed, and the pre-N3 transition row. */
function ownershipBranches(): Record<string, unknown>[] {
  const conjunction = selectionFilter?.$and as Record<string, unknown>[];
  return (conjunction?.[1]?.$or as Record<string, unknown>[]) ?? [];
}

describe("eligibility-time candidate selection", () => {
  it("selects both awaiting populations under the shared effective-availability rule", async () => {
    await runEligibilityNotificationSweep(dependencies());

    expect(selectionFilter).toEqual({
      // `$and`, because both halves carry a top-level `$or`; merging them as
      // sibling keys would silently drop one.
      $and: [
        buildEffectiveAvailabilityFilter(sweepInstant),
        {
          $or: [
            { helperNotification: "awaiting-eligibility" },
            {
              helperNotification: { $exists: false },
              windowStart: { $type: "date" },
              $expr: { $gt: ["$visibleFrom", "$createdAt"] },
            },
          ],
        },
      ],
    });
  });

  it("bounds discovery by eligibility rather than by creation age", async () => {
    // The whole slice: a Later request created long before any creation-time
    // lookback must still be found the moment it becomes eligible. A
    // `createdAt` clause of any kind here is what would lose it.
    const dispatch = dependencies();
    stubCandidates([laterRequest()]);

    await runEligibilityNotificationSweep(dispatch);

    // No creation-age bound of any kind. `createdAt` survives only inside the
    // transition branch's `visibleFrom > createdAt` comparison, which is a
    // statement about the request's shape rather than about its age.
    expect(selectionFilter).not.toHaveProperty("createdAt");
    expect(availabilityClause()).not.toHaveProperty("createdAt");
    for (const branch of ownershipBranches()) {
      expect(branch).not.toHaveProperty("createdAt");
    }
    expect(dispatch.notifySubscribers).toHaveBeenCalledOnce();
    expect(dispatch.dispatchPush).toHaveBeenCalledOnce();
  });

  it("never selects a request whose helper notification was already initiated", async () => {
    // Neither branch can match `initiated`: one is an exact equality on the
    // awaiting state, and the other requires the field to be absent entirely.
    // An ASAP request is written `initiated` at creation, so the state
    // creation-time dispatch owns is outside the candidate set by
    // construction rather than by a later check.
    await runEligibilityNotificationSweep(dependencies());

    expect(ownershipBranches()).toEqual([
      { helperNotification: "awaiting-eligibility" },
      expect.objectContaining({ helperNotification: { $exists: false } }),
    ]);
  });

  it("only offers catch-up to an identifiable future Later row", async () => {
    // The transition population is pre-N3 W3-R1 Later requests, not every
    // historical row that happens to lack the field. A row that cannot prove
    // its eligibility began after its creation is left alone.
    await runEligibilityNotificationSweep(dependencies());

    expect(ownershipBranches()[1]).toEqual({
      helperNotification: { $exists: false },
      windowStart: { $type: "date" },
      $expr: { $gt: ["$visibleFrom", "$createdAt"] },
    });
  });

  it("withholds a request whose visibleFrom has not arrived", async () => {
    const future = {
      ...laterRequest(),
      visibleFrom: new Date(sweepInstant.getTime() + 60 * 60 * 1000),
      expiresAt: new Date(sweepInstant.getTime() + 4 * 60 * 60 * 1000),
    } as unknown as IRequest;

    await runEligibilityNotificationSweep(dependencies());

    // The selection filter carries the shared start-of-visibility clause, and
    // that same rule refuses this document at this instant: eligibility-time
    // initiation cannot run early. It gates both ownership branches, so the
    // pre-N3 transition population is withheld before `visibleFrom` too.
    expect(availabilityClause().visibleFrom).toEqual(
      buildEffectiveAvailabilityFilter(sweepInstant).visibleFrom
    );
    expect(isEffectivelyAvailable(future, sweepInstant)).toBe(false);
  });

  it.each([
    ["expired", { expiresAt: new Date(sweepInstant.getTime() - 1) }],
    ["placed", { status: "placed" }],
    [
      "actively claimed",
      {
        status: "claimed",
        claimExpiresAt: new Date(sweepInstant.getTime() + 10 * 60 * 1000),
      },
    ],
  ])(
    "leaves a %s request out of eligibility-time notification",
    async (_label, overrides) => {
      const unavailable = { ...laterRequest(), ...overrides } as IRequest;

      expect(isEffectivelyAvailable(unavailable, sweepInstant)).toBe(false);
      // A request that stops being available while it waits simply never
      // matches the selection filter again: it leaves the awaiting state by
      // TTL deletion, never by a stale new-request alert.
      await runEligibilityNotificationSweep(dependencies());
      expect(availabilityClause()).toEqual(
        buildEffectiveAvailabilityFilter(sweepInstant)
      );
    }
  );

  it("takes the longest-eligible requests first, under a bounded batch", async () => {
    await runEligibilityNotificationSweep(dependencies());

    expect(selectionSort).toEqual({ visibleFrom: 1 });
    expect(selectionLimit).toBe(MAXIMUM_REQUESTS_PER_SWEEP);
  });

  it("reports a failed selection without dispatching anything", async () => {
    const dispatch = dependencies();
    find.mockImplementation(() => ({
      sort() {
        return this;
      },
      limit() {
        return this;
      },
      exec: async () => {
        throw new Error("selection failed");
      },
    }));

    const summary = await runEligibilityNotificationSweep(dispatch);

    expect(summary.stop).toBe("selection-failed");
    expect(dispatch.notifySubscribers).not.toHaveBeenCalled();
    expect(dispatch.dispatchPush).not.toHaveBeenCalled();
    expect(updateOne).not.toHaveBeenCalled();
  });
});

describe("eligibility-time initiation of both existing channels", () => {
  it("starts the existing helper push and helper email dispatch for the request itself", async () => {
    const request = laterRequest();
    const dispatch = dependencies();
    stubCandidates([request]);

    const summary = await runEligibilityNotificationSweep(dispatch);

    // The same dispatchers the create route calls, given the same document —
    // so recipient eligibility, payloads, provider classification, retirement,
    // and tap routing are whatever those already do.
    expect(dispatch.dispatchPush).toHaveBeenCalledWith(request);
    expect(dispatch.notifySubscribers).toHaveBeenCalledWith(request);
    expect(summary).toEqual({
      stop: "completed",
      candidates: 1,
      initiated: 1,
      deferred: 0,
    });
  });

  it("moves the request out of the awaiting state with one conditional update", async () => {
    const request = laterRequest();
    stubCandidates([request]);

    await runEligibilityNotificationSweep(dependencies());

    expect(updateOne).toHaveBeenCalledOnce();
    // `$ne: "initiated"` rather than an equality on the awaiting state: both
    // selectable populations have to be able to leave, including a pre-N3
    // transition row that carries no state at all yet.
    // W4-R5: additionally conditional on the notification generation the
    // dispatches ran for, so a rescheduling that landed meanwhile keeps the
    // request awaiting for its new generation.
    expect(updateOne).toHaveBeenCalledWith(
      {
        $and: [
          { _id: request._id, helperNotification: { $ne: "initiated" } },
          buildNotificationGenerationFilter(1),
        ],
      },
      { $set: { helperNotification: "initiated" } }
    );
  });

  it("records initiation against the stored generation, not the initial one", async () => {
    const request = {
      ...laterRequest(),
      notificationGeneration: 3,
    } as unknown as IRequest;
    stubCandidates([request]);

    await runEligibilityNotificationSweep(dependencies());

    expect(updateOne).toHaveBeenCalledWith(
      {
        $and: [
          { _id: request._id, helperNotification: { $ne: "initiated" } },
          { notificationGeneration: 3 },
        ],
      },
      { $set: { helperNotification: "initiated" } }
    );
  });

  it("selects the private generation so initiation is recorded against the right one", async () => {
    stubCandidates([laterRequest()]);

    await runEligibilityNotificationSweep(dependencies());

    expect(find).toHaveBeenCalledWith(
      expect.anything(),
      "+notificationGeneration +contentRevision"
    );
  });

  it("initiates each eligible request, one at a time", async () => {
    const order: string[] = [];
    const requests = [laterRequest(1), laterRequest(2), laterRequest(3)];
    stubCandidates(requests);
    const dispatch = dependencies({
      notifySubscribers: vi.fn(
        async (request: IRequest): Promise<HelperNotificationInitiation> => {
          order.push(`email:${String(request._id)}`);
          return "processed";
        }
      ),
      dispatchPush: vi.fn(
        async (request: IRequest): Promise<HelperNotificationInitiation> => {
          order.push(`push:${String(request._id)}`);
          return "processed";
        }
      ),
    });

    const summary = await runEligibilityNotificationSweep(dispatch);

    expect(summary.initiated).toBe(3);
    expect(order).toEqual([
      `push:${String(requests[0]._id)}`,
      `email:${String(requests[0]._id)}`,
      `push:${String(requests[1]._id)}`,
      `email:${String(requests[1]._id)}`,
      `push:${String(requests[2]._id)}`,
      `email:${String(requests[2]._id)}`,
    ]);
  });

  it("keeps the two channels independent of each other", async () => {
    const failingPush = dependencies({
      dispatchPush: vi.fn(async () => {
        throw new Error("APNs selection failed");
      }),
    });
    stubCandidates([laterRequest()]);

    await runEligibilityNotificationSweep(failingPush);

    expect(failingPush.notifySubscribers).toHaveBeenCalledOnce();

    const failingEmail = dependencies({
      notifySubscribers: vi.fn(async () => {
        throw new Error("subscriber query failed");
      }),
    });
    stubCandidates([laterRequest()]);

    await runEligibilityNotificationSweep(failingEmail);

    expect(failingEmail.dispatchPush).toHaveBeenCalledOnce();
  });

  it("does not stop the requests behind a failing one", async () => {
    stubCandidates([laterRequest(1), laterRequest(2)]);
    const dispatch = dependencies({
      dispatchPush: vi
        .fn()
        .mockRejectedValueOnce(new Error("APNs selection failed"))
        .mockResolvedValueOnce("processed"),
    });

    const summary = await runEligibilityNotificationSweep(dispatch);

    expect(dispatch.notifySubscribers).toHaveBeenCalledTimes(2);
    expect(summary).toEqual({
      stop: "completed",
      candidates: 2,
      initiated: 1,
      deferred: 1,
    });
  });
});

describe("initiation is completion, not promise resolution", () => {
  /**
   * Both dispatchers can resolve perfectly normally having initiated nothing.
   * Reading resolution as completion would consume the request's one
   * initiation on work that never happened.
   */
  it.each([
    ["push", "email"],
    ["email", "push"],
  ])(
    "leaves the request awaiting when %s resolves retryable",
    async (retryable, processed) => {
      const dispatch = dependencies({
        dispatchPush: vi.fn(async () =>
          retryable === "push" ? "retryable" : "processed"
        ),
        notifySubscribers: vi.fn(async () =>
          retryable === "email" ? "retryable" : "processed"
        ),
      });
      stubCandidates([laterRequest()]);

      const summary = await runEligibilityNotificationSweep(dispatch);

      expect(updateOne).not.toHaveBeenCalled();
      expect(summary).toEqual({
        stop: "completed",
        candidates: 1,
        initiated: 0,
        deferred: 1,
      });
      // Channel independence: the processed one still ran, and a later sweep
      // revisits both — the processed one as a per-recipient no-op.
      expect(
        processed === "push"
          ? dispatch.dispatchPush
          : dispatch.notifySubscribers
      ).toHaveBeenCalledOnce();
    }
  );

  it("moves the state only when both channels report a processed initiation", async () => {
    const dispatch = dependencies();
    stubCandidates([laterRequest()]);

    const summary = await runEligibilityNotificationSweep(dispatch);

    expect(summary.initiated).toBe(1);
    expect(updateOne).toHaveBeenCalledOnce();
  });

  it("recovers on a later run once the retryable channel processes", async () => {
    const request = laterRequest();
    stubCandidates([request]);
    const dispatchPush = vi
      .fn()
      .mockResolvedValueOnce("retryable")
      .mockResolvedValueOnce("processed");

    const blocked = await runEligibilityNotificationSweep(
      dependencies({ dispatchPush })
    );
    const recovered = await runEligibilityNotificationSweep(
      dependencies({ dispatchPush })
    );

    expect(blocked.deferred).toBe(1);
    expect(recovered.initiated).toBe(1);
    expect(updateOne).toHaveBeenCalledOnce();
  });

});

describe("catch-up and interruption safety", () => {
  it("leaves a request selectable when a channel dispatch throws", async () => {
    const request = laterRequest();
    stubCandidates([request]);

    const summary = await runEligibilityNotificationSweep(
      dependencies({
        notifySubscribers: vi.fn(async () => {
          throw new Error("subscriber query failed");
        }),
      })
    );

    // Nothing is marked, so the next run finds this request again — the
    // existing per-recipient `SendLog` and `PushDelivery` claims are what make
    // that retry a no-op for anyone already notified.
    expect(updateOne).not.toHaveBeenCalled();
    expect(summary).toEqual({
      stop: "completed",
      candidates: 1,
      initiated: 0,
      deferred: 1,
    });
  });

  it("reports a lost bookkeeping write without losing the dispatch", async () => {
    const dispatch = dependencies();
    stubCandidates([laterRequest()]);
    stubUpdate(Promise.reject(new Error("write failed")));

    const summary = await runEligibilityNotificationSweep(dispatch);

    expect(dispatch.dispatchPush).toHaveBeenCalledOnce();
    expect(dispatch.notifySubscribers).toHaveBeenCalledOnce();
    expect(summary.initiated).toBe(0);
    expect(summary.deferred).toBe(1);
  });

  it("initiates a request that became eligible long before this run", async () => {
    // A worker that did not run at `visibleFrom`. The request is two hours past
    // it, still available, and still selectable — the sweep is a catch-up, not
    // a tick that had to be present at the exact instant.
    const late = {
      ...laterRequest(),
      visibleFrom: new Date(sweepInstant.getTime() - 2 * 60 * 60 * 1000),
      expiresAt: new Date(sweepInstant.getTime() + 60 * 60 * 1000),
    } as unknown as IRequest;
    const dispatch = dependencies();
    stubCandidates([late]);

    expect(isEffectivelyAvailable(late, sweepInstant)).toBe(true);

    const summary = await runEligibilityNotificationSweep(dispatch);

    expect(dispatch.dispatchPush).toHaveBeenCalledWith(late);
    expect(dispatch.notifySubscribers).toHaveBeenCalledWith(late);
    expect(summary.initiated).toBe(1);
  });
});

describe("repeated, overlapping, and concurrent processing", () => {
  it("refuses to run against itself while a run is outstanding", async () => {
    let release: () => void = () => {};
    const blocked = new Promise<void>((resolve) => {
      release = resolve;
    });
    stubCandidates([laterRequest()]);
    const dispatch = dependencies({
      dispatchPush: vi.fn(async () => {
        await blocked;
      }),
    });

    const first = runEligibilityNotificationSweep(dispatch);
    const overlapping = await runEligibilityNotificationSweep(dependencies());

    expect(overlapping).toEqual({
      stop: "overlapping",
      candidates: 0,
      initiated: 0,
      deferred: 0,
    });

    release();
    await first;
    expect(dispatch.dispatchPush).toHaveBeenCalledOnce();
  });

  it("becomes available again after the outstanding run finishes", async () => {
    await runEligibilityNotificationSweep(dependencies());
    const second = await runEligibilityNotificationSweep(dependencies());

    expect(second.stop).toBe("completed");
  });

  it("writes the transition conditionally, so a concurrent run cannot reopen it", async () => {
    // Two processes can select the same request; both dispatch, and existing
    // per-recipient deduplication makes the second a no-op. The state write is
    // conditional on the awaiting state, so the second write matches nothing
    // rather than overwriting a decision the first already made.
    const request = laterRequest();
    stubCandidates([request]);

    await runEligibilityNotificationSweep(dependencies());
    await runEligibilityNotificationSweep(dependencies());

    for (const call of updateOne.mock.calls) {
      expect(call[0]).toEqual({
        $and: [
          { _id: request._id, helperNotification: { $ne: "initiated" } },
          buildNotificationGenerationFilter(1),
        ],
      });
    }
  });

  it("creates no submission path of its own", async () => {
    // Everything this module sends, it sends through the two existing
    // dispatchers. Pinned as the exact import list rather than as forbidden
    // words: a second submission path, a second delivery ledger, or a second
    // recipient-eligibility query would each have to appear here first.
    const source = readFileSync(
      new URL("./eligibilityNotificationSweep.ts", import.meta.url),
      "utf8"
    );
    const imports = [...source.matchAll(/^import [\s\S]*?from "([^"]+)";$/gm)]
      .map((match) => match[1])
      .sort();

    expect(imports).toEqual([
      "../models/db.js",
      "./externalProviders.js",
      "./helperNewRequestPush.js",
      "./helperNotificationInitiation.js",
      "./notifySubscribers.js",
      "./publicActionsPause.js",
      "./requestAvailability.js",
      "./requestRevision.js",
      "./scheduledJobs.js",
    ]);
  });
});

describe("public-actions pause", () => {
  beforeEach(() => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
  });

  it("consumes nothing while public actions are paused", async () => {
    // `isPaused` is deliberately left to the module default, so this proves
    // the real `PUBLIC_ACTIONS_PAUSED` reading, not an injected one.
    const { now, notifySubscribers, dispatchPush } = dependencies();
    const dispatch = { notifySubscribers, dispatchPush };
    stubCandidates([laterRequest()]);

    const summary = await runEligibilityNotificationSweep({
      now,
      ...dispatch,
    });

    expect(summary.stop).toBe("paused");
    // Not merely "sends nothing": the awaiting state must survive the pause,
    // or unpausing would leave the request permanently unannounced.
    expect(find).not.toHaveBeenCalled();
    expect(updateOne).not.toHaveBeenCalled();
    expect(dispatch.dispatchPush).not.toHaveBeenCalled();
    expect(dispatch.notifySubscribers).not.toHaveBeenCalled();
  });
});

describe("scheduled registration", () => {
  /**
   * `app.ts` connects to MongoDB and listens at module scope, so it is read as
   * text like the other startup-wiring assertions in this repository.
   */
  const appSource = readFileSync(
    new URL("../app.ts", import.meta.url),
    "utf8"
  );

  it("is registered from app.ts exactly once", () => {
    expect(
      appSource.match(/scheduleEligibilityNotificationSweep\(\{/g)
    ).toHaveLength(1);
  });

  it("is not gated on CRON_ENABLED", () => {
    // `CRON_ENABLED` guards the expired-request cleanup backup to TTL
    // deletion. This job is not a backup for anything: without it, a future
    // Later request is never notified about at all.
    const registration = appSource.indexOf(
      "scheduleEligibilityNotificationSweep({"
    );
    const cleanupBlockEnd = appSource.indexOf("[cron] disabled");

    expect(cleanupBlockEnd).toBeGreaterThan(-1);
    expect(registration).toBeGreaterThan(cleanupBlockEnd);
  });

  it("stays outside the hourly digest block", () => {
    // The digest's own source-text assertions slice app.ts between its cron
    // expression and the next one; a job registered inside that slice would
    // silently become part of what they pin.
    const digestStart = appSource.indexOf('scheduleAppJob("5 * * * *"');
    const digestEnd = appSource.indexOf('scheduleAppJob("0 3 * * *"', digestStart);
    const registration = appSource.indexOf(
      "scheduleEligibilityNotificationSweep({"
    );

    expect(digestStart).toBeGreaterThan(-1);
    expect(digestEnd).toBeGreaterThan(digestStart);
    expect(registration).toBeGreaterThan(digestEnd);
  });

  it("checks eligibility every minute", () => {
    expect(ELIGIBILITY_SWEEP_CRON).toBe("* * * * *");
  });

  it("hands the scheduler the total entry point", () => {
    const schedule = vi
      .spyOn(cron, "schedule")
      .mockImplementation(() => undefined as never);

    scheduleEligibilityNotificationSweep({ enabled: true });

    expect(schedule).toHaveBeenCalledWith(
      ELIGIBILITY_SWEEP_CRON,
      expect.any(Function),
      { noOverlap: true }
    );
  });
});

describe("the scheduled entry point", () => {
  it("contains a rejected sweep instead of leaving an unhandled rejection", async () => {
    find.mockImplementation(() => {
      throw new Error("selection exploded");
    });

    await expect(startEligibilityNotificationSweep()).resolves.toBeUndefined();
  });

  it("returns a promise that keeps the scheduler from overlapping a running sweep", async () => {
    await expect(startEligibilityNotificationSweep()).resolves.toBeUndefined();
  });
});
