import mongoose from "mongoose";
import { describe, expect, it } from "vitest";
import {
  HELPER_NEW_REQUEST_NOTIFICATION_TYPE,
  HELPER_NEW_REQUEST_THREAD_ID,
  HelperPushPayloadError,
  MAXIMUM_PUSH_TEXT_LENGTH,
  boundPushText,
  buildHelperClosingSoonPayload,
  buildHelperNewRequestHeaders,
  buildHelperNewRequestPayload,
  helperPushQuantityText,
} from "./helperPushPayload.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const expiresAt = new Date("2026-07-28T21:00:00.000Z");
const TOPIC = "org.commonplatenyu.CommonPlateios";

/**
 * A document carrying every private field the request lifecycle can hold, so
 * the allowlist is proved against real leakage rather than against a fixture
 * that never had anything to leak.
 */
function fullRequestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupWindowText: "Jul 28, 1:00 PM – 2:00 PM",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    status: "open",
    claimTokenDigest: "private-claim-digest",
    claimedAt: new Date("2026-07-28T16:30:00.000Z"),
    claimExpiresAt: new Date("2026-07-28T17:30:00.000Z"),
    claimExtendedAt: null,
    fulfillerEmail: "helper@nyu.edu",
    contactMessage: "Private contact message",
    orderNumber: "PRIVATE-ORDER-9",
    notificationStatus: "sent",
    expiresAt,
    deleteAt: expiresAt,
    // Every request accepted since W3-C1 carries an integer 1-5, on every
    // accepted shape including the legacy web one, so an ordinary fixture
    // always supplies it.
    mealSwipes: 3,
    ...overrides,
  } as never;
}

describe("helper new-request payload public allowlist", () => {
  it.each([
    [{ mealSwipes: 1, pickupWindowText: "ASAP" }, "1 meal swipe"],
    [{ mealSwipes: 5, pickupWindowText: "ASAP (available for the next 3 hours)" }, "5 meal swipes"],
    // W4-N1 Increment B (Faith, 2026-10-23): a mixed Meal Exchange + Dining
    // Dollars top-up request now shows both components, superseding
    // Increment A's accepted omission of the top-up.
    [{ mealSwipes: 2, estimatedDiningDollarsCents: 999 }, "2 meal swipes + $9.99 DD"],
    [
      {
        mealSwipes: 2,
        estimatedDiningDollarsCents: 800,
        pickupWindowText: "Oct 23, 8:00 PM – 8:30 PM",
      },
      "2 meal swipes + $8.00 DD",
    ],
    [{ menuPath: "dining-dollars", mealSwipes: 0, estimatedDiningDollarsCents: 1234, pickupWindowText: "ASAP" }, "$12.34 DD"],
    [{ menuPath: "dining-dollars", mealSwipes: 0, estimatedDiningDollarsCents: 1200 }, "$12.00 DD"],
  ])("uses the value-first title and dining-location body: %j", (fields, title) => {
    expect(buildHelperNewRequestPayload(fullRequestDocument(fields)).aps.alert).toEqual({
      title, body: "Campus Market",
    });
  });
  it("carries only quantity, time, location and routing context", () => {
    // A normal post-C1 request: every accepted shape requires a valid
    // quantity, so the ordinary fixture (default `mealSwipes: 3`) carries one
    // and the allowlist proof reflects that, rather than the malformed/pre-C1
    // absent-quantity case proved separately below.
    const payload = buildHelperNewRequestPayload(fullRequestDocument());

    expect(payload).toEqual({
      aps: {
        alert: {
          title: "3 meal swipes",
          body: "Campus Market",
        },
        sound: "default",
        "interruption-level": "active",
        "thread-id": HELPER_NEW_REQUEST_THREAD_ID,
      },
      type: HELPER_NEW_REQUEST_NOTIFICATION_TYPE,
      requestId: requestId.toString(),
    });
  });

  it("includes the meal-swipe quantity concisely in the alert title (W3-C1)", () => {
    const payload = buildHelperNewRequestPayload(
      fullRequestDocument({ mealSwipes: 3 })
    );

    expect(payload.aps.alert.title).toBe(
      "3 meal swipes"
    );
  });

  it("refuses to fabricate a quantity for malformed stored data", () => {
    expect(() => buildHelperNewRequestPayload(
      fullRequestDocument({ mealSwipes: undefined })
    )).toThrow(HelperPushPayloadError);
  });

  it("leaks no private field from a document that carries all of them", () => {
    const serialized = JSON.stringify(
      buildHelperNewRequestPayload(fullRequestDocument())
    );

    for (const secret of [
      "Vegetable rice bowl",
      "Requester Private Name",
      "requester@nyu.edu",
      "private-claim-digest",
      "helper@nyu.edu",
      "Private contact message",
      "PRIVATE-ORDER-9",
      "claimExpiresAt",
      "notificationStatus",
      "deleteAt",
    ]) {
      expect(serialized).not.toContain(secret);
    }
    // The APNs token and installation credential are never even in scope here:
    // the payload is built once per request, before any installation is read.
    expect(serialized).not.toMatch(/apnsToken|installationCredential/);
  });

  it("routes by the same public id the list and detail responses expose", () => {
    expect(
      buildHelperNewRequestPayload(fullRequestDocument()).requestId
    ).toBe(String(requestId));
  });

  it("is an alert push, never a silent content-available push", () => {
    // The accepted product behavior requires a visible notification, including
    // while CommonPlate is in the foreground.
    const payload = buildHelperNewRequestPayload(fullRequestDocument());

    expect(payload.aps).not.toHaveProperty("content-available");
    expect(payload.aps.alert.title).not.toBe("");
    expect(payload.aps.alert.body).not.toBe("");
  });

  it("bounds each requester-supplied field and stays far under the APNs limit", () => {
    const payload = buildHelperNewRequestPayload(
      fullRequestDocument({
        vendor: "V".repeat(4000),
        food: "F".repeat(4000),
        pickupWindowText: "W".repeat(4000),
      })
    );
    const size = Buffer.byteLength(JSON.stringify(payload), "utf8");

    expect(payload.aps.alert.body.length).toBeLessThanOrEqual(
      MAXIMUM_PUSH_TEXT_LENGTH
    );
    expect(payload.aps.alert.title.length).toBeLessThanOrEqual(
      "3 meal swipes · ".length + MAXIMUM_PUSH_TEXT_LENGTH
    );
    expect(size).toBeLessThan(4096);
    expect(size).toBeLessThan(1024);
  });

  it("collapses whitespace and truncates with an ellipsis", () => {
    expect(boundPushText("  Campus   Market \n")).toBe("Campus Market");
    expect(boundPushText(undefined)).toBe("");
    const long = boundPushText("x".repeat(MAXIMUM_PUSH_TEXT_LENGTH + 10));
    expect(long).toHaveLength(MAXIMUM_PUSH_TEXT_LENGTH);
    expect(long.endsWith("…")).toBe(true);
    expect(boundPushText("y".repeat(MAXIMUM_PUSH_TEXT_LENGTH))).toHaveLength(
      MAXIMUM_PUSH_TEXT_LENGTH
    );
  });
});

describe("helper new-request APNs headers", () => {
  it("builds the accepted header set", () => {
    const headers = buildHelperNewRequestHeaders(fullRequestDocument(), {
      topic: TOPIC,
    });

    expect(headers).toEqual({
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-topic": TOPIC,
      "apns-collapse-id": requestId.toString(),
      "apns-expiration": String(Math.floor(expiresAt.getTime() / 1000)),
      "content-type": "application/json",
    });
  });

  it("derives apns-expiration from the request's own availability deadline", () => {
    // A notification APNs could not deliver promptly is discarded rather than
    // surfacing after the request can no longer be helped.
    const headers = buildHelperNewRequestHeaders(
      fullRequestDocument({ expiresAt: "2026-07-28T18:00:00.000Z" }),
      { topic: TOPIC }
    );

    expect(headers["apns-expiration"]).toBe("1785261600");
    expect(Number(headers["apns-expiration"])).toBe(
      new Date("2026-07-28T18:00:00.000Z").getTime() / 1000
    );
  });

  it("uses the request id as the collapse id, within Apple's 64-byte limit", () => {
    const headers = buildHelperNewRequestHeaders(fullRequestDocument(), {
      topic: TOPIC,
    });

    expect(headers["apns-collapse-id"]).toBe(requestId.toString());
    expect(
      Buffer.byteLength(headers["apns-collapse-id"], "utf8")
    ).toBeLessThanOrEqual(64);
  });

  it("carries no authorization header, so no builder ever holds a secret", () => {
    const headers = buildHelperNewRequestHeaders(fullRequestDocument(), {
      topic: TOPIC,
    });

    expect(headers).not.toHaveProperty("authorization");
    expect(Object.keys(headers)).not.toContain("Authorization");
  });

  it.each([undefined, null, "not-a-date"])(
    "refuses to build headers without a usable expiresAt (%j)",
    (expiration) => {
      expect(() =>
        buildHelperNewRequestHeaders(
          fullRequestDocument({ expiresAt: expiration }),
          { topic: TOPIC }
        )
      ).toThrow(HelperPushPayloadError);
    }
  );

  it("refuses to build headers without a configured topic", () => {
    expect(() =>
      buildHelperNewRequestHeaders(fullRequestDocument(), { topic: "  " })
    ).toThrow(HelperPushPayloadError);
  });
});

describe("W4-R5 content revision in the payload", () => {
  it("carries the content revision when the request has one", () => {
    const payload = buildHelperNewRequestPayload(
      fullRequestDocument({ contentRevision: 3 })
    );

    expect(payload.contentRevision).toBe(3);
  });

  it.each([undefined, null, 0, -1, 1.5, "2"])(
    "omits an unusable revision (%j) instead of inventing one",
    (value) => {
      const payload = buildHelperNewRequestPayload(
        fullRequestDocument({ contentRevision: value })
      );

      expect(payload).not.toHaveProperty("contentRevision");
    }
  );

  it("still carries nothing private alongside the revision", () => {
    const text = JSON.stringify(
      buildHelperNewRequestPayload(
        fullRequestDocument({ contentRevision: 2, notificationGeneration: 7 })
      )
    );

    expect(text).not.toContain("notificationGeneration");
    expect(text).not.toContain("requester@nyu.edu");
  });
});

describe("W4-N1 Increment B value-first copy helpers", () => {
  it.each([
    [{ mealSwipes: 1 }, "1 meal swipe"],
    [{ mealSwipes: 3 }, "3 meal swipes"],
    [{ menuPath: "dining-dollars", mealSwipes: 0, estimatedDiningDollarsCents: 1200 }, "$12.00 DD"],
    [{ mealSwipes: 2, estimatedDiningDollarsCents: 800 }, "2 meal swipes + $8.00 DD"],
    [{ mealSwipes: 1, estimatedDiningDollarsCents: 100 }, "1 meal swipe + $1.00 DD"],
  ])("formats the authoritative quantity: %j", (fields, expected) => {
    expect(helperPushQuantityText(fields as never)).toBe(expected);
  });

  it("refuses a mixed top-up that is not a valid stored amount", () => {
    expect(() =>
      helperPushQuantityText({ mealSwipes: 2, estimatedDiningDollarsCents: 0 } as never)
    ).toThrow(HelperPushPayloadError);
  });

  it.each([
    "ASAP",
    "ASAP (available for the next 3 hours)",
    "Oct 23, 8:00 PM – 8:30 PM",
  ])("omits implicit timing without changing stored requester timing: %j", (stored) => {
    const request = { _id: requestId, vendor: "Crave NYU", food: "Rice bowl", mealSwipes: 3, pickupWindowText: stored };
    expect(buildHelperNewRequestPayload(request).aps.alert.title).toBe("3 meal swipes");
    expect(request.pickupWindowText).toBe(stored);
  });
});

describe("W4-N1 Increment B closing-soon push", () => {
  it.each([
    [{ mealSwipes: 1 }, "1 meal swipe"],
    [{ mealSwipes: 3 }, "3 meal swipes"],
    [
      { menuPath: "dining-dollars", mealSwipes: 0, estimatedDiningDollarsCents: 1200 },
      "$12.00 DD",
    ],
    [
      { mealSwipes: 2, estimatedDiningDollarsCents: 800 },
      "2 meal swipes + $8.00 DD",
    ],
  ])("separates value and closing timing into native title and subtitle: %j", (fields, title) => {
    expect(buildHelperClosingSoonPayload(fullRequestDocument(fields)).aps.alert).toEqual({
      title,
      subtitle: "Closing in 15 min",
      body: "Campus Market",
    });
  });

  it("reuses the initial discovery notification's type and thread so a tap routes identically", () => {
    const payload = buildHelperClosingSoonPayload(fullRequestDocument());

    expect(payload.type).toBe(HELPER_NEW_REQUEST_NOTIFICATION_TYPE);
    expect(payload.aps["thread-id"]).toBe(HELPER_NEW_REQUEST_THREAD_ID);
    expect(payload.requestId).toBe(String(requestId));
  });

  it("carries nothing private", () => {
    const serialized = JSON.stringify(
      buildHelperClosingSoonPayload(fullRequestDocument())
    );

    expect(serialized).not.toContain("Vegetable rice bowl");
    expect(serialized).not.toContain("requester@nyu.edu");
    expect(serialized).not.toContain("claimExpiresAt");
  });
});
