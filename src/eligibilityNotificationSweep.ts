import { registerScheduledJob } from "./scheduledJobs.js";
import { isReviewRuntime } from "./externalProviders.js";
import { Request as MealRequest, type IRequest } from "../models/db.js";
import {
  dispatchHelperNewRequestPush,
  helperPushInitiation,
} from "./helperNewRequestPush.js";
import {
  isInitiationProcessed,
  type HelperNotificationInitiation,
} from "./helperNotificationInitiation.js";
import { notifySubscribersForRequest } from "./notifySubscribers.js";
import { isPublicActionsPaused, logPausedSkip } from "./publicActionsPause.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import {
  buildNotificationGenerationFilter,
  notificationGenerationOf,
} from "./requestRevision.js";

/**
 * Eligibility-time helper-notification initiation (W3-N3).
 *
 * The product event that starts helper notification is **the request becoming
 * helper-eligible**. For an ASAP request that is its creation instant, and
 * `POST /api/request` already dispatches both channels there. For a future
 * Later request (W3-R1) it is `visibleFrom`, which can arrive hours later —
 * long after any creation-time lookback would still find the request. Nothing
 * else in the system watches for that instant, so without this sweep a Later
 * request is correctly withheld at creation and then permanently missed.
 *
 * This module adds no notification behavior of its own. It is discovery and
 * initiation only: it finds requests that have just become helper-eligible and
 * calls the same two dispatchers the create route calls, with the same
 * recipient eligibility, the same deduplication, the same provider
 * classification, and the same payloads.
 *
 * ## Why a periodic sweep of persisted state
 *
 * The alternative — an in-process timer armed at creation for each future Later
 * request — cannot survive a restart, and a restart between creation and
 * `visibleFrom` is exactly the case the contract requires not to lose. Durable
 * state plus a sweep is the smallest mechanism that is correct across restarts
 * without introducing a queue or a second worker process: the request row is
 * already durable, already TTL-bounded, and already carries `visibleFrom`.
 *
 * ## Why the state is marked after dispatch, not before
 *
 * Claim-before-work is the right shape when the work cannot be repeated safely.
 * Here it can: `SendLog`'s unique `(requestId, subscriberId)` claim and
 * `PushDelivery`'s unique `(requestId, installationId, purpose)` claim already
 * make a repeated dispatch a no-op per recipient, and both dispatchers were
 * written for concurrent dispatches of one request. Marking first would
 * therefore buy nothing and cost the one guarantee the contract asks for: a
 * process killed between the mark and the send would have permanently consumed
 * the request's only chance. Marking after means an interrupted run leaves the
 * request exactly as it found it, and the next sweep retries it — through the
 * existing per-recipient guards, never through a second submission path.
 *
 * ## Why "after dispatch" is not the same as "after the promise resolves"
 *
 * Both dispatchers can resolve perfectly normally having initiated nothing —
 * paused, the request no longer effectively available at the instant that
 * channel looked, or a delivery-ledger claim that could not be written. Reading
 * resolution as completion would consume the request's one initiation on work
 * that never happened, and a request that became eligible again afterwards
 * would be permanently undiscoverable. Each channel therefore reports
 * `"processed"` or `"retryable"` (`src/helperNotificationInitiation.ts`), and
 * the state moves only when both say `"processed"`. This adds no provider
 * retry: every existing terminal provider outcome stays terminal.
 */
export const ELIGIBILITY_SWEEP_CRON = "* * * * *";

/**
 * Requests initiated per run. A cap, not a lookback: a request stays selectable
 * until it is initiated or stops being available, so a run that hits this bound
 * defers the remainder to the next minute rather than dropping it. Ordering by
 * `visibleFrom` makes that deferral the fairest one available — whoever has
 * been eligible longest goes first.
 */
export const MAXIMUM_REQUESTS_PER_SWEEP = 50;

export interface EligibilitySweepDependencies {
  now: () => Date;
  isPaused: () => boolean;
  notifySubscribers: (request: IRequest) => Promise<HelperNotificationInitiation>;
  dispatchPush: (request: IRequest) => Promise<HelperNotificationInitiation>;
  maximumRequests: number;
}

const defaultDependencies: EligibilitySweepDependencies = {
  now: () => new Date(),
  isPaused: () => isPublicActionsPaused(),
  notifySubscribers: (request) => notifySubscribersForRequest(request),
  dispatchPush: async (request) =>
    helperPushInitiation(await dispatchHelperNewRequestPush(request)),
  maximumRequests: MAXIMUM_REQUESTS_PER_SWEEP,
};

/** Why a sweep stopped, or that it ran to completion. */
export type EligibilitySweepStop =
  | "completed"
  | "paused"
  | "overlapping"
  | "selection-failed";

export interface EligibilitySweepSummary {
  stop: EligibilitySweepStop;
  /** Requests selected as newly helper-eligible and not yet initiated. */
  candidates: number;
  /** Requests whose state this run moved to `initiated`. */
  initiated: number;
  /**
   * Requests left awaiting: a channel threw, a channel resolved without
   * reaching a terminal initiation outcome, or the transition could not be
   * written. Each stays selectable for a later run.
   */
  deferred: number;
}

function emptySummary(stop: EligibilitySweepStop): EligibilitySweepSummary {
  return { stop, candidates: 0, initiated: 0, deferred: 0 };
}

/**
 * Nothing derived from a caught value is logged beyond its constructor name,
 * matching the helper-push dispatcher: a driver or provider error can carry
 * connection URLs, credentials, and request bodies.
 */
function errorLabel(error: unknown): string {
  return error instanceof Error ? error.constructor.name : "UnknownError";
}

const AWAITING_ELIGIBILITY = "awaiting-eligibility";

/**
 * The transition population: a Later request created after committed W3-R1 but
 * before this slice was deployed. It has correct `visibleFrom`/`expiresAt`
 * semantics and no `helperNotification` at all, so exact-match selection would
 * never find it and it would be withheld at creation and then never announced.
 *
 * Three clauses, and each one is load-bearing:
 *
 * - `helperNotification: {$exists: false}` — every request created since this
 *   slice carries the field, so this can only ever match a pre-deployment row.
 *   The branch retires itself: `deleteAt` removes the last of these within
 *   hours, after which it matches nothing.
 * - `windowStart: {$type: "date"}` — the request was created through a
 *   scheduled shape. An ASAP request has no `windowStart`.
 * - `visibleFrom > createdAt` — helper eligibility began *after* creation,
 *   which is the actual definition of what this slice exists to catch. A row
 *   with no `visibleFrom` at all — a genuinely old pre-W3-R1 row that cannot
 *   prove it is a future Later request — fails this comparison and is left
 *   alone, which is why this is not a legacy migration. An ASAP request fails
 *   it too: its `visibleFrom` is the handler's `now`, captured before the
 *   write, so `createdAt` is always the later of the two.
 *
 * Anything this branch does find is protected by the same per-recipient
 * `SendLog` and `PushDelivery` claims as everything else, so a transition row
 * that somehow already had a channel initiated cannot be notified twice.
 *
 * The partial index only covers the awaiting state, so this branch is a scan.
 * That is acceptable for a population that is bounded by one deployment and
 * expires within hours of it.
 */
const PRE_N3_LATER_REQUEST = {
  helperNotification: { $exists: false },
  windowStart: { $type: "date" },
  $expr: { $gt: ["$visibleFrom", "$createdAt"] },
};

/**
 * Requests that are helper-eligible **now** and whose helper notification has
 * not been initiated — either because creation handed them here, or because
 * they predate this field entirely and are identifiably future Later requests.
 *
 * `createdAt` bounds nothing. That is the whole point of the slice: a Later
 * request created this morning and eligible this evening must still be found,
 * and any creation-age bound is exactly what would lose it. It appears only
 * inside the transition branch's `visibleFrom > createdAt` comparison, which
 * is a statement about the request's shape, not about its age.
 *
 * The availability filter is the same shared one the list, detail, claim, and
 * both dispatchers apply, so a request that expired, was placed, or is holding
 * a live claim while it waited is simply never selected — it leaves the
 * awaiting state only by TTL deletion, never by a stale new-request alert.
 */
function buildEligibleForInitiationFilter(now: Date) {
  return {
    // `$and`, because the availability filter carries a top-level `$or` of its
    // own and the ownership clause carries another; merging them as sibling
    // keys would silently drop one.
    $and: [
      buildEffectiveAvailabilityFilter(now),
      {
        $or: [
          { helperNotification: AWAITING_ELIGIBILITY },
          PRE_N3_LATER_REQUEST,
        ],
      },
    ],
  };
}

/**
 * The conditional transition into the initiated state. Conditional rather than
 * a read-then-write, so a concurrent sweep in another process cannot reopen a
 * request this one has finished with.
 *
 * `$ne: "initiated"` rather than an equality on the awaiting state, because
 * both selectable populations have to be able to leave: a request creation
 * handed here, and a transition row that carries no state at all yet.
 */
async function recordInitiated(
  requestId: unknown,
  expectedGeneration: number
): Promise<void> {
  // W4-R5: conditional on the generation the dispatches ran for. If the
  // requester rescheduled while they ran, the generation moved on, this matches
  // nothing, and the request stays awaiting for the new generation — initiation
  // is never completed for a generation it was not performed for.
  await MealRequest.updateOne(
    {
      $and: [
        { _id: requestId, helperNotification: { $ne: "initiated" } },
        buildNotificationGenerationFilter(expectedGeneration),
      ],
    },
    { $set: { helperNotification: "initiated" } }
  ).exec();
}

/**
 * Runs one channel and reports whether it terminally processed this request's
 * initiation. A channel that throws has decided nothing at all, so it is
 * reported exactly like one that resolved `"retryable"`.
 */
async function runChannel(
  label: string,
  requestId: string,
  channel: () => Promise<HelperNotificationInitiation>
): Promise<HelperNotificationInitiation> {
  try {
    return await channel();
  } catch (error) {
    console.error(
      `[eligibility] helper ${label} dispatch failed for request ${requestId}`,
      { error: errorLabel(error) }
    );
    return "retryable";
  }
}

/**
 * One request's initiation. Both channels are attempted independently — a push
 * failure must not withhold the email, and neither must stop the request behind
 * this one — and the state moves only when both report a terminally processed
 * initiation, so anything less leaves the request selectable for the next run.
 */
async function initiate(
  request: IRequest,
  dependencies: EligibilitySweepDependencies,
  summary: EligibilitySweepSummary
): Promise<void> {
  const requestId = String(request._id);

  // Same order as `POST /api/request`, for no reason beyond keeping the two
  // initiation paths readable as the one behavior they are. Both run whatever
  // the other reports: one channel being retryable must not withhold the
  // other, and a later run finds the processed one a per-recipient no-op.
  const push = await runChannel("push", requestId, () =>
    dependencies.dispatchPush(request)
  );
  const email = await runChannel("email", requestId, () =>
    dependencies.notifySubscribers(request)
  );

  if (!isInitiationProcessed(push, email)) {
    summary.deferred += 1;
    console.log(
      `[eligibility] request ${requestId} stays awaiting eligibility-time initiation`,
      { push, email }
    );
    return;
  }

  try {
    await recordInitiated(
      request._id,
      notificationGenerationOf(
        request as unknown as { notificationGeneration?: number | null }
      )
    );
    summary.initiated += 1;
  } catch (error) {
    // The dispatches already happened, so this is a bookkeeping loss rather
    // than a lost notification: the next run will dispatch again and every
    // recipient will be skipped by the existing per-recipient guards.
    summary.deferred += 1;
    console.error(
      `[eligibility] could not record helper-notification initiation for request ${requestId}`,
      { error: errorLabel(error) }
    );
  }
}

/**
 * Guards one process against overlapping itself. Cross-process overlap is not
 * guarded here and does not need to be — the per-recipient claims handle it —
 * but a run that outlives its own interval would otherwise pile up against
 * itself for no benefit.
 */
let running = false;

/** The awaitable sweep. Directly testable, and directly callable. */
export async function runEligibilityNotificationSweep(
  overrides: Partial<EligibilitySweepDependencies> = {}
): Promise<EligibilitySweepSummary> {
  const dependencies = { ...defaultDependencies, ...overrides };

  // Before selection, and before any state moves. A paused deployment must
  // not consume a request's awaiting state: doing so would silence its alert
  // permanently, which is the opposite of what pausing means.
  if (isReviewRuntime() || dependencies.isPaused()) {
    logPausedSkip("eligibility-time helper notification");
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
      // The generation is private (`select: false`) and is the authority the
      // dispatches below are started under and the initiation is recorded
      // against (W4-R5), so it is selected explicitly.
      candidates = await MealRequest.find(
        buildEligibleForInitiationFilter(now),
        "+notificationGeneration +contentRevision"
      )
        .sort({ visibleFrom: 1 })
        .limit(dependencies.maximumRequests)
        .exec();
    } catch (error) {
      console.error("[eligibility] could not select newly eligible requests", {
        error: errorLabel(error),
      });
      return emptySummary("selection-failed");
    }

    const summary: EligibilitySweepSummary = {
      ...emptySummary("completed"),
      candidates: candidates.length,
    };

    // Sequential on purpose. Each request's own fan-out is already the
    // parallel part, and running several unbounded fan-outs at once is how a
    // background job starts competing with request traffic for connections.
    for (const request of candidates) {
      await initiate(request, dependencies, summary);
    }

    if (summary.candidates) {
      console.log(
        `[eligibility] initiated helper notification for ${summary.initiated} of ${summary.candidates} newly eligible requests`
      );
    }

    return summary;
  } finally {
    running = false;
  }
}

/**
 * The scheduler-facing entry point, and a **total** function: an ordinary
 * non-`async` function that never throws and returns nothing to await. Mirrors
 * `startHelperNewRequestPush`, for the same reason — a rejection escaping a
 * `node-cron` callback is an unhandled rejection in the server process.
 */
export function startEligibilityNotificationSweep(): Promise<void> {
  try {
    return runEligibilityNotificationSweep().then(() => undefined).catch((error: unknown) => {
      console.error("[eligibility] sweep failed", { error: errorLabel(error) });
    });
  } catch (error) {
    console.error("[eligibility] sweep could not start", {
      error: errorLabel(error),
    });
    return Promise.resolve();
  }
}

/**
 * Registered from `app.ts` at module scope, alongside the other scheduled jobs.
 *
 * Every minute, because `visibleFrom` is chosen to the minute and the accepted
 * contract adds no product latency allowance: the notification is meant to
 * happen when the request becomes eligible, and the next minute boundary is the
 * closest a scheduled job gets to that without polling. This is not a delivery
 * SLA — nothing here proves provider delivery — only how often eligibility is
 * checked.
 */
export function scheduleEligibilityNotificationSweep(options: {
  enabled?: boolean;
  isReady?: () => boolean;
} = {}): void {
  registerScheduledJob(
    ELIGIBILITY_SWEEP_CRON,
    startEligibilityNotificationSweep,
    options
  );
}
