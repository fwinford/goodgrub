/**
 * The D-N1-5 helper pickup-confirmation push payload and its APNs headers
 * (W4-N1 Increment B).
 *
 * Pure: no configuration, database, or secret. Mirrors
 * `src/requesterFulfillmentPushPayload.ts` in shape and in the reason
 * `requestId` is carried only for `apns-collapse-id`: it never carries the
 * requester's identity, email, order contents, or any other private
 * placement detail. Tap routing is Home, unconditionally — no backend-truth
 * resolution is needed because the notification creates no state a tap
 * could get wrong by opening Home.
 */
export const HELPER_PICKUP_CONFIRMED_NOTIFICATION_TYPE = "helper-pickup-confirmed";
export const HELPER_PICKUP_CONFIRMED_THREAD_ID = "helper-pickup-confirmed";

export const HELPER_PICKUP_CONFIRMED_TITLE = "Pickup confirmed";
export const HELPER_PICKUP_CONFIRMED_BODY =
  "The requester confirmed pickup. Thanks for helping make a meal possible!";

export class HelperPickupConfirmedPushPayloadError extends Error {}

export interface HelperPickupConfirmedPushRequest {
  _id: unknown;
}

export interface HelperPickupConfirmedPayload {
  aps: {
    alert: { title: string; body: string };
    sound: "default";
    "interruption-level": "active";
    "thread-id": typeof HELPER_PICKUP_CONFIRMED_THREAD_ID;
  };
  type: typeof HELPER_PICKUP_CONFIRMED_NOTIFICATION_TYPE;
  requestId: string;
}

export function buildHelperPickupConfirmedPayload(
  request: HelperPickupConfirmedPushRequest
): HelperPickupConfirmedPayload {
  return {
    aps: {
      alert: {
        title: HELPER_PICKUP_CONFIRMED_TITLE,
        body: HELPER_PICKUP_CONFIRMED_BODY,
      },
      sound: "default",
      "interruption-level": "active",
      "thread-id": HELPER_PICKUP_CONFIRMED_THREAD_ID,
    },
    type: HELPER_PICKUP_CONFIRMED_NOTIFICATION_TYPE,
    requestId: String(request._id),
  };
}

export interface HelperPickupConfirmedHeaderOptions {
  /** The configured bundle identifier. */
  topic: string;
}

/**
 * Like the requester-fulfillment push, a confirmed pickup has no meaningful
 * remaining-availability deadline to derive `apns-expiration` from, so a
 * short, fixed expiration bounds how long APNs will hold an undeliverable
 * notification for an event that is already history by the time it could be
 * shown.
 */
export const HELPER_PICKUP_CONFIRMED_APNS_EXPIRATION_SECONDS = 60 * 60;

export function buildHelperPickupConfirmedHeaders(
  request: HelperPickupConfirmedPushRequest,
  options: HelperPickupConfirmedHeaderOptions,
  now: Date
): Record<string, string> {
  if (options.topic.trim() === "") {
    throw new HelperPickupConfirmedPushPayloadError(
      "a helper pickup-confirmed push requires a configured apns-topic"
    );
  }

  const expiration =
    Math.floor(now.getTime() / 1000) +
    HELPER_PICKUP_CONFIRMED_APNS_EXPIRATION_SECONDS;

  return {
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-topic": options.topic,
    "apns-collapse-id": String(request._id),
    "apns-expiration": String(expiration),
    "content-type": "application/json",
  };
}
