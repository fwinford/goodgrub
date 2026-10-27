// Focused coverage for the W3-H2 one-successful-participation invariant:
// once a verified participant has successfully acquired reservation
// authority over a request, they can never successfully acquire it again.
// `claimRoute.test.ts` already covers ordinary claim behavior in depth; this
// file is scoped to the new durable participation check and record it adds
// around that existing conditional grant.
import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Request as MealRequest,
  Participant,
  ParticipantBlock,
  ParticipantIdentityKeyVersion,
  RequestParticipation,
} from "../models/db.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  CLAIM_DURATION_MS,
  claimRequest,
  REQUEST_ALREADY_PARTICIPATED_CODE,
  REQUEST_ALREADY_PARTICIPATED_MESSAGE,
  REQUEST_OWN_REQUEST_CODE,
  REQUEST_OWN_REQUEST_MESSAGE,
} from "./claimRoute.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000101");
const now = new Date("2026-08-10T16:00:00.000Z");
const expiresAt = new Date("2026-08-10T18:00:00.000Z");
const secretText = "unit-test-participation-hmac-secret-material";
const secret = Buffer.from(secretText);

const helperParticipantId = new mongoose.Types.ObjectId(
  "64c0000000000000000000d1"
);
const helperPrincipal = "participation-helper@nyu.edu";
const participantSecretText = "participant-participation-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);
const participationKey = Buffer.alloc(32, 0x31);
const blockSafetyKey = Buffer.alloc(32, 0x52);

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
  vi.spyOn(ParticipantIdentityKeyVersion, "find").mockImplementation(
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

function stubParticipationReads(result: unknown = null) {
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

function document(overrides: Record<string, unknown> = {}) {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Private Pickup Name",
    pickupWindowText: "ASAP (available for the next 3 hours)",
    mealSwipes: 4,
    windowStart: null,
    windowEnd: null,
    status: "open",
    createdAt: new Date("2026-08-10T15:00:00.000Z"),
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

function stubVerifiedParticipant() {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi
          .fn()
          .mockResolvedValue({ _id: helperParticipantId, email: helperPrincipal }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
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
        email: helperPrincipal,
      }),
    };
    return query;
  }) as never);
}

function routeContext(id = requestId.toString()) {
  const req = {
    params: { id },
    body: undefined,
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority },
  } as unknown as Request;
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

function mockReservationLockResult(result: unknown = { _id: helperParticipantId }) {
  return vi.spyOn(Participant, "findOneAndUpdate").mockReturnValue({
    exec: vi.fn().mockResolvedValue(result),
  } as unknown as ReturnType<typeof Participant.findOneAndUpdate>);
}

function mockExistingActiveReservation(result: unknown = null) {
  return vi.spyOn(MealRequest, "findOne").mockReturnValue({
    lean: () => ({
      exec: vi.fn().mockResolvedValue(result),
    }),
  } as unknown as ReturnType<typeof MealRequest.findOne>);
}

function mockExistingParticipation(result: unknown = null) {
  return stubParticipationReads(result);
}

/**
 * The W4-H2 self-claim ownership pre-check `claimRequest` performs inside its
 * transaction before the participation check: is this exact verified
 * participant the request's own requester. Defaults to "no owner on record"
 * so every existing claim case, which is not itself exercising this
 * behavior, is unaffected by it.
 */
function mockOwnershipCheck(result: unknown = document()) {
  return vi.spyOn(MealRequest, "findById").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue(result),
      }),
    }),
  } as unknown as ReturnType<typeof MealRequest.findById>);
}

function mockParticipationInsert(
  implementation: () => Promise<unknown> = () => Promise.resolve([{}])
) {
  return vi
    .spyOn(RequestParticipation, "create")
    .mockImplementation(implementation as never);
}

function duplicateKeyError() {
  const error = new Error("E11000 duplicate key error") as Error & {
    code: number;
  };
  error.code = 11000;
  return error;
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
  mockReservationLockResult();
  vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1, modifiedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);
  mockExistingActiveReservation();
  mockExistingParticipation();
  // W4-U1.3: no block exists between any pair unless a case says otherwise.
  vi.spyOn(ParticipantBlock, "findOne").mockReturnValue({
    lean: () => ({ exec: vi.fn().mockResolvedValue(null) }),
  } as unknown as ReturnType<typeof ParticipantBlock.findOne>);
  mockParticipationInsert();
  mockOwnershipCheck();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("W3-H2 one-successful-participation invariant", () => {
  it("refuses a reacquisition attempt before ever running the conditional grant", async () => {
    mockExistingParticipation({
      _id: "existing-participation-row",
      requestId: requestId.toString(),
    });
    const atomic = mockAtomicResult(document());
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context)).toEqual({
      error: {
        code: REQUEST_ALREADY_PARTICIPATED_CODE,
        message: REQUEST_ALREADY_PARTICIPATED_MESSAGE,
        fields: null,
      },
    });
    // Refused before any attempt to grant the claim — a raced or failed
    // attempt that never won authority must never be what this check is
    // keyed on.
    expect(atomic).not.toHaveBeenCalled();
  });

  it("consults the participation record scoped to exactly this request and this participant", async () => {
    const lookup = mockExistingParticipation(null);
    mockAtomicResult(document());
    const context = routeContext();

    await claimRequest(context.req, context.res);

    const participationCalls = lookup.mock.calls as unknown as Array<
      [Record<string, any>]
    >;
    const participationLookup = participationCalls.find(([filter]) =>
      (filter as Record<string, any>).$or?.some(
        (part: Record<string, unknown>) => "participantId" in part
      )
    )?.[0];
    expect(participationLookup).toBeDefined();
    const participationFilter = participationLookup as Record<string, any>;
    expect(participationFilter.$or[0]).toEqual({
      participantId: helperParticipantId,
      requestId: { $in: [requestId.toString()] },
    });
    expect(participationFilter.$or[1]).toMatchObject({
      requestId: requestId.toString(),
      participationKeyVersion: 1,
      participationHmac: expect.stringMatching(/^[0-9a-f]{64}$/),
    });
  });

  it("writes a durable participation record atomically after a successful grant", async () => {
    const claimed = document();
    mockAtomicResult(claimed);
    const insert = mockParticipationInsert();
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    const [rows, options] = insert.mock.calls[0] as any[];
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      requestId: claimed._id,
      participantId: helperParticipantId,
      participationKeyVersion: 1,
      participationHmac: expect.stringMatching(/^[0-9a-f]{64}$/),
    });
    expect(options).toEqual({ session: sessionMock });
  });

  it("does not write a participation record when the conditional grant itself fails", async () => {
    mockAtomicResult(null);
    vi.spyOn(MealRequest, "findById").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue(document({ status: "claimed" })),
        }),
      }),
    } as unknown as ReturnType<typeof MealRequest.findById>);
    const insert = mockParticipationInsert();
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(insert).not.toHaveBeenCalled();
  });

  it("refuses the claim when the participation insert loses a race to a concurrent grant", async () => {
    mockAtomicResult(document());
    mockParticipationInsert(() => Promise.reject(duplicateKeyError()));
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context).error.code).toBe(
      REQUEST_ALREADY_PARTICIPATED_CODE
    );
    // The transaction aborted along with the insert: no claimant-private
    // data may leak from a grant that did not actually stick.
    expect(JSON.stringify(responseBody(context))).not.toMatch(
      /pickupName|claimToken|Private Pickup/
    );
  });

  it("rethrows a non-duplicate-key participation insert failure as an internal failure", async () => {
    mockAtomicResult(document());
    mockParticipationInsert(() => Promise.reject(new Error("connection reset")));
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context).error.code).toBe("INTERNAL_FAILURE");
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(
      /connection reset/
    );
  });

  it("still allows an eligible participant with no participation record to claim normally", async () => {
    mockExistingParticipation(null);
    const claimed = document();
    mockAtomicResult(claimed);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    expect(responseBody(context).claim).not.toHaveProperty("pickupName");
    expect(responseBody(context).claim.claimToken).toEqual(expect.any(String));
  });
});

describe("W4-H2 self-claim guard", () => {
  it("refuses a verified participant attempting to claim their own request, before the conditional grant", async () => {
    mockOwnershipCheck(
      document({ requesterParticipantId: helperParticipantId })
    );
    const atomic = mockAtomicResult(document());
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context)).toEqual({
      error: {
        code: REQUEST_OWN_REQUEST_CODE,
        message: REQUEST_OWN_REQUEST_MESSAGE,
        fields: null,
      },
    });
    // Refused before any attempt to grant the claim — no reservation side
    // effect for the rejected self-claim.
    expect(atomic).not.toHaveBeenCalled();
    expect(JSON.stringify(responseBody(context))).not.toMatch(
      /pickupName|claimToken|Private Pickup/
    );
  });

  it("creates no participation record for a refused self-claim", async () => {
    mockOwnershipCheck(
      document({ requesterParticipantId: helperParticipantId })
    );
    const insert = mockParticipationInsert();
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(insert).not.toHaveBeenCalled();
  });

  it("still allows a different verified participant to claim the same request normally", async () => {
    const otherRequesterParticipantId = new mongoose.Types.ObjectId(
      "64d0000000000000000000e2"
    );
    mockOwnershipCheck(
      document({ requesterParticipantId: otherRequesterParticipantId })
    );
    const claimed = document();
    mockAtomicResult(claimed);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    expect(responseBody(context).claim).not.toHaveProperty("pickupName");
    expect(responseBody(context).claim.claimToken).toEqual(expect.any(String));
  });

  it("allows claiming a request with no recorded requester (legacy/pre-I1 row)", async () => {
    mockOwnershipCheck(document({ requesterParticipantId: undefined }));
    const claimed = document();
    mockAtomicResult(claimed);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    expect(responseBody(context).claim).not.toHaveProperty("pickupName");
    expect(responseBody(context).claim.claimToken).toEqual(expect.any(String));
  });
});
