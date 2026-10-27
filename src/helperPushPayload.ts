/**
 * The helper new-request push payload and its APNs headers.
 *
 * Pure: no configuration, database or secret. The alert contains only dining
 * location, timing and quantity, plus routing context outside the visible copy.
 * Never food/order details, participant identity, pickup names or credentials.
 */
import { DINING_DOLLARS_PATH, formatDiningDollars } from "./structuredRequest.js";

export const HELPER_NEW_REQUEST_NOTIFICATION_TYPE = "new-request";
export const HELPER_NEW_REQUEST_THREAD_ID = "new-request";

/**
 * `vendor`, `food`, and `pickupWindowText` are requester-supplied free text.
 * Bounding each one keeps a single long field from crowding the visible alert
 * or approaching the 4 KB APNs payload limit.
 */
export const MAXIMUM_PUSH_TEXT_LENGTH = 80;

export class HelperPushPayloadError extends Error {}

export interface HelperPushRequest {
  _id: unknown;
  vendor: string;
  food: string;
  pickupWindowText: string;
  /**
   * V1 meal-swipe requirement (W3-C1). Every shape `POST /api/request`
   * accepts, including the legacy web one, has required an integer 1-5 since
   * this slice, so `undefined`/`null` here reaches this builder only from a
   * malformed/pre-C1 stored `Request` document, never a supported
   * representation of an accepted submission.
   */
  mealSwipes?: number | null;
  menuPath?: string | null;
  estimatedDiningDollarsCents?: number | null;
  expiresAt?: Date | string | null;
  /**
   * W4-R5 content revision at send time. Opaque to the device: a tap compares
   * it with the current revision the detail read returns, to say truthfully that
   * the request changed since this notification was sent.
   */
  contentRevision?: number | null;
}

export interface HelperNewRequestPayload {
  aps: {
    alert: { title: string; subtitle?: string; body: string };
    sound: "default";
    "interruption-level": "active";
    "thread-id": typeof HELPER_NEW_REQUEST_THREAD_ID;
  };
  type: typeof HELPER_NEW_REQUEST_NOTIFICATION_TYPE;
  requestId: string;
  /** Present only when the request carries a revision (W4-R5). */
  contentRevision?: number;
}

/** Bounded, whitespace-collapsed display text. */
export function boundPushText(value: unknown): string {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  return text.length <= MAXIMUM_PUSH_TEXT_LENGTH
    ? text
    : `${text.slice(0, MAXIMUM_PUSH_TEXT_LENGTH - 1)}…`;
}

/**
 * W4-N1 Increment B value-first hierarchy: the authoritative quantity first
 * (meal swipes, Dining Dollars, or — superseding Increment A's accepted
 * omission — both together for a mixed Meal Exchange + Dining Dollars
 * top-up request), closing timing in a subtitle, dining location in the body.
 * Shared by the initial discovery push and the T-15 closing-soon push below,
 * which share the same thread/collapse identity.
 *
 * System-notification copy uses `DD` to keep compact titles readable.
 * A Dining-Dollars-only request
 * (`menuPath === DINING_DOLLARS_PATH`) is unaffected: the top-up branch only
 * ever applies to the meal-swipe quantity.
 */
export function helperPushQuantityText(
  request: Pick<HelperPushRequest, "menuPath" | "mealSwipes" | "estimatedDiningDollarsCents">
): string {
  if (request.menuPath === DINING_DOLLARS_PATH) {
    const cents = request.estimatedDiningDollarsCents;
    if (cents == null || !Number.isSafeInteger(cents) || cents <= 0) {
      throw new HelperPushPayloadError("a Dining Dollars push requires the stored amount");
    }
    return `${formatDiningDollars(cents)} DD`;
  }

  const swipes = request.mealSwipes;
  if (swipes == null || !Number.isInteger(swipes) || swipes < 1 || swipes > 5) {
    throw new HelperPushPayloadError("a meal-swipe push requires the stored quantity");
  }
  const swipesText = `${swipes} meal swipe${swipes === 1 ? "" : "s"}`;

  const topUpCents = request.estimatedDiningDollarsCents;
  if (topUpCents == null) return swipesText;
  if (!Number.isSafeInteger(topUpCents) || topUpCents <= 0) {
    throw new HelperPushPayloadError(
      "a mixed-shape push requires a valid stored Dining Dollars top-up amount"
    );
  }
  return `${swipesText} + ${formatDiningDollars(topUpCents)} DD`;
}

/**
 * An alert notification, never a silent `content-available` push: the accepted
 * product behavior requires a visible notification, including while
 * CommonPlate is in the foreground.
 */
export function buildHelperNewRequestPayload(
  request: HelperPushRequest
): HelperNewRequestPayload {
  const vendor = boundPushText(request.vendor);
  const quantity = helperPushQuantityText(request);

  return {
    aps: {
      alert: {
        title: quantity,
        body: vendor,
      },
      sound: "default",
      "interruption-level": "active",
      "thread-id": HELPER_NEW_REQUEST_THREAD_ID,
    },
    type: HELPER_NEW_REQUEST_NOTIFICATION_TYPE,
    // The routing identifier, and the only linkage the payload carries. It is
    // the same public `id` the list and detail responses already expose.
    requestId: String(request._id),
    ...(typeof request.contentRevision === "number" &&
    Number.isInteger(request.contentRevision) &&
    request.contentRevision >= 1
      ? { contentRevision: request.contentRevision }
      : {}),
  };
}

/**
 * W4-N1 Increment B: the one additional T-15 closing-soon discovery push.
 * Deliberately reuses `HELPER_NEW_REQUEST_NOTIFICATION_TYPE` and
 * `HELPER_NEW_REQUEST_THREAD_ID` rather than inventing a second notification
 * kind: a tap resolves through the exact same backend-truth routing as the
 * initial discovery push (`HelperNotificationPayloadParser`,
 * `HelperNotificationRouter`), and collapsing on the same request id is the
 * same duplicate-banner guard the initial push already uses. Only the
 * closing-soon subtitle differs.
 */
export function buildHelperClosingSoonPayload(
  request: HelperPushRequest
): HelperNewRequestPayload {
  const vendor = boundPushText(request.vendor);
  const quantity = helperPushQuantityText(request);

  return {
    aps: {
      alert: {
        title: quantity,
        subtitle: "Closing in 15 min",
        body: vendor,
      },
      sound: "default",
      "interruption-level": "active",
      "thread-id": HELPER_NEW_REQUEST_THREAD_ID,
    },
    type: HELPER_NEW_REQUEST_NOTIFICATION_TYPE,
    requestId: String(request._id),
    ...(typeof request.contentRevision === "number" &&
    Number.isInteger(request.contentRevision) &&
    request.contentRevision >= 1
      ? { contentRevision: request.contentRevision }
      : {}),
  };
}

export interface HelperNewRequestHeaderOptions {
  /** The configured bundle identifier. */
  topic: string;
}

/**
 * Everything but `authorization`, which the dispatcher adds from the cached
 * provider token at submission time. Keeping the provider JWT out of this
 * module means no pure builder — and no test of one — ever holds a secret.
 *
 * `apns-expiration` comes from the request's own availability deadline, so a
 * notification APNs could not deliver promptly is discarded rather than
 * surfacing after the request can no longer be helped. `apns-collapse-id` is
 * the request id, a second device-side guard against a duplicate banner.
 */
export function buildHelperNewRequestHeaders(
  request: HelperPushRequest,
  options: HelperNewRequestHeaderOptions
): Record<string, string> {
  const expiration = request.expiresAt == null
    ? Number.NaN
    : new Date(request.expiresAt).getTime();
  if (!Number.isFinite(expiration)) {
    throw new HelperPushPayloadError(
      "a helper new-request push requires the request's expiresAt"
    );
  }
  if (options.topic.trim() === "") {
    throw new HelperPushPayloadError(
      "a helper new-request push requires a configured apns-topic"
    );
  }

  return {
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-topic": options.topic,
    "apns-collapse-id": String(request._id),
    "apns-expiration": String(Math.floor(expiration / 1000)),
    "content-type": "application/json",
  };
}
