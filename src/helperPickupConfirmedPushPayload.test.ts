import mongoose from "mongoose";
import { describe, expect, it } from "vitest";
import {
  HELPER_PICKUP_CONFIRMED_APNS_EXPIRATION_SECONDS,
  HELPER_PICKUP_CONFIRMED_BODY,
  HELPER_PICKUP_CONFIRMED_NOTIFICATION_TYPE,
  HELPER_PICKUP_CONFIRMED_THREAD_ID,
  HELPER_PICKUP_CONFIRMED_TITLE,
  HelperPickupConfirmedPushPayloadError,
  buildHelperPickupConfirmedHeaders,
  buildHelperPickupConfirmedPayload,
} from "./helperPickupConfirmedPushPayload.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000003");
const now = new Date("2026-08-05T12:00:00.000Z");
const TOPIC = "org.commonplatenyu.CommonPlateios";

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
    requesterPickupConfirmedAt: new Date("2026-08-05T11:55:00.000Z"),
    helperParticipantId: "64d000000000000000000003",
    requesterParticipantId: "64d000000000000000000004",
    ...overrides,
  } as never;
}

describe("D-N1-5 pickup-confirmed payload fixed copy and privacy", () => {
  it("carries exactly the fixed title, body, and the request id", () => {
    const payload = buildHelperPickupConfirmedPayload(fullPlacedRequestDocument());

    expect(payload).toEqual({
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
      requestId: requestId.toString(),
    });
  });

  it("locks the accepted visible copy exactly (Faith, 2026-10-21/23)", () => {
    expect(HELPER_PICKUP_CONFIRMED_TITLE).toBe("Pickup confirmed");
    expect(HELPER_PICKUP_CONFIRMED_BODY).toBe(
      "The requester confirmed pickup. Thanks for helping make a meal possible!"
    );
  });

  it("uses a distinct type from every other push kind", () => {
    expect(HELPER_PICKUP_CONFIRMED_NOTIFICATION_TYPE).not.toBe("new-request");
    expect(HELPER_PICKUP_CONFIRMED_NOTIFICATION_TYPE).not.toBe("requester-order-placed");
  });

  it("leaks no requester identity, order contents, or placement evidence", () => {
    const serialized = JSON.stringify(
      buildHelperPickupConfirmedPayload(fullPlacedRequestDocument())
    );

    for (const secret of [
      "Campus Market",
      "Vegetable rice bowl",
      "Requester Private Name",
      "requester@nyu.edu",
      "PRIVATE-ORDER-9",
      "15 minutes",
      "helper@nyu.edu",
      "Private contact message",
      "notificationStatus",
      "requesterPickupConfirmedAt",
      "helperParticipantId",
      "requesterParticipantId",
      "64d000000000000000000003",
      "64d000000000000000000004",
    ]) {
      expect(serialized).not.toContain(secret);
    }
  });

  it("routes by the same public id the list and detail responses expose", () => {
    expect(
      buildHelperPickupConfirmedPayload(fullPlacedRequestDocument()).requestId
    ).toBe(String(requestId));
  });

  it("is an alert push, never a silent content-available push", () => {
    const payload = buildHelperPickupConfirmedPayload(fullPlacedRequestDocument());
    expect(payload.aps).not.toHaveProperty("content-available");
  });
});

describe("D-N1-5 pickup-confirmed APNs headers", () => {
  it("builds the accepted header set", () => {
    const headers = buildHelperPickupConfirmedHeaders(
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
        Math.floor(now.getTime() / 1000) +
          HELPER_PICKUP_CONFIRMED_APNS_EXPIRATION_SECONDS
      ),
      "content-type": "application/json",
    });
  });

  it("uses the request id as the collapse id, within Apple's 64-byte limit", () => {
    const headers = buildHelperPickupConfirmedHeaders(
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
    const headers = buildHelperPickupConfirmedHeaders(
      fullPlacedRequestDocument(),
      { topic: TOPIC },
      now
    );

    expect(headers).not.toHaveProperty("authorization");
  });

  it("refuses to build headers without a configured topic", () => {
    expect(() =>
      buildHelperPickupConfirmedHeaders(
        fullPlacedRequestDocument(),
        { topic: "  " },
        now
      )
    ).toThrow(HelperPickupConfirmedPushPayloadError);
  });
});
