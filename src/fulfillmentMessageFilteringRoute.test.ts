import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { generateClaimToken } from "./claimToken.js";
import {
  Fulfillment,
  Participant,
  ParticipantIdentityKeyVersion,
  PlacementEvidence,
  Request as MealRequest,
} from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  BLOCK_SAFETY_HMAC_KEYRING_ENV,
  PARTICIPATION_HMAC_KEYRING_ENV,
} from "./participantIdentityKeys.js";

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import { fulfillRequest } from "./fulfillmentRoute.js";

/**
 * W4-U1.1 helper Message boundary at the fulfillment route (unit level).
 *
 * The Message is filtered after authority/payload validation and before the
 * durable placement mutation. A match is a SUCCESSFUL placement, not a refusal:
 * placement commits exactly once, the Message is neither stored nor emailed,
 * and only a content-free suppression marker is written — in the same atomic
 * conditional update that commits placement. An allowed Message is transient:
 * it reaches the immediate requester email attempt and is never persisted.
 */

const requestId = "64b000000000000000000001";
const helperParticipantId = new mongoose.Types.ObjectId("64c0000000000000000000b2");
const boundHelperEmail = "helper@nyu.edu";
const participationKey = Buffer.alloc(32, 0x31);
const blockSafetyKey = Buffer.alloc(32, 0x52);
const participantSecretText = "participant-message-filter-unit-test-secret";
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  Buffer.from(participantSecretText)
);
const placedAt = new Date("2026-08-01T12:00:00.000Z");

/** Distinctive on purpose, so any leak into a log/response/write is detectable. */
const BLOCKED_MESSAGE = "Thanks, you stupid bitch";
const ALLOWED_MESSAGE = "I'll shoot you a text when I'm at the front door";

// Smallest well-formed 1x1 PNG. W4-H1a makes a valid placed-order screenshot
// part of every new fulfillment; evidence validity is independent of the Message
// filter, so every case here carries one.
const ONE_PIXEL_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

function fulfillment(contactMessage?: string) {
  return {
    orderNumber: "70154321",
    eta: "15 minutes",
    placedOrderScreenshot: {
      mimeType: "image/png",
      imageBase64: ONE_PIXEL_PNG_BASE64,
    },
    ...(contactMessage === undefined ? {} : { contactMessage }),
  };
}

function tokenBody(contactMessage?: string) {
  return { claimToken: generateClaimToken(), fulfillment: fulfillment(contactMessage) };
}

function routeContext(
  body: unknown,
  headers: Record<string, string> = {}
) {
  const req = { params: { id: requestId }, body, headers } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

function stubVerifiedParticipant() {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi
          .fn()
          .mockResolvedValue({ _id: helperParticipantId, email: boundHelperEmail }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

function stubBoundHelper() {
  vi.spyOn(MealRequest, "findById").mockImplementation(
    (() => ({
      select: (projection: string) => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue(
            projection === "+requesterParticipantId +helperParticipantId"
              ? { requesterParticipantId: null, helperParticipantId }
              : { helperParticipantId }
          ),
        }),
      }),
    })) as unknown as typeof MealRequest.findById
  );
  vi.spyOn(Participant, "findById").mockReturnValue({
    select: () => ({
      session: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue({
            _id: helperParticipantId,
            email: boundHelperEmail,
            authorityVersion: 1,
          }),
        }),
      }),
      lean: () => ({
        exec: vi.fn().mockResolvedValue({
          _id: helperParticipantId,
          email: boundHelperEmail,
          authorityVersion: 1,
        }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findById>);
  vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);
}

function stubCommittedPlacement() {
  const placed = {
    _id: new mongoose.Types.ObjectId(requestId),
    status: "placed",
    vendor: "Palladium",
    food: "Vegetable rice bowl",
    pickupWindowText: "ASAP",
    windowStart: null,
    windowEnd: null,
    createdAt: placedAt,
    expiresAt: new Date(placedAt.getTime() + 3 * 60 * 60 * 1000),
    placedAt,
  };
  const findOneAndUpdate = vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
    select: () => ({ exec: vi.fn().mockResolvedValue(placed) }),
  } as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>);
  const ledger = vi.spyOn(Fulfillment, "create").mockResolvedValue([{}] as never);
  const evidence = vi.spyOn(PlacementEvidence, "create").mockResolvedValue([{}] as never);
  const recordOutcome = vi.spyOn(MealRequest, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({}),
  } as unknown as ReturnType<typeof MealRequest.updateOne>);
  const startSession = vi.spyOn(mongoose, "startSession").mockResolvedValue({
    withTransaction: vi.fn(async (work: () => Promise<void>) => {
      await work();
    }),
    endSession: vi.fn().mockResolvedValue(undefined),
  } as never);
  return { findOneAndUpdate, ledger, evidence, recordOutcome, startSession };
}

let consoleError: ReturnType<typeof vi.spyOn>;
let consoleInfo: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "unit-test-claim-hmac-secret-material");
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
  vi.stubEnv(
    PARTICIPATION_HMAC_KEYRING_ENV,
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": participationKey.toString("base64") },
    })
  );
  vi.stubEnv(
    BLOCK_SAFETY_HMAC_KEYRING_ENV,
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": blockSafetyKey.toString("base64") },
    })
  );
  vi.spyOn(ParticipantIdentityKeyVersion, "find").mockImplementation(
    ((filter: { purpose: string }) => {
      const rows = [
        {
          purpose: filter.purpose,
          version: 1,
          normalizationVersion: 1,
        },
      ];
      const chain = {
        maxTimeMS: () => chain,
        select: () => chain,
        session: () => chain,
        lean: () => chain,
        exec: vi.fn().mockResolvedValue(rows),
      };
      return chain as never;
    }) as never
  );
  stubBoundHelper();
  stubVerifiedParticipant();
  sendFulfillmentEmail.mockReset();
  sendFulfillmentEmail.mockResolvedValue(undefined);
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
  consoleInfo = vi.spyOn(console, "info").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("allowed helper Message is transient", () => {
  it("emails the Message but never writes it to the Request or the Fulfillment ledger", async () => {
    const { findOneAndUpdate, ledger } = stubCommittedPlacement();
    const context = routeContext(tokenBody(ALLOWED_MESSAGE));

    await fulfillRequest(context.req, context.res);

    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.anything(),
      "70154321",
      "15 minutes",
      ALLOWED_MESSAGE,
      boundHelperEmail
    );

    const [, update] = findOneAndUpdate.mock.calls[0] as any[];
    expect(update.$set).not.toHaveProperty("contactMessage");
    expect(update.$set).not.toHaveProperty("contactMessageSuppressed");
    expect(update.$unset).not.toHaveProperty("contactMessage");
    expect(JSON.stringify(update)).not.toContain(ALLOWED_MESSAGE);
    expect(JSON.stringify(ledger.mock.calls)).not.toContain(ALLOWED_MESSAGE);

    const body = responseBody(context);
    expect(body).not.toHaveProperty("messageSuppressed");
    expect(JSON.stringify(body)).not.toContain(ALLOWED_MESSAGE);
    expect(body.notification).toEqual({ status: "sent" });
  });

  it("never persists or suppresses when no Message was submitted", async () => {
    const { findOneAndUpdate } = stubCommittedPlacement();
    const context = routeContext(tokenBody());

    await fulfillRequest(context.req, context.res);

    const [, update] = findOneAndUpdate.mock.calls[0] as any[];
    expect(update.$set).not.toHaveProperty("contactMessage");
    expect(update.$set).not.toHaveProperty("contactMessageSuppressed");
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.anything(),
      "70154321",
      "15 minutes",
      undefined,
      boundHelperEmail
    );
    expect(responseBody(context)).not.toHaveProperty("messageSuppressed");
  });

  it("treats a whitespace-only Message as no Message, not as suppressed", async () => {
    const { findOneAndUpdate } = stubCommittedPlacement();
    const context = routeContext(tokenBody("   \n  "));

    await fulfillRequest(context.req, context.res);

    const [, update] = findOneAndUpdate.mock.calls[0] as any[];
    expect(update.$set).not.toHaveProperty("contactMessageSuppressed");
    expect(responseBody(context)).not.toHaveProperty("messageSuppressed");
  });
});

describe("blocked helper Message is a successful placement with the Message suppressed", () => {
  it("commits placement exactly once and returns normal success plus the private suppression signal", async () => {
    const { findOneAndUpdate, ledger, startSession } = stubCommittedPlacement();
    const context = routeContext(tokenBody(BLOCKED_MESSAGE));

    await fulfillRequest(context.req, context.res);

    // Not a refusal: no error status, one transaction, one conditional update,
    // one ledger row.
    expect(context.status).not.toHaveBeenCalled();
    expect(startSession).toHaveBeenCalledOnce();
    expect(findOneAndUpdate).toHaveBeenCalledOnce();
    expect(ledger).toHaveBeenCalledOnce();

    const body = responseBody(context);
    expect(body.request).toEqual(expect.objectContaining({ id: requestId, status: "placed" }));
    expect(body.notification).toEqual({ status: "sent" });
    expect(body.messageSuppressed).toBe(true);
  });

  it("writes only the content-free marker, atomically in the placement update itself", async () => {
    const { findOneAndUpdate, ledger } = stubCommittedPlacement();
    const context = routeContext(tokenBody(BLOCKED_MESSAGE));

    await fulfillRequest(context.req, context.res);

    const [filter, update] = findOneAndUpdate.mock.calls[0] as any[];
    // The marker rides the same conditional update that sets `status: placed`,
    // so it cannot disagree with committed placement.
    expect(update.$set.status).toBe("placed");
    expect(update.$set.contactMessageSuppressed).toBe(true);
    expect(filter.status).toBe("claimed");
    // No Message text anywhere in any durable write.
    expect(update.$set).not.toHaveProperty("contactMessage");
    expect(JSON.stringify(update)).not.toMatch(/stupid|bitch|Thanks/i);
    expect(JSON.stringify(ledger.mock.calls)).not.toMatch(/stupid|bitch|Thanks/i);
  });

  it("sends the normal requester email without the blocked Message", async () => {
    stubCommittedPlacement();
    const context = routeContext(tokenBody(BLOCKED_MESSAGE));

    await fulfillRequest(context.req, context.res);

    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.anything(),
      "70154321",
      "15 minutes",
      undefined,
      boundHelperEmail
    );
    expect(JSON.stringify(sendFulfillmentEmail.mock.calls)).not.toMatch(/stupid|bitch/i);
  });

  it("never echoes, logs, or exposes the blocked text or term", async () => {
    stubCommittedPlacement();
    const context = routeContext(tokenBody(BLOCKED_MESSAGE));

    await fulfillRequest(context.req, context.res);

    expect(JSON.stringify(responseBody(context))).not.toMatch(/stupid|bitch|Thanks/i);
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(/stupid|bitch|Thanks/i);
    expect(JSON.stringify(consoleInfo.mock.calls)).not.toMatch(/stupid|bitch|Thanks/i);
  });

  it("a requester-email failure cannot undo placement or the suppression signal", async () => {
    stubCommittedPlacement();
    sendFulfillmentEmail.mockRejectedValue(new Error("provider unavailable"));
    const context = routeContext(tokenBody(BLOCKED_MESSAGE));

    await fulfillRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    const body = responseBody(context);
    expect(body.request.status).toBe("placed");
    expect(body.notification).toEqual({ status: "failed" });
    expect(body.messageSuppressed).toBe(true);
  });

  it("applies equally on the participant-authority continuation path", async () => {
    const { findOneAndUpdate } = stubCommittedPlacement();
    const context = routeContext(
      { fulfillment: fulfillment(BLOCKED_MESSAGE) },
      { [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority }
    );

    await fulfillRequest(context.req, context.res);

    const [, update] = findOneAndUpdate.mock.calls[0] as any[];
    expect(update.$set.contactMessageSuppressed).toBe(true);
    expect(responseBody(context).messageSuppressed).toBe(true);
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.anything(),
      "70154321",
      "15 minutes",
      undefined,
      boundHelperEmail
    );
  });
});

describe("stale clients still receive truthful placement success", () => {
  it("a pre-I1 app build (legacy fulfillerEmail wire key) with a blocked Message gets a normal 200 placement, not a failure", async () => {
    const { findOneAndUpdate } = stubCommittedPlacement();
    // The wire shape an app build that predates W3-I1 actually sends: the
    // tolerated-and-discarded `fulfillerEmail` key beside the other fields.
    const context = routeContext({
      claimToken: generateClaimToken(),
      fulfillment: {
        fulfillerEmail: "stale-build-helper@example.edu",
        orderNumber: "70154321",
        eta: "15 minutes",
        contactMessage: BLOCKED_MESSAGE,
        placedOrderScreenshot: {
          mimeType: "image/png",
          imageBase64: ONE_PIXEL_PNG_BASE64,
        },
      },
    });

    await fulfillRequest(context.req, context.res);

    // Never an error status for a committed placement, whatever the client's age.
    expect(context.status).not.toHaveBeenCalled();
    const body = responseBody(context);
    expect(body.request).toEqual(expect.objectContaining({ id: requestId, status: "placed" }));
    expect(body.notification).toEqual({ status: "sent" });
    // The extra, additive key is the only difference from the old success shape;
    // a client that does not know it simply ignores it.
    expect(Object.keys(body).sort()).toEqual(["messageSuppressed", "notification", "request"]);
    const [, update] = findOneAndUpdate.mock.calls[0] as any[];
    expect(update.$set.contactMessageSuppressed).toBe(true);
    expect(JSON.stringify(update)).not.toMatch(/stupid|bitch|stale-build-helper/i);
    expect(sendFulfillmentEmail.mock.calls[0][3]).toBeUndefined();
  });

  it("a normal placement keeps the exact pre-U1.1 two-key success shape", async () => {
    stubCommittedPlacement();
    const context = routeContext(tokenBody(ALLOWED_MESSAGE));

    await fulfillRequest(context.req, context.res);

    expect(Object.keys(responseBody(context)).sort()).toEqual(["notification", "request"]);
  });
});

describe("filter ordering relative to authority and payload validation", () => {
  it("an unauthenticated continuation learns nothing about its Message before authority is checked", async () => {
    const { startSession } = stubCommittedPlacement();
    const context = routeContext({ fulfillment: fulfillment(BLOCKED_MESSAGE) });

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(startSession).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    expect(JSON.stringify(responseBody(context))).not.toMatch(/suppress|stupid|bitch/i);
  });

  it("payload validation still wins: an invalid payload is refused whatever the Message says", async () => {
    const { startSession } = stubCommittedPlacement();
    const context = routeContext({
      claimToken: generateClaimToken(),
      fulfillment: { ...fulfillment(BLOCKED_MESSAGE), orderNumber: "not digits" },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_FULFILLMENT_PAYLOAD");
    expect(startSession).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("an ordinary conditional-placement failure keeps its classification and reports no suppression", async () => {
    vi.spyOn(MealRequest, "findById").mockImplementation(
      (() => ({
        select: (projection: string) => ({
          lean: () => ({
            exec: vi
              .fn()
              .mockResolvedValue(
                projection === "+helperParticipantId"
                  ? { helperParticipantId }
                  : { status: "placed" }
              ),
          }),
        }),
      })) as unknown as typeof MealRequest.findById
    );
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
      select: () => ({ exec: vi.fn().mockResolvedValue(null) }),
    } as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>);
    vi.spyOn(mongoose, "startSession").mockResolvedValue({
      withTransaction: vi.fn(async (work: () => Promise<void>) => {
        await work();
      }),
      endSession: vi.fn().mockResolvedValue(undefined),
    } as never);
    const context = routeContext(tokenBody(BLOCKED_MESSAGE));

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context).error.code).toBe("REQUEST_ALREADY_PLACED");
    expect(JSON.stringify(responseBody(context))).not.toMatch(/suppress|stupid|bitch/i);
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });
});
