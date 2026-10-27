import { randomUUID } from "node:crypto";
import mongoose from "mongoose";
import { establishRequestOperationLedger } from "./requestOperationAuthority.js";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, ParticipantDeletionOperation, ParticipantVerification } from "../models/db.js";
import {
  createOrResolveParticipantDeletionOperation,
  issueParticipantDeletionChallenge,
  readParticipantDeletionStatus,
  redeemParticipantDeletionChallenge,
  type DeletionOwner,
  type ParticipantDeletionDependencies,
} from "./participantDeletionOperations.js";
import {
  issueParticipantVerificationChallenge,
  redeemParticipantVerificationCode,
  type ParticipantVerificationDependencies,
} from "./participantVerification.js";
import { SAFETY_IDENTITY_KEYRING_ENV, readSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_p2_challenge_delivery`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const deletionSecret = Buffer.from("f".repeat(32));
const verificationSecret = Buffer.from("g".repeat(32));
const safetyKeyring = readSafetyIdentityKeyring({
  [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
    current: "k1",
    keys: { k1: Buffer.alloc(32, 0x61).toString("base64url") },
  }),
});
let now = new Date("2026-10-24T09:00:00.000Z");

function deletionDependencies(
  overrides: Partial<ParticipantDeletionDependencies> = {}
): Partial<ParticipantDeletionDependencies> {
  return {
    now: () => now,
    readSecret: () => deletionSecret,
    generateOperationId: randomUUID,
    generateCode: () => "111111",
    sendChallengeEmail: async () => {},
    ...overrides,
  };
}

async function readyOperation(email: string) {
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
    deletionDependencies()
  );
  const owner: DeletionOwner = {
    operationId: created.status.operationId,
    participantId,
    canonicalEmail: email,
    authorityVersion: 1,
  };
  return { owner, participantId };
}

async function internalRow(operationId: string) {
  return ParticipantDeletionOperation.findOne({ operationId })
    .select(
      "+participantId +emailBinding +authorityVersion +challengeDigest +challengeIssuedAt " +
        "+challengeCooldownEndsAt +challengeExpiresAt +challengeAttemptsRemaining +authorizedAt +authorizationExpiresAt"
    )
    .lean()
    .exec();
}

describeMongo("W4-P2 deletion challenge email delivery (real Mongo)", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
    await establishRequestOperationLedger();
    await prepareParticipantIdentityMongoTestState();
    await Promise.all([
      Participant.createIndexes(),
      ParticipantDeletionOperation.syncIndexes(),
      ParticipantVerification.createIndexes(),
    ]);
  });

  beforeEach(() => {
    now = new Date("2026-10-24T09:00:00.000Z");
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await Promise.all([
      Participant.deleteMany({}),
      ParticipantDeletionOperation.deleteMany({}),
      ParticipantVerification.deleteMany({}),
    ]);
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("a ready operation sends the deletion challenge to the exact bound canonical email, with the exact live code", async () => {
    const email = "delivery-ready@nyu.edu";
    const { owner } = await readyOperation(email);
    const sendChallengeEmail = vi.fn(async () => {});

    const result = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({
      generateCode: () => "246810",
      sendChallengeEmail,
    }));

    expect(result.outcome).toBe("issued");
    expect(sendChallengeEmail).toHaveBeenCalledTimes(1);
    expect(sendChallengeEmail).toHaveBeenCalledWith(email, "246810");
    const row = await internalRow(owner.operationId);
    expect(row?.phase).toBe("challengeIssued");
  });

  it("a waiting operation sends nothing", async () => {
    const email = "delivery-waiting@nyu.edu";
    const participantId = new mongoose.Types.ObjectId();
    await Participant.create({ _id: participantId, email, verifiedAt: now, authorityVersion: 1 });
    const created = await createOrResolveParticipantDeletionOperation(
      { participantId, canonicalEmail: email, authorityVersion: 1, initialPhase: "waiting" },
      deletionDependencies()
    );
    const owner: DeletionOwner = { operationId: created.status.operationId, participantId, canonicalEmail: email, authorityVersion: 1 };
    const sendChallengeEmail = vi.fn(async () => {});

    const result = await issueParticipantDeletionChallenge(owner, 0, deletionDependencies({ sendChallengeEmail }));

    expect(result.outcome).toBe("notReady");
    expect(sendChallengeEmail).not.toHaveBeenCalled();
  });

  it("a stale readiness generation sends nothing", async () => {
    const email = "delivery-stale@nyu.edu";
    const { owner } = await readyOperation(email);
    const sendChallengeEmail = vi.fn(async () => {});

    const result = await issueParticipantDeletionChallenge(owner, 99, deletionDependencies({ sendChallengeEmail }));

    expect(result.outcome).toBe("stale");
    expect(sendChallengeEmail).not.toHaveBeenCalled();
  });

  it("a wrong owner binding sends nothing and fails closed rather than silently issuing", async () => {
    const email = "delivery-wrong-owner@nyu.edu";
    const { owner } = await readyOperation(email);
    const sendChallengeEmail = vi.fn(async () => {});
    const foreignOwner: DeletionOwner = { ...owner, participantId: new mongoose.Types.ObjectId() };

    await expect(
      issueParticipantDeletionChallenge(foreignOwner, 1, deletionDependencies({ sendChallengeEmail }))
    ).rejects.toThrow();
    expect(sendChallengeEmail).not.toHaveBeenCalled();
  });

  it("another participant cannot cause challenge delivery for this operation (cross-owner isolation)", async () => {
    const email = "delivery-victim@nyu.edu";
    const { owner } = await readyOperation(email);
    const attackerId = new mongoose.Types.ObjectId();
    await Participant.create({ _id: attackerId, email: "delivery-attacker@nyu.edu", verifiedAt: now, authorityVersion: 1 });
    const sendChallengeEmail = vi.fn(async () => {});
    const spoofedOwner: DeletionOwner = { ...owner, canonicalEmail: "delivery-attacker@nyu.edu" };

    await expect(
      issueParticipantDeletionChallenge(spoofedOwner, 1, deletionDependencies({ sendChallengeEmail }))
    ).rejects.toThrow();
    expect(sendChallengeEmail).not.toHaveBeenCalled();
  });

  it("a resend before the one-minute cooldown is refused and delivers nothing a second time", async () => {
    const email = "delivery-cooldown@nyu.edu";
    const { owner } = await readyOperation(email);
    const sendChallengeEmail = vi.fn(async () => {});

    const first = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ sendChallengeEmail, generateCode: () => "111111" }));
    expect(first.outcome).toBe("issued");
    const second = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ sendChallengeEmail, generateCode: () => "222222" }));
    expect(second.outcome).toBe("cooldown");
    expect(sendChallengeEmail).toHaveBeenCalledTimes(1);
    expect(sendChallengeEmail).toHaveBeenCalledWith(email, "111111");
  });

  it("a resend after the cooldown interval delivers a fresh distinct code", async () => {
    const email = "delivery-resend@nyu.edu";
    const { owner } = await readyOperation(email);
    const sendChallengeEmail = vi.fn(async () => {});

    const first = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ sendChallengeEmail, generateCode: () => "111111" }));
    expect(first.outcome).toBe("issued");
    now = new Date(now.getTime() + 61_000);
    const second = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ sendChallengeEmail, generateCode: () => "222222" }));
    expect(second.outcome).toBe("issued");
    expect(sendChallengeEmail).toHaveBeenCalledTimes(2);
    expect(sendChallengeEmail).toHaveBeenNthCalledWith(1, email, "111111");
    expect(sendChallengeEmail).toHaveBeenNthCalledWith(2, email, "222222");
    // Only the second, freshly issued code redeems; the first no longer does.
    await expect(redeemParticipantDeletionChallenge(owner, 1, "111111", deletionDependencies()))
      .resolves.toMatchObject({ outcome: "invalidCode" });
    await expect(redeemParticipantDeletionChallenge(owner, 1, "222222", deletionDependencies()))
      .resolves.toMatchObject({ outcome: "authorized" });
  });

  it("provider failure never leaves a falsely usable success state: the operation reverts to ready and the code it tried to send never redeems", async () => {
    const email = "delivery-provider-failure@nyu.edu";
    const { owner } = await readyOperation(email);
    const sendChallengeEmail = vi.fn(async () => {
      throw new Error("provider is down");
    });

    const result = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ sendChallengeEmail, generateCode: () => "999999" }));

    expect(result.outcome).toBe("emailUnavailable");
    expect(sendChallengeEmail).toHaveBeenCalledTimes(1);
    const status = await readParticipantDeletionStatus(owner, deletionDependencies());
    expect(status).toMatchObject({ phase: "ready" });
    // The code the (failed) send attempted to deliver can never redeem,
    // because the challenge it belonged to was reverted, not left live.
    await expect(redeemParticipantDeletionChallenge(owner, 1, "999999", deletionDependencies()))
      .resolves.toMatchObject({ outcome: "notRedeemable" });
    // The one-minute resend cooldown is a write-time property of the
    // original issue attempt and, by accepted design, survives a reverted
    // challenge exactly the way it survives an ordinary demotion/expiry
    // ("the last issue's cooldown survives exhaustion of its live
    // challenge") — so an immediate retry still correctly sees "cooldown",
    // not a second silent failure.
    const immediateRetry = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ generateCode: () => "888888" }));
    expect(immediateRetry.outcome).toBe("cooldown");
    // Once past that same cooldown, a fresh issue works normally — the
    // earlier failure left no other residue.
    now = new Date(now.getTime() + 61_000);
    const retry = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ generateCode: () => "888888" }));
    expect(retry.outcome).toBe("issued");
  });

  it("a send failure's compensation cannot demote a newer, already-superseding challenge (generation/digest-pinned revert)", async () => {
    const email = "delivery-superseded@nyu.edu";
    const { owner } = await readyOperation(email);
    let failFirst = true;
    const sendChallengeEmail = vi.fn(async () => {
      if (failFirst) {
        failFirst = false;
        throw new Error("provider is down");
      }
    });

    // First attempt fails and reverts to ready. The resend cooldown it
    // wrote survives that revert by accepted design, so the next attempt
    // must be past it to actually reach the write stage this test cares
    // about (the compensation's own digest/generation pinning), not just
    // re-observe the still-live cooldown.
    const first = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ sendChallengeEmail, generateCode: () => "111111" }));
    expect(first.outcome).toBe("emailUnavailable");
    now = new Date(now.getTime() + 61_000);
    const second = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ sendChallengeEmail, generateCode: () => "222222" }));
    expect(second.outcome).toBe("issued");
    const row = await internalRow(owner.operationId);
    expect(row?.phase).toBe("challengeIssued");
    await expect(redeemParticipantDeletionChallenge(owner, 1, "222222", deletionDependencies()))
      .resolves.toMatchObject({ outcome: "authorized" });
  });

  it("the public outcome never carries the raw code, and no console output carries the raw code or canonical email", async () => {
    const email = "delivery-no-leak@nyu.edu";
    const { owner } = await readyOperation(email);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const sendChallengeEmail = vi.fn(async () => {
      throw new Error("provider is down");
    });

    const result = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ sendChallengeEmail, generateCode: () => "135791" }));

    expect(JSON.stringify(result)).not.toContain("135791");
    expect(JSON.stringify(result)).not.toContain(email);
    for (const call of errorSpy.mock.calls) {
      const joined = call.map((arg) => String(arg)).join(" ");
      expect(joined).not.toContain("135791");
      expect(joined).not.toContain(email);
    }
    errorSpy.mockRestore();
  });

  it("an ordinary participant-verification code cannot redeem as a deletion challenge, and the reverse also fails", async () => {
    const email = "delivery-cross-purpose@nyu.edu";
    const { owner } = await readyOperation(email);

    // Issue a real deletion challenge.
    const deletionIssued = await issueParticipantDeletionChallenge(owner, 1, deletionDependencies({ generateCode: () => "444444" }));
    expect(deletionIssued.outcome).toBe("issued");

    // Issue a real ordinary verification challenge for the same email, a
    // different purpose-bound domain and a different persisted collection.
    const verificationDeps: ParticipantVerificationDependencies = {
      now: () => now,
      generateCode: () => "555555",
      readSecret: () => verificationSecret,
      sendVerificationEmail: async () => {},
      readSafetyKeyring: () => safetyKeyring,
    };
    const verificationIssued = await issueParticipantVerificationChallenge(email, verificationDeps);
    expect(verificationIssued.outcome).toBe("issued");

    // The deletion challenge's own code cannot redeem as ordinary verification.
    await expect(redeemParticipantVerificationCode(email, "444444", verificationDeps))
      .resolves.toMatchObject({ outcome: "invalidCode" });
    // The ordinary verification code cannot redeem as a deletion challenge.
    await expect(redeemParticipantDeletionChallenge(owner, 1, "555555", deletionDependencies()))
      .resolves.toMatchObject({ outcome: "invalidCode" });
    // Each purpose's own real code still redeems correctly on its own channel.
    await expect(redeemParticipantDeletionChallenge(owner, 1, "444444", deletionDependencies()))
      .resolves.toMatchObject({ outcome: "authorized" });
    await expect(redeemParticipantVerificationCode(email, "555555", verificationDeps))
      .resolves.toMatchObject({ outcome: "verified" });
  });
});
