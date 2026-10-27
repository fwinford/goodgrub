import mongoose from "mongoose";
import { describe, expect, it } from "vitest";
import {
  REQUESTER_FULFILLMENT_APNS_EXPIRATION_SECONDS,
  REQUESTER_FULFILLMENT_BODY,
  REQUESTER_FULFILLMENT_NOTIFICATION_TYPE,
  REQUESTER_FULFILLMENT_THREAD_ID,
  REQUESTER_FULFILLMENT_TITLE,
  RequesterFulfillmentPushPayloadError,
  buildRequesterFulfillmentHeaders,
  buildRequesterFulfillmentPayload,
} from "./requesterFulfillmentPushPayload.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const now = new Date("2026-08-05T12:00:00.000Z");
const TOPIC = "org.commonplatenyu.CommonPlateios";

/**
 * A document carrying every private field a *placed* request lifecycle can
 * hold, so the fixed-copy payload is proved against real leakage rather than
 * against a fixture that never had anything to leak.
 */
function fullPlacedRequestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupWindowText: "Jul 28, 1:00 PM – 2:00 PM",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    status: "placed",
    orderNumber: "PRIVATE-ORDER-9",
    etaText: "15 minutes",
    fulfillerEmail: "helper@nyu.edu",
    contactMessage: "Private contact message",
    notificationStatus: "sent",
    installationId: "64d000000000000000000001",
    ...overrides,
  } as never;
}

describe("requester fulfillment payload fixed copy and privacy", () => {
  it("carries exactly the fixed title, body, and the request id", () => {
    const payload = buildRequesterFulfillmentPayload(fullPlacedRequestDocument());

    expect(payload).toEqual({
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
      requestId: requestId.toString(),
    });
  });

  it("locks the accepted visible copy exactly", () => {
    expect(REQUESTER_FULFILLMENT_TITLE).toBe("Your order was placed");
    expect(REQUESTER_FULFILLMENT_BODY).toBe(
      "A helper placed the order for your request."
    );
  });

  it("uses a distinct type/purpose from the helper new-request push", () => {
    expect(REQUESTER_FULFILLMENT_NOTIFICATION_TYPE).not.toBe("new-request");
  });

  it("leaks no private field from a document that carries all of them, for any vendor/food content", () => {
    const serialized = JSON.stringify(
      buildRequesterFulfillmentPayload(
        fullPlacedRequestDocument({
          vendor: "Requester Private Name",
          food: "requester@nyu.edu",
        })
      )
    );

    for (const secret of [
      "Requester Private Name",
      "requester@nyu.edu",
      "PRIVATE-ORDER-9",
      "15 minutes",
      "helper@nyu.edu",
      "Private contact message",
      "notificationStatus",
      "installationId",
      "64d000000000000000000001",
    ]) {
      expect(serialized).not.toContain(secret);
    }
    // Copy is fixed, never derived from request content: vendor/food are
    // never read by the payload builder at all, so a document that happens
    // to carry a private value there cannot leak it either.
    expect(serialized).not.toMatch(/apnsToken|installationCredential|claimToken/);
  });

  it("routes by the same public id the list and detail responses expose", () => {
    expect(
      buildRequesterFulfillmentPayload(fullPlacedRequestDocument()).requestId
    ).toBe(String(requestId));
  });

  it("is an alert push, never a silent content-available push", () => {
    const payload = buildRequesterFulfillmentPayload(fullPlacedRequestDocument());

    expect(payload.aps).not.toHaveProperty("content-available");
  });
});

describe("requester fulfillment APNs headers", () => {
  it("builds the accepted header set", () => {
    const headers = buildRequesterFulfillmentHeaders(
      fullPlacedRequestDocument(),
      { topic: TOPIC },
      now
    );

    expect(headers).toEqual({
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-topic": TOPIC,
      "apns-collapse-id": requestId.toString(),
      "apns-expiration": String(
        Math.floor(now.getTime() / 1000) + REQUESTER_FULFILLMENT_APNS_EXPIRATION_SECONDS
      ),
      "content-type": "application/json",
    });
  });

  it("derives apns-expiration from dispatch time, not the request's own (now-irrelevant) expiresAt", () => {
    const headers = buildRequesterFulfillmentHeaders(
      fullPlacedRequestDocument({ expiresAt: undefined }),
      { topic: TOPIC },
      now
    );

    expect(headers["apns-expiration"]).toBe(
      String(Math.floor(now.getTime() / 1000) + 60 * 60)
    );
  });

  it("uses the request id as the collapse id, within Apple's 64-byte limit", () => {
    const headers = buildRequesterFulfillmentHeaders(
      fullPlacedRequestDocument(),
      { topic: TOPIC },
      now
    );

    expect(headers["apns-collapse-id"]).toBe(requestId.toString());
    expect(
      Buffer.byteLength(headers["apns-collapse-id"], "utf8")
    ).toBeLessThanOrEqual(64);
  });

  it("carries no authorization header, so no builder ever holds a secret", () => {
    const headers = buildRequesterFulfillmentHeaders(
      fullPlacedRequestDocument(),
      { topic: TOPIC },
      now
    );

    expect(headers).not.toHaveProperty("authorization");
  });

  it("refuses to build headers without a configured topic", () => {
    expect(() =>
      buildRequesterFulfillmentHeaders(
        fullPlacedRequestDocument(),
        { topic: "  " },
        now
      )
    ).toThrow(RequesterFulfillmentPushPayloadError);
  });
});
