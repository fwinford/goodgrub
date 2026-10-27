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
import {
  buildHelperClosingSoonPayload,
  buildHelperNewRequestHeaders,
  type HelperPushRequest,
} from "./helperPushPayload.js";
import { isPublicActionsPaused, logPausedSkip } from "./publicActionsPause.js";
import { isReviewRuntime } from "./externalProviders.js";
import { readCurrentForDispatch } from "./requestDispatchGuard.js";
import { notificationGenerationOf } from "./requestRevision.js";
import { selectEligiblePushInstallations } from "./pushEligibility.js";
import {
  runBounded,
  type HelperPushDispatchSummary,
} from "./helperNewRequestPush.js";

/**
 * W4-N1 Increment B — the one additional T-15 closing-soon discovery push.
 *
 * Deliberately modeled on `src/helperNewRequestPush.ts`'s dispatcher rather
 * than sharing its code: both target the same eligible-installation fan-out
 * and need the identical W4-R5 three-guard protection against a request
 * that is claimed, withdrawn, rescheduled or expired mid-dispatch, but they
 * are two independent one-shot notifications (the initial discovery push and
 * this one) with two independent dedup identities
 * (`PushDelivery.purpose`) and two independent persisted latches
 * (`helperNotification` vs. `closingSoonNotification`) — reusing the exact
 * dispatch loop of an already-accepted, independently reviewed HIGH-risk
 * module was judged riskier than this parallel module, which instead reuses
 * every real shared primitive: `selectEligiblePushInstallations`,
 * `readCurrentForDispatch`, the APNs client/configuration/provider-token
 * helpers, and `PushDelivery`'s own claim-before-submit index.
 *
 * `helperPushInitiation` from `helperNewRequestPush.ts` is reused unchanged
 * to classify this dispatcher's summary, because the summary shape and the
 * processed/retryable rule are identical.
 */
export const HELPER_CLOSING_SOON_PURPOSE = "helper-new-request-closing-soon";

export const CLOSING_SOON_MAXIMUM_CONCURRENT_SUBMISSIONS = 8;
export const CLOSING_SOON_SUBMISSION_TIMEOUT_MS = 10_000;
export const CLOSING_SOON_DISPATCH_DEADLINE_MS = 20_000;
export const CLOSING_SOON_PUSH_DELIVERY_RETENTION_MS = 24 * 60 * 60 * 1000;

export interface HelperClosingSoonPushDependencies {
  now: () => Date;
  isPaused: () => boolean;
  readConfiguration: () => ApnsConfiguration;
  providerToken: () => string;
  openConnection: (origin: string) => ApnsConnection;
  maximumConcurrentSubmissions: number;
  submissionTimeoutMs: number;
  dispatchDeadlineMs: number;
}

const defaultDependencies: HelperClosingSoonPushDependencies = {
  now: () => new Date(),
  isPaused: () => isPublicActionsPaused(),
  readConfiguration: () => readApnsConfiguration(),
  providerToken: () => apnsProviderTokenSource.current(),
  openConnection: (origin) => openApnsConnection(origin),
  maximumConcurrentSubmissions: CLOSING_SOON_MAXIMUM_CONCURRENT_SUBMISSIONS,
  submissionTimeoutMs: CLOSING_SOON_SUBMISSION_TIMEOUT_MS,
  dispatchDeadlineMs: CLOSING_SOON_DISPATCH_DEADLINE_MS,
};

function emptySummary(
  stop: HelperPushDispatchSummary["stop"]
): HelperPushDispatchSummary {
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

function isDuplicateKeyError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === 11000
  );
}

function errorLabel(error: unknown): string {
  return error instanceof Error ? error.constructor.name : "UnknownError";
}

interface EligibleInstallation {
  id: unknown;
  apnsToken: string;
  apnsEnvironment: ApnsEnvironment;
  origin: string;
}

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
        `[push] installation ${String(row._id)} has no usable APNs environment, skipping closing-soon push for request ${String(requestId)}`
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
 * The awaitable dispatcher. Directly testable, and directly callable by the
 * closing-soon sweep.
 */
export async function dispatchHelperClosingSoonPush(
  request: IRequest,
  overrides: Partial<HelperClosingSoonPushDependencies> = {}
): Promise<HelperPushDispatchSummary> {
  const dependencies = { ...defaultDependencies, ...overrides };
  const requestId = String(request._id);

  if (isReviewRuntime() || dependencies.isPaused()) {
    logPausedSkip(`helper closing-soon push for request ${requestId}`);
    return emptySummary("paused");
  }

  const now = dependencies.now();

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
      `[push] request ${requestId} is no longer available, skipping closing-soon push`
    );
    return emptySummary("unavailable");
  }

  let configuration: ApnsConfiguration;
  let headers: Record<string, string>;
  let payload: string;
  let payloadRevision: number | null | undefined;
  try {
    configuration = dependencies.readConfiguration();
    headers = buildHelperNewRequestHeaders(
      request as unknown as HelperPushRequest,
      { topic: configuration.bundleId }
    );
    payload = JSON.stringify(
      buildHelperClosingSoonPayload(request as unknown as HelperPushRequest)
    );
    payloadRevision = (request as { contentRevision?: number | null }).contentRevision;
  } catch (error) {
    console.error(
      `[push] closing-soon push is not configured for request ${requestId}`,
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
    new Date(request.expiresAt ?? now).getTime() +
      CLOSING_SOON_PUSH_DELIVERY_RETENTION_MS
  );
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
        `[push] could not record a closing-soon push outcome for request ${requestId}`,
        { error: errorLabel(error), status }
      );
    }
  }

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
        `[push] closing-soon dispatch deadline reached for request ${requestId}; abandoning the remaining submissions`
      );
      return;
    }

    if (!(await readCurrentForDispatch(request._id, expectedGeneration, new Date()))) {
      abandoned = true;
      summary.stop = "unavailable";
      summary.invalidated += 1;
      return;
    }

    let claimId: unknown;
    try {
      const claim = await PushDelivery.create({
        requestId: request._id,
        installationId: installation.id,
        purpose: HELPER_CLOSING_SOON_PURPOSE,
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
      summary.claimFailed += 1;
      console.error(
        `[push] could not claim a closing-soon push delivery for request ${requestId}`,
        { error: errorLabel(error) }
      );
      return;
    }

    async function releaseUnsubmittedClaim(): Promise<void> {
      try {
        await PushDelivery.deleteOne({ _id: claimId, status: "claimed" }).exec();
        summary.claimed -= 1;
      } catch (error) {
        summary.persistenceFailed += 1;
        console.error(
          `[push] could not release an unsent closing-soon push claim for request ${requestId}`,
          { error: errorLabel(error) }
        );
      }
    }

    let current;
    try {
      current = await readCurrentForDispatch(
        request._id,
        expectedGeneration,
        new Date()
      );
    } catch (error) {
      await releaseUnsubmittedClaim();
      throw error;
    }
    if (!current) {
      await releaseUnsubmittedClaim();
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
          buildHelperClosingSoonPayload(current as unknown as HelperPushRequest)
        );
        payloadRevision = current.contentRevision;
      } catch (error) {
        console.error(
          `[push] could not rebuild the closing-soon push payload for request ${requestId}`,
          { error: errorLabel(error) }
        );
      }
    }

    let eligibleNow;
    try {
      eligibleNow = await selectEligiblePushInstallations({
        installationId: installation.id,
        excludeParticipantId: current.requesterParticipantId,
      });
    } catch (error) {
      await releaseUnsubmittedClaim();
      throw error;
    }
    if (!eligibleNow.some((row) =>
      row.apnsToken === installation.apnsToken &&
      row.apnsEnvironment === installation.apnsEnvironment
    )) {
      await releaseUnsubmittedClaim();
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
        `[push] APNs rejected the token for installation ${String(installation.id)} on closing-soon request ${requestId}`,
        { reason: outcome.reason, status: outcome.status }
      );
      return;
    }

    summary.failed += 1;
    await record(claimId, outcome, "failed");

    if (outcome.classification === "provider-auth") {
      abandoned = true;
      summary.stop = "provider-auth";
      console.error(
        `[push] APNs refused the provider configuration for closing-soon request ${requestId}; abandoning the remaining submissions`,
        { reason: outcome.reason, status: outcome.status }
      );
      return;
    }

    console.log(
      `[push] closing-soon push submission failed for installation ${String(installation.id)} on request ${requestId}`,
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
