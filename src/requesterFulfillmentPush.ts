import {
  Installation,
  PushDelivery,
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
import {
  buildRequesterFulfillmentHeaders,
  buildRequesterFulfillmentPayload,
  type RequesterFulfillmentPushRequest,
} from "./requesterFulfillmentPushPayload.js";
import { isPublicActionsPaused, logPausedSkip } from "./publicActionsPause.js";
import { isReviewRuntime } from "./externalProviders.js";
import { selectEligiblePushInstallations } from "./pushEligibility.js";

/**
 * Requester fulfillment push (Week 3 Day 6 Slice 6E).
 *
 * Only the one installation a request was created from — its stored
 * `installationId` — is ever eligible. There is no fallback or heuristic
 * recipient, and dispatch starts only after placement has durably committed.
 * Delivery is best-effort and independent of placement success and of the
 * existing fulfillment email: a `200` from APNs means only that APNs accepted
 * the submission, never delivery, display, opening, or reading.
 *
 * Mirrors `helperNewRequestPush.ts`'s shape (pause guard before any delivery
 * record, claim-before-submit dedup on the shared `PushDelivery` collection,
 * the same provider-response classification and exact-token retirement) at
 * an audience of at most one installation, so the concurrency pool and
 * dispatch-deadline machinery that bounds a many-installation fan-out has no
 * work to do here and is not reproduced.
 */
export const REQUESTER_FULFILLMENT_PURPOSE = "requester-fulfillment";

export const REQUESTER_FULFILLMENT_SUBMISSION_TIMEOUT_MS = 10_000;
/** The duplicate guard outlives every plausible second dispatch, then expires. */
export const REQUESTER_FULFILLMENT_RETENTION_MS = 24 * 60 * 60 * 1000;

export interface RequesterFulfillmentPushDependencies {
  now: () => Date;
  isPaused: () => boolean;
  readConfiguration: () => ApnsConfiguration;
  providerToken: () => string;
  openConnection: (origin: string) => ApnsConnection;
  submissionTimeoutMs: number;
}

const defaultDependencies: RequesterFulfillmentPushDependencies = {
  now: () => new Date(),
  isPaused: () => isPublicActionsPaused(),
  readConfiguration: () => readApnsConfiguration(),
  providerToken: () => apnsProviderTokenSource.current(),
  openConnection: (origin) => openApnsConnection(origin),
  submissionTimeoutMs: REQUESTER_FULFILLMENT_SUBMISSION_TIMEOUT_MS,
};

/** Why a dispatch stopped, or that it ran to completion. */
export type RequesterFulfillmentDispatchStop =
  | "completed"
  | "paused"
  | "no-association"
  | "no-eligible-installation"
  | "configuration";

export interface RequesterFulfillmentDispatchSummary {
  stop: RequesterFulfillmentDispatchStop;
  /** 1 when the request's associated installation is currently push-eligible. */
  eligible: 0 | 1;
  /** The `PushDelivery` row this dispatch owns. */
  claimed: 0 | 1;
  /** 1 when another dispatch already owned this triple. */
  duplicate: 0 | 1;
  accepted: 0 | 1;
  rejected: 0 | 1;
  failed: 0 | 1;
  /** 1 when the eligible installation's exact token/environment was retired. */
  retired: 0 | 1;
  /**
   * An outcome or retirement write that could not be persisted. Counted apart
   * from the provider outcomes above, which stay exactly what APNs said: a
   * database failure after submission is a bookkeeping loss, never a
   * reinterpretation of the provider's answer.
   */
  persistenceFailed: 0 | 1;
}

function emptySummary(
  stop: RequesterFulfillmentDispatchStop
): RequesterFulfillmentDispatchSummary {
  return {
    stop,
    eligible: 0,
    claimed: 0,
    duplicate: 0,
    accepted: 0,
    rejected: 0,
    failed: 0,
    retired: 0,
    persistenceFailed: 0,
  };
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
 * The single candidate: the request's own stored `installationId`, and no
 * other. `apnsToken` is `select: false` on the schema, so it is requested
 * explicitly — a query that forgets this silently selects nothing
 * deliverable. The environment is validated in code, never defaulted:
 * guessing would submit a sandbox token to production or the reverse.
 */
async function selectEligibleInstallation(
  installationId: unknown,
  request: IRequest
): Promise<EligibleInstallation | null> {
  const [row] = await selectEligiblePushInstallations({
    installationId,
    requiredParticipantId: request.requesterParticipantId,
    counterpartParticipantId: request.helperParticipantId,
  });

  if (!row) return null;

  const origin = apnsOriginForEnvironment(row.apnsEnvironment);
  if (!isApnsEnvironment(row.apnsEnvironment) || origin === null) {
    console.log(
      `[push] installation ${String(row._id)} has no usable APNs environment, skipping requester fulfillment push`
    );
    return null;
  }

  return {
    id: row._id,
    apnsToken: row.apnsToken as string,
    apnsEnvironment: row.apnsEnvironment,
    origin,
  };
}

/**
 * One atomic conditional update, matching the invalidation boundary shared
 * with the helper new-request dispatcher: the exact token and environment
 * are part of the filter, not just the installation, so a delayed rejection
 * for a token that has since been replaced cannot disable the newer
 * registration.
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
 * The awaitable dispatcher. Directly testable, and directly callable — which
 * is why the pause guard lives here rather than only on the fulfillment
 * route.
 */
export async function dispatchRequesterFulfillmentPush(
  request: IRequest,
  overrides: Partial<RequesterFulfillmentPushDependencies> = {}
): Promise<RequesterFulfillmentDispatchSummary> {
  const dependencies = { ...defaultDependencies, ...overrides };
  const requestId = String(request._id);

  // Before any delivery record is written, for the same reason the helper
  // dispatcher and `notifySubscribersForRequest` carry their own guards: this
  // function can be invoked directly, and a suppressed notification must
  // leave no row behind.
  if (isReviewRuntime() || dependencies.isPaused()) {
    logPausedSkip(`requester fulfillment push for request ${requestId}`);
    return emptySummary("paused");
  }

  const installationId = request.installationId;
  if (!installationId) {
    // Web-created, or created without a usable installation credential.
    // There is no fallback or heuristic recipient.
    return emptySummary("no-association");
  }

  const now = dependencies.now();

  let configuration: ApnsConfiguration;
  let headers: Record<string, string>;
  let payload: string;
  try {
    configuration = dependencies.readConfiguration();
    headers = buildRequesterFulfillmentHeaders(
      request as unknown as RequesterFulfillmentPushRequest,
      { topic: configuration.bundleId },
      now
    );
    payload = JSON.stringify(
      buildRequesterFulfillmentPayload(
        request as unknown as RequesterFulfillmentPushRequest
      )
    );
  } catch (error) {
    console.error(
      `[push] requester fulfillment push is not configured for request ${requestId}`,
      { error: errorLabel(error) }
    );
    return emptySummary("configuration");
  }

  const installation = await selectEligibleInstallation(installationId, request);
  if (!installation) {
    return emptySummary("no-eligible-installation");
  }

  const summary: RequesterFulfillmentDispatchSummary = {
    ...emptySummary("completed"),
    eligible: 1,
  };

  const deleteAt = new Date(now.getTime() + REQUESTER_FULFILLMENT_RETENTION_MS);

  // Claim before submission. A row in any state — including a prior terminal
  // failure — owns this triple: V1 has no push retry path, so a duplicate
  // claim means another dispatch already submitted (or terminally failed)
  // for it and this one must not submit again.
  let claimId: unknown;
  try {
    const claim = await PushDelivery.create({
      requestId: request._id,
      installationId: installation.id,
      purpose: REQUESTER_FULFILLMENT_PURPOSE,
      status: "claimed",
      deleteAt,
    });
    claimId = claim._id;
    summary.claimed = 1;
  } catch (error) {
    if (isDuplicateKeyError(error)) {
      summary.duplicate = 1;
      return summary;
    }
    summary.failed = 1;
    console.error(
      `[push] could not claim a requester fulfillment push delivery for request ${requestId}`,
      { error: errorLabel(error) }
    );
    return summary;
  }

  async function record(
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
      summary.persistenceFailed = 1;
      console.error(
        `[push] could not record a requester fulfillment push outcome for request ${requestId}`,
        { error: errorLabel(error), status }
      );
    }
  }

  const eligibleNow = await selectEligibleInstallation(installationId, request);
  if (!eligibleNow || eligibleNow.apnsToken !== installation.apnsToken ||
      eligibleNow.origin !== installation.origin) {
    try {
      await PushDelivery.deleteOne({ _id: claimId, status: "claimed" }).exec();
      summary.claimed = 0;
    } catch (error) {
      summary.persistenceFailed = 1;
      console.error(`[push] could not release an ineligible requester push claim for request ${requestId}`,
        { error: errorLabel(error) });
    }
    summary.stop = "no-eligible-installation";
    summary.eligible = 0;
    return summary;
  }

  const connection = dependencies.openConnection(installation.origin);
  let outcome: ApnsOutcome;
  try {
    outcome = await connection.submit(
      {
        deviceToken: installation.apnsToken,
        headers: {
          ...headers,
          authorization: `bearer ${dependencies.providerToken()}`,
        },
        payload,
      },
      dependencies.submissionTimeoutMs
    );
  } catch (error) {
    outcome = { classification: "transient", reason: errorLabel(error) };
  } finally {
    connection.close();
  }

  if (outcome.classification === "accepted") {
    // "APNs accepted the submission" — not delivered, displayed, or read.
    summary.accepted = 1;
    await record(outcome, "accepted");
    return summary;
  }

  if (outcome.classification === "token-rejected") {
    summary.rejected = 1;
    await record(outcome, "rejected");
    try {
      if (await retireRejectedToken(installation, new Date())) {
        summary.retired = 1;
      }
    } catch (error) {
      summary.persistenceFailed = 1;
      console.error(
        `[push] could not retire a rejected token for request ${requestId}`,
        { error: errorLabel(error) }
      );
    }
    console.log(
      `[push] APNs rejected the token for installation ${String(installation.id)} on request ${requestId}`,
      { reason: outcome.reason, status: outcome.status }
    );
    return summary;
  }

  summary.failed = 1;
  await record(outcome, "failed");
  console.log(
    `[push] requester fulfillment push submission failed for installation ${String(installation.id)} on request ${requestId}`,
    { classification: outcome.classification, reason: outcome.reason, status: outcome.status }
  );
  return summary;
}

/**
 * The route-facing entry point, and a **total** function: an ordinary
 * non-`async` function that never throws and returns nothing the route can
 * await. Mirrors `startHelperNewRequestPush` exactly, for the same reason:
 * `fulfillRequest` calls it *after* its response has been sent, so an
 * escaping throw or unhandled rejection would attempt a second response on a
 * request whose headers are already flushed.
 */
export function startRequesterFulfillmentPush(request: IRequest): void {
  let requestId = "unknown";
  try {
    requestId = String(request._id);
    void dispatchRequesterFulfillmentPush(request).catch((error: unknown) => {
      console.error(
        `[push] Requester fulfillment dispatch failed for request ${requestId}`,
        { error: errorLabel(error) }
      );
    });
  } catch (error) {
    console.error(
      `[push] Requester fulfillment dispatch could not start for request ${requestId}`,
      { error: errorLabel(error) }
    );
  }
}
