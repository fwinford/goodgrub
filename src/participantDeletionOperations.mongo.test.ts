import { randomUUID } from "node:crypto";
import { establishRequestOperationLedger } from "./requestOperationAuthority.js";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { Participant, ParticipantDeletionOperation } from "../models/db.js";
import {
  DELETION_AUTHORIZATION_LIFETIME_MS,
  DELETION_CHALLENGE_LIFETIME_MS,
  DELETION_CHALLENGE_RESEND_COOLDOWN_MS,
} from "./participantDeletionSecurity.js";
import {
  cancelParticipantDeletionOperation,
  createOrResolveParticipantDeletionOperation,
  demoteParticipantDeletionReadiness,
  expireParticipantDeletionAuthorization,
  expireParticipantDeletionChallenge,
  issueParticipantDeletionChallenge,
  promoteParticipantDeletionReadiness,
  readParticipantDeletionStatus,
  redeemParticipantDeletionChallenge,
  type DeletionOwner,
  type ParticipantDeletionDependencies,
} from "./participantDeletionOperations.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_participant_deletion`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;
const secret = Buffer.from("d".repeat(32));
let now = new Date("2026-10-14T12:00:00.000Z");

function dependencies(
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Partial<ParticipantDeletionDependencies> {
  return {
    now: () => now,
    readSecret: () => secret,
    generateOperationId: randomUUID,
    generateCode: () => "424242",
    sendChallengeEmail: async () => {},
    ...overrides,
  };
}

async function readyOperation(email = "student@nyu.edu") {
  const participantId = new mongoose.Types.ObjectId();
  await Participant.create({
    _id: participantId,
    email,
    verifiedAt: now,
    authorityVersion: 1,
    accountFenceEpoch: 0,
  });
  const created = await createOrResolveParticipantDeletionOperation(
    { participantId, canonicalEmail: email, authorityVersion: 1, initialPhase: "ready" },
    dependencies()
  );
  const owner: DeletionOwner = {
    operationId: created.status.operationId,
    participantId,
    canonicalEmail: email,
    authorityVersion: 1,
  };
  return { owner, created };
}

type InternalDeletionRow = Record<string, unknown> & {
  phase: string;
  readinessGeneration: number;
  challengeGeneration: number;
  challengeDigest?: string;
  challengeIssuedAt?: Date;
  challengeCooldownEndsAt?: Date;
  challengeAttemptsRemaining?: number;
  authorizationExpiresAt?: Date;
};

async function internalRow(operationId: string) {
  return ParticipantDeletionOperation.findOne({ operationId })
    .select("+participantId +emailBinding +authorityVersion +challengeDigest +challengeIssuedAt +challengeCooldownEndsAt +challengeExpiresAt +challengeAttemptsRemaining +authorizedAt +authorizationExpiresAt")
    .lean<InternalDeletionRow | null>()
    .exec();
}

describeMongo("W4-P2 real Mongo participant deletion foundation", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
    await establishRequestOperationLedger();
    await ParticipantDeletionOperation.syncIndexes();
  });

  afterEach(async () => {
    now = new Date("2026-10-14T12:00:00.000Z");
    await ParticipantDeletionOperation.deleteMany({});
    await Participant.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("enforces one active lifecycle and racing starts converge on it", async () => {
    const participantId = new mongoose.Types.ObjectId();
    await Participant.create({
      _id: participantId,
      email: "student@nyu.edu",
      verifiedAt: now,
      authorityVersion: 1,
      accountFenceEpoch: 0,
    });
    const results = await Promise.all(
      Array.from({ length: 12 }, () =>
        createOrResolveParticipantDeletionOperation(
          { participantId, canonicalEmail: "student@nyu.edu", authorityVersion: 1, initialPhase: "waiting" },
          dependencies()
        )
      )
    );
    expect(await ParticipantDeletionOperation.countDocuments({})).toBe(1);
    expect(new Set(results.map((result) => result.status.operationId)).size).toBe(1);
    expect(results.filter((result) => result.outcome === "created")).toHaveLength(1);
    expect(results.every((result) => result.status.phase === "waiting")).toBe(true);
  });

  it("installs the permanent identity, active-lifecycle, and deadline indexes without a TTL cleanup", async () => {
    const indexes = await ParticipantDeletionOperation.collection.indexes();
    const byName = new Map(indexes.map((index) => [index.name, index]));
    expect(byName.get("operationId_1")).toMatchObject({ unique: true, key: { operationId: 1 } });
    expect(byName.get("participant_deletion_one_active_operation_per_participant")).toMatchObject({
      unique: true,
      key: { participantId: 1 },
      partialFilterExpression: { phase: { $in: ["waiting", "ready", "challengeIssued", "authorized"] } },
    });
    for (const name of ["participant_deletion_challenge_expiry", "participant_deletion_authorization_expiry"]) {
      expect(byName.get(name)).not.toHaveProperty("expireAfterSeconds");
    }
  });

  it("enforces permanent operation-id uniqueness under concurrent distinct starts", async () => {
    const fixedId = "11111111-1111-4111-8111-111111111111";
    const firstParticipantId = new mongoose.Types.ObjectId();
    const secondParticipantId = new mongoose.Types.ObjectId();
    await Participant.create([
      {
        _id: firstParticipantId,
        email: "one@nyu.edu",
        verifiedAt: now,
        authorityVersion: 1,
        accountFenceEpoch: 0,
      },
      {
        _id: secondParticipantId,
        email: "two@nyu.edu",
        verifiedAt: now,
        authorityVersion: 1,
        accountFenceEpoch: 0,
      },
    ]);
    const start = (participantId: mongoose.Types.ObjectId, email: string) => createOrResolveParticipantDeletionOperation(
      { participantId, canonicalEmail: email, authorityVersion: 1, initialPhase: "waiting" },
      dependencies({ generateOperationId: () => fixedId })
    );
    const settled = await Promise.allSettled([
      start(firstParticipantId, "one@nyu.edu"),
      start(secondParticipantId, "two@nyu.edu"),
    ]);
    expect(settled.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(await ParticipantDeletionOperation.countDocuments({ operationId: fixedId })).toBe(1);
  });

  it("uses a partial active index: terminal history permits a fresh later lifecycle", async () => {
    const participantId = new mongoose.Types.ObjectId();
    const input = { participantId, canonicalEmail: "student@nyu.edu", authorityVersion: 1, initialPhase: "waiting" as const };
    await Participant.create({
      _id: participantId,
      email: input.canonicalEmail,
      verifiedAt: now,
      authorityVersion: 1,
      accountFenceEpoch: 0,
    });
    const first = await createOrResolveParticipantDeletionOperation(input, dependencies());
    const owner: DeletionOwner = { operationId: first.status.operationId, participantId, canonicalEmail: input.canonicalEmail, authorityVersion: 1 };
    await expect(cancelParticipantDeletionOperation(owner, dependencies())).resolves.toMatchObject({ outcome: "canceled" });
    const second = await createOrResolveParticipantDeletionOperation(input, dependencies());
    expect(second).toMatchObject({ outcome: "created", status: { phase: "waiting" } });
    expect(second.status.operationId).not.toBe(first.status.operationId);
    expect(await ParticipantDeletionOperation.countDocuments({ participantId })).toBe(2);
  });

  it("issues/reissues only a deletion-purpose digest and projects no secret material", async () => {
    const { owner, created } = await readyOperation();
    const first = await issueParticipantDeletionChallenge(owner, 1, dependencies({ generateCode: () => "111111" }));
    expect(first.outcome).toBe("issued");
    const ordinary = await ParticipantDeletionOperation.findOne({ operationId: created.status.operationId }).lean<Record<string, unknown>>().exec();
    expect(ordinary).not.toHaveProperty("participantId");
    expect(ordinary).not.toHaveProperty("emailBinding");
    expect(ordinary).not.toHaveProperty("authorityVersion");
    expect(ordinary).not.toHaveProperty("challengeDigest");
    expect(ordinary).not.toHaveProperty("challengeCooldownEndsAt");
    expect(ordinary).not.toHaveProperty("challengeAttemptsRemaining");
    expect(first.status).not.toHaveProperty("code");
    expect(first.status).not.toHaveProperty("participantId");
    expect(first.status).not.toHaveProperty("authorityVersion");
    expect(first.status).not.toHaveProperty("emailBinding");
    const stored = await internalRow(created.status.operationId);
    expect(stored?.challengeDigest).not.toContain("111111");
    now = new Date(now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS + 1);
    const second = await issueParticipantDeletionChallenge(owner, 1, dependencies({ generateCode: () => "222222" }));
    expect(second.outcome).toBe("issued");
    await expect(redeemParticipantDeletionChallenge(owner, 1, "111111", dependencies())).resolves.toMatchObject({ outcome: "invalidCode" });
  });

  it("enforces cooldown, malformed-code non-spend, five atomic wrong attempts, and challenge expiry", async () => {
    const { owner } = await readyOperation();
    await issueParticipantDeletionChallenge(owner, 1, dependencies());
    await expect(issueParticipantDeletionChallenge(owner, 1, dependencies())).resolves.toMatchObject({ outcome: "cooldown" });
    await expect(redeemParticipantDeletionChallenge(owner, 1, "not-a-code", dependencies())).resolves.toMatchObject({ outcome: "invalidCode", status: { challenge: { attemptsRemaining: 5 } } });
    await Promise.all(Array.from({ length: 5 }, () => redeemParticipantDeletionChallenge(owner, 1, "999999", dependencies())));
    await expect(readParticipantDeletionStatus(owner, dependencies())).resolves.toMatchObject({ phase: "ready" });
    const exhausted = await internalRow(owner.operationId);
    expect(exhausted).not.toHaveProperty("challengeDigest");
    expect(exhausted).not.toHaveProperty("challengeIssuedAt");
    expect(exhausted).not.toHaveProperty("challengeExpiresAt");
    expect(exhausted).not.toHaveProperty("challengeAttemptsRemaining");
    expect(exhausted?.challengeCooldownEndsAt).toEqual(new Date(now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS));
    await expect(issueParticipantDeletionChallenge(owner, 1, dependencies())).resolves.toMatchObject({ outcome: "cooldown" });
    now = new Date(now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS - 1);
    await expect(issueParticipantDeletionChallenge(owner, 1, dependencies())).resolves.toMatchObject({ outcome: "cooldown" });
    now = new Date(now.getTime() + 1);

    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    expect(issued.outcome).toBe("issued");
    expect((await internalRow(owner.operationId))?.challengeCooldownEndsAt).toEqual(
      new Date(now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS)
    );
    now = new Date(now.getTime() + DELETION_CHALLENGE_LIFETIME_MS);
    await expect(readParticipantDeletionStatus(owner, dependencies())).resolves.toMatchObject({ phase: "ready" });
  });

  it("serializes a concurrent initial issue and later reissue to one usable generation", async () => {
    const { owner } = await readyOperation();
    const firstAt = now;
    const laterAt = new Date(now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS + 1);
    const results = await Promise.all([
      issueParticipantDeletionChallenge(owner, 1, dependencies({ now: () => firstAt, generateCode: () => "111111" })),
      issueParticipantDeletionChallenge(owner, 1, dependencies({ now: () => laterAt, generateCode: () => "222222" })),
    ]);
    const issued = results.filter((result) => result.outcome === "issued");
    expect(issued.length).toBeGreaterThanOrEqual(1);
    const row = await internalRow(owner.operationId);
    expect(row?.phase).toBe("challengeIssued");
    expect(row?.challengeGeneration).toBe(issued.length);
    const currentCode = row?.challengeIssuedAt?.getTime() === laterAt.getTime() ? "222222" : "111111";
    const otherCode = currentCode === "111111" ? "222222" : "111111";
    expect(row?.challengeCooldownEndsAt).toEqual(new Date(row!.challengeIssuedAt!.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS));
    await expect(redeemParticipantDeletionChallenge(owner, 1, otherCode, dependencies({ now: () => laterAt })))
      .resolves.toMatchObject({ outcome: "invalidCode" });
    expect((await internalRow(owner.operationId))?.challengeAttemptsRemaining).toBe(4);
    await expect(redeemParticipantDeletionChallenge(owner, 1, currentCode, dependencies({ now: () => laterAt })))
      .resolves.toMatchObject({ outcome: "authorized" });
    expect((await internalRow(owner.operationId))?.challengeDigest).toBeUndefined();
  });

  it("allows only one of concurrent reissues after cooldown", async () => {
    const { owner } = await readyOperation();
    await issueParticipantDeletionChallenge(owner, 1, dependencies({ generateCode: () => "111111" }));
    now = new Date(now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS);
    const results = await Promise.all([
      issueParticipantDeletionChallenge(owner, 1, dependencies({ generateCode: () => "222222" })),
      issueParticipantDeletionChallenge(owner, 1, dependencies({ generateCode: () => "333333" })),
    ]);
    const issued = results.filter((result) => result.outcome === "issued");
    expect(issued).toHaveLength(1);
    const row = await internalRow(owner.operationId);
    expect(row?.phase).toBe("challengeIssued");
    expect(row?.challengeGeneration).toBe(2);
    expect(row?.challengeCooldownEndsAt).toEqual(new Date(now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS));
    const winningCode = issued[0].code;
    expect(winningCode).toMatch(/^(222222|333333)$/);
    await expect(redeemParticipantDeletionChallenge(owner, 1, "111111", dependencies()))
      .resolves.toMatchObject({ outcome: "invalidCode" });
    await expect(redeemParticipantDeletionChallenge(owner, 1, winningCode, dependencies()))
      .resolves.toMatchObject({ outcome: "authorized" });
  });

  it("demotion racing correct redemption leaves no stale authorization", async () => {
    const { owner } = await readyOperation();
    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (issued.outcome !== "issued") throw new Error("fixture did not issue");
    const [demoted, redemption] = await Promise.all([
      demoteParticipantDeletionReadiness(owner, 1, dependencies()),
      redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies()),
    ]);
    expect(demoted).toBe(true);
    expect(["authorized", "notRedeemable", "stale"]).toContain(redemption.outcome);
    const row = await internalRow(owner.operationId);
    expect(row?.phase).toBe("waiting");
    expect(row?.readinessGeneration).toBe(1);
    expect(row).not.toHaveProperty("challengeDigest");
    expect(row).not.toHaveProperty("authorizationExpiresAt");
    await expect(promoteParticipantDeletionReadiness(owner, 1, dependencies())).resolves.toBe(true);
    await expect(redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies()))
      .resolves.toMatchObject({ outcome: "stale" });
  });

  it("normalization racing redemption enforces the exact challenge deadline", async () => {
    const { owner } = await readyOperation();
    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (issued.outcome !== "issued") throw new Error("fixture did not issue");
    const deadline = new Date(now.getTime() + DELETION_CHALLENGE_LIFETIME_MS);
    const atDeadline = dependencies({ now: () => deadline });
    await Promise.all([
      readParticipantDeletionStatus(owner, atDeadline),
      redeemParticipantDeletionChallenge(owner, 1, issued.code, atDeadline),
    ]);
    const row = await internalRow(owner.operationId);
    expect(row?.phase).toBe("ready");
    expect(row).not.toHaveProperty("challengeDigest");
    expect(row).not.toHaveProperty("authorizationExpiresAt");
    await expect(redeemParticipantDeletionChallenge(owner, 1, issued.code, atDeadline))
      .resolves.toMatchObject({ outcome: "notRedeemable" });
  });

  it("an expiry/redemption race permits only a pre-deadline winner or expiry", async () => {
    const { owner } = await readyOperation();
    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (issued.outcome !== "issued") throw new Error("fixture did not issue");
    const deadline = new Date(now.getTime() + DELETION_CHALLENGE_LIFETIME_MS);
    const justBefore = new Date(deadline.getTime() - 1);
    const [expired, redemption] = await Promise.all([
      expireParticipantDeletionChallenge(owner, 1, dependencies({ now: () => deadline })),
      redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies({ now: () => justBefore })),
    ]);
    const row = await internalRow(owner.operationId);
    expect(row).not.toHaveProperty("challengeDigest");
    if (expired) {
      expect(row?.phase).toBe("ready");
      expect(redemption.outcome).not.toBe("authorized");
      expect(row).not.toHaveProperty("authorizationExpiresAt");
    } else {
      expect(redemption.outcome).toBe("authorized");
      expect(row?.phase).toBe("authorized");
      expect(row?.authorizationExpiresAt).toEqual(new Date(justBefore.getTime() + DELETION_AUTHORIZATION_LIFETIME_MS));
    }
    await expect(redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies({ now: () => deadline })))
      .resolves.toMatchObject({ outcome: "notRedeemable" });
  });

  it("stale authorization expiry cannot erase a later redeemed challenge", async () => {
    const { owner } = await readyOperation();
    const first = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (first.outcome !== "issued") throw new Error("fixture did not issue");
    await expect(redeemParticipantDeletionChallenge(owner, 1, first.code, dependencies()))
      .resolves.toMatchObject({ outcome: "authorized" });
    const oldDeadline = new Date(now.getTime() + DELETION_AUTHORIZATION_LIFETIME_MS);
    const atOldDeadline = dependencies({ now: () => oldDeadline });
    await expect(expireParticipantDeletionAuthorization(owner, 1, atOldDeadline)).resolves.toBe(true);
    const second = await issueParticipantDeletionChallenge(owner, 1, dependencies({
      now: () => oldDeadline,
      generateCode: () => "222222",
    }));
    if (second.outcome !== "issued") throw new Error("fixture did not reissue");
    const [staleExpiry, redemption] = await Promise.all([
      expireParticipantDeletionAuthorization(owner, 1, atOldDeadline),
      redeemParticipantDeletionChallenge(owner, 1, second.code, atOldDeadline),
    ]);
    expect(staleExpiry).toBe(false);
    expect(redemption.outcome).toBe("authorized");
    const row = await internalRow(owner.operationId);
    expect(row?.phase).toBe("authorized");
    expect(row?.authorizationExpiresAt).toEqual(new Date(oldDeadline.getTime() + DELETION_AUTHORIZATION_LIFETIME_MS));
    expect(row).not.toHaveProperty("challengeDigest");
  });

  it("binds redemption to operation, participant, email, authority version, readiness, and current challenge generation", async () => {
    const { owner } = await readyOperation();
    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (issued.outcome !== "issued") throw new Error("fixture did not issue");
    const altered = [
      { ...owner, operationId: randomUUID() },
      { ...owner, participantId: new mongoose.Types.ObjectId() },
      { ...owner, canonicalEmail: "other@nyu.edu" },
      { ...owner, authorityVersion: 2 },
    ];
    for (const wrongOwner of altered) {
      await expect(redeemParticipantDeletionChallenge(wrongOwner, 1, issued.code, dependencies())).rejects.toThrow();
    }
    await expect(redeemParticipantDeletionChallenge(owner, 0, issued.code, dependencies())).resolves.toMatchObject({ outcome: "stale" });
    now = new Date(now.getTime() + DELETION_CHALLENGE_RESEND_COOLDOWN_MS + 1);
    await issueParticipantDeletionChallenge(owner, 1, dependencies({ generateCode: () => "111111" }));
    await expect(redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies())).resolves.toMatchObject({ outcome: "invalidCode" });
  });

  it("redeems exactly once to a five-minute authorization without creating another Participant or ordinary credential", async () => {
    const { owner } = await readyOperation();
    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (issued.outcome !== "issued") throw new Error("fixture did not issue");
    const outcomes = await Promise.all([
      redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies()),
      redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies()),
    ]);
    expect(outcomes.filter((result) => result.outcome === "authorized")).toHaveLength(1);
    const status = await readParticipantDeletionStatus(owner, dependencies());
    expect(status).toMatchObject({ phase: "authorized" });
    expect(status?.authorization?.expiresAt.getTime()).toBe(now.getTime() + DELETION_AUTHORIZATION_LIFETIME_MS);
    expect(await Participant.countDocuments({})).toBe(1);
    expect(await Participant.exists({ _id: owner.participantId })).not.toBeNull();
    now = new Date(now.getTime() + DELETION_AUTHORIZATION_LIFETIME_MS);
    await expect(readParticipantDeletionStatus(owner, dependencies())).resolves.toMatchObject({ phase: "ready" });
  });

  it("demotion clears a live challenge and fences stale-generation authorization", async () => {
    const { owner, created } = await readyOperation();
    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (issued.outcome !== "issued") throw new Error("fixture did not issue");
    expect(await demoteParticipantDeletionReadiness(owner, 1, dependencies())).toBe(true);
    expect(await promoteParticipantDeletionReadiness(owner, 1, dependencies())).toBe(true);
    await expect(redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies())).resolves.toMatchObject({ outcome: "stale" });
    await expect(readParticipantDeletionStatus(owner, dependencies())).resolves.toMatchObject({ phase: "ready", readinessGeneration: 2 });
    const row = await internalRow(created.status.operationId);
    expect(row).not.toHaveProperty("challengeDigest");
    expect(row).not.toHaveProperty("challengeExpiresAt");
  });

  it("demotion and cancellation invalidate authorization; cancellation wins or coherently follows redemption", async () => {
    const { owner, created } = await readyOperation();
    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (issued.outcome !== "issued") throw new Error("fixture did not issue");
    const race = await Promise.all([
      redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies()),
      cancelParticipantDeletionOperation(owner, dependencies()),
    ]);
    expect(race.some((result) => result.outcome === "canceled" || result.outcome === "authorized")).toBe(true);
    await expect(readParticipantDeletionStatus(owner, dependencies())).resolves.toMatchObject({ phase: "canceled" });
    const row = await internalRow(created.status.operationId);
    expect(row).not.toHaveProperty("authorizationExpiresAt");
    await expect(cancelParticipantDeletionOperation(owner, dependencies())).resolves.toMatchObject({ outcome: "alreadyCanceled" });
    await expect(issueParticipantDeletionChallenge(owner, 1, dependencies())).resolves.toMatchObject({ outcome: "notReady" });
  });

  it("cancels idempotently from every nonterminal phase and never resumes a canceled lifecycle", async () => {
    const phases: Array<"waiting" | "ready" | "challengeIssued" | "authorized"> = [
      "waiting", "ready", "challengeIssued", "authorized",
    ];
    for (const phase of phases) {
      const { owner } = await readyOperation(`${phase}@nyu.edu`);
      if (phase === "waiting") {
        expect(await demoteParticipantDeletionReadiness(owner, 1, dependencies())).toBe(true);
      } else if (phase === "challengeIssued" || phase === "authorized") {
        const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
        if (issued.outcome !== "issued") throw new Error("fixture did not issue");
        if (phase === "authorized") {
          await expect(redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies())).resolves.toMatchObject({ outcome: "authorized" });
        }
      }
      await expect(cancelParticipantDeletionOperation(owner, dependencies())).resolves.toMatchObject({ outcome: "canceled", status: { phase: "canceled" } });
      await expect(promoteParticipantDeletionReadiness(owner, 0, dependencies())).resolves.toBe(false);
      await expect(issueParticipantDeletionChallenge(owner, 1, dependencies())).resolves.toMatchObject({ outcome: "notReady" });
    }
  });

  it("demotes an authorized lifecycle back to waiting and invalidates its five-minute authorization", async () => {
    const { owner, created } = await readyOperation();
    const issued = await issueParticipantDeletionChallenge(owner, 1, dependencies());
    if (issued.outcome !== "issued") throw new Error("fixture did not issue");
    await expect(redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies())).resolves.toMatchObject({ outcome: "authorized" });
    expect(await demoteParticipantDeletionReadiness(owner, 1, dependencies())).toBe(true);
    await expect(readParticipantDeletionStatus(owner, dependencies())).resolves.toMatchObject({ phase: "waiting", readinessGeneration: 1 });
    const row = await internalRow(created.status.operationId);
    expect(row).not.toHaveProperty("authorizationExpiresAt");
    await expect(redeemParticipantDeletionChallenge(owner, 1, issued.code, dependencies())).resolves.toMatchObject({ outcome: "notRedeemable" });
  });
});
