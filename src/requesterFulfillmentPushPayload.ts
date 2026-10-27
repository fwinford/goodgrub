/**
 * The requester-order-placed push payload and its APNs headers (Week 3 Day 6
 * Slice 6E).
 *
 * Pure: no configuration, no database, no secret. Title and body are locked
 * product copy, never derived from request content, so nothing requester- or
 * helper-private (pickup name, either party's email, order number, claim
 * data, the installation credential) can ever reach this payload. `requestId`
 * is carried only for `apns-collapse-id`, a device-side duplicate-banner
 * guard matching the helper new-request push's own use of it — routing itself
 * always opens Home, never a specific request screen.
 */
export const REQUESTER_FULFILLMENT_NOTIFICATION_TYPE = "requester-order-placed";
export const REQUESTER_FULFILLMENT_THREAD_ID = "requester-order-placed";

export const REQUESTER_FULFILLMENT_TITLE = "Your order was placed";
export const REQUESTER_FULFILLMENT_BODY =
  "A helper placed the order for your request.";

export class RequesterFulfillmentPushPayloadError extends Error {}

export interface RequesterFulfillmentPushRequest {
  _id: unknown;
  expiresAt?: Date | string | null;
}

export interface RequesterFulfillmentPayload {
  aps: {
    alert: { title: string; body: string };
    sound: "default";
    "interruption-level": "active";
    "thread-id": typeof REQUESTER_FULFILLMENT_THREAD_ID;
  };
  type: typeof REQUESTER_FULFILLMENT_NOTIFICATION_TYPE;
  requestId: string;
}

/**
 * An alert notification, matching the helper new-request push's visibility:
 * always a real system notification, never a silent `content-available` push.
 */
export function buildRequesterFulfillmentPayload(
  request: RequesterFulfillmentPushRequest
): RequesterFulfillmentPayload {
  return {
    aps: {
      alert: {
        title: REQUESTER_FULFILLMENT_TITLE,
        body: REQUESTER_FULFILLMENT_BODY,
      },
      sound: "default",
      "interruption-level": "active",
      "thread-id": REQUESTER_FULFILLMENT_THREAD_ID,
    },
    type: REQUESTER_FULFILLMENT_NOTIFICATION_TYPE,
    requestId: String(request._id),
  };
}

export interface RequesterFulfillmentHeaderOptions {
  /** The configured bundle identifier. */
  topic: string;
}

/**
 * Everything but `authorization`, which the dispatcher adds from the cached
 * provider token at submission time — matching the helper new-request push
 * builder, so no pure builder ever holds a secret.
 *
 * Unlike the helper push, `apns-expiration` cannot be derived from the
 * request's own availability deadline: a placed request has no meaningful
 * `expiresAt` left to advertise. A short, fixed expiration is used instead,
 * bounding how long APNs will hold an undeliverable notification for an event
 * that is already history by the time it can be shown.
 */
export const REQUESTER_FULFILLMENT_APNS_EXPIRATION_SECONDS = 60 * 60;

export function buildRequesterFulfillmentHeaders(
  request: RequesterFulfillmentPushRequest,
  options: RequesterFulfillmentHeaderOptions,
  now: Date
): Record<string, string> {
  if (options.topic.trim() === "") {
    throw new RequesterFulfillmentPushPayloadError(
      "a requester-fulfillment push requires a configured apns-topic"
    );
  }

  const expiration =
    Math.floor(now.getTime() / 1000) +
    REQUESTER_FULFILLMENT_APNS_EXPIRATION_SECONDS;

  return {
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-topic": options.topic,
    "apns-collapse-id": String(request._id),
    "apns-expiration": String(expiration),
    "content-type": "application/json",
  };
}
