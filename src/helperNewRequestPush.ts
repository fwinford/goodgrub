import {
  Installation,
  PushDelivery,
  Request as MealRequest,
  type IRequest,
} from "../models/db.js";
import {
  apnsOriginForEnvironment,
  isApnsEnvironment,
  readApnsConfiguration,
  type ApnsConfiguration,
  type ApnsEnvironment,
} from "./apnsConfig.js";
import {
  openApnsConnection,
  type ApnsConnection,
  type ApnsOutcome,
} from "./apnsClient.js";
import { apnsProviderTokenSource } from "./apnsProviderToken.js";
import type { HelperNotificationInitiation } from "./helperNotificationInitiation.js";
import {
  buildHelperNewRequestHeaders,
  buildHelperNewRequestPayload,
  type HelperPushRequest,
} from "./helperPushPayload.js";
import { isPublicActionsPaused, logPausedSkip } from "./publicActionsPause.js";
import { isReviewRuntime } from "./externalProviders.js";
import { readCurrentForDispatch, type DispatchRequest } from "./requestDispatchGuard.js";
import { notificationGenerationOf } from "./requestRevision.js";
import { selectEligiblePushInstallations } from "./pushEligibility.js";

/**
 * Helper new-request push delivery (Week 3 Day 6 Slice 6D).
 *
 * Every push-enabled installation is submitted for on every new eligible
 * request: no round-robin selection, no per-installation frequency cap, and no
 * provider-wide budget in V1. Delivery is best effort — an APNs `200` means
 * APNs accepted the submission and nothing more — and there is no retry, so a
 * transient failure loses that one notification permanently.
 *
 * Dispatch runs detached, after the `201` has been sent. The bounds below
 * limit this detached work's own lifetime; they never bound the audience and
 * they cannot delay the requester's response, which is already gone.
 */
export const HELPER_NEW_REQUEST_PURPOSE = "helper-new-request";

export const MAXIMUM_CONCURRENT_SUBMISSIONS = 8;
export const SUBMISSION_TIMEOUT_MS = 10_000;
export const DISPATCH_DEADLINE_MS = 20_000;
/** The duplicate guard outlives every plausible second dispatch, then expires. */
export const PUSH_DELIVERY_RETENTION_MS = 24 * 60 * 60 * 1000;

export interface HelperNewRequestPushDependencies {
  now: () => Date;
  isPaused: () => boolean;
  readConfiguration: () => ApnsConfiguration;
  providerToken: () => string;
  openConnection: (origin: string) => ApnsConnection;
  maximumConcurrentSubmissions: number;
  submissionTimeoutMs: number;
  dispatchDeadlineMs: number;
}

const defaultDependencies: HelperNewRequestPushDependencies = {
  now: () => new Date(),
  isPaused: () => isPublicActionsPaused(),
  readConfiguration: () => readApnsConfiguration(),
  providerToken: () => apnsProviderTokenSource.current(),
  openConnection: (origin) => openApnsConnection(origin),
  maximumConcurrentSubmissions: MAXIMUM_CONCURRENT_SUBMISSIONS,
  submissionTimeoutMs: SUBMISSION_TIMEOUT_MS,
  dispatchDeadlineMs: DISPATCH_DEADLINE_MS,
};

/** Why a dispatch stopped, or that it ran to completion. */
export type HelperPushDispatchStop =
  | "completed"
  | "paused"
  | "unavailable"
  | "configuration"
  | "no-eligible-installations"
  | "provider-auth"
  | "deadline";

export interface HelperPushDispatchSummary {
  stop: HelperPushDispatchStop;
  /** Installations selected as eligible before per-installation guards. */
  eligible: number;
  /** Eligible rows skipped for an unusable stored environment. */
  skippedEnvironment: number;
  /** `PushDelivery` rows this dispatch owns. */
  claimed: number;
  /** Triples another dispatch already owned. */
  duplicate: number;
  accepted: number;
  rejected: number;
  failed: number;
  /**
   * Claims that could not be written for a reason other than "another dispatch
   * already owns this triple". Counted apart from `failed`, which is provider
   * truth: this installation was never submitted for and nothing about it was
   * recorded, so it is the one outcome here that leaves initiation undecided
   * (`src/helperNotificationInitiation.ts`). It adds no provider retry — the
   * eligibility sweep may look at the request again, and any installation that
   * *was* claimed is skipped as a duplicate.
   */
  claimFailed: number;
  /**
   * W4-R5: claims released unsent because, between the dispatch's start and
   * this installation's provider handoff, the request was rescheduled,
   * withdrawn, claimed or expired. Counted apart from every provider outcome:
   * nothing was handed to a provider and nothing about it was decided.
   */
  invalidated: number;
  /** Installations whose exact token/environment retirement matched a row. */
  retired: number;
  /**
   * Outcome or retirement writes that could not be persisted. Counted apart
   * from the provider outcomes above, which stay exactly what APNs said: a
   * database failure after submission is a bookkeeping loss, never a
   * reinterpretation of the provider's answer.
   */
  persistenceFailed: number;
}

function emptySummary(stop: HelperPushDispatchStop): HelperPushDispatchSummary {
  return {
    stop,
    eligible: 0,
    skippedEnvironment: 0,
    claimed: 0,
    duplicate: 0,
    accepted: 0,
    rejected: 0,
    failed: 0,
    claimFailed: 0,
    invalidated: 0,
    retired: 0,
    persistenceFailed: 0,
  };
}

/**
 * Whether this dispatch reached its existing terminal outcome for the request,
 * or did no initiation work at all. Initiation bookkeeping for the eligibility
 * sweep only: it introduces no provider retry and reinterprets no provider
 * answer.
 *
 * `paused` and `unavailable` are the two stops that return before anything is
 * claimed or submitted. A `claimFailed` installation is the same situation at
 * one installation's scale.
 *
 * Everything else stays exactly as terminal as it already was:
 * `no-eligible-installations` is a complete dispatch to nobody,
 * `configuration` is a per-deployment or per-request payload defect that
 * repeating cannot fix, and `provider-auth` and `deadline` are the accepted
 * abandonments — re-running them is the retry V1 deliberately does not have.
 */
export function helperPushInitiation(
  summary: HelperPushDispatchSummary
): HelperNotificationInitiation {
  if (summary.stop === "paused" || summary.stop === "unavailable") {
    return "retryable";
  }
  // An invalidated claim is an undecided initiation for the *new* generation,
  // exactly like an unwritten claim: the sweep must look again.
  return summary.claimFailed > 0 || summary.invalidated > 0
    ? "retryable"
    : "processed";
}

function isDuplicateKeyError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === 11000
  );
}

/**
 * Nothing derived from a caught value is logged beyond its constructor name.
 * A provider or driver error can carry headers, tokens, connection URLs, and
 * request bodies, so the raw object never reaches a log line.
 */
function errorLabel(error: unknown): string {
  return error instanceof Error ? error.constructor.name : "UnknownError";
}

interface EligibleInstallation {
  id: unknown;
  apnsToken: string;
  apnsEnvironment: ApnsEnvironment;
  origin: string;
}

/**
 * Eligibility: push on, a usable token, and not invalidated. `invalidatedAt`
 * is filtered explicitly — every write path already pairs invalidation with
 * `pushEnabled: false`, so this is a redundant guard rather than a new state.
 *
 * `apnsToken` is `select: false` on the schema, so it is requested explicitly.
 * A query that forgets this silently selects zero deliverable installations.
 *
 * The environment is checked in code rather than in the filter so an
 * unrecognized stored value can be skipped *and logged* instead of vanishing
 * from the result set. It is never defaulted: guessing would submit a sandbox
 * token to production, or the reverse, and produce a spurious token rejection.
 *
 * `Subscriber`, `SendLog`, and the `notify_cursor`
 * `System` row belong to the email channel and are neither read nor written.
 */
async function selectEligibleInstallations(
  requestId: unknown,
  requesterParticipantId: unknown
): Promise<{ installations: EligibleInstallation[]; skippedEnvironment: number }> {
  const rows = await selectEligiblePushInstallations({
    excludeParticipantId:
      requesterParticipantId == null ? null : String(requesterParticipantId),
  });

  const installations: EligibleInstallation[] = [];
  let skippedEnvironment = 0;

  for (const row of rows) {
    const origin = apnsOriginForEnvironment(row.apnsEnvironment);
    if (!isApnsEnvironment(row.apnsEnvironment) || origin === null) {
      skippedEnvironment += 1;
      console.log(
        `[push] installation ${String(row._id)} has no usable APNs environment, skipping for request ${String(requestId)}`
      );
      continue;
    }
    installations.push({
      id: row._id,
      apnsToken: row.apnsToken as string,
      apnsEnvironment: row.apnsEnvironment,
      origin,
    });
  }

  return { installations, skippedEnvironment };
}

/**
 * One atomic conditional update, matching the invalidation boundary accepted
 * in Slice 6A. The exact token and the exact environment are part of the
 * filter, not just the installation, so a delayed rejection for a token that
 * has since been replaced cannot disable the newer registration. Matching zero
 * documents is the expected outcome for a stale response, not an error.
 */
async function retireRejectedToken(
  installation: EligibleInstallation,
  now: Date
): Promise<boolean> {
  const result = await Installation.updateOne(
    {
      _id: installation.id,
      apnsToken: installation.apnsToken,
      apnsEnvironment: installation.apnsEnvironment,
      pushEnabled: true,
    },
    {
      $set: { pushEnabled: false, invalidatedAt: now, updatedAt: now },
    }
  ).exec();

  return (result.modifiedCount ?? 0) > 0;
}

/**
 * Exported so W4-N1 Increment B's closing-soon and pickup-confirmation
 * dispatchers (`src/helperClosingSoonPush.ts`,
 * `src/helperPickupConfirmedPush.ts`) reuse this exact bounded-concurrency
 * runner instead of a second copy. Purely additive — no existing caller's
 * behavior changes.
 */
export async function runBounded(
  count: number,
  limit: number,
  worker: (index: number) => Promise<void>
): Promise<void> {
  let next = 0;
  const runners = Array.from(
    { length: Math.max(1, Math.min(limit, count)) },
    async () => {
      while (next < count) {
        const index = next;
        next += 1;
        await worker(index);
      }
    }
  );
  await Promise.all(runners);
}

/**
 * The awaitable dispatcher. Directly testable, and directly callable — which
 * is why the pause guard lives here rather than only on the create route.
 */
export async function dispatchHelperNewRequestPush(
  request: IRequest,
  overrides: Partial<HelperNewRequestPushDependencies> = {}
): Promise<HelperPushDispatchSummary> {
  const dependencies = { ...defaultDependencies, ...overrides };
  const requestId = String(request._id);

  // Before any delivery record is written, for the same reason
  // `notifySubscribersForRequest` carries its own guard: this function can be
  // invoked directly, and a suppressed notification must leave no row behind.
  if (isReviewRuntime() || dependencies.isPaused()) {
    logPausedSkip(`helper new-request push for request ${requestId}`);
    return emptySummary("paused");
  }

  const now = dependencies.now();

  // Creation and notification are separate side effects. A request claimed
  // between the two must not be advertised.
  //
  // W4-R5: nor one the requester has rescheduled or withdrawn since this
  // dispatch was started for its notification generation. The same guard runs
  // again before every delivery claim and immediately before every provider
  // handoff below.
  const expectedGeneration = notificationGenerationOf(
    request as unknown as { notificationGeneration?: number | null }
  );
  const stillAvailable = await readCurrentForDispatch(
    request._id,
    expectedGeneration,
    now
  );
  if (!stillAvailable) {
    console.log(
      `[push] request ${requestId} is no longer available, skipping helper push`
    );
    return emptySummary("unavailable");
  }

  let configuration: ApnsConfiguration;
  let headers: Record<string, string>;
  let payload: string;
  // The content revision the cached payload was built from. Rebuilt only if an
  // ordinary edit lands mid-dispatch, so the banner a helper reads is the
  // request's current text, never a stale copy (W4-R5).
  let payloadRevision: number | null | undefined;
  try {
    configuration = dependencies.readConfiguration();
    // Built once: everything but `:path` is identical for every installation.
    // Building before the first claim means a configuration or payload defect
    // cannot leave a claimed row that no submission will ever follow.
    headers = buildHelperNewRequestHeaders(
      request as unknown as HelperPushRequest,
      { topic: configuration.bundleId }
    );
    payload = JSON.stringify(
      buildHelperNewRequestPayload(request as unknown as HelperPushRequest)
    );
    payloadRevision = (request as DispatchRequest).contentRevision;
  } catch (error) {
    console.error(
      `[push] helper new-request push is not configured for request ${requestId}`,
      { error: errorLabel(error) }
    );
    return emptySummary("configuration");
  }

  const { installations, skippedEnvironment } = await selectEligibleInstallations(
    request._id,
    stillAvailable.requesterParticipantId
  );
  if (installations.length === 0) {
    return {
      ...emptySummary("no-eligible-installations"),
      skippedEnvironment,
    };
  }

  const summary: HelperPushDispatchSummary = {
    ...emptySummary("completed"),
    eligible: installations.length,
    skippedEnvironment,
  };

  const deleteAt = new Date(
    new Date(request.expiresAt ?? now).getTime() + PUSH_DELIVERY_RETENTION_MS
  );
  // Measured from wall-clock elapsed time rather than from the dispatch's
  // captured instant: this bounds how long the detached work may run, not how
  // old the request is.
  const deadline = Date.now() + dependencies.dispatchDeadlineMs;
  const connections = new Map<string, ApnsConnection>();
  let abandoned = false;

  function connectionFor(origin: string): ApnsConnection {
    const existing = connections.get(origin);
    if (existing) return existing;
    const opened = dependencies.openConnection(origin);
    connections.set(origin, opened);
    return opened;
  }

  /**
   * Contained per installation, on purpose.
   *
   * The provider outcome is already decided by the time this runs, so a failed
   * write is a bookkeeping loss for one installation and nothing more: it must
   * not reinterpret what APNs said, and it must not stop the installations
   * behind it in the fan-out from being submitted for. The claim row stays
   * `claimed`, which still blocks a second submission — the deduplication
   * guard is the row's existence, not its status — and V1 adds no retry.
   */
  async function record(
    claimId: unknown,
    outcome: ApnsOutcome,
    status: "accepted" | "rejected" | "failed"
  ): Promise<void> {
    try {
      await PushDelivery.updateOne(
        { _id: claimId },
        {
          $set: {
            status,
            submittedAt: new Date(),
            ...(outcome.apnsId ? { apnsId: outcome.apnsId } : {}),
          },
        }
      ).exec();
    } catch (error) {
      summary.persistenceFailed += 1;
      console.error(
        `[push] could not record a helper push outcome for request ${requestId}`,
        { error: errorLabel(error), status }
      );
    }
  }

  /**
   * Contained for the same reason, with one addition: a retirement that could
   * not be written is not a retirement. The count only ever reflects a
   * conditional update that actually matched, so a write failure can never be
   * mistaken for a disabled installation.
   */
  async function retire(installation: EligibleInstallation): Promise<void> {
    try {
      if (await retireRejectedToken(installation, new Date())) {
        summary.retired += 1;
      }
    } catch (error) {
      summary.persistenceFailed += 1;
      console.error(
        `[push] could not retire a rejected token for request ${requestId}`,
        { error: errorLabel(error) }
      );
    }
  }

  async function submitFor(installation: EligibleInstallation): Promise<void> {
    if (abandoned) return;

    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      abandoned = true;
      summary.stop = "deadline";
      console.error(
        `[push] helper new-request dispatch deadline reached for request ${requestId}; abandoning the remaining submissions`
      );
      return;
    }

    // W4-R5 guard 1 of 3: before any delivery claim is written. A request that
    // was rescheduled, withdrawn, claimed or expired since this dispatch began
    // stops the rest of the fan-out; nothing has been claimed for it.
    if (!(await readCurrentForDispatch(request._id, expectedGeneration, new Date()))) {
      abandoned = true;
      summary.stop = "unavailable";
      summary.invalidated += 1;
      return;
    }

    // Claim before submission. A row in any state owns this triple, so a
    // duplicate-key error means another dispatch already submitted (or
    // terminally failed) for it and this one must not submit again.
    let claimId: unknown;
    try {
      const claim = await PushDelivery.create({
        requestId: request._id,
        installationId: installation.id,
        purpose: HELPER_NEW_REQUEST_PURPOSE,
        status: "claimed",
        deleteAt,
      });
      claimId = claim._id;
      summary.claimed += 1;
    } catch (error) {
      if (isDuplicateKeyError(error)) {
        summary.duplicate += 1;
        return;
      }
      // Not a provider outcome: nothing was submitted and nothing was
      // recorded, so this is counted apart from `failed` rather than being
      // reported as a delivery failure.
      summary.claimFailed += 1;
      console.error(
        `[push] could not claim a helper push delivery for request ${requestId}`,
        { error: errorLabel(error) }
      );
      return;
    }

    // W4-R5 guards 2 and 3 of 3: after the claim exists and immediately before
    // provider handoff. The fresh document is also the content submitted.
    const current = await readCurrentForDispatch(
      request._id,
      expectedGeneration,
      new Date()
    );
    if (!current) {
      // Definitely unsent: nothing was handed to a provider. The claim just
      // written is released, so this installation stays eligible for the
      // generation that replaced this one, with no duplicate possible.
      try {
        await PushDelivery.deleteOne({ _id: claimId, status: "claimed" }).exec();
        summary.claimed -= 1;
      } catch (error) {
        summary.persistenceFailed += 1;
        console.error(
          `[push] could not release an unsent helper push claim for request ${requestId}`,
          { error: errorLabel(error) }
        );
      }
      abandoned = true;
      summary.stop = "unavailable";
      summary.invalidated += 1;
      return;
    }
    if (current.contentRevision !== payloadRevision) {
      try {
        headers = buildHelperNewRequestHeaders(
          current as unknown as HelperPushRequest,
          { topic: configuration.bundleId }
        );
        payload = JSON.stringify(
          buildHelperNewRequestPayload(current as unknown as HelperPushRequest)
        );
        payloadRevision = current.contentRevision;
      } catch (error) {
        // Could not describe the edited request: keep the content this
        // dispatch already holds rather than send nothing. It is still the
        // right request; only its wording may be one revision old.
        console.error(
          `[push] could not rebuild the helper push payload for request ${requestId}`,
          { error: errorLabel(error) }
        );
      }
    }

    const eligibleNow = await selectEligiblePushInstallations({
      installationId: installation.id,
      excludeParticipantId: current.requesterParticipantId,
    });
    if (!eligibleNow.some((row) =>
      row.apnsToken === installation.apnsToken &&
      row.apnsEnvironment === installation.apnsEnvironment
    )) {
      try {
        await PushDelivery.deleteOne({ _id: claimId, status: "claimed" }).exec();
        summary.claimed -= 1;
      } catch (error) {
        summary.persistenceFailed += 1;
        console.error(`[push] could not release an ineligible helper push claim for request ${requestId}`,
          { error: errorLabel(error) });
      }
      summary.invalidated += 1;
      return;
    }

    let outcome: ApnsOutcome;
    try {
      outcome = await connectionFor(installation.origin).submit(
        {
          deviceToken: installation.apnsToken,
          headers: {
            ...headers,
            authorization: `bearer ${dependencies.providerToken()}`,
          },
          payload,
        },
        Math.min(dependencies.submissionTimeoutMs, Math.max(1, remaining))
      );
    } catch (error) {
      outcome = { classification: "transient", reason: errorLabel(error) };
    }

    if (outcome.classification === "accepted") {
      // "APNs accepted the submission" — not delivered, displayed, or read.
      summary.accepted += 1;
      await record(claimId, outcome, "accepted");
      return;
    }

    if (outcome.classification === "token-rejected") {
      summary.rejected += 1;
      await record(claimId, outcome, "rejected");
      await retire(installation);
      console.log(
        `[push] APNs rejected the token for installation ${String(installation.id)} on request ${requestId}`,
        { reason: outcome.reason, status: outcome.status }
      );
      return;
    }

    summary.failed += 1;
    await record(claimId, outcome, "failed");

    if (outcome.classification === "provider-auth") {
      // Nothing else in this dispatch can succeed with the same provider
      // token, so repeating the call would only produce identical refusals.
      abandoned = true;
      summary.stop = "provider-auth";
      console.error(
        `[push] APNs refused the provider configuration for request ${requestId}; abandoning the remaining submissions`,
        { reason: outcome.reason, status: outcome.status }
      );
      return;
    }

    // Transient and non-token configuration failures alike: recorded, never
    // retried in V1, and never allowed to retire an installation's token.
    console.log(
      `[push] helper push submission failed for installation ${String(installation.id)} on request ${requestId}`,
      { classification: outcome.classification, reason: outcome.reason, status: outcome.status }
    );
  }

  try {
    await runBounded(
      installations.length,
      dependencies.maximumConcurrentSubmissions,
      (index) => submitFor(installations[index])
    );
  } finally {
    for (const connection of connections.values()) {
      connection.close();
    }
  }

  return summary;
}

/**
 * The route-facing entry point, and a **total** function: an ordinary
 * non-`async` function that never throws and returns nothing the route can
 * await.
 *
 * Both guards are load-bearing. The attached `.catch` contains every
 * asynchronous rejection — a provider timeout, an HTTP/2 failure, a database
 * error during selection. The synchronous `try`/`catch` contains a setup error
 * thrown before any promise exists.
 *
 * This matters because `createRequest` calls it *after* the `201` has been
 * sent, from inside a `try` whose `catch` answers `500
 * REQUEST_CREATION_FAILED`. An escaping throw would enter that `catch` and
 * attempt a second response on a request whose headers are already flushed,
 * turning a successfully created request into a logged `ERR_HTTP_HEADERS_SENT`
 * and an inconsistency for any client that read the first response.
 */
export function startHelperNewRequestPush(request: IRequest): void {
  // Resolved once, inside the guard: the rejection handler must not touch the
  // request again, or a document that cannot describe itself would throw from
  // the very handler meant to contain it.
  let requestId = "unknown";
  try {
    requestId = String(request._id);
    void dispatchHelperNewRequestPush(request).catch((error: unknown) => {
      console.error(
        `[push] Helper new-request dispatch failed for request ${requestId}`,
        { error: errorLabel(error) }
      );
    });
  } catch (error) {
    console.error(
      `[push] Helper new-request dispatch could not start for request ${requestId}`,
      { error: errorLabel(error) }
    );
  }
}
