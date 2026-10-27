import { Subscriber, SendLog, IRequest, ISubscriber, Request as MealRequest } from "../models/db.js";
import { sendNewRequestAlert } from "./emailHelpers.js";
import type { HelperNotificationInitiation } from "./helperNotificationInitiation.js";
import { isPublicActionsPaused, logPausedSkip } from "./publicActionsPause.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import { readCurrentForDispatch } from "./requestDispatchGuard.js";
import { notificationGenerationOf } from "./requestRevision.js";
import { isReviewRuntime } from "./externalProviders.js";
import { isRequestAlertEmailDeliveryActive } from "./requestAlertEmailDelivery.js";

// Notify every confirmed, non-bounced subscriber about a new eligible request.
//
// The return value is initiation bookkeeping for the eligibility sweep
// (`src/helperNotificationInitiation.ts`), not a delivery result. Callers that
// dispatch at creation time ignore it, and it changes nothing about who is
// emailed or what a provider outcome means.
export async function notifySubscribersForRequest(
  request: IRequest
): Promise<HelperNotificationInitiation> {
  if (!isRequestAlertEmailDeliveryActive()) return "processed";
  // Guarded here rather than only at the create route because this function is
  // also called directly (scripts/trigger-notify.ts). Returning before the
  // SendLog claim means a skipped alert leaves no delivery record behind.
  if (isReviewRuntime() || isPublicActionsPaused()) {
    logPausedSkip(`real-time alert for request ${request._id}`);
    return "retryable";
  }

  console.log(`[notify] called for request ${request._id} vendor=${request.vendor} pickupWindow=${request.pickupWindowText}`);

  // Creation and notification are separate side effects. Re-check effective
  // availability so a fast claim cannot be advertised after it was reserved.
  //
  // W4-R5: and so a request the requester has since rescheduled or withdrawn
  // is not advertised under the generation this dispatch was started for. The
  // same guard runs again before every delivery claim and immediately before
  // every provider handoff below.
  const expectedGeneration = notificationGenerationOf(
    request as unknown as { notificationGeneration?: number | null }
  );
  const isStillAvailable = await readCurrentForDispatch(
    request._id,
    expectedGeneration,
    new Date()
  );
  if (!isStillAvailable) {
    console.log(
      `[notify] request ${request._id} is no longer available, skipping`
    );
    return "retryable";
  }

  // Deduplication is per recipient and nowhere else. The unique
  // `(requestId, subscriberId)` claim below decides, one subscriber at a time,
  // whether that specific address has already been processed for this request —
  // by an earlier real-time attempt, by a concurrent one, or by the hourly
  // digest, which writes the same rows.
  //
  // There is deliberately no request-level short-circuit. A single successful
  // send does not mean the request is done: the accepted policy is that every
  // confirmed, non-bounced subscriber is considered for every eligible request,
  // and an interrupted fan-out that reached one address must be able to resume
  // for the rest. Asking "has anyone been sent this?" answered a different
  // question and silenced everybody behind the first success.

  // V1 real-time policy: every confirmed, non-bounced subscriber is notified
  // for every eligible request — no cooldown, no daily cap, no round-robin
  // selection. `dailyCount`/`lastSentAt` are still written below because the
  // hourly digest still reads them; only the real-time eligibility filter
  // stops checking them.
  const eligible = await Subscriber.find({
    $and: [
      { status: "confirmed" },
      { bounced: false },
    ]
  }).sort({ _id: 1 });

  console.log(`[notify] eligible subscribers found: ${eligible.length} for request ${request._id}`);

  if (!eligible.length) {
    console.log(`[notify] no eligible subscribers for request ${request._id}, exiting`);
    // Terminally processed, not retryable: the accepted lifecycle notifies
    // whoever is eligible when a request becomes eligible. It does not hold the
    // request open until somebody subscribes.
    return "processed";
  }

  let notified = 0;
  // A claim that could not be written for any reason other than "already
  // claimed" means this subscriber was neither notified nor recorded, so this
  // request's initiation has not been decided. Tracked only to answer that
  // question for the eligibility sweep; it changes nothing about the loop,
  // which still isolates every subscriber from every other one.
  let claimWriteFailed = false;
  // The request stopped being the one this dispatch was started for (edited
  // timing, withdrawn, claimed, expired). Nothing is decided for it, so the
  // sweep must see it as undecided rather than as processed.
  let invalidated = false;
  for (const sub of eligible) {
    // W4-R5 guard 1 of 3: before any delivery claim is written.
    if (!(await readCurrentForDispatch(request._id, expectedGeneration, new Date()))) {
      invalidated = true;
      break;
    }

    console.log(`[notify] processing subscriber ${String(sub._id)} for request ${request._id}`);
    // Atomic claim: try to insert a pending SendLog to claim this (request,subscriber).
    // If another process already claimed it, skip to avoid duplicate sends.
    try {
      await SendLog.create({
        subscriberId: sub._id,
        requestId: request._id,
        sentAt: new Date(),
        status: "fail", // placeholder - will be updated after send
      });
      console.log(`[notify] SendLog claim created for request ${request._id} subscriber ${String(sub._id)}`);
    } catch (claimErr: unknown) {
      // Duplicate key means another process has claimed this subscriber for this request.
      const claimMsg = String((claimErr as any)?.message || '');
      if (claimMsg.includes('E11000') || (claimErr as any)?.code === 11000) {
        console.log(`[notify] SendLog claim already exists for request ${request._id} subscriber ${String(sub._id)}, skipping`);
        continue; // skip this subscriber
      }
      // Unexpected error creating claim - log and skip
      claimWriteFailed = true;
      console.error("[notify] delivery claim could not be created");
      continue;
    }

    // W4-R5 guards 2 and 3 of 3: after the claim exists and immediately before
    // the provider handoff. The current document is also the content sent, so
    // an ordinary edit committed since this dispatch began is what the
    // subscriber reads, never a stale copy.
    const current = await readCurrentForDispatch(
      request._id,
      expectedGeneration,
      new Date()
    );
    if (!current) {
      // Definitely unsent: the claim was written a moment ago and nothing has
      // been handed to a provider. Releasing exactly that placeholder (the
      // `error` field is only ever set by a real send attempt) keeps this
      // recipient eligible for the generation that replaced this one, without
      // consuming the request's eligibility or enabling a duplicate.
      await SendLog.deleteOne({
        requestId: request._id,
        subscriberId: sub._id,
        status: "fail",
        error: { $exists: false },
      });
      invalidated = true;
      break;
    }

    try {
      await sendNewRequestAlert(sub, current as unknown as IRequest);
      console.log(`[notify] sendNewRequestAlert accepted for ${String(sub._id)} request ${request._id}`);
      await Subscriber.updateOne(
        { _id: sub._id },
        {
          $set: { lastSentAt: new Date() },
          $inc: { dailyCount: 1 },
        }
      );
      await SendLog.updateOne(
        { requestId: request._id, subscriberId: sub._id },
        { $set: { status: 'sent', sentAt: new Date(), error: undefined } }
      );
      notified++;
    } catch (err: unknown) {
      const errText = err instanceof Error ? err.message : String(err);
      console.error(`[notify] email submission failed for ${String(sub._id)} request ${request._id}`);
      await SendLog.updateOne(
        { requestId: request._id, subscriberId: sub._id },
        { $set: { status: 'fail', sentAt: new Date(), error: errText } }
      );
      if (errText.match(/invalid|bounce|not found|recipient/i)) {
        await Subscriber.updateOne({ _id: sub._id }, { $set: { bounced: true } });
      }
    }
  }

  if (notified) {
    console.log(`[notify] sent to ${notified} of ${eligible.length} eligible subscribers for request ${request._id}`);
  }

  // Every send outcome above is terminal and stays terminal: a delivered alert
  // is not repeated, and a failed one keeps its `fail` row, which the unique
  // claim turns into a skip next time. Only an unwritten claim leaves anything
  // undecided.
  return claimWriteFailed || invalidated ? "retryable" : "processed";
}

// Notify a single subscriber about recent un-notified requests (used after double-opt-in)
export async function notifySubscriberAboutRecentRequests(subscriber: ISubscriber) {
  if (!isRequestAlertEmailDeliveryActive()) return;
  if (!subscriber) return;

  if (isReviewRuntime() || isPublicActionsPaused()) {
    logPausedSkip(
      `recent-request alerts for subscriber ${String(subscriber._id)}`
    );
    return;
  }

  console.log(`[notify:on-confirm] called for subscriber ${String(subscriber._id)}`);
  try {
    if (subscriber.status !== 'confirmed') {
      console.log(`[notify:on-confirm] subscriber ${String(subscriber._id)} not confirmed, skipping`);
      return;
    }
    if (subscriber.bounced) {
      console.log(`[notify:on-confirm] subscriber ${String(subscriber._id)} is bounced, skipping`);
      return;
    }

    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    if ((subscriber.dailyCount || 0) >= 4) {
      console.log(`[notify:on-confirm] subscriber ${String(subscriber._id)} reached daily cap, skipping`);
      return;
    }
    if (subscriber.lastSentAt && subscriber.lastSentAt > oneHourAgo) {
      console.log(`[notify:on-confirm] subscriber ${String(subscriber._id)} sent within last hour, skipping`);
      return;
    }

    // Find effectively available requests created within the last 24 hours.
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const availabilityNow = new Date();
    const recentRequests = await MealRequest.find({
      createdAt: { $gte: since },
      ...buildEffectiveAvailabilityFilter(availabilityNow),
    }).sort({ createdAt: -1 }).limit(50).lean();
    if (!recentRequests.length) {
      console.log(`[notify:on-confirm] no recent requests to notify ${String(subscriber._id)}`);
      return;
    }

    let sentCount = 0;
    for (const req of recentRequests) {
      const already = await SendLog.exists({ requestId: req._id, subscriberId: subscriber._id, status: 'sent' });
      if (already) continue;

      // Claim the SendLog slot atomically
      try {
        await SendLog.create({ requestId: req._id, subscriberId: subscriber._id, sentAt: new Date(), status: 'fail' });
        console.log(`[notify:on-confirm] SendLog claim created for request ${req._id} subscriber ${String(subscriber._id)}`);
        } catch (claimErr: unknown) {
          const claimMsg = String((claimErr as any)?.message || '');
          if (claimMsg.includes('E11000') || (claimErr as any)?.code === 11000) {
            console.log(`[notify:on-confirm] SendLog claim already exists for request ${req._id} subscriber ${String(subscriber._id)}, skipping`);
            continue;
          }
          console.error("[notify:on-confirm] delivery claim could not be created");
        continue;
      }

      try {
        await sendNewRequestAlert(subscriber as any, req as any);
        console.log(`[notify:on-confirm] sendNewRequestAlert success for subscriber ${String(subscriber._id)} request ${req._id}`);
        await Subscriber.updateOne({ _id: subscriber._id }, { $set: { lastSentAt: new Date() }, $inc: { dailyCount: 1 } });
        await SendLog.updateOne({ requestId: req._id, subscriberId: subscriber._id }, { $set: { status: 'sent', sentAt: new Date(), error: undefined } });
        sentCount++;
  const latest: any = await Subscriber.findById(subscriber._id).lean();
  if (latest && (latest.dailyCount >= 4)) break;
      } catch (err: unknown) {
        const errText = err instanceof Error ? err.message : String(err);
        await SendLog.updateOne({ requestId: req._id, subscriberId: subscriber._id }, { $set: { status: 'fail', sentAt: new Date(), error: errText } });
        if (errText.match(/invalid|bounce|not found|recipient/i)) {
          await Subscriber.updateOne({ _id: subscriber._id }, { $set: { bounced: true } });
          break;
        }
      }
    }
    if (sentCount) console.log(`[notify:on-confirm] submitted ${sentCount} notifications`);
  } catch (err) {
    console.error("[notify:on-confirm] unexpected failure");
  }
}
