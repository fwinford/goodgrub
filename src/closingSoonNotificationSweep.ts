import { registerScheduledJob } from "./scheduledJobs.js";
import { isReviewRuntime } from "./externalProviders.js";
import { Request as MealRequest, type IRequest } from "../models/db.js";
import {
  dispatchHelperClosingSoonPush,
} from "./helperClosingSoonPush.js";
import { helperPushInitiation } from "./helperNewRequestPush.js";
import type { HelperNotificationInitiation } from "./helperNotificationInitiation.js";
import { isPublicActionsPaused, logPausedSkip } from "./publicActionsPause.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import {
  buildNotificationGenerationFilter,
  notificationGenerationOf,
} from "./requestRevision.js";

/**
 * W4-N1 Increment B — the T-15 unclaimed closing-soon discovery sweep.
 *
 * Deliberately a second, independent cron job rather than a second concern
 * folded into `src/eligibilityNotificationSweep.ts`. That module's whole
 * surface and extensive correctness commentary are about one thing — "the
 * request became helper-eligible, start its one initial notification" — and
 * this is a different event ("the request is about to stop being eligible,
 * send its one closing-soon notification") with its own one-shot latch
 * (`closingSoonNotification`, independent of `helperNotification`). Folding
 * the two into one function would conflate two one-shot guarantees that must
 * never be allowed to interact.
 *
 * Push-only: there is no closing-soon email in the accepted contract, so this
 * sweep has one channel, not two, and the "both channels agree" rule the
 * eligibility sweep needs does not apply here.
 */
export const CLOSING_SOON_SWEEP_CRON = "* * * * *";

/** The accepted window: at most 15 minutes before authoritative expiration. */
export const CLOSING_SOON_WINDOW_MS = 15 * 60 * 1000;

export const MAXIMUM_CLOSING_SOON_REQUESTS_PER_SWEEP = 50;

export interface ClosingSoonSweepDependencies {
  now: () => Date;
  isPaused: () => boolean;
  dispatchPush: (request: IRequest) => Promise<HelperNotificationInitiation>;
  maximumRequests: number;
}

const defaultDependencies: ClosingSoonSweepDependencies = {
  now: () => new Date(),
  isPaused: () => isPublicActionsPaused(),
  dispatchPush: async (request) =>
    helperPushInitiation(await dispatchHelperClosingSoonPush(request)),
  maximumRequests: MAXIMUM_CLOSING_SOON_REQUESTS_PER_SWEEP,
};

export type ClosingSoonSweepStop =
  | "completed"
  | "paused"
  | "overlapping"
  | "selection-failed";

export interface ClosingSoonSweepSummary {
  stop: ClosingSoonSweepStop;
  candidates: number;
  initiated: number;
  deferred: number;
}

function emptySummary(stop: ClosingSoonSweepStop): ClosingSoonSweepSummary {
  return { stop, candidates: 0, initiated: 0, deferred: 0 };
}

function errorLabel(error: unknown): string {
  return error instanceof Error ? error.constructor.name : "UnknownError";
}

/**
 * Requests within 15 minutes of authoritative expiration, still effectively
 * available (open or a lapsed claim reopened to advertisable — the same
 * shared availability filter every other advertising path applies), and not
 * yet sent their one closing-soon chance. `closingSoonNotification` absent
 * reads as "awaiting," the same legacy allowance `helperNotification` uses —
 * every request, old or new, gets exactly one chance, never zero and never
 * two.
 */
function buildClosingSoonCandidateFilter(now: Date) {
  const windowEnd = new Date(now.getTime() + CLOSING_SOON_WINDOW_MS);
  return {
    $and: [
      buildEffectiveAvailabilityFilter(now),
      { expiresAt: { $lte: windowEnd } },
      {
        $or: [
          { closingSoonNotification: "awaiting" },
          { closingSoonNotification: { $exists: false } },
        ],
      },
    ],
  };
}

/**
 * The conditional transition into the initiated state, exactly mirroring
 * `recordInitiated` in `src/eligibilityNotificationSweep.ts`: conditional so
 * a concurrent sweep in another process cannot double-initiate, and fenced
 * by the notification generation the dispatch actually ran for, so a
 * reschedule mid-dispatch cannot have this run complete a chance that was
 * never performed for the new deadline.
 */
async function recordClosingSoonInitiated(
  requestId: unknown,
  expectedGeneration: number
): Promise<void> {
  await MealRequest.updateOne(
    {
      $and: [
        { _id: requestId, closingSoonNotification: { $ne: "initiated" } },
        buildNotificationGenerationFilter(expectedGeneration),
      ],
    },
    { $set: { closingSoonNotification: "initiated" } }
  ).exec();
}

async function initiate(
  request: IRequest,
  dependencies: ClosingSoonSweepDependencies,
  summary: ClosingSoonSweepSummary
): Promise<void> {
  const requestId = String(request._id);

  let result: HelperNotificationInitiation;
  try {
    result = await dependencies.dispatchPush(request);
  } catch (error) {
    console.error(
      `[closing-soon] push dispatch failed for request ${requestId}`,
      { error: errorLabel(error) }
    );
    result = "retryable";
  }

  if (result !== "processed") {
    summary.deferred += 1;
    console.log(
      `[closing-soon] request ${requestId} stays awaiting its closing-soon chance`,
      { result }
    );
    return;
  }

  try {
    await recordClosingSoonInitiated(
      request._id,
      notificationGenerationOf(
        request as unknown as { notificationGeneration?: number | null }
      )
    );
    summary.initiated += 1;
  } catch (error) {
    summary.deferred += 1;
    console.error(
      `[closing-soon] could not record closing-soon initiation for request ${requestId}`,
      { error: errorLabel(error) }
    );
  }
}

let running = false;

/** The awaitable sweep. Directly testable, and directly callable. */
export async function runClosingSoonNotificationSweep(
  overrides: Partial<ClosingSoonSweepDependencies> = {}
): Promise<ClosingSoonSweepSummary> {
  const dependencies = { ...defaultDependencies, ...overrides };

  if (isReviewRuntime() || dependencies.isPaused()) {
    logPausedSkip("closing-soon helper notification");
    return emptySummary("paused");
  }

  if (running) {
    return emptySummary("overlapping");
  }
  running = true;

  try {
    const now = dependencies.now();

    let candidates: IRequest[];
    try {
      candidates = await MealRequest.find(
        buildClosingSoonCandidateFilter(now),
        "+notificationGeneration +contentRevision"
      )
        .sort({ expiresAt: 1 })
        .limit(dependencies.maximumRequests)
        .exec();
    } catch (error) {
      console.error("[closing-soon] could not select closing-soon candidates", {
        error: errorLabel(error),
      });
      return emptySummary("selection-failed");
    }

    const summary: ClosingSoonSweepSummary = {
      ...emptySummary("completed"),
      candidates: candidates.length,
    };

    for (const request of candidates) {
      await initiate(request, dependencies, summary);
    }

    if (summary.candidates) {
      console.log(
        `[closing-soon] initiated ${summary.initiated} of ${summary.candidates} closing-soon notifications`
      );
    }

    return summary;
  } finally {
    running = false;
  }
}

/**
 * The scheduler-facing entry point, and a **total** function: never throws,
 * returns nothing a `node-cron` callback would need to await — matching
 * `startEligibilityNotificationSweep`.
 */
export function startClosingSoonNotificationSweep(): Promise<void> {
  try {
    return runClosingSoonNotificationSweep()
      .then(() => undefined)
      .catch((error: unknown) => {
        console.error("[closing-soon] sweep failed", { error: errorLabel(error) });
      });
  } catch (error) {
    console.error("[closing-soon] sweep could not start", {
      error: errorLabel(error),
    });
    return Promise.resolve();
  }
}

/**
 * Registered from `app.ts`, alongside the eligibility sweep. Every minute,
 * for the same reason: this is how often the T-15 condition is checked, not
 * a delivery SLA.
 */
export function scheduleClosingSoonNotificationSweep(options: {
  enabled?: boolean;
  isReady?: () => boolean;
} = {}): void {
  registerScheduledJob(
    CLOSING_SOON_SWEEP_CRON,
    startClosingSoonNotificationSweep,
    options
  );
}
