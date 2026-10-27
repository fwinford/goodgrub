import { Subscriber } from "../models/db.js";
import { isRequestAlertEmailDeliveryActive } from "./requestAlertEmailDelivery.js";
import {
  digestSubscriptionToken,
  isValidRawSubscriptionToken,
} from "./subscriptionTokens.js";

/**
 * Internal outcome of redeeming a confirmation token. It is deliberately not a
 * response shape: the caller decides what a browser or API surface may learn,
 * and no route consumes this yet.
 */
export type ConfirmationOutcome =
  | "confirmed"
  | "alreadyConfirmed"
  | "expired"
  | "invalid"
  | "unavailable";

export interface ConfirmationResult {
  outcome: ConfirmationOutcome;
  subscriberId?: string;
}

/** Cleared by a successful transition: none of it outlives `pending`. */
const CONFIRMATION_CLEARED_FIELDS = [
  "confirmationTokenDigest",
  "confirmationExpiresAt",
  // Confirmation is the user's action, not the send attempt's. It must succeed
  // under a live or orphaned signup lease, and it ends that lease: the
  // lifecycle the lease guarded no longer exists once the address is confirmed.
  "confirmationSendAttemptId",
  "confirmationSendAttemptAt",
  "unsubscribedAt",
  // Legacy raw credentials from a pre-digest row. A subscriber confirmed by
  // this lifecycle keeps digests only, so a raw token left behind here would be
  // a live credential the new contract never issued and cannot revoke.
  "confirmToken",
  "unsubToken",
] as const;

/**
 * The same definition minus the unsubscribe timestamp, which is lifecycle
 * history rather than confirmation state: the unsubscribe path writes its own
 * timestamp and must not clear it.
 *
 * Derived rather than written out again, so a field added to the confirmation
 * clear list cannot be left behind by unsubscribe.
 */
export const ACTIVE_CONFIRMATION_FIELDS = CONFIRMATION_CLEARED_FIELDS.filter(
  (field) => field !== "unsubscribedAt"
);

/**
 * The bounded receipt a successful confirmation writes: the digest of the token
 * that was spent and the expiry it stays recognisable until. Confirmation
 * writes it, so it is not part of the clear list above — but it is still
 * confirmation credential state, and it decides the `alreadyConfirmed` answer.
 */
export const CONFIRMATION_RECEIPT_FIELDS = [
  "lastConfirmedTokenDigest",
  "lastConfirmedTokenExpiresAt",
] as const;

/**
 * Everything unsubscribe clears: the active credential and send-lease fields,
 * plus the receipt.
 *
 * A confirmed address that unsubscribes must keep no confirmation credential of
 * any kind, live or spent. While the receipt survived, reopening the original
 * confirmation link inside its window still answered *already confirmed* to a
 * reader who had just asked to stop — an answer the row no longer supports.
 */
export const UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS = [
  ...ACTIVE_CONFIRMATION_FIELDS,
  ...CONFIRMATION_RECEIPT_FIELDS,
];

/**
 * Redeems a raw confirmation token against backend `now`.
 *
 * The transition is one conditional atomic mutation. Reading the subscriber
 * first and saving a decided status would let two concurrent redemptions both
 * observe `pending` and both write; the conditional update lets exactly one
 * win, so exactly one lifecycle transition happens.
 *
 * Confirmation issues no unsubscribe credential. The unsubscribe link is
 * signed on demand from `_id` and `unsubscribeCredentialVersion`, so this
 * mutation must leave that version alone: touching it would invalidate every
 * unsubscribe link already delivered to this address.
 */
export async function confirmSubscription(
  rawToken: unknown,
  now: Date
): Promise<ConfirmationResult> {
  if (!isRequestAlertEmailDeliveryActive()) return { outcome: "unavailable" };
  if (!isValidRawSubscriptionToken(rawToken)) return { outcome: "invalid" };

  const confirmationTokenDigest = digestSubscriptionToken(rawToken);

  const confirmed = await Subscriber.findOneAndUpdate(
    {
      status: "pending",
      confirmationTokenDigest,
      confirmationExpiresAt: { $gt: now },
    },
    // An aggregation pipeline, because the receipt must carry the expiry the
    // document already held. Reading it in a separate round trip would
    // reopen the race this single mutation exists to close.
    [
      {
        $set: {
          status: "confirmed",
          lastConfirmedTokenDigest: "$confirmationTokenDigest",
          lastConfirmedTokenExpiresAt: "$confirmationExpiresAt",
          // Confirmation starts delivery history over: a freshly confirmed
          // address must not inherit a bounce or a spent daily allowance
          // from an earlier lifecycle.
          lastSentAt: { $literal: null },
          dailyCount: { $literal: 0 },
          bounced: { $literal: false },
        },
      },
      { $unset: [...CONFIRMATION_CLEARED_FIELDS] },
    ],
    { new: true }
  )
    .select("_id")
    .lean<{ _id: unknown }>()
    .exec();

  if (confirmed) {
    return { outcome: "confirmed", subscriberId: String(confirmed._id) };
  }

  // Checked only after the mutation lost, so the loser of a concurrent
  // redemption reports the winner's success rather than an invalid token.
  // The receipt is honoured only inside the original confirmation window;
  // past it the link is simply spent.
  const alreadyConfirmed = await Subscriber.findOne({
    status: "confirmed",
    lastConfirmedTokenDigest: confirmationTokenDigest,
    lastConfirmedTokenExpiresAt: { $gt: now },
  })
    .select("_id")
    .lean<{ _id: unknown }>()
    .exec();
  if (alreadyConfirmed) {
    return {
      outcome: "alreadyConfirmed",
      subscriberId: String(alreadyConfirmed._id),
    };
  }

  const expired = await Subscriber.exists({
    confirmationTokenDigest,
    confirmationExpiresAt: { $lte: now },
  });
  if (expired) return { outcome: "expired" };

  return { outcome: "invalid" };
}
