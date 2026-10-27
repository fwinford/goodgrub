import express, { type Request, type Response } from "express";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import {
  Request as MealRequest,
  Participant,
  ParticipantBlock,
  ParticipantIdentityKeyVersion,
  RequestParticipation,
} from "../models/db.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_AUTHORITY_INVALID_CODE,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  CLAIM_DURATION_MS,
  CLAIM_EXTENSION_MS,
  CLAIM_UNAVAILABLE_MESSAGE,
  HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE,
  claimRequest,
  createDay4MutationRateLimiter,
  extendClaim,
  pauseDay4Mutation,
  releaseClaim,
} from "./claimRoute.js";
import {
  digestClaimToken,
  generateClaimToken,
} from "./claimToken.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  CLAIM_MINIMUM_REMAINING_MS,
  buildEffectiveAvailabilityFilter,
  isEffectivelyAvailable,
} from "./requestAvailability.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const now = new Date("2026-07-30T16:00:00.000Z");
const expiresAt = new Date("2026-07-30T17:00:00.000Z");
const secretText = "unit-test-claim-hmac-secret-material";
const secret = Buffer.from(secretText);

function document(overrides: Record<string, unknown> = {}) {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Private Pickup Name",
    pickupWindowText: "ASAP (available for the next 3 hours)",
    // Every request accepted since W3-C1 carries an integer quantity, on
    // every accepted shape including the legacy web one, so an ordinary
    // fixture always supplies it — now alongside the W4-R4 structured fields.
    // `pickupName` above is retained deliberately, as a stray pre-R4 stored
    // value neither the public projection nor the claim response may emit.
    mealSwipes: 4,
    menuPath: "meal-exchange",
    mealItems: ["Vegetable rice bowl", "Side salad", "Iced tea", "Cookie"],
    windowStart: null,
    windowEnd: null,
    status: "claimed",
    createdAt: new Date("2026-07-30T15:00:00.000Z"),
    expiresAt,
    deleteAt: expiresAt,
    claimedAt: now,
    claimExpiresAt: new Date(now.getTime() + CLAIM_DURATION_MS),
    claimExtendedAt: null,
    claimTokenDigest: "private-digest",
    email: "private@example.edu",
    ...overrides,
  };
}

/**
 * The verified helper every claim case in this file acts as (W3-I1).
 *
 * A real signed credential in the real header, resolved by the real gate
 * against a stubbed Participant row, so these suites prove the helper gate as
 * it runs rather than a stand-in for it.
 */
const helperParticipantId = new mongoose.Types.ObjectId(
  "64c0000000000000000000b2"
);
const helperPrincipal = "helper@nyu.edu";
let fencedPrincipal = helperPrincipal;
const participantSecretText = "participant-claim-route-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);
const participationKey = Buffer.alloc(32, 0x31);
const blockSafetyKey = Buffer.alloc(32, 0x52);

function stubIdentityManifest() {
  return vi.spyOn(ParticipantIdentityKeyVersion, "find").mockImplementation(
    ((filter: { purpose: string }) => {
      const query: any = {
        session: () => query,
        maxTimeMS: () => query,
        select: () => query,
        lean: () => query,
        exec: vi.fn().mockResolvedValue([
          {
            purpose: filter.purpose,
            version: 1,
            normalizationVersion: 1,
          },
        ]),
      };
      return query;
    }) as never
  );
}

function stubIdentityReads() {
  vi.stubEnv(
    "PARTICIPATION_HMAC_KEYRING",
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": participationKey.toString("base64") },
    })
  );
  vi.stubEnv(
    "BLOCK_SAFETY_HMAC_KEYRING",
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": blockSafetyKey.toString("base64") },
    })
  );
  stubIdentityManifest();
  vi.spyOn(RequestParticipation, "find").mockImplementation((() => {
    const query: any = {
      session: () => query,
      maxTimeMS: () => query,
      select: () => query,
      limit: () => query,
      lean: () => query,
      exec: vi.fn().mockResolvedValue([]),
    };
    return query;
  }) as never);
}

function stubAccountFenceReads() {
  vi.spyOn(Participant, "findById").mockImplementation(((id: unknown) => {
    const query: any = {
      select: () => query,
      session: () => query,
      lean: () => query,
      exec: vi.fn().mockResolvedValue({
        _id: id,
        authorityVersion: 1,
        email: fencedPrincipal,
      }),
    };
    return query;
  }) as never);
}

function stubVerifiedParticipant(email: string = helperPrincipal) {
  fencedPrincipal = email;
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({ _id: helperParticipantId, email }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

function routeContext(
  body: unknown = undefined,
  id = requestId.toString(),
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
  }
) {
  const req = { params: { id }, body, headers } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

/**
 * Chainable enough for every caller of `MealRequest.findOneAndUpdate` in
 * `claimRoute.ts`: `claimRequest` calls `.lean().exec()` directly, while
 * `extendClaim` and `releaseClaim` call `.select("+helperParticipantId")`
 * first (W3-H1 continuation). Both paths resolve to the same result.
 */
function atomicResultChain(exec: () => unknown) {
  const lean = () => ({ exec });
  return { select: () => ({ lean }), lean, exec };
}

function mockAtomicResult(result: unknown) {
  return vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue(
    atomicResultChain(
      vi.fn().mockResolvedValue(result)
    ) as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>
  );
}

function mockAtomicRejection(error: Error) {
  return vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue(
    atomicResultChain(
      vi.fn().mockRejectedValue(error)
    ) as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>
  );
}

function mockDiagnosticResult(result: unknown) {
  return vi.spyOn(MealRequest, "findById").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue(result),
      }),
    }),
  } as unknown as ReturnType<typeof MealRequest.findById>);
}

/**
 * Like `mockDiagnosticResult`, except each query execution resolves the
 * current value supplied by the caller. Transaction-retry tests use this to
 * model a read that would observe a concurrent writer's committed version.
 */
function mockDynamicDiagnosticResult(resolve: () => unknown) {
  return vi.spyOn(MealRequest, "findById").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockImplementation(async () => resolve()),
      }),
    }),
  } as unknown as ReturnType<typeof MealRequest.findById>);
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

/**
 * `claimRequest`, `extendClaim`, and `releaseClaim` are all transactional
 * (W3-H1): each opens a real `mongoose.startSession()` and runs its
 * conditional mutations inside `session.withTransaction`. This is the
 * default happy-path session double every test gets — it simply runs the
 * work once, like the equivalent double already established in
 * `fulfillmentRoute.test.ts` — so a test that cares only about the
 * `MealRequest` or `Participant` mutations does not also have to stand up
 * its own session.
 */
let sessionMock: {
  withTransaction: ReturnType<typeof vi.fn>;
  endSession: ReturnType<typeof vi.fn>;
};

function mockSession() {
  sessionMock = {
    withTransaction: vi.fn(async (work: () => Promise<void>) => {
      await work();
    }),
    endSession: vi.fn().mockResolvedValue(undefined),
  };
  vi.spyOn(mongoose, "startSession").mockResolvedValue(sessionMock as never);
  return sessionMock;
}

/**
 * The one-active-reservation lock step `claimRequest` runs inside its
 * transaction (W3-H1). Defaults to "lock acquired" so every existing claim
 * case, which is not itself testing this new behavior, is unaffected by it.
 */
function mockReservationLockResult(result: unknown) {
  return vi.spyOn(Participant, "findOneAndUpdate").mockReturnValue({
    exec: vi.fn().mockResolvedValue(result),
  } as unknown as ReturnType<typeof Participant.findOneAndUpdate>);
}

/**
 * The rollout-compatibility read `claimRequest` performs inside its
 * transaction before claiming (W3-H1): does this exact participant already
 * hold *any* other live claim, regardless of whether the Participant lock
 * was ever written for it. Defaults to "none found" so every existing claim
 * case, which is not itself testing this behavior, is unaffected by it.
 */
function mockExistingActiveReservation(result: unknown = null) {
  return vi.spyOn(MealRequest, "findOne").mockReturnValue({
    lean: () => ({
      exec: vi.fn().mockResolvedValue(result),
    }),
  } as unknown as ReturnType<typeof MealRequest.findOne>);
}

/**
 * The W3-H2 durable one-successful-participation pre-check `claimRequest`
 * performs inside its transaction before the conditional grant: has this
 * exact verified participant already successfully held this exact request.
 * Defaults to "none found" so every existing claim case, which is not itself
 * exercising this behavior, is unaffected by it.
 */
function mockExistingParticipation(result: unknown = null) {
  return vi.spyOn(RequestParticipation, "find").mockImplementation(
    ((filter: Record<string, any>) => {
      const hasParticipantLookup = filter.$or?.some(
        (part: Record<string, unknown>) => "participantId" in part
      );
      const query: any = {
        session: () => query,
        maxTimeMS: () => query,
        select: () => query,
        limit: () => query,
        lean: () => query,
        exec: vi.fn().mockResolvedValue(
          hasParticipantLookup && result ? [result] : []
        ),
      };
      return query;
    }) as never
  );
}

/**
 * The durable W3-H2 participation record `claimRequest` writes inside its
 * transaction immediately after a successful grant. Defaults to an ordinary
 * successful insert so every existing claim case is unaffected by it.
 */
function mockParticipationInsert(
  implementation: () => Promise<unknown> = () => Promise.resolve([{}])
) {
  return vi
    .spyOn(RequestParticipation, "create")
    .mockImplementation(implementation as never);
}

/**
 * The reservation-lock mirror/clear `extendClaim` and `releaseClaim` run
 * inside their transactions (W3-H1). Defaults to a harmless success so
 * cases not exercising this behavior directly are unaffected by it.
 */
function mockReservationLockMutation() {
  return vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1, modifiedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(now);
  vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", secretText);
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
  stubIdentityReads();
  stubAccountFenceReads();
  stubVerifiedParticipant();
  mockSession();
  mockReservationLockResult({ _id: helperParticipantId });
  mockReservationLockMutation();
  mockExistingActiveReservation();
  mockExistingParticipation();
  mockParticipationInsert();
  vi.spyOn(ParticipantBlock, "findOne").mockReturnValue({
    lean: () => ({ exec: vi.fn().mockResolvedValue(null) }),
  } as unknown as ReturnType<typeof ParticipantBlock.findOne>);
  // Release captures this Request version once before entering its
  // transaction; failure-classification cases override the same read with
  // the state they need to explain.
  mockDiagnosticResult(document());
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("POST /api/request/:id/claim", () => {
  it("claims with one conditional atomic update and returns private data only in claim", async () => {
    const claimed = document();
    const atomic = mockAtomicResult(claimed);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(atomic).toHaveBeenCalledOnce();
    const [filter, update, options] = atomic.mock.calls[0] as any[];
    expect(filter).toEqual({
      _id: requestId.toString(),
      status: { $ne: "placed" },
      // The same start-of-visibility clause the list and alert paths apply, so
      // a scheduled request cannot be claimed before helpers can see it.
      visibleFrom: { $not: { $gt: now } },
      expiresAt: {
        $gt: now,
        $gte: new Date(now.getTime() + 5 * 60 * 1000),
      },
      // W4-U1.3: a request with the post-Yes external-order-risk authority is
      // never claimable, inside the same conditional mutation that grants.
      externalOrderAffirmed: { $ne: true },
      // W4-U1.2 (boundary contract EO): M and L make a request unclaimable
      // the same way, in the same conditional mutation.
      moderationUnavailable: { $ne: true },
      reservationLapseHold: { $ne: true },
      $or: [
        { status: "open" },
        { status: "claimed", claimExpiresAt: { $lte: now } },
      ],
    });
    expect(options).toEqual({ new: true, session: sessionMock });
    expect(update[0].$set).toMatchObject({
      status: "claimed",
      claimedAt: now,
      claimExtendedAt: null,
      updatedAt: now,
    });
    // The reservation and the verified helper it belongs to are written by the
    // same conditional mutation, so a claim never exists unbound (W3-I1).
    expect(update[0].$set.helperParticipantId).toEqual(helperParticipantId);
    expect(update[0].$set.claimExpiresAt).toEqual({
      $min: [
        new Date(now.getTime() + CLAIM_DURATION_MS),
        "$expiresAt",
      ],
    });
    expect(update[0].$set.claimTokenDigest).toMatch(/^[a-f0-9]{64}$/);

    const body = responseBody(context);
    expect(body.request).toEqual({
      id: requestId.toString(),
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP (available for the next 3 hours)",
      mealSwipes: 4,
      menuPath: "meal-exchange",
      mealItems: ["Vegetable rice bowl", "Side salad", "Iced tea", "Cookie"],
      orderDetails: null,
      estimatedDiningDollarsCents: null,
      windowStart: null,
      windowEnd: null,
      status: "claimed",
      createdAt: new Date("2026-07-30T15:00:00.000Z"),
      expiresAt,
    });
    // W4-R4: `pickupName` is gone from the V1 request contract, so the
    // claimant-private half carries only the claim authorization itself. A
    // stray stored value on a pre-R4 document must not reappear here either.
    expect(body.claim).not.toHaveProperty("pickupName");
    expect(JSON.stringify(body.claim)).not.toMatch(/Private Pickup/);
    expect(body.claim.claimToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(body.claim.claimExpiresAt).toEqual(claimed.claimExpiresAt);
    expect(update[0].$set.claimTokenDigest).toBe(
      digestClaimToken(body.claim.claimToken, secret)
    );
    expect(JSON.stringify(body.request)).not.toMatch(
      /pickupName|email|deleteAt|claimedAt|claimExtendedAt|claimTokenDigest/
    );
  });

  it("gates claiming on the same rule that gates advertising", async () => {
    // Both sides read the identical clause from the shared helper, so a request
    // can never be advertised in a window where claiming must refuse it.
    const atomic = mockAtomicResult(document());
    const context = routeContext();

    await claimRequest(context.req, context.res);

    const [filter] = atomic.mock.calls[0] as any[];
    expect(filter.expiresAt).toEqual(
      buildEffectiveAvailabilityFilter(now).expiresAt
    );
    expect(filter.$or).toEqual(buildEffectiveAvailabilityFilter(now).$or);

    const exactMinimum = new Date(
      now.getTime() + CLAIM_MINIMUM_REMAINING_MS
    );
    expect(filter.expiresAt.$gte).toEqual(exactMinimum);
    expect(
      isEffectivelyAvailable({ status: "open", expiresAt: exactMinimum }, now)
    ).toBe(true);
    expect(
      isEffectivelyAvailable(
        { status: "open", expiresAt: new Date(exactMinimum.getTime() - 1) },
        now
      )
    ).toBe(false);
  });

  it("returns the locked conflict and no claimant data when an active claim wins first", async () => {
    mockAtomicResult(null);
    mockDiagnosticResult(
      document({
        claimTokenDigest: "f".repeat(64),
      })
    );
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context)).toEqual({
      error: {
        code: "REQUEST_ALREADY_CLAIMED",
        message: "Someone else just started helping with this request.",
        fields: null,
      },
    });
    expect(JSON.stringify(responseBody(context))).not.toMatch(
      /pickupName|claimToken|Private Pickup/
    );
  });

  it.each([
    {
      name: "not found",
      diagnostic: null,
      status: 404,
      code: "REQUEST_NOT_FOUND",
    },
    {
      name: "already placed",
      diagnostic: document({ status: "placed" }),
      status: 409,
      code: "REQUEST_ALREADY_PLACED",
    },
    {
      name: "expired",
      diagnostic: document({
        status: "open",
        expiresAt: now,
      }),
      status: 410,
      code: "REQUEST_EXPIRED",
    },
    {
      name: "under five minutes",
      diagnostic: document({
        status: "open",
        expiresAt: new Date(now.getTime() + 5 * 60 * 1000 - 1),
      }),
      status: 409,
      code: "REQUEST_INSUFFICIENT_TIME",
    },
    {
      // Classified ahead of expiration, and deliberately its own code: this
      // request has not run out, it has not started. A legacy row with no
      // recorded start is unaffected — it has always been visible.
      name: "not started yet",
      diagnostic: document({
        status: "open",
        visibleFrom: new Date(now.getTime() + 1),
        expiresAt: new Date(now.getTime() + 3 * 60 * 60 * 1000),
      }),
      status: 409,
      code: "REQUEST_NOT_YET_AVAILABLE",
    },
  ])("distinguishes $name after the atomic update loses", async (scenario) => {
    mockAtomicResult(null);
    mockDiagnosticResult(scenario.diagnostic);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(scenario.status);
    expect(responseBody(context).error).toMatchObject({
      code: scenario.code,
      fields: null,
    });
  });

  it("rejects an invalid ID before token generation or database access", async () => {
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const context = routeContext(undefined, "not-an-id");

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_REQUEST_ID");
    expect(atomic).not.toHaveBeenCalled();
  });

  it("fails safely when the HMAC secret is missing", async () => {
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "");
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context).error.code).toBe("INTERNAL_FAILURE");
    expect(atomic).not.toHaveBeenCalled();
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(
      /secret-material|claimTokenDigest/
    );
  });

  it("returns structured INTERNAL_FAILURE when the atomic execution rejects", async () => {
    // A rejected driver operation does not prove no claim was written: MongoDB
    // may have applied the conditional mutation before its acknowledgement was
    // lost. The route deliberately preserves its structured error envelope.
    const atomic = mockAtomicRejection(new Error("acknowledgement lost"));
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(atomic).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context)).toEqual({
      error: {
        code: "INTERNAL_FAILURE",
        message: "Unable to claim this request right now.",
        fields: null,
      },
    });
    expect(consoleError).toHaveBeenCalledOnce();
  });
});

describe("POST /api/request/:id/claim helper gate (W3-I1)", () => {
  /**
   * Browsing stays open to anyone; reserving does not. A reservation takes a
   * real student's meal out of every other helper's reach and commits a person
   * to placing an order, so it is a participant action.
   */
  it("refuses a helper with no participant credential and reserves nothing", async () => {
    const atomic = mockAtomicResult(document());
    const context = routeContext(undefined, requestId.toString(), {});

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_VERIFICATION_REQUIRED_CODE
    );
    // Ahead of token generation and the conditional mutation: nothing is
    // reserved, and no claim token is minted for a caller who proved nothing.
    expect(atomic).not.toHaveBeenCalled();
  });

  it("refuses a credential whose participant no longer exists", async () => {
    const atomic = mockAtomicResult(document());
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
    } as unknown as ReturnType<typeof Participant.findOne>);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_AUTHORITY_INVALID_CODE
    );
    expect(atomic).not.toHaveBeenCalled();
  });

  it("refuses a credential signed at a revoked authority version", async () => {
    // The stub answers only for version 1, so a version-2 credential fails the
    // database check even though its signature is genuine. Revocation is the
    // one lever that invalidates a credential already on a device.
    const atomic = mockAtomicResult(document());
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
    } as unknown as ReturnType<typeof Participant.findOne>);
    const context = routeContext(undefined, requestId.toString(), {
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
        helperParticipantId,
        2,
        participantSecret
      ),
    });

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(atomic).not.toHaveBeenCalled();
  });

  it("answers 503 and reserves nothing when the gate itself cannot decide", async () => {
    const atomic = mockAtomicResult(document());
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, "");
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(atomic).not.toHaveBeenCalled();
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      participantSecretText
    );
  });

  it("rebinds the reservation to whoever wins a re-claim after expiry", async () => {
    // A lapsed reservation is claimable again, and the new holder is the new
    // bound helper — not whoever held it before.
    const otherParticipantId = new mongoose.Types.ObjectId(
      "64c0000000000000000000c3"
    );
    stubVerifiedParticipant("other-helper@nyu.edu");
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue({
            _id: otherParticipantId,
            email: "other-helper@nyu.edu",
          }),
        }),
      }),
    } as unknown as ReturnType<typeof Participant.findOne>);
    const atomic = mockAtomicResult(document());
    const context = routeContext(undefined, requestId.toString(), {
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
        otherParticipantId,
        1,
        participantSecret
      ),
    });

    await claimRequest(context.req, context.res);

    const [, update] = atomic.mock.calls[0] as any[];
    expect(update[0].$set.helperParticipantId).toEqual(otherParticipantId);
  });

  it("keeps the participant credential out of the claim response", async () => {
    mockAtomicResult(document());
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(JSON.stringify(responseBody(context))).not.toContain(
      participantAuthority
    );
    expect(JSON.stringify(responseBody(context))).not.toContain(
      helperParticipantId.toString()
    );
    // Participant identity is not public request data, so the helper's own
    // address must not appear either.
    expect(JSON.stringify(responseBody(context))).not.toContain(helperPrincipal);
  });
});

describe("POST /api/request/:id/claim one-active-reservation lock (W3-H1)", () => {
  it("locks the verified helper to this reservation in the same transaction", async () => {
    const claimed = document();
    mockAtomicResult(claimed);
    const lock = mockReservationLockResult({ _id: helperParticipantId });
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(lock).toHaveBeenCalledWith(
      {
        _id: helperParticipantId,
        suspended: { $ne: true },
        authorityVersion: 1,
        $or: [
          { activeReservationRequestId: null },
          { activeReservationClaimExpiresAt: { $lte: now } },
        ],
      },
      {
        $set: {
          activeReservationRequestId: claimed._id,
          activeReservationClaimExpiresAt: claimed.claimExpiresAt,
        },
      },
      { session: sessionMock }
    );
    expect(context.status).not.toHaveBeenCalled();
  });

  it("refuses a second reservation for a helper who already holds one elsewhere", async () => {
    mockAtomicResult(document());
    mockReservationLockResult(null);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context).error).toMatchObject({
      code: HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE,
      fields: null,
    });
    // The transaction rolled back: the target request must not end up
    // claimed for a helper who was refused the reservation.
    expect(sessionMock.withTransaction).toHaveBeenCalledOnce();
  });

  describe("rollout compatibility for pre-H1 active claims", () => {
    // A claim granted before the Participant lock existed never wrote
    // `activeReservationRequestId` — the row reads exactly as if the
    // participant had never claimed anything, even though a real Request is
    // still bound to them (`helperParticipantId`, `status: "claimed"`,
    // unexpired). The lock-only check alone cannot see this; the direct
    // read must.
    it("refuses a new claim when the participant already holds a live pre-H1-bound request", async () => {
      const existingRequestId = new mongoose.Types.ObjectId(
        "64b0000000000000000000aa"
      );
      const existingReservationRead = mockExistingActiveReservation({
        _id: existingRequestId,
      });
      const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
      const context = routeContext();

      await claimRequest(context.req, context.res);

      expect(existingReservationRead).toHaveBeenCalledWith(
        {
          helperParticipantId,
          status: "claimed",
          claimExpiresAt: { $gt: now },
        },
        { _id: 1 },
        { session: sessionMock }
      );
      // Refused before ever attempting to claim the new target — the
      // existing reservation is truth enough on its own.
      expect(atomic).not.toHaveBeenCalled();
      expect(context.status).toHaveBeenCalledWith(409);
      expect(responseBody(context).error).toMatchObject({
        code: HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE,
        fields: null,
      });
    });

    it("still allows a claim when the participant's only prior reservation has expired", async () => {
      // An expired pre-H1-bound request is not "live" by the same
      // `claimExpiresAt: { $gt: now }` rule every other lapsed reservation
      // is judged by, so the direct read correctly finds nothing and the new
      // claim proceeds exactly as the ordinary lock-free path already does.
      mockExistingActiveReservation(null);
      const claimed = document();
      mockAtomicResult(claimed);
      const context = routeContext();

      await claimRequest(context.req, context.res);

      expect(context.status).not.toHaveBeenCalled();
    });
  });
});

describe("POST /api/request/:id/claim/extend", () => {
  it("extends once with one conditional atomic update and returns only timestamps", async () => {
    const rawToken = generateClaimToken();
    const originalClaimExpiration = new Date(
      now.getTime() + CLAIM_DURATION_MS
    );
    const extended = document({
      claimExpiresAt: new Date(
        originalClaimExpiration.getTime() + CLAIM_EXTENSION_MS
      ),
      claimExtendedAt: now,
    });
    const atomic = mockAtomicResult(extended);
    const context = routeContext({ claimToken: rawToken });

    await extendClaim(context.req, context.res);

    const submittedDigest = digestClaimToken(rawToken, secret);
    expect(atomic).toHaveBeenCalledWith(
      {
        _id: requestId.toString(),
        status: "claimed",
        claimTokenDigest: submittedDigest,
        claimExpiresAt: { $gt: now },
        claimExtendedAt: null,
        $expr: {
          $lte: [
            { $add: ["$claimExpiresAt", CLAIM_EXTENSION_MS] },
            "$expiresAt",
          ],
        },
      },
      [
        {
          $set: {
            claimExpiresAt: {
              $add: ["$claimExpiresAt", CLAIM_EXTENSION_MS],
            },
            claimExtendedAt: now,
            updatedAt: now,
          },
        },
      ],
      { new: true, session: sessionMock }
    );
    expect(responseBody(context)).toEqual({
      claim: {
        claimExpiresAt: extended.claimExpiresAt,
        claimExtendedAt: now,
      },
    });
    expect(JSON.stringify(responseBody(context))).not.toMatch(
      /claimToken|pickupName|vendor|request/
    );
  });

  it.each([
    {
      name: "request not found",
      diagnostic: (_digest: string) => null,
      status: 404,
      code: "REQUEST_NOT_FOUND",
    },
    {
      name: "placed request",
      diagnostic: (digest: string) =>
        document({ status: "placed", claimTokenDigest: digest }),
      status: 409,
      code: "REQUEST_ALREADY_PLACED",
    },
    {
      name: "expired request",
      diagnostic: (digest: string) =>
        document({
          claimTokenDigest: digest,
          expiresAt: now,
          claimExpiresAt: now,
        }),
      status: 410,
      code: "REQUEST_EXPIRED",
    },
    {
      name: "request without a claim",
      diagnostic: (digest: string) =>
        document({ status: "open", claimTokenDigest: digest }),
      status: 409,
      code: "REQUEST_NOT_CLAIMED",
    },
    {
      name: "wrong token",
      diagnostic: (digest: string) =>
        document({
          claimTokenDigest:
            digest === "0".repeat(64) ? "1".repeat(64) : "0".repeat(64),
        }),
      status: 403,
      code: "INVALID_CLAIM_TOKEN",
    },
    {
      name: "expired claim",
      diagnostic: (digest: string) =>
        document({ claimTokenDigest: digest, claimExpiresAt: now }),
      status: 409,
      code: "CLAIM_EXPIRED",
    },
    {
      name: "second extension",
      diagnostic: (digest: string) =>
        document({ claimTokenDigest: digest, claimExtendedAt: now }),
      status: 409,
      code: "CLAIM_EXTENSION_ALREADY_USED",
    },
    {
      name: "no room for a full extension",
      diagnostic: (digest: string) =>
        document({
          claimTokenDigest: digest,
          claimExpiresAt: new Date(expiresAt.getTime() - CLAIM_EXTENSION_MS + 1),
        }),
      status: 409,
      code: "CLAIM_EXTENSION_INSUFFICIENT_TIME",
    },
  ])("rejects $name after the conditional update loses", async (scenario) => {
    const rawToken = generateClaimToken();
    const digest = digestClaimToken(rawToken, secret);
    mockAtomicResult(null);
    mockDiagnosticResult(scenario.diagnostic(digest));
    const context = routeContext({ claimToken: rawToken });

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(scenario.status);
    expect(responseBody(context).error).toMatchObject({
      code: scenario.code,
      fields: null,
    });
  });

  it("reports an expired claim, not an invalid token, when another helper replaced it", async () => {
    // Helper A claims, A's claim lapses, helper B claims and overwrites the
    // digest, then A's extension arrives. A's token is genuinely absent from
    // the record, but the truthful cause is that A's claim expired.
    const helperAToken = generateClaimToken();
    const helperBDigest = digestClaimToken(generateClaimToken(), secret);
    mockAtomicResult(null);
    mockDiagnosticResult(
      document({
        status: "claimed",
        claimTokenDigest: helperBDigest,
        claimExpiresAt: new Date(now.getTime() - 1),
        claimExtendedAt: null,
      })
    );
    const context = routeContext({ claimToken: helperAToken });

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context).error).toMatchObject({
      code: "CLAIM_EXPIRED",
      fields: null,
    });
    expect(JSON.stringify(responseBody(context))).not.toMatch(
      /claimToken|pickupName|[a-f0-9]{64}/
    );
  });

  it("still rejects a wrong token on an active claim", async () => {
    const rawToken = generateClaimToken();
    mockAtomicResult(null);
    mockDiagnosticResult(
      document({
        status: "claimed",
        claimTokenDigest: digestClaimToken(generateClaimToken(), secret),
        claimExpiresAt: new Date(now.getTime() + CLAIM_DURATION_MS),
      })
    );
    const context = routeContext({ claimToken: rawToken });

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(responseBody(context).error).toMatchObject({
      code: "INVALID_CLAIM_TOKEN",
      fields: null,
    });
  });

  it("rejects an invalid request ID before token or database work", async () => {
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const context = routeContext(
      { claimToken: generateClaimToken() },
      "not-an-id"
    );

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_REQUEST_ID");
    expect(atomic).not.toHaveBeenCalled();
  });

  it.each([
    undefined,
    { claimToken: "not-base64url" },
    { claimToken: generateClaimToken(), extra: true },
  ])("rejects missing or malformed token body %j", async (body) => {
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const context = routeContext(body);

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_CLAIM_TOKEN");
    expect(atomic).not.toHaveBeenCalled();
  });

  describe("participant-authority continuation (W3-H1)", () => {
    // An empty body is the accepted second request shape: it carries no raw
    // claim token (gone after termination/relaunch) and authorizes instead
    // from the verified participant header, matched against the target
    // request's own `helperParticipantId`.
    it("extends using participant authority when the raw token is unavailable", async () => {
      const originalClaimExpiration = new Date(
        now.getTime() + CLAIM_DURATION_MS
      );
      const extended = document({
        claimExpiresAt: new Date(
          originalClaimExpiration.getTime() + CLAIM_EXTENSION_MS
        ),
        claimExtendedAt: now,
        helperParticipantId,
      });
      const atomic = mockAtomicResult(extended);
      mockDiagnosticResult(document({ helperParticipantId }));
      const lockMutation = mockReservationLockMutation();
      const context = routeContext({});

      await extendClaim(context.req, context.res);

      const [filter, , options] = atomic.mock.calls[0] as any[];
      expect(filter.helperParticipantId).toEqual(helperParticipantId);
      expect(filter.claimTokenDigest).toBeUndefined();
      expect(options).toEqual({ new: true, session: sessionMock });
      expect(responseBody(context)).toEqual({
        claim: {
          claimExpiresAt: extended.claimExpiresAt,
          claimExtendedAt: now,
        },
      });
      // The lock's mirrored deadline moves with the extension, so a claim
      // just extended cannot be mistaken for one stale enough to no longer
      // block a fresh reservation by the same principal. Owning the lock is
      // now mandatory for the commit itself (MUST FIX 2): the filter accepts
      // the lock already pointing here or never having been written (a
      // pre-H1 claim, self-healed), never a different request.
      expect(lockMutation).toHaveBeenCalledWith(
        {
          _id: helperParticipantId,
          $or: [
            { activeReservationRequestId: requestId },
            { activeReservationRequestId: null },
          ],
        },
        {
          $set: {
            activeReservationRequestId: requestId,
            activeReservationClaimExpiresAt: extended.claimExpiresAt,
          },
        },
        { session: sessionMock }
      );
    });

    it("does not touch the reservation lock extending a legacy claim with no bound helper", async () => {
      // A claim granted before W3-I1 carries no `helperParticipantId` and
      // therefore never held this lock — token-mode extension of it (the
      // pre-I1 compatibility path) must not invent a lock update for it.
      const rawToken = generateClaimToken();
      const extended = document({
        claimExtendedAt: now,
        claimTokenDigest: digestClaimToken(rawToken, secret),
      });
      mockAtomicResult(extended);
      const lockMutation = mockReservationLockMutation();
      const context = routeContext({ claimToken: rawToken });

      await extendClaim(context.req, context.res);

      expect(lockMutation).not.toHaveBeenCalled();
    });

    it("requires participant verification when no token and no credential are presented", async () => {
      const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
      const context = routeContext({}, requestId.toString(), {});

      await extendClaim(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(401);
      expect(atomic).not.toHaveBeenCalled();
    });

    it("reports the reservation as not theirs when the participant does not match", async () => {
      mockAtomicResult(null);
      mockDiagnosticResult(
        document({
          claimTokenDigest: "f".repeat(64),
          helperParticipantId: new mongoose.Types.ObjectId(
            "64c0000000000000000000c9"
          ),
        })
      );
      const context = routeContext({});

      await extendClaim(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(403);
      expect(responseBody(context).error.code).toBe("INVALID_CLAIM_TOKEN");
    });
  });
});

describe("POST /api/request/:id/claim/extend versus a later reservation lock (independent-review MUST FIX 2)", () => {
  // The delayed-extension race: a stale/old extension attempt whose
  // Participant lock has since moved to a different, later reservation for
  // the same principal must never durably renew the old Request's deadline.
  // `Participant.updateOne` matching zero documents — because the lock now
  // points elsewhere — must abort the whole transaction, not merely fail
  // silently while the Request-side commit still lands.
  it("refuses to commit the extension when the participant lock has moved to a different reservation", async () => {
    const extended = document({
      claimExpiresAt: new Date(now.getTime() + CLAIM_DURATION_MS),
      claimExtendedAt: now,
      helperParticipantId,
    });
    mockAtomicResult(extended);
    mockDiagnosticResult(document({ helperParticipantId }));
    const lockMutation = vi.spyOn(Participant, "updateOne").mockReturnValue({
      exec: vi.fn().mockResolvedValue({ matchedCount: 0, modifiedCount: 0 }),
    } as unknown as ReturnType<typeof Participant.updateOne>);
    // The re-read diagnostic after the transaction rolls back: from the
    // Request's own perspective everything still looks authorized and
    // timely — it is the Participant lock that moved, which the Request
    // diagnostic alone cannot explain, so this correctly lands on the
    // generic terminal rather than fabricating a more specific reason.
    mockDiagnosticResult(
      document({
        claimExpiresAt: new Date(now.getTime() + CLAIM_DURATION_MS),
        claimExtendedAt: null,
        helperParticipantId,
      })
    );
    const context = routeContext({});

    await extendClaim(context.req, context.res);

    expect(lockMutation).toHaveBeenCalledOnce();
    // Refused, not a silent 200 with the deadline quietly extended. Nothing
    // about the Request diagnostic alone explains this failure, so it lands
    // on the generic terminal — truthful, since the actual reason (the lock
    // moved) is not something a Request-only diagnostic can see.
    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context).error.code).toBe("INTERNAL_FAILURE");
    expect(responseBody(context).claim).toBeUndefined();
  });

  it("self-heals and commits when the lock was never written for a pre-H1-bound claim", async () => {
    const extended = document({
      claimExpiresAt: new Date(now.getTime() + CLAIM_DURATION_MS),
      claimExtendedAt: now,
      helperParticipantId,
    });
    mockAtomicResult(extended);
    mockDiagnosticResult(document({ helperParticipantId }));
    const lockMutation = vi.spyOn(Participant, "updateOne").mockReturnValue({
      exec: vi.fn().mockResolvedValue({ matchedCount: 1, modifiedCount: 1 }),
    } as unknown as ReturnType<typeof Participant.updateOne>);
    const context = routeContext({});

    await extendClaim(context.req, context.res);

    const [filter] = lockMutation.mock.calls.find(
      ([candidate]: any[]) => Array.isArray(candidate.$or)
    ) as any[];
    expect(filter.$or).toEqual([
      { activeReservationRequestId: requestId },
      { activeReservationRequestId: null },
    ]);
    expect(context.status).not.toHaveBeenCalled();
    expect(responseBody(context).claim.claimExpiresAt).toEqual(
      extended.claimExpiresAt
    );
  });
});

describe("POST /api/request/:id/claim/release (W3-H1)", () => {
  it("releases with one conditional atomic update and restores availability", async () => {
    const rawToken = generateClaimToken();
    const digest = digestClaimToken(rawToken, secret);
    const claimed = document({
      claimTokenDigest: digest,
      helperParticipantId,
    });
    const atomic = mockAtomicResult(claimed);
    const lockMutation = mockReservationLockMutation();
    const context = routeContext({ claimToken: rawToken });

    await releaseClaim(context.req, context.res);

    const [filter, update, options] = atomic.mock.calls[0] as any[];
    expect(filter).toEqual({
      _id: requestId.toString(),
      status: "claimed",
      claimExpiresAt: {
        $gt: now,
        $eq: claimed.claimExpiresAt,
      },
      claimExtendedAt: { $eq: null, $exists: true },
      claimTokenDigest: digest,
      // W4-U1.3/W4-U1.2: the ordinary release matches only a request without
      // E, M, or an unconfirmed L; the update itself is unchanged.
      externalOrderAffirmed: { $ne: true },
      moderationUnavailable: { $ne: true },
      reservationLapseHold: { $ne: true },
    });
    expect(update).toEqual({
      $set: { status: "open", updatedAt: now },
      $unset: {
        claimedAt: 1,
        claimExpiresAt: 1,
        claimExtendedAt: 1,
        claimTokenDigest: 1,
        helperParticipantId: 1,
      },
    });
    expect(options).toEqual({ session: sessionMock });
    expect(responseBody(context)).toEqual({ released: true });
    // Released authority must not linger as a block on this same principal's
    // next reservation.
    expect(lockMutation).toHaveBeenCalledWith(
      {
        _id: helperParticipantId,
        activeReservationRequestId: requestId,
      },
      {
        $set: {
          activeReservationRequestId: null,
          activeReservationClaimExpiresAt: null,
        },
      },
      { session: sessionMock }
    );
  });

  it("releases the extended version when the release starts after extension completed", async () => {
    const rawToken = generateClaimToken();
    const digest = digestClaimToken(rawToken, secret);
    const extendedAt = new Date(now.getTime() - 60_000);
    const extendedExpiration = new Date(
      now.getTime() + CLAIM_DURATION_MS + CLAIM_EXTENSION_MS
    );
    const extended = document({
      claimTokenDigest: digest,
      claimExpiresAt: extendedExpiration,
      claimExtendedAt: extendedAt,
      helperParticipantId,
    });
    mockDiagnosticResult(extended);
    const atomic = mockAtomicResult(extended);
    const context = routeContext({ claimToken: rawToken });

    await releaseClaim(context.req, context.res);

    const [filter] = atomic.mock.calls[0] as any[];
    expect(filter).toMatchObject({
      _id: requestId.toString(),
      status: "claimed",
      claimExpiresAt: {
        $gt: now,
        $eq: extendedExpiration,
      },
      claimExtendedAt: extendedAt,
      claimTokenDigest: digest,
    });
    expect(responseBody(context)).toEqual({ released: true });
  });

  it("releases using participant-authority continuation when the raw token is unavailable", async () => {
    const claimed = document({ helperParticipantId });
    const atomic = mockAtomicResult(claimed);
    mockDiagnosticResult(claimed);
    const context = routeContext({});

    await releaseClaim(context.req, context.res);

    const [filter] = atomic.mock.calls[0] as any[];
    expect(filter.helperParticipantId).toEqual(helperParticipantId);
    expect(filter.claimTokenDigest).toBeUndefined();
    expect(responseBody(context)).toEqual({ released: true });
  });

  it("does not touch the reservation lock releasing a legacy claim with no bound helper", async () => {
    const rawToken = generateClaimToken();
    const claimed = document({
      claimTokenDigest: digestClaimToken(rawToken, secret),
    });
    mockAtomicResult(claimed);
    const lockMutation = mockReservationLockMutation();
    const context = routeContext({ claimToken: rawToken });

    await releaseClaim(context.req, context.res);

    expect(lockMutation).not.toHaveBeenCalled();
  });

  it("releases a pre-H1 version whose extension marker is physically absent", async () => {
    const rawToken = generateClaimToken();
    const claimed = document({
      claimTokenDigest: digestClaimToken(rawToken, secret),
      claimExtendedAt: undefined,
    });
    mockDiagnosticResult(claimed);
    const atomic = mockAtomicResult(claimed);
    const context = routeContext({ claimToken: rawToken });

    await releaseClaim(context.req, context.res);

    const [filter] = atomic.mock.calls[0] as any[];
    expect(filter.claimExtendedAt).toEqual({ $exists: false });
    expect(responseBody(context)).toEqual({ released: true });
  });

  it("keeps the initially captured version across a retried transaction callback", async () => {
    const rawToken = generateClaimToken();
    const digest = digestClaimToken(rawToken, secret);
    const originalExpiration = new Date(now.getTime() + CLAIM_DURATION_MS);
    const extendedAt = new Date(now.getTime() + 60_000);
    const extendedExpiration = new Date(
      originalExpiration.getTime() + CLAIM_EXTENSION_MS
    );
    let persisted = document({
      claimTokenDigest: digest,
      claimExpiresAt: originalExpiration,
      claimExtendedAt: null,
    });
    // This resolves `persisted` at *read time*, not at mock setup. If the
    // production version read moved inside the retryable callback, attempt 2
    // would now receive V2 and build a V2 filter that matches the simulated
    // persistence (incorrectly releasing the extension). Current production
    // reads V once before `withTransaction`, so both callback filters retain
    // that captured V after this variable changes.
    const versionRead = mockDynamicDiagnosticResult(() => persisted);
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate").mockImplementation(
      ((filter: Record<string, unknown>) => {
        const versionMatches =
          JSON.stringify(filter.claimExpiresAt) ===
            JSON.stringify({ $gt: now, $eq: persisted.claimExpiresAt }) &&
          JSON.stringify(filter.claimExtendedAt) ===
            JSON.stringify(
              persisted.claimExtendedAt === null
                ? { $eq: null, $exists: true }
                : persisted.claimExtendedAt
            );
        return atomicResultChain(
          vi.fn().mockResolvedValue(versionMatches ? persisted : null)
        ) as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>;
      }) as any
    );
    sessionMock.withTransaction.mockImplementationOnce(
      async (work: () => Promise<void>) => {
        await work();
        // Simulate another writer committing V2 before Mongo retries this
        // callback. The second attempt must keep V, not reread/adopt V2.
        persisted = document({
          claimTokenDigest: digest,
          claimExpiresAt: extendedExpiration,
          claimExtendedAt: extendedAt,
        });
        await work();
      }
    );
    const context = routeContext({ claimToken: rawToken });

    await releaseClaim(context.req, context.res);

    expect(sessionMock.withTransaction).toHaveBeenCalledOnce();
    // Each callback attempt runs the ordinary release filter; an attempt whose
    // ordinary filter misses also tries the W4-U1.3 post-Yes branch (same
    // version pin, `externalOrderAffirmed: true`). Attempt 1 matches; attempt 2
    // misses both, so three updates in all: two ordinary, one post-Yes.
    const calls = atomic.mock.calls as Array<[Record<string, any>]>;
    expect(calls).toHaveLength(3);
    expect(
      calls.filter(([filter]) => filter.externalOrderAffirmed?.$ne === true)
    ).toHaveLength(2);
    // W4-U1.2: the retire-in-place branch now matches E, M, or L through an
    // `$or`, not a flat `externalOrderAffirmed: true` key.
    expect(
      calls.filter(
        ([filter]) =>
          Array.isArray(filter.$or) &&
          filter.$or.some(
            (clause: Record<string, unknown>) => clause.externalOrderAffirmed === true
          )
      )
    ).toHaveLength(1);
    // One read captures V before the transaction and one post-miss diagnostic
    // classifies the result. Neither callback attempt rereads or adopts V2.
    expect(versionRead).toHaveBeenCalledTimes(2);
    for (const [filter] of calls) {
      expect(filter.claimExpiresAt).toEqual({
        $gt: now,
        $eq: originalExpiration,
      });
      expect(filter.claimExtendedAt).toEqual({ $eq: null, $exists: true });
    }
    expect(context.status).toHaveBeenCalledWith(500);
  });

  it.each([
    {
      name: "request not found",
      diagnostic: (_digest: string) => null,
      status: 404,
      code: "REQUEST_NOT_FOUND",
    },
    {
      name: "placed request",
      diagnostic: (digest: string) =>
        document({ status: "placed", claimTokenDigest: digest }),
      status: 409,
      code: "REQUEST_ALREADY_PLACED",
    },
    {
      name: "request without a claim",
      diagnostic: (digest: string) =>
        document({ status: "open", claimTokenDigest: digest }),
      status: 409,
      code: "REQUEST_NOT_CLAIMED",
    },
    {
      name: "expired claim",
      diagnostic: (digest: string) =>
        document({ claimTokenDigest: digest, claimExpiresAt: now }),
      status: 409,
      code: "CLAIM_EXPIRED",
    },
    {
      name: "wrong token",
      diagnostic: (digest: string) =>
        document({
          claimTokenDigest:
            digest === "0".repeat(64) ? "1".repeat(64) : "0".repeat(64),
        }),
      status: 403,
      code: "INVALID_CLAIM_TOKEN",
    },
  ])("rejects $name after the conditional update loses", async (scenario) => {
    const rawToken = generateClaimToken();
    const digest = digestClaimToken(rawToken, secret);
    mockAtomicResult(null);
    mockDiagnosticResult(scenario.diagnostic(digest));
    const context = routeContext({ claimToken: rawToken });

    await releaseClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(scenario.status);
    expect(responseBody(context).error).toMatchObject({
      code: scenario.code,
      fields: null,
    });
  });

  it("cannot release a stale/wrong credential even against an active claim", async () => {
    mockAtomicResult(null);
    mockDiagnosticResult(
      document({
        status: "claimed",
        claimTokenDigest: digestClaimToken(generateClaimToken(), secret),
        claimExpiresAt: new Date(now.getTime() + CLAIM_DURATION_MS),
      })
    );
    const context = routeContext({ claimToken: generateClaimToken() });

    await releaseClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(responseBody(context).error.code).toBe("INVALID_CLAIM_TOKEN");
  });

  it("rejects an invalid request ID before authorization or database work", async () => {
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const context = routeContext(
      { claimToken: generateClaimToken() },
      "not-an-id"
    );

    await releaseClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_REQUEST_ID");
    expect(atomic).not.toHaveBeenCalled();
  });

  it("requires participant verification when no token and no credential are presented", async () => {
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const context = routeContext({}, requestId.toString(), {});

    await releaseClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(atomic).not.toHaveBeenCalled();
  });
});

describe("Day 4 operational middleware", () => {
  it("refuses paused claims with the Day 4 envelope before the handler", () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    const context = routeContext();
    const next = vi.fn();

    pauseDay4Mutation(context.req, context.res, next);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context)).toEqual({
      error: {
        code: "PUBLIC_ACTIONS_PAUSED",
        message: CLAIM_UNAVAILABLE_MESSAGE,
        fields: null,
      },
    });
    expect(next).not.toHaveBeenCalled();
  });

  it("rate limits with a structured Day 4 error", async () => {
    vi.useRealTimers();
    const testApp = express();
    testApp.post(
      "/limited",
      createDay4MutationRateLimiter(1),
      (_req, res) => res.json({ ok: true })
    );
    const server = createServer(testApp);
    await new Promise<void>((resolve) =>
      server.listen(0, "127.0.0.1", resolve)
    );

    try {
      const { port } = server.address() as AddressInfo;
      const first = await fetch(`http://127.0.0.1:${port}/limited`, {
        method: "POST",
      });
      const second = await fetch(`http://127.0.0.1:${port}/limited`, {
        method: "POST",
      });

      expect(first.status).toBe(200);
      expect(second.status).toBe(429);
      await expect(second.json()).resolves.toEqual({
        error: {
          code: "RATE_LIMITED",
          message: "Too many attempts. Please wait a moment and try again.",
          fields: null,
        },
      });
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      );
    }
  });
});
