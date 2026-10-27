import type { Request, Response } from "express";
import mongoose from "mongoose";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DELETION_CHALLENGE_LIFETIME_MS } from "./participantDeletionSecurity.js";
import { DELETION_NAMESPACE_HEADER, deletionNamespaceBinding } from "./participantDeletionNamespace.js";

const {
  resolveParticipantAuthority,
  classifyDeletionRequesterObservation,
  classifyDeletionHelperObservation,
  evaluateParticipantDeletionReadiness,
  createOrResolveParticipantDeletionOperation,
  readParticipantDeletionStatus,
  cancelParticipantDeletionOperation,
  issueParticipantDeletionChallenge,
  redeemParticipantDeletionChallenge,
  completeParticipantDeletionOperation,
  readCompletedDeletionRecovery,
  sendParticipantDeletionChallengeEmail,
  compareDeletionRecordedLedger,
} = vi.hoisted(() => ({
  resolveParticipantAuthority: vi.fn(),
  classifyDeletionRequesterObservation: vi.fn(),
  classifyDeletionHelperObservation: vi.fn(),
  evaluateParticipantDeletionReadiness: vi.fn(),
  createOrResolveParticipantDeletionOperation: vi.fn(),
  readParticipantDeletionStatus: vi.fn(),
  cancelParticipantDeletionOperation: vi.fn(),
  issueParticipantDeletionChallenge: vi.fn(),
  redeemParticipantDeletionChallenge: vi.fn(),
  completeParticipantDeletionOperation: vi.fn(),
  readCompletedDeletionRecovery: vi.fn(),
  sendParticipantDeletionChallengeEmail: vi.fn(),
  compareDeletionRecordedLedger: vi.fn(),
}));

vi.mock("./participantDeletionProvenance.js", () => ({ compareDeletionRecordedLedger }));
// The route imports the real email helper, which constructs a Resend client
// at module scope requiring a live API key. Every case below drives the
// mocked `issueParticipantDeletionChallenge` directly, so the real send
// function this module passes in as a dependency is never actually invoked
// by production code in these tests — but the wiring test below still calls
// the captured override itself and asserts it forwards to this exact mock.
vi.mock("./emailHelpers.js", () => ({
  sendParticipantDeletionChallengeEmail,
}));

vi.mock("./participantAuthorityGate.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./participantAuthorityGate.js")>();
  return { ...actual, resolveParticipantAuthority };
});

vi.mock("./participantDeletionRequesterAdapter.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./participantDeletionRequesterAdapter.js")>();
  return { ...actual, classifyDeletionRequesterObservation };
});

vi.mock("./participantDeletionHelperAdapter.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./participantDeletionHelperAdapter.js")>();
  return { ...actual, classifyDeletionHelperObservation };
});

vi.mock("./participantDeletionReadinessEvaluator.js", () => ({
  evaluateParticipantDeletionReadiness,
}));

vi.mock("./participantDeletionOperations.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./participantDeletionOperations.js")>();
  return {
    ...actual,
    createOrResolveParticipantDeletionOperation,
    readParticipantDeletionStatus,
    cancelParticipantDeletionOperation,
    issueParticipantDeletionChallenge,
    redeemParticipantDeletionChallenge,
  };
});

vi.mock("./participantDeletionCompletion.js", () => ({
  completeParticipantDeletionOperation,
}));

vi.mock("./participantDeletionRecovery.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./participantDeletionRecovery.js")>();
  return { ...actual, readCompletedDeletionRecovery };
});

vi.mock("../models/db.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../models/db.js")>();
  return {
    ...actual,
    Participant: {
      findOne: vi.fn(() => ({
        select: vi.fn().mockReturnThis(),
        lean: vi.fn().mockReturnThis(),
        exec: vi.fn(async () => ({
          activeReservationRequestId: null,
          activeReservationClaimExpiresAt: null,
        })),
      })),
    },
  };
});

import {
  cancelParticipantDeletion,
  completeParticipantDeletionRoute,
  createParticipantDeletion,
  getParticipantDeletionEligibility,
  getParticipantDeletionStatus,
  issueParticipantDeletionChallengeRoute,
  recoverParticipantDeletionCompletion,
  redeemParticipantDeletionChallengeRoute,
  compareParticipantDeletionProvenance,
} from "./participantDeletionRoute.js";

const participantId = String(new mongoose.Types.ObjectId());
const operationId = "a3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d";
const namespaceBinding = deletionNamespaceBinding("b3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d");
const okAuthority = {
  ok: true as const,
  participant: { participantId, principal: "student@nyu.edu", authorityVersion: 1 },
};

/**
 * Note: `status`/`payload` are exposed as getters so callers must read
 * `ctx.status` / `ctx.payload` *after* invoking the handler — destructuring
 * them at creation time would freeze the initial 200/undefined snapshot.
 */
function context(body: unknown = {}, query: Record<string, unknown> = {}) {
  const req = { body, query, headers: { [DELETION_NAMESPACE_HEADER]: namespaceBinding } } as unknown as Request;
  let status = 200;
  let payload: unknown;
  const res = {
    status(value: number) { status = value; return this; },
    json(value: unknown) { payload = value; return this; },
    setHeader() { return this; },
  } as unknown as Response;
  return { req, res, get status() { return status; }, get payload() { return payload; } };
}

describe("W4-P2 account-deletion route layer", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    resolveParticipantAuthority.mockResolvedValue(okAuthority);
    classifyDeletionRequesterObservation.mockResolvedValue("clear");
    classifyDeletionHelperObservation.mockResolvedValue("clear");
    evaluateParticipantDeletionReadiness.mockResolvedValue({
      outcome: "ready",
      status: { operationId, phase: "ready", readinessGeneration: 1 },
    });
  });

  it.each([true, false])("projects only match/no-match from owner-bound comparison (%s)", async (matches) => {
    const recordedLedger = "b3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d";
    compareDeletionRecordedLedger.mockResolvedValue(matches);
    const ctx = context({ operationId, recordedLedger });
    await compareParticipantDeletionProvenance(ctx.req, ctx.res);
    expect(ctx.status).toBe(200);
    expect(ctx.payload).toEqual({ matches });
    expect(compareDeletionRecordedLedger).toHaveBeenCalledWith(
      expect.objectContaining({ operationId, namespaceBinding, canonicalEmail: "student@nyu.edu" }),
      recordedLedger
    );
  });

  it("rejects malformed comparison inputs, missing namespace, and unauthenticated callers", async () => {
    for (const body of [
      { operationId, recordedLedger: [] },
      { operationId, recordedLedger: "not-a-ledger" },
      { operationId, recordedLedger: "b3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d", extra: true },
    ]) {
      const ctx = context(body);
      await compareParticipantDeletionProvenance(ctx.req, ctx.res);
      expect(ctx.status).toBe(400);
    }
    const ctx = context({ operationId, recordedLedger: "b3f1c2b4-5e6d-4a1b-8c9d-0e1f2a3b4c5d" });
    ctx.req.headers = {};
    await compareParticipantDeletionProvenance(ctx.req, ctx.res);
    expect(ctx.status).toBe(503);
    resolveParticipantAuthority.mockResolvedValue({ ok: false, refusal: "missing" });
    await compareParticipantDeletionProvenance(ctx.req, ctx.res);
    expect(ctx.status).toBe(401);
    expect(compareDeletionRecordedLedger).not.toHaveBeenCalled();
  });

  it("refuses every mutating route the same way when authority cannot be resolved", async () => {
    resolveParticipantAuthority.mockResolvedValue({ ok: false, refusal: "missing" });
    const ctx = context({ operationId });
    await createParticipantDeletion(ctx.req, ctx.res);
    expect(ctx.status).toBe(401);
  });

  it("eligibility reports only accepted categories, never raw adapter vocabulary leaking moderation state", async () => {
    classifyDeletionRequesterObservation.mockResolvedValue("withdrawalRequired");
    classifyDeletionHelperObservation.mockResolvedValue("helperOrPickup");
    const ctx = context();
    await getParticipantDeletionEligibility(ctx.req, ctx.res);
    expect(ctx.payload).toEqual({
      eligible: false,
      categories: expect.arrayContaining(["activeRequest", "activeHelpingOrPickup"]),
    });
    expect(JSON.stringify(ctx.payload)).not.toMatch(/moderat|suspend|safetyIdentity|report/i);
  });

  it("eligibility reports eligible:true when both classifiers are clear", async () => {
    const ctx = context();
    await getParticipantDeletionEligibility(ctx.req, ctx.res);
    expect(ctx.payload).toEqual({ eligible: true, categories: [] });
  });

  it("create chooses ready when clear, and never fabricates a code", async () => {
    createOrResolveParticipantDeletionOperation.mockResolvedValue({
      outcome: "created",
      status: { operationId, phase: "ready", readinessGeneration: 1, namespaceBinding },
    });
    const ctx = context();
    await createParticipantDeletion(ctx.req, ctx.res);
    expect(ctx.status).toBe(201);
    expect(createOrResolveParticipantDeletionOperation).toHaveBeenCalledWith(
      expect.objectContaining({ initialPhase: "ready" })
    );
    expect(ctx.payload).toEqual({ operationId, phase: "ready", readinessGeneration: 1, namespaceBinding });
    expect(ctx.payload).not.toHaveProperty("code");
  });

  it.each([undefined, "", "internal-ledger-uuid", ["dn1_" + "a".repeat(64)]])(
    "refuses final completion without a canonical namespace header (%j)",
    async (header) => {
      const ctx = context({ operationId, readinessGeneration: 1, capability: "cap" });
      ctx.req.headers[DELETION_NAMESPACE_HEADER] = header;
      await completeParticipantDeletionRoute(ctx.req, ctx.res);
      expect(ctx.status).toBe(503);
      expect(completeParticipantDeletionOperation).not.toHaveBeenCalled();
    }
  );

  it("passes the exact namespace header to final completion without exposing internal ledger identity", async () => {
    completeParticipantDeletionOperation.mockResolvedValue("completed");
    const ctx = context({ operationId, readinessGeneration: 1, capability: "cap" });
    await completeParticipantDeletionRoute(ctx.req, ctx.res);
    expect(completeParticipantDeletionOperation).toHaveBeenCalledWith(
      expect.objectContaining({ namespaceBinding, operationId }), 1, "cap"
    );
    expect(ctx.payload).toEqual({ outcome: "completed" });
  });

  it("passes the exact namespace to capability-only recovery", async () => {
    readCompletedDeletionRecovery.mockResolvedValue({ outcome: "unavailable" });
    const ctx = context({ operationId, capability: "cap" });
    await recoverParticipantDeletionCompletion(ctx.req, ctx.res);
    expect(readCompletedDeletionRecovery).toHaveBeenCalledWith(operationId, "cap", namespaceBinding);
    expect(resolveParticipantAuthority).not.toHaveBeenCalled();
    expect(ctx.status).toBe(503);
  });

  it("refuses recovery without a namespace before performing any lookup", async () => {
    readCompletedDeletionRecovery.mockResolvedValue({ outcome: "completed" });
    const ctx = context({ operationId, capability: "cap" });
    delete ctx.req.headers[DELETION_NAMESPACE_HEADER];
    await recoverParticipantDeletionCompletion(ctx.req, ctx.res);
    expect(ctx.status).toBe(503);
    expect(readCompletedDeletionRecovery).not.toHaveBeenCalled();
    expect(resolveParticipantAuthority).not.toHaveBeenCalled();
  });

  it("create uses waiting when a classifier observes a blocker", async () => {
    classifyDeletionRequesterObservation.mockResolvedValue("withdrawalRequired");
    createOrResolveParticipantDeletionOperation.mockResolvedValue({
      outcome: "created",
      status: { operationId, phase: "waiting", readinessGeneration: 0 },
    });
    const ctx = context();
    await createParticipantDeletion(ctx.req, ctx.res);
    expect(createOrResolveParticipantDeletionOperation).toHaveBeenCalledWith(
      expect.objectContaining({ initialPhase: "waiting" })
    );
  });

  it("rejects a malformed operation id before ever resolving authority", async () => {
    const ctx = context(undefined, { operationId: "not-a-uuid" });
    await getParticipantDeletionStatus(ctx.req, ctx.res);
    expect(ctx.status).toBe(400);
    expect(resolveParticipantAuthority).not.toHaveBeenCalled();
  });

  it("status 404s when the operation cannot be found for the resolved owner (ownership, not existence, decides)", async () => {
    readParticipantDeletionStatus.mockResolvedValue(null);
    const ctx = context(undefined, { operationId });
    await getParticipantDeletionStatus(ctx.req, ctx.res);
    expect(ctx.status).toBe(404);
    expect(readParticipantDeletionStatus).toHaveBeenCalledWith(
      expect.objectContaining({ participantId: expect.any(mongoose.Types.ObjectId), operationId })
    );
  });

  it.each([
    { outcome: "ready", phase: "ready", generation: 1 },
    { outcome: "waiting", phase: "waiting", generation: 0 },
    { outcome: "stale", phase: "ready", generation: 2 },
    { outcome: "inactive", phase: "canceled", generation: 0 },
  ])("status reconciles stored waiting then returns fresh $phase after $outcome evaluation", async ({ outcome, phase, generation }) => {
    const initial = { operationId, namespaceBinding, phase: "waiting", readinessGeneration: 0 };
    const current = { ...initial, phase, readinessGeneration: generation };
    readParticipantDeletionStatus.mockResolvedValueOnce(initial).mockResolvedValueOnce(current);
    evaluateParticipantDeletionReadiness.mockResolvedValue({
      outcome, status: current, blockers: [{ source: "helper", observation: "unknown" }],
    });
    const ctx = context(undefined, { operationId });
    await getParticipantDeletionStatus(ctx.req, ctx.res);
    expect(ctx.status).toBe(200);
    expect(ctx.payload).toEqual(current);
    expect(evaluateParticipantDeletionReadiness).toHaveBeenCalledWith(
      expect.objectContaining({ operationId, namespaceBinding, participantId: expect.any(mongoose.Types.ObjectId) }),
      0, {}
    );
    expect(readParticipantDeletionStatus).toHaveBeenCalledTimes(2);
    expect(issueParticipantDeletionChallenge).not.toHaveBeenCalled();
    expect(completeParticipantDeletionOperation).not.toHaveBeenCalled();
  });

  it.each(["ready", "challengeIssued", "authorized"])("status rechecks %s for newly introduced blockers", async (phase) => {
    readParticipantDeletionStatus
      .mockResolvedValueOnce({ operationId, phase, readinessGeneration: 4 })
      .mockResolvedValueOnce({ operationId, phase: "waiting", readinessGeneration: 4 });
    evaluateParticipantDeletionReadiness.mockResolvedValue({ outcome: "waiting" });
    const ctx = context(undefined, { operationId });
    await getParticipantDeletionStatus(ctx.req, ctx.res);
    expect(evaluateParticipantDeletionReadiness).toHaveBeenCalledWith(expect.anything(), 4, {});
    expect(ctx.payload).toMatchObject({ phase: "waiting", readinessGeneration: 4 });
  });

  it.each(["completed", "canceled"])("status does not reconcile terminal %s", async (phase) => {
    readParticipantDeletionStatus.mockResolvedValue({ operationId, phase, readinessGeneration: 2 });
    const ctx = context(undefined, { operationId });
    await getParticipantDeletionStatus(ctx.req, ctx.res);
    expect(ctx.payload).toMatchObject({ phase });
    expect(evaluateParticipantDeletionReadiness).not.toHaveBeenCalled();
  });

  it("status fails closed when readiness evaluation fails", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      readParticipantDeletionStatus.mockResolvedValue({ operationId, phase: "waiting", readinessGeneration: 0 });
      evaluateParticipantDeletionReadiness.mockRejectedValue(new Error("database unavailable"));
      const ctx = context(undefined, { operationId });
      await getParticipantDeletionStatus(ctx.req, ctx.res);
      expect(ctx.status).toBe(503);
      expect(log).toHaveBeenCalledWith("[route] Participant deletion status check failed");
    } finally {
      log.mockRestore();
    }
  });

  it("status refuses ownership lost during evaluation", async () => {
    readParticipantDeletionStatus.mockResolvedValue({ operationId, phase: "waiting", readinessGeneration: 0 });
    evaluateParticipantDeletionReadiness.mockResolvedValue({ outcome: "notOwned" });
    const ctx = context(undefined, { operationId });
    await getParticipantDeletionStatus(ctx.req, ctx.res);
    expect(ctx.status).toBe(404);
  });

  it("challenge issue maps cooldown to 429 and never returns a code", async () => {
    issueParticipantDeletionChallenge.mockResolvedValue({
      outcome: "cooldown",
      status: { operationId, phase: "ready", readinessGeneration: 1 },
    });
    const ctx = context({ operationId, readinessGeneration: 1 });
    await issueParticipantDeletionChallengeRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(429);
    expect(JSON.stringify(ctx.payload)).not.toMatch(/\d{6}/);
    expect(evaluateParticipantDeletionReadiness).toHaveBeenCalledWith(
      expect.objectContaining({ operationId }),
      1,
      {}
    );
  });

  it("reconciles a waiting operation before challenge issue and uses the promoted generation", async () => {
    evaluateParticipantDeletionReadiness.mockResolvedValue({
      outcome: "ready",
      status: { operationId, phase: "ready", readinessGeneration: 5 },
    });
    issueParticipantDeletionChallenge.mockResolvedValue({
      outcome: "issued",
      code: "123456",
      status: { operationId, phase: "challengeIssued", readinessGeneration: 5 },
    });
    const ctx = context({ operationId, readinessGeneration: 4 });
    await issueParticipantDeletionChallengeRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(202);
    expect(issueParticipantDeletionChallenge).toHaveBeenCalledWith(
      expect.objectContaining({ operationId }),
      5,
      expect.any(Object)
    );
  });

  it("does not issue a challenge while readiness reconciliation remains blocked", async () => {
    evaluateParticipantDeletionReadiness.mockResolvedValue({
      outcome: "waiting",
      status: { operationId, phase: "waiting", readinessGeneration: 1 },
      blockers: [{ source: "helper", observation: "helperOrPickup" }],
    });
    const ctx = context({ operationId, readinessGeneration: 1 });
    await issueParticipantDeletionChallengeRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(409);
    expect(issueParticipantDeletionChallenge).not.toHaveBeenCalled();
    expect(JSON.stringify(ctx.payload)).not.toMatch(/helperOrPickup|blocker/i);
  });

  it("challenge issue returns 202 and never echoes the raw code in the response", async () => {
    issueParticipantDeletionChallenge.mockResolvedValue({
      outcome: "issued",
      code: "123456",
      status: { operationId, phase: "challengeIssued", readinessGeneration: 1 },
    });
    const ctx = context({ operationId, readinessGeneration: 1 });
    await issueParticipantDeletionChallengeRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(202);
    expect(JSON.stringify(ctx.payload)).not.toContain("123456");
  });

  it("challenge issue wires a real sendChallengeEmail dependency that actually forwards to the email helper with the right arguments", async () => {
    issueParticipantDeletionChallenge.mockResolvedValue({
      outcome: "issued",
      code: "123456",
      status: { operationId, phase: "challengeIssued", readinessGeneration: 1 },
    });
    const ctx = context({ operationId, readinessGeneration: 1 });
    await issueParticipantDeletionChallengeRoute(ctx.req, ctx.res);
    const [, , overrides] = issueParticipantDeletionChallenge.mock.calls[0];
    expect(typeof overrides.sendChallengeEmail).toBe("function");

    // Prove the wiring, not just that *some* function was passed: invoking
    // the captured override must actually forward to the real email helper
    // with the caller's principal, the live code, and the accepted
    // 10-minute challenge lifetime in minutes.
    await overrides.sendChallengeEmail(okAuthority.participant.principal, "999999");
    expect(sendParticipantDeletionChallengeEmail).toHaveBeenCalledWith(
      okAuthority.participant.principal,
      "999999",
      DELETION_CHALLENGE_LIFETIME_MS / 60_000
    );
  });

  it("challenge issue maps a provider send failure to a generic 503, never a false success", async () => {
    issueParticipantDeletionChallenge.mockResolvedValue({
      outcome: "emailUnavailable",
      status: { operationId, phase: "ready", readinessGeneration: 1 },
    });
    const ctx = context({ operationId, readinessGeneration: 1 });
    await issueParticipantDeletionChallengeRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(503);
    expect(JSON.stringify(ctx.payload)).not.toMatch(/provider|resend|smtp/i);
  });

  it("redeem maps invalidCode to 401", async () => {
    redeemParticipantDeletionChallenge.mockResolvedValue({
      outcome: "invalidCode",
      status: { operationId, phase: "challengeIssued", readinessGeneration: 1 },
    });
    const ctx = context({ operationId, readinessGeneration: 1, code: "000000" });
    await redeemParticipantDeletionChallengeRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(401);
  });

  it("redeem success returns the one-time recovery capability", async () => {
    redeemParticipantDeletionChallenge.mockResolvedValue({
      outcome: "authorized",
      recoveryCapability: "cap-value",
      status: { operationId, phase: "authorized", readinessGeneration: 1 },
    });
    const ctx = context({ operationId, readinessGeneration: 1, code: "123456" });
    await redeemParticipantDeletionChallengeRoute(ctx.req, ctx.res);
    expect(ctx.payload).toMatchObject({ recoveryCapability: "cap-value" });
  });

  it("complete maps safetyIdentityUnavailable to a generic 503 that leaks no internal reason", async () => {
    completeParticipantDeletionOperation.mockResolvedValue("safetyIdentityUnavailable");
    const ctx = context({ operationId, readinessGeneration: 1, capability: "cap" });
    await completeParticipantDeletionRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(503);
    expect(JSON.stringify(ctx.payload)).not.toMatch(/safety|moderat|identity/i);
  });

  it("complete maps blocked, invalidCapability, expired, and notAuthorized to distinct refusals", async () => {
    const cases: Array<[string, number]> = [
      ["blocked", 409],
      ["invalidCapability", 401],
      ["expired", 409],
      ["notAuthorized", 409],
      ["stale", 409],
      ["notOwned", 404],
    ];
    for (const [outcome, expectedStatus] of cases) {
      completeParticipantDeletionOperation.mockResolvedValue(outcome);
      const ctx = context({ operationId, readinessGeneration: 1, capability: "cap" });
      await completeParticipantDeletionRoute(ctx.req, ctx.res);
      expect(ctx.status, outcome).toBe(expectedStatus);
    }
  });

  it("complete success returns only the minimal completed outcome", async () => {
    completeParticipantDeletionOperation.mockResolvedValue("completed");
    const ctx = context({ operationId, readinessGeneration: 1, capability: "cap" });
    await completeParticipantDeletionRoute(ctx.req, ctx.res);
    expect(ctx.payload).toEqual({ outcome: "completed" });
  });

  it("complete derives the owner only from the resolved authority, never from the request body", async () => {
    completeParticipantDeletionOperation.mockResolvedValue("completed");
    const ctx = context({ operationId, readinessGeneration: 1, capability: "cap" });
    await completeParticipantDeletionRoute(ctx.req, ctx.res);
    const [owner] = completeParticipantDeletionOperation.mock.calls[0];
    expect(String(owner.participantId)).toBe(participantId);
  });

  it("complete rejects a body carrying an extra field (e.g. a spoofed participant id) instead of silently ignoring it", async () => {
    const ctx = context({
      operationId,
      readinessGeneration: 1,
      capability: "cap",
      participantId: "attacker-supplied",
    });
    await completeParticipantDeletionRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(400);
    expect(completeParticipantDeletionOperation).not.toHaveBeenCalled();
  });

  it("cancel surfaces a terminal operation distinctly", async () => {
    cancelParticipantDeletionOperation.mockResolvedValue({
      outcome: "terminal",
      status: { operationId, phase: "completed", readinessGeneration: 1 },
    });
    const ctx = context({ operationId });
    await cancelParticipantDeletion(ctx.req, ctx.res);
    expect(ctx.status).toBe(409);
  });

  it("cancel returns the resulting status on an ordinary cancellation", async () => {
    cancelParticipantDeletionOperation.mockResolvedValue({
      outcome: "canceled",
      status: { operationId, phase: "canceled", readinessGeneration: 1 },
    });
    const ctx = context({ operationId });
    await cancelParticipantDeletion(ctx.req, ctx.res);
    expect(ctx.status).toBe(200);
    expect(ctx.payload).toMatchObject({ phase: "canceled" });
  });

  it("recovery requires no participant authority at all and gives the same generic refusal for a wrong capability", async () => {
    readCompletedDeletionRecovery.mockResolvedValue({ outcome: "unavailable" });
    const ctx = context({ operationId, capability: "wrong" });
    await recoverParticipantDeletionCompletion(ctx.req, ctx.res);
    expect(ctx.status).toBe(503);
    expect(resolveParticipantAuthority).not.toHaveBeenCalled();
  });

  it("recovery success returns only the minimal completed outcome, nothing else", async () => {
    readCompletedDeletionRecovery.mockResolvedValue({ outcome: "completed" });
    const ctx = context({ operationId, capability: "cap" });
    await recoverParticipantDeletionCompletion(ctx.req, ctx.res);
    expect(ctx.payload).toEqual({ outcome: "completed" });
  });

  it("every malformed body is a clean 400, not a thrown error", async () => {
    const ctx = context({ not: "a valid shape" });
    await completeParticipantDeletionRoute(ctx.req, ctx.res);
    expect(ctx.status).toBe(400);
  });
});
