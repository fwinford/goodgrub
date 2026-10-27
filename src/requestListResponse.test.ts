import { describe, expect, it } from "vitest";
import { CLAIM_MINIMUM_REMAINING_MS } from "./requestAvailability.js";
import {
  buildPublicRequestDetailResponse,
  buildPublicRequestListResponse,
} from "./requestListResponse.js";

const serverNow = new Date("2026-07-26T19:00:00.000Z");
const exactlyClaimable = new Date(
  serverNow.getTime() + CLAIM_MINIMUM_REMAINING_MS
);
const justUnderClaimable = new Date(exactlyClaimable.getTime() - 1);

function requestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: "request-1",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    // W4-R4 removed `pickupName` from the request contract. It is deliberately
    // still present on this fixture: like `email`, `phone`, and the claim/
    // fulfillment fields beside it, it is here to prove the projection's
    // allowlist omits whatever it does not name — a stray stored value on a
    // pre-R4 document must not reach the wire either.
    pickupName: "Requester Name",
    pickupWindowText: "1:00 PM – 2:00 PM",
    mealSwipes: 3,
    menuPath: "meal-exchange",
    mealItems: ["Vegetable rice bowl", "Side salad", "Iced tea"],
    orderDetails: undefined,
    estimatedDiningDollarsCents: undefined,
    email: "requester@example.edu",
    requesterPhone: "555-0100",
    requesterPhoneNumber: "555-0101",
    phone: "555-0102",
    windowStart: new Date("2026-07-26T20:00:00.000Z"),
    windowEnd: new Date("2026-07-26T21:00:00.000Z"),
    status: "open",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    claimToken: "raw-token",
    claimTokenHash: "hashed-token",
    claimTokenDigest: "digested-token",
    claimExpiresAt: new Date("2026-07-26T19:15:00.000Z"),
    claimedAt: new Date("2026-07-26T19:00:00.000Z"),
    claimExtendedAt: null,
    deleteAt: new Date("2026-07-26T22:00:00.000Z"),
    orderNumber: "private-order-number",
    eta: new Date("2026-07-26T20:30:00.000Z"),
    etaText: "30 minutes",
    placedAt: new Date("2026-07-26T20:15:00.000Z"),
    fulfillerEmail: "helper@example.edu",
    contactMessage: "private message",
    notificationAttemptedAt: new Date("2026-07-26T20:16:00.000Z"),
    note: "private note",
    notificationStatus: "pending_retry",
    __v: 0,
    ...overrides,
  };
}

describe("buildPublicRequestListResponse", () => {
  it("includes an available, unexpired request in the canonical wrapper", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument()],
      serverNow
    );

    expect(response).toEqual({
      requests: [
        {
          id: "request-1",
          vendor: "Campus Market",
          food: "Vegetable rice bowl",
          pickupWindowText: "1:00 PM – 2:00 PM",
          mealSwipes: 3,
          menuPath: "meal-exchange",
          mealItems: ["Vegetable rice bowl", "Side salad", "Iced tea"],
          orderDetails: null,
          estimatedDiningDollarsCents: null,
          windowStart: new Date("2026-07-26T20:00:00.000Z"),
          windowEnd: new Date("2026-07-26T21:00:00.000Z"),
          status: "open",
          createdAt: new Date("2026-07-26T18:00:00.000Z"),
          expiresAt: new Date("2026-07-26T22:00:00.000Z"),
        },
      ],
    });
  });

  it("excludes a placed request", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument({ status: "placed" })],
      serverNow
    );

    expect(response).toEqual({ requests: [] });
  });

  it("excludes an active claim completely", () => {
    const response = buildPublicRequestListResponse(
      [
        requestDocument({
          status: "claimed",
          claimExpiresAt: new Date("2026-07-26T19:00:00.001Z"),
        }),
      ],
      serverNow
    );

    expect(response).toEqual({ requests: [] });
  });

  it("advertises a claim expiring at backend now as open", () => {
    const response = buildPublicRequestListResponse(
      [
        requestDocument({
          status: "claimed",
          claimExpiresAt: serverNow,
        }),
      ],
      serverNow
    );

    expect(response.requests).toHaveLength(1);
    expect(response.requests[0].status).toBe("open");
  });

  it("advertises an expired claim as open without altering the record", () => {
    const document = requestDocument({
      status: "claimed",
      claimExpiresAt: new Date("2026-07-26T18:45:00.000Z"),
    });

    const response = buildPublicRequestListResponse([document], serverNow);

    expect(response.requests).toHaveLength(1);
    expect(response.requests[0].status).toBe("open");
    // The persisted record keeps its claimed lifecycle state: projection is
    // derived per response, never written back.
    expect(document.status).toBe("claimed");
    expect(document.claimExpiresAt).toEqual(
      new Date("2026-07-26T18:45:00.000Z")
    );
  });

  it("never advertises a status other than open", () => {
    const response = buildPublicRequestListResponse(
      [
        requestDocument({ _id: "open-request" }),
        requestDocument({
          _id: "expired-claim",
          status: "claimed",
          claimExpiresAt: new Date("2026-07-26T18:45:00.000Z"),
        }),
        requestDocument({
          _id: "active-claim",
          status: "claimed",
          claimExpiresAt: new Date("2026-07-26T19:30:00.000Z"),
        }),
        requestDocument({ _id: "placed-request", status: "placed" }),
      ],
      serverNow
    );

    expect(response.requests).toHaveLength(2);
    expect(
      response.requests.map((request) => request.status)
    ).toEqual(["open", "open"]);
  });

  it("excludes a request expired according to server time", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument({ expiresAt: serverNow })],
      serverNow
    );

    expect(response).toEqual({ requests: [] });
  });

  it("advertises an open request with exactly five minutes remaining", () => {
    // The last advertised instant is also the last claimable instant: the list
    // must not stop short of what POST /claim would still accept.
    const response = buildPublicRequestListResponse(
      [requestDocument({ expiresAt: exactlyClaimable })],
      serverNow
    );

    expect(response.requests).toHaveLength(1);
    expect(response.requests[0].status).toBe("open");
  });

  it("excludes a request with less than five full minutes remaining", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument({ expiresAt: justUnderClaimable })],
      serverNow
    );

    // Advertising it would promise help that claiming answers with
    // REQUEST_INSUFFICIENT_TIME.
    expect(response).toEqual({ requests: [] });
  });

  it("reopens an expired claim that still has five minutes left", () => {
    const document = requestDocument({
      status: "claimed",
      expiresAt: exactlyClaimable,
      claimExpiresAt: new Date("2026-07-26T18:45:00.000Z"),
    });

    const response = buildPublicRequestListResponse([document], serverNow);

    expect(response.requests).toHaveLength(1);
    expect(response.requests[0].status).toBe("open");
    expect(document.status).toBe("claimed");
  });

  it("does not reopen an expired claim with too little time left", () => {
    const document = requestDocument({
      status: "claimed",
      expiresAt: justUnderClaimable,
      claimExpiresAt: new Date("2026-07-26T18:45:00.000Z"),
    });

    const response = buildPublicRequestListResponse([document], serverNow);

    expect(response).toEqual({ requests: [] });
    expect(document.status).toBe("claimed");
    expect(document.claimExpiresAt).toEqual(
      new Date("2026-07-26T18:45:00.000Z")
    );
  });

  it("fails closed when an open document has no valid expiration", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument({ expiresAt: undefined })],
      serverNow
    );

    expect(response).toEqual({ requests: [] });
  });

  it("omits every requester-, claim-, fulfillment-, and database-private field", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument()],
      serverNow
    );
    const serializedRequest = JSON.parse(
      JSON.stringify(response.requests[0])
    ) as Record<string, unknown>;

    expect(Object.keys(response)).toEqual(["requests"]);
    expect(Object.keys(serializedRequest)).toEqual([
      "id",
      "vendor",
      "food",
      "pickupWindowText",
      "mealSwipes",
      "menuPath",
      "mealItems",
      "orderDetails",
      "estimatedDiningDollarsCents",
      "windowStart",
      "windowEnd",
      "status",
      "createdAt",
      "expiresAt",
    ]);
    expect(serializedRequest).not.toHaveProperty("email");
    expect(serializedRequest).not.toHaveProperty("requesterPhone");
    expect(serializedRequest).not.toHaveProperty("requesterPhoneNumber");
    expect(serializedRequest).not.toHaveProperty("phone");
    expect(serializedRequest).not.toHaveProperty("pickupName");
    expect(serializedRequest).not.toHaveProperty("claimToken");
    expect(serializedRequest).not.toHaveProperty("claimTokenHash");
    expect(serializedRequest).not.toHaveProperty("claimTokenDigest");
    expect(serializedRequest).not.toHaveProperty("claimExpiresAt");
    expect(serializedRequest).not.toHaveProperty("claimedAt");
    expect(serializedRequest).not.toHaveProperty("claimExtendedAt");
    expect(serializedRequest).not.toHaveProperty("deleteAt");
    expect(serializedRequest).not.toHaveProperty("orderNumber");
    expect(serializedRequest).not.toHaveProperty("eta");
    expect(serializedRequest).not.toHaveProperty("etaText");
    expect(serializedRequest).not.toHaveProperty("placedAt");
    expect(serializedRequest).not.toHaveProperty("fulfillerEmail");
    expect(serializedRequest).not.toHaveProperty("contactMessage");
    expect(serializedRequest).not.toHaveProperty("notificationAttemptedAt");
    expect(serializedRequest).not.toHaveProperty("note");
    expect(serializedRequest).not.toHaveProperty("notificationStatus");
    expect(serializedRequest).not.toHaveProperty("_id");
    expect(serializedRequest).not.toHaveProperty("__v");
  });

  describe("W4-H2 participant-scoped ownership projection", () => {
    const resolved = (participantId: string) =>
      ({ kind: "resolved", participantId }) as const;

    it("states isOwnRequest: true for the caller's own request", () => {
      const response = buildPublicRequestListResponse(
        [requestDocument({ requesterParticipantId: "caller-1" })],
        serverNow,
        resolved("caller-1")
      );

      expect(response.requests[0].isOwnRequest).toBe(true);
    });

    // A resolved caller can be told either way. Omitting the field here would
    // make "definitely not yours" indistinguishable from "ownership unknown",
    // which is exactly what let an unusable credential read as permission.
    it("states isOwnRequest: false for another verified participant's request", () => {
      const response = buildPublicRequestListResponse(
        [requestDocument({ requesterParticipantId: "someone-else" })],
        serverNow,
        resolved("caller-1")
      );

      expect(response.requests[0].isOwnRequest).toBe(false);
    });

    it("states isOwnRequest: false when a resolved caller's request carries no binding", () => {
      const response = buildPublicRequestListResponse(
        [requestDocument({ requesterParticipantId: undefined })],
        serverNow,
        resolved("caller-1")
      );

      expect(response.requests[0].isOwnRequest).toBe(false);
    });

    it("omits isOwnRequest for an anonymous caller", () => {
      const response = buildPublicRequestListResponse(
        [requestDocument({ requesterParticipantId: "caller-1" })],
        serverNow,
        { kind: "anonymous" }
      );

      expect(response.requests[0]).not.toHaveProperty("isOwnRequest");
    });

    // A credential was presented and could not be resolved. Ownership is
    // genuinely unknown, so the wire must say nothing rather than "false".
    it("omits isOwnRequest when the presented authority could not be resolved", () => {
      const response = buildPublicRequestListResponse(
        [requestDocument({ requesterParticipantId: "caller-1" })],
        serverNow,
        { kind: "unresolved" }
      );

      expect(response.requests[0]).not.toHaveProperty("isOwnRequest");
    });

    it("never leaks the raw requesterParticipantId onto the wire response", () => {
      const response = buildPublicRequestListResponse(
        [requestDocument({ requesterParticipantId: "caller-1" })],
        serverNow,
        resolved("caller-1")
      );

      expect(response.requests[0]).not.toHaveProperty(
        "requesterParticipantId"
      );
      expect(JSON.stringify(response)).not.toContain("caller-1");
    });

    it("distinguishes ownership per request within the same response", () => {
      const response = buildPublicRequestListResponse(
        [
          requestDocument({
            _id: "request-1",
            requesterParticipantId: "caller-1",
          }),
          requestDocument({
            _id: "request-2",
            requesterParticipantId: "someone-else",
            windowStart: null,
            windowEnd: null,
          }),
        ],
        serverNow,
        resolved("caller-1")
      );

      expect(response.requests.find((r) => r.id === "request-1")?.isOwnRequest).toBe(
        true
      );
      expect(response.requests.find((r) => r.id === "request-2")?.isOwnRequest).toBe(
        false
      );
    });
  });
});

describe("buildPublicRequestDetailResponse", () => {
  it("reports the persisted status when it is effectively available", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument({ status: "open" }) as never,
      serverNow
    );

    expect(response.request.status).toBe("open");
  });

  it("reports a claim-expired request as effectively open", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument({
        status: "claimed",
        claimExpiresAt: new Date(serverNow.getTime() - 1),
      }) as never,
      serverNow
    );

    expect(response.request.status).toBe("open");
  });

  it("keeps a claimed request with an unexpired claim as claimed", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument({
        status: "claimed",
        claimExpiresAt: new Date(serverNow.getTime() + 1),
      }) as never,
      serverNow
    );

    expect(response.request.status).toBe("claimed");
  });

  it("reports a placed request as placed regardless of expiration", () => {
    const response = buildPublicRequestDetailResponse(
      requestDocument({
        status: "placed",
        expiresAt: new Date("2020-01-01T00:00:00.000Z"),
      }) as never,
      serverNow
    );

    expect(response.request.status).toBe("placed");
  });
});
