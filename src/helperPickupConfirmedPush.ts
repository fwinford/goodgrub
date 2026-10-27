import {
  Installation,
  PushDelivery,
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
  buildHelperPickupConfirmedHeaders,
  buildHelperPickupConfirmedPayload,
} from "./helperPickupConfirmedPushPayload.js";
import { isPublicActionsPaused, logPausedSkip } from "./publicActionsPause.js";
import { isReviewRuntime } from "./externalProviders.js";
import { selectEligiblePushInstallations } from "./pushEligibility.js";
import {
  PUSH_DELIVERY_RETENTION_MS,
  runBounded,
  type HelperPushDispatchSummary,
} from "./helperNewRequestPush.js";

/**
 * D-N1-5 (W4-N1 Increment B) — the helper pickup-confirmation push.
 *
 * Deliberately the simplest of the three new Increment B dispatchers. The
 * other two re-check Request *availability* mid-fan-out because an
 * advertised request can be claimed, withdrawn, rescheduled, or expire while
 * they run. Nothing here advertises anything: this push is triggered by —
 * and only by — R3's one atomic `requesterPickupConfirmedAt` write already
 * having committed (`src/placedOrderRoutes.ts`), which is itself terminal
 * and idempotent. There is no "still available" question to ask, no
 * notification generation to fence against, and no payload content that
 * depends on live request state (the copy is fixed, like the
 * requester-fulfillment push). What *is* kept, because they are genuinely
 * independent concerns, is: a defensive eligibility re-check immediately
 * before provider handoff (suspension/fencing/authority-version can change
 * between selection and submission), the exact same `PushDelivery`
 * claim-before-submit dedup identity other N1 pushes use, and the exact
 * same APNs client/connection/provider-token primitives.
 */
export const HELPER_PICKUP_CONFIRMED_PURPOSE = "requester-pickup-confirmed";

export const PICKUP_CONFIRMED_MAXIMUM_CONCURRENT_SUBMISSIONS = 8;
export const PICKUP_CONFIRMED_SUBMISSION_TIMEOUT_MS = 10_000;
export const PICKUP_CONFIRMED_DISPATCH_DEADLINE_MS = 20_000;

export interface HelperPickupConfirmedDispatchTarget {
  requestId: unknown;
  /** The participant recorded on the placed order as the one who helped. */
  helperParticipantId: unknown;
  /** Excluded from its own fan-out and used for the pair-fence check. */
  requesterParticipantId: unknown;
}

export interface HelperPickupConfirmedPushDependencies {
  now: () => Date;
  isPaused: () => boolean;
  readConfiguration: () => ApnsConfiguration;
  providerToken: () => string;
  openConnection: (origin: string) => ApnsConnection;
  maximumConcurrentSubmissions: number;
  submissionTimeoutMs: number;
  dispatchDeadlineMs: number;
}

const defaultDependencies: HelperPickupConfirmedPushDependencies = {
  now: () => new Date(),
  isPaused: () => isPublicActionsPaused(),
  readConfiguration: () => readApnsConfiguration(),
  providerToken: () => apnsProviderTokenSource.current(),
  openConnection: (origin) => openApnsConnection(origin),
  maximumConcurrentSubmissions: PICKUP_CONFIRMED_MAXIMUM_CONCURRENT_SUBMISSIONS,
  submissionTimeoutMs: PICKUP_CONFIRMED_SUBMISSION_TIMEOUT_MS,
  dispatchDeadlineMs: PICKUP_CONFIRMED_DISPATCH_DEADLINE_MS,
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

/**
 * Targets exactly the recorded helper's eligible Installations, via the
 * shared N1 eligibility predicate — `requiredParticipantId` fences to that
 * one participant (no requester self-notification is possible by
 * construction: the predicate target is the helper, never the requester),
 * and `counterpartParticipantId` applies the pair fence against the
 * requester. Suspension and authority-version fencing are inherited from
 * the predicate, not reimplemented.
 */
async function selectEligibleInstallations(
  target: HelperPickupConfirmedDispatchTarget
): Promise<{ installations: EligibleInstallation[]; skippedEnvironment: number }> {
  if (target.helperParticipantId == null) {
    return { installations: [], skippedEnvironment: 0 };
  }

  const rows = await selectEligiblePushInstallations({
    requiredParticipantId: String(target.helperParticipantId),
    counterpartParticipantId:
      target.requesterParticipantId == null
        ? null
        : String(target.requesterParticipantId),
  });

  const installations: EligibleInstallation[] = [];
  let skippedEnvironment = 0;

  for (const row of rows) {
    const origin = apnsOriginForEnvironment(row.apnsEnvironment);
    if (!isApnsEnvironment(row.apnsEnvironment) || origin === null) {
      skippedEnvironment += 1;
      console.log(
        `[push] installation ${String(row._id)} has no usable APNs environment, skipping pickup-confirmed push for request ${String(target.requestId)}`
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
 * The awaitable dispatcher. Directly testable, and directly callable from
 * `src/placedOrderRoutes.ts` immediately after the atomic pickup-confirmation
 * write commits.
 */
export async function dispatchHelperPickupConfirmedPush(
  target: HelperPickupConfirmedDispatchTarget,
  overrides: Partial<HelperPickupConfirmedPushDependencies> = {}
): Promise<HelperPushDispatchSummary> {
  const dependencies = { ...defaultDependencies, ...overrides };
  const requestId = String(target.requestId);

  if (isReviewRuntime() || dependencies.isPaused()) {
    logPausedSkip(`helper pickup-confirmed push for request ${requestId}`);
    return emptySummary("paused");
  }

  const now = dependencies.now();

  let configuration: ApnsConfiguration;
  let headers: Record<string, string>;
  let payload: string;
  try {
    configuration = dependencies.readConfiguration();
    headers = buildHelperPickupConfirmedHeaders(
      { _id: target.requestId },
      { topic: configuration.bundleId },
      now
    );
    payload = JSON.stringify(
      buildHelperPickupConfirmedPayload({ _id: target.requestId })
    );
  } catch (error) {
    console.error(
      `[push] pickup-confirmed push is not configured for request ${requestId}`,
      { error: errorLabel(error) }
    );
    return emptySummary("configuration");
  }

  const { installations, skippedEnvironment } = await selectEligibleInstallations(target);
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

  const deleteAt = new Date(now.getTime() + PUSH_DELIVERY_RETENTION_MS);
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
        `[push] could not record a pickup-confirmed push outcome for request ${requestId}`,
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
        `[push] pickup-confirmed dispatch deadline reached for request ${requestId}; abandoning the remaining submissions`
      );
      return;
    }

    let claimId: unknown;
    try {
      const claim = await PushDelivery.create({
        requestId: target.requestId,
        installationId: installation.id,
        purpose: HELPER_PICKUP_CONFIRMED_PURPOSE,
        status: "claimed",
        deleteAt,
      });
      claimId = claim._id;
      summary.claimed += 1;
    } catch (error) {
      if (isDuplicateKeyError(error)) {
        // Replay/concurrent confirmation attempt: another dispatch already
        // claimed this exact (request, installation) triple, so this attempt
        // yields no second logical notification.
        summary.duplicate += 1;
        return;
      }
      summary.claimFailed += 1;
      console.error(
        `[push] could not claim a pickup-confirmed push delivery for request ${requestId}`,
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
          `[push] could not release an unsent pickup-confirmed push claim for request ${requestId}`,
          { error: errorLabel(error) }
        );
      }
    }

    // Defensive re-check immediately before provider handoff: suspension,
    // fencing, or authority-version can change between selection and
    // submission even in a short fan-out.
    let eligibleNow;
    try {
      eligibleNow = await selectEligiblePushInstallations({
        installationId: installation.id,
        requiredParticipantId:
          target.helperParticipantId == null ? null : String(target.helperParticipantId),
        counterpartParticipantId:
          target.requesterParticipantId == null
            ? null
            : String(target.requesterParticipantId),
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
      summary.accepted += 1;
      await record(claimId, outcome, "accepted");
      return;
    }

    if (outcome.classification === "token-rejected") {
      summary.rejected += 1;
      await record(claimId, outcome, "rejected");
      await retire(installation);
      console.log(
        `[push] APNs rejected the token for installation ${String(installation.id)} on pickup-confirmed request ${requestId}`,
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
        `[push] APNs refused the provider configuration for pickup-confirmed request ${requestId}; abandoning the remaining submissions`,
        { reason: outcome.reason, status: outcome.status }
      );
      return;
    }

    console.log(
      `[push] pickup-confirmed push submission failed for installation ${String(installation.id)} on request ${requestId}`,
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
 * The route-facing entry point, and a **total** function: never throws,
 * returns nothing the route needs to await — matching
 * `startHelperNewRequestPush`. `src/placedOrderRoutes.ts` calls this *after*
 * its own response has already been sent, so delivery success or failure can
 * never affect pickup correctness: the authoritative transition is already
 * committed by the time this runs.
 */
export function startHelperPickupConfirmedPush(
  target: HelperPickupConfirmedDispatchTarget
): void {
  try {
    dispatchHelperPickupConfirmedPush(target).catch((error: unknown) => {
      console.error("[push] pickup-confirmed dispatch failed", {
        error: errorLabel(error),
      });
    });
  } catch (error) {
    console.error("[push] pickup-confirmed dispatch could not start", {
      error: errorLabel(error),
    });
  }
}
