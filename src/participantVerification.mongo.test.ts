import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  Participant,
  ParticipantBlock,
  ParticipantVerification,
} from "../models/db.js";
import { MODERATION_MODELS, establishModerationIndexes } from "../models/moderation.js";
import {
  MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES,
  digestVerificationCode,
  verifyParticipantAuthority,
} from "./participantCredentials.js";
import {
  VERIFICATION_CODE_LIFETIME_MS,
  VERIFICATION_MAXIMUM_ATTEMPTS,
  VERIFICATION_REDEMPTION_REPLAY_MS,
  VERIFICATION_RESEND_COOLDOWN_MS,
  issueParticipantAuthority,
  issueParticipantVerificationChallenge,
  redeemParticipantVerificationCode,
  type ParticipantVerificationDependencies,
} from "./participantVerification.js";
import { readSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";
import {
  blockSafetyIdentityFields,
  prepareParticipantIdentityMongoTestState,
} from "./participantIdentityMongoTestSupport.js";

/**
 * The participant verification lifecycle against a real replica set.
 *
 * This is where the conditional-mutation claims are actually settled: that a
 * resend supersedes rather than accumulates, that concurrent redemption yields
 * one coherent outcome, that concurrent wrong guesses cannot both spend the
 * same attempt, and that one address is one participant no matter how many
 * verifications race. None of those can be proved against stubs.
 */
const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

const secret = Buffer.from(
  "p".repeat(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES)
);
const principal = "student@nyu.edu";
const other = "other@stern.nyu.edu";
const participantKeyring = readSafetyIdentityKeyring({
  SAFETY_IDENTITY_KEYRING: JSON.stringify({
    current: "verification-test",
    keys: { "verification-test": Buffer.alloc(32, 0x52).toString("base64url") },
  }),
});

function dependencies(
  overrides: Partial<ParticipantVerificationDependencies> = {}
): ParticipantVerificationDependencies {
  return {
    now: () => new Date(),
    generateCode: () => "424242",
    readSecret: () => secret,
    sendVerificationEmail: vi.fn().mockResolvedValue(undefined),
    readSafetyKeyring: () => participantKeyring,
    ...overrides,
  };
}

/** The stored row including its `select: false` digest. */
async function storedChallenge(email = principal) {
  return ParticipantVerification.findOne({ email })
    .select("+codeDigest")
    .lean<{
      codeDigest: string;
      issuedAt: Date;
      expiresAt: Date;
      attemptsRemaining: number;
      redeemedAt?: Date | null;
      deleteAt: Date;
    } | null>()
    .exec();
}

describeMongo("participant verification against real MongoDB", () => {
  beforeAll(async () => {
    // Its own database. The runner executes Mongo files concurrently and this
    // suite clears whole collections between cases, so sharing a database
    // would let it delete another suite's fixtures mid-test.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_participant_test",
    });
    await prepareParticipantIdentityMongoTestState();
    await Participant.createIndexes();
    await ParticipantBlock.createIndexes();
    await ParticipantVerification.createIndexes();
    await establishModerationIndexes();
  });

  afterEach(async () => {
    await ParticipantVerification.deleteMany({});
    await ParticipantBlock.deleteMany({});
    await Participant.deleteMany({});
    for (const model of MODERATION_MODELS) await model.deleteMany({});
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  describe("challenge issue and supersede", () => {
    it("persists only the keyed digest, and a TTL past the deadline", async () => {
      const now = new Date();
      const result = await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => now })
      );

      expect(result.outcome).toBe("issued");
      const stored = await storedChallenge();
      expect(stored).not.toBeNull();
      expect(stored!.codeDigest).toBe(
        digestVerificationCode(principal, "424242", secret)
      );
      expect(stored!.codeDigest).not.toContain("424242");
      expect(stored!.expiresAt.getTime()).toBe(
        now.getTime() + VERIFICATION_CODE_LIFETIME_MS
      );
      expect(stored!.deleteAt.getTime()).toBeGreaterThan(
        stored!.expiresAt.getTime()
      );
      expect(stored!.attemptsRemaining).toBe(VERIFICATION_MAXIMUM_ATTEMPTS);
    });

    it("keeps the digest out of an ordinary read", async () => {
      await issueParticipantVerificationChallenge(principal, dependencies());

      const projected = await ParticipantVerification.findOne({
        email: principal,
      })
        .lean<Record<string, unknown>>()
        .exec();

      expect(projected).not.toBeNull();
      expect(projected).not.toHaveProperty("codeDigest");
    });

    it("supersedes the previous code instead of leaving two live", async () => {
      const first = new Date();
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => first, generateCode: () => "111111" })
      );
      const later = new Date(
        first.getTime() + VERIFICATION_RESEND_COOLDOWN_MS + 1
      );
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => later, generateCode: () => "222222" })
      );

      expect(await ParticipantVerification.countDocuments({})).toBe(1);
      // The superseded code is dead the moment the replacement is written.
      await expect(
        redeemParticipantVerificationCode(
          principal,
          "111111",
          dependencies({ now: () => later })
        )
      ).resolves.toMatchObject({ outcome: "invalidCode" });
      await expect(
        redeemParticipantVerificationCode(
          principal,
          "222222",
          dependencies({ now: () => later })
        )
      ).resolves.toMatchObject({ outcome: "verified" });
    });

    it("restores the full attempt allowance on a resend", async () => {
      const first = new Date();
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => first, generateCode: () => "111111" })
      );
      for (let attempt = 0; attempt < VERIFICATION_MAXIMUM_ATTEMPTS; attempt += 1) {
        await redeemParticipantVerificationCode(
          principal,
          "999999",
          dependencies({ now: () => first })
        );
      }
      expect((await storedChallenge())!.attemptsRemaining).toBe(0);

      const later = new Date(
        first.getTime() + VERIFICATION_RESEND_COOLDOWN_MS + 1
      );
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => later, generateCode: () => "222222" })
      );

      expect((await storedChallenge())!.attemptsRemaining).toBe(
        VERIFICATION_MAXIMUM_ATTEMPTS
      );
    });

    it("refuses a resend inside the cooldown without touching the stored code", async () => {
      const first = new Date();
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => first, generateCode: () => "111111" })
      );
      const before = await storedChallenge();

      const send = vi.fn().mockResolvedValue(undefined);
      const result = await issueParticipantVerificationChallenge(
        principal,
        dependencies({
          now: () => new Date(first.getTime() + 1_000),
          generateCode: () => "222222",
          sendVerificationEmail: send,
        })
      );

      expect(result.outcome).toBe("cooldown");
      expect(send).not.toHaveBeenCalled();
      expect(await storedChallenge()).toEqual(before);
    });

    it("removes its own challenge when the code cannot be mailed", async () => {
      const result = await issueParticipantVerificationChallenge(
        principal,
        dependencies({
          sendVerificationEmail: vi
            .fn()
            .mockRejectedValue(new Error("provider down")),
        })
      );

      expect(result.outcome).toBe("emailUnavailable");
      // Nothing to wait out and nothing to guess against.
      expect(await storedChallenge()).toBeNull();
    });

    it("keeps one live challenge per address under concurrent issues", async () => {
      const now = new Date();
      const results = await Promise.all(
        Array.from({ length: 8 }, (_unused, index) =>
          issueParticipantVerificationChallenge(
            principal,
            dependencies({
              now: () => now,
              generateCode: () => String(100000 + index),
            })
          )
        )
      );

      expect(await ParticipantVerification.countDocuments({})).toBe(1);
      // Exactly one winner. The cooldown is enforced by the conditional write
      // itself, so the losers neither mailed a code nor overwrote the winner's.
      expect(
        results.filter((result) => result.outcome === "issued")
      ).toHaveLength(1);
      expect(
        results.filter((result) => result.outcome === "cooldown")
      ).toHaveLength(results.length - 1);
    });

    it("keeps two addresses' challenges independent", async () => {
      const now = new Date();
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => now, generateCode: () => "111111" })
      );
      await issueParticipantVerificationChallenge(
        other,
        dependencies({ now: () => now, generateCode: () => "222222" })
      );

      // A code mailed to one address must not verify the other, even when both
      // challenges are live: the digest is bound to its own principal.
      await expect(
        redeemParticipantVerificationCode(
          principal,
          "222222",
          dependencies({ now: () => now })
        )
      ).resolves.toMatchObject({ outcome: "invalidCode" });
      await expect(
        redeemParticipantVerificationCode(
          other,
          "222222",
          dependencies({ now: () => now })
        )
      ).resolves.toMatchObject({ outcome: "verified" });
    });
  });

  /**
   * Concurrent resend, against a challenge that is already past its cooldown.
   *
   * This is the case a read-then-write cannot survive: both callers read an
   * eligible challenge, both decide they may issue, both mail a code, and the
   * second write replaces the first's digest — leaving one inbox holding two
   * codes and the database recognizing exactly one of them, with no way for
   * either caller to know which. Every case here starts from a real
   * cooldown-eligible row rather than an empty collection.
   */
  describe("concurrent resend", () => {
    async function cooldownEligibleChallenge() {
      const first = new Date();
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => first, generateCode: () => "111111" })
      );
      return new Date(first.getTime() + VERIFICATION_RESEND_COOLDOWN_MS + 1);
    }

    it("mails exactly one code and leaves exactly that code redeemable", async () => {
      const now = await cooldownEligibleChallenge();
      const mailed: string[] = [];

      const results = await Promise.all(
        Array.from({ length: 6 }, (_unused, index) =>
          issueParticipantVerificationChallenge(
            principal,
            dependencies({
              now: () => now,
              generateCode: () => String(200000 + index),
              sendVerificationEmail: async (_principal, code) => {
                mailed.push(code);
              },
            })
          )
        )
      );

      const issued = results.filter((result) => result.outcome === "issued");
      expect(issued).toHaveLength(1);
      expect(mailed).toHaveLength(1);
      expect(await ParticipantVerification.countDocuments({})).toBe(1);

      // The one mailed code is the one the database recognizes: the winner was
      // not orphaned by a loser's overwrite.
      const stored = await storedChallenge();
      expect(stored!.codeDigest).toBe(
        digestVerificationCode(principal, mailed[0], secret)
      );
      await expect(
        redeemParticipantVerificationCode(
          principal,
          mailed[0],
          dependencies({ now: () => now })
        )
      ).resolves.toMatchObject({ outcome: "verified" });
    });

    it("leaves the superseded code dead after a concurrent resend", async () => {
      const now = await cooldownEligibleChallenge();

      await Promise.all(
        Array.from({ length: 4 }, (_unused, index) =>
          issueParticipantVerificationChallenge(
            principal,
            dependencies({
              now: () => now,
              generateCode: () => String(300000 + index),
            })
          )
        )
      );

      await expect(
        redeemParticipantVerificationCode(
          principal,
          "111111",
          dependencies({ now: () => now })
        )
      ).resolves.toMatchObject({ outcome: "invalidCode" });
    });

    it("rolls back only its own attempt when the winner's send fails", async () => {
      const now = await cooldownEligibleChallenge();

      const result = await issueParticipantVerificationChallenge(
        principal,
        dependencies({
          now: () => now,
          generateCode: () => "500001",
          sendVerificationEmail: vi
            .fn()
            .mockRejectedValue(new Error("provider down")),
        })
      );

      expect(result.outcome).toBe("emailUnavailable");
      // Nothing to wait out, nothing to guess against, and the superseded code
      // stays superseded — it was replaced by the write, not restored by the
      // rollback.
      expect(await storedChallenge()).toBeNull();
      await expect(
        redeemParticipantVerificationCode(
          principal,
          "111111",
          dependencies({ now: () => now })
        )
      ).resolves.toMatchObject({ outcome: "noChallenge" });
    });

    it("keeps replacement B when attempt A's delayed provider failure cleans up", async () => {
      const attemptATime = await cooldownEligibleChallenge();
      let signalAttemptASendStarted!: () => void;
      const attemptASendStarted = new Promise<void>((resolve) => {
        signalAttemptASendStarted = resolve;
      });
      let failAttemptA!: () => void;
      const delayedAttemptAFailure = new Promise<void>((_resolve, reject) => {
        failAttemptA = () => reject(new Error("delayed provider failure"));
      });

      // A owns the conditional write, then remains suspended inside the real
      // provider-await boundary. Its cleanup has not run yet.
      const attemptA = issueParticipantVerificationChallenge(
        principal,
        dependencies({
          now: () => attemptATime,
          generateCode: () => "800001",
          sendVerificationEmail: async () => {
            signalAttemptASendStarted();
            await delayedAttemptAFailure;
          },
        })
      );
      await attemptASendStarted;
      expect((await storedChallenge())!.codeDigest).toBe(
        digestVerificationCode(principal, "800001", secret)
      );

      // Backend time advances beyond A's cooldown while A's provider request
      // is still unresolved. B replaces A and successfully mails its code.
      const attemptBTime = new Date(
        attemptATime.getTime() + VERIFICATION_RESEND_COOLDOWN_MS + 1
      );
      const attemptB = await issueParticipantVerificationChallenge(
        principal,
        dependencies({
          now: () => attemptBTime,
          generateCode: () => "800002",
          sendVerificationEmail: vi.fn().mockResolvedValue(undefined),
        })
      );
      expect(attemptB.outcome).toBe("issued");
      expect((await storedChallenge())!.codeDigest).toBe(
        digestVerificationCode(principal, "800002", secret)
      );

      // A now fails and executes its production cleanup. The compare-and-set
      // ownership filter names A's digest and issuing instant, so it cannot
      // delete, restore, or replace B.
      failAttemptA();
      await expect(attemptA).resolves.toMatchObject({
        outcome: "emailUnavailable",
      });
      const afterDelayedCleanup = await storedChallenge();
      expect(afterDelayedCleanup).not.toBeNull();
      expect(afterDelayedCleanup!.issuedAt).toEqual(attemptBTime);
      expect(afterDelayedCleanup!.codeDigest).toBe(
        digestVerificationCode(principal, "800002", secret)
      );

      await expect(
        redeemParticipantVerificationCode(
          principal,
          "800002",
          dependencies({ now: () => attemptBTime })
        )
      ).resolves.toMatchObject({ outcome: "verified" });
      await expect(
        redeemParticipantVerificationCode(
          principal,
          "800001",
          dependencies({ now: () => attemptBTime })
        )
      ).resolves.toMatchObject({ outcome: "invalidCode" });
      expect((await storedChallenge())!.codeDigest).toBe(
        digestVerificationCode(principal, "800002", secret)
      );
    });

    it("keeps the cooldown authoritative per address under concurrency", async () => {
      // Two addresses, resent at the same instant. One winner each: the
      // cooldown is a property of an address, not of the process.
      const now = await cooldownEligibleChallenge();
      await issueParticipantVerificationChallenge(
        other,
        dependencies({
          now: () => new Date(now.getTime() - VERIFICATION_RESEND_COOLDOWN_MS - 1),
          generateCode: () => "111111",
        })
      );

      const results = await Promise.all([
        ...Array.from({ length: 3 }, (_unused, index) =>
          issueParticipantVerificationChallenge(
            principal,
            dependencies({
              now: () => now,
              generateCode: () => String(600000 + index),
            })
          )
        ),
        ...Array.from({ length: 3 }, (_unused, index) =>
          issueParticipantVerificationChallenge(
            other,
            dependencies({
              now: () => now,
              generateCode: () => String(700000 + index),
            })
          )
        ),
      ]);

      expect(
        results.filter((result) => result.outcome === "issued")
      ).toHaveLength(2);
      expect(await ParticipantVerification.countDocuments({})).toBe(2);
    });
  });

  describe("redemption", () => {
    async function liveChallenge(now: Date, code = "424242") {
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => now, generateCode: () => code })
      );
    }

    it("establishes one participant and a usable authority", async () => {
      const now = new Date();
      await liveChallenge(now);

      const result = await redeemParticipantVerificationCode(
        principal,
        "424242",
        dependencies({ now: () => now })
      );

      expect(result.outcome).toBe("verified");
      if (result.outcome !== "verified") return;
      expect(result.principal).toBe(principal);
      const authority = issueParticipantAuthority(result.participant, secret);
      expect(verifyParticipantAuthority(authority, secret)).toEqual({
        participantId: String(result.participant._id),
        authorityVersion: 1,
      });
      expect(await Participant.countDocuments({ email: principal })).toBe(1);
    });

    it("rebinds retained safety context without changing its event timestamps", async () => {
      const blocker = await Participant.create({
        email: other,
        verifiedAt: new Date(),
        authorityVersion: 1,
        accountFenceEpoch: 0,
      });
      const eventTime = new Date("2024-02-03T04:05:06.000Z");
      const retainedIdentity = blockSafetyIdentityFields(principal);
      const inserted = await ParticipantBlock.collection.insertOne({
        blockerParticipantId: blocker._id,
        ...retainedIdentity,
        blockedRole: "requester",
        diningLocation: "North Dining",
        interactionAt: eventTime,
        createdAt: eventTime,
        updatedAt: eventTime,
      });
      const now = new Date();
      await liveChallenge(now);

      const result = await redeemParticipantVerificationCode(
        principal,
        "424242",
        dependencies({ now: () => now })
      );

      expect(result.outcome).toBe("verified");
      if (result.outcome !== "verified") return;
      const rebound = await ParticipantBlock.collection.findOne({
        _id: inserted.insertedId,
      });
      expect(rebound).toMatchObject({
        blockedParticipantId: result.participant._id,
        ...retainedIdentity,
        createdAt: eventTime,
        updatedAt: eventTime,
      });
    });

    it("yields one coherent outcome under concurrent redemption", async () => {
      const now = new Date();
      await liveChallenge(now);

      const results = await Promise.all(
        Array.from({ length: 10 }, () =>
          redeemParticipantVerificationCode(
            principal,
            "424242",
            dependencies({ now: () => now })
          )
        )
      );

      // Every caller learns the truth — this mailbox was proved — and there is
      // exactly one participant behind all of them.
      expect(results.every((result) => result.outcome === "verified")).toBe(
        true
      );
      expect(await Participant.countDocuments({})).toBe(1);
      const ids = new Set(
        results.map((result) =>
          result.outcome === "verified" ? String(result.participant._id) : "?"
        )
      );
      expect(ids.size).toBe(1);
      // One winner stamped the receipt; nothing spent an attempt.
      const stored = await storedChallenge();
      expect(stored!.redeemedAt).toBeInstanceOf(Date);
      expect(stored!.attemptsRemaining).toBe(VERIFICATION_MAXIMUM_ATTEMPTS);
    });

    it("spends exactly one attempt per wrong guess, even concurrently", async () => {
      const now = new Date();
      await liveChallenge(now);

      await Promise.all(
        Array.from({ length: 3 }, () =>
          redeemParticipantVerificationCode(
            principal,
            "999999",
            dependencies({ now: () => now })
          )
        )
      );

      expect((await storedChallenge())!.attemptsRemaining).toBe(
        VERIFICATION_MAXIMUM_ATTEMPTS - 3
      );
    });

    it("stops accepting the right code once the attempt bound is spent", async () => {
      const now = new Date();
      await liveChallenge(now);

      for (let attempt = 0; attempt < VERIFICATION_MAXIMUM_ATTEMPTS; attempt += 1) {
        await redeemParticipantVerificationCode(
          principal,
          "999999",
          dependencies({ now: () => now })
        );
      }

      await expect(
        redeemParticipantVerificationCode(
          principal,
          "424242",
          dependencies({ now: () => now })
        )
      ).resolves.toMatchObject({ outcome: "tooManyAttempts" });
      expect(await Participant.countDocuments({})).toBe(0);
    });

    it("refuses the right code after its deadline", async () => {
      const now = new Date();
      await liveChallenge(now);
      const late = new Date(now.getTime() + VERIFICATION_CODE_LIFETIME_MS + 1);

      await expect(
        redeemParticipantVerificationCode(
          principal,
          "424242",
          dependencies({ now: () => late })
        )
      ).resolves.toMatchObject({ outcome: "expired" });
      expect(await Participant.countDocuments({})).toBe(0);
    });

    it("accepts the right code one millisecond before its deadline", async () => {
      const now = new Date();
      await liveChallenge(now);
      const justInTime = new Date(
        now.getTime() + VERIFICATION_CODE_LIFETIME_MS - 1
      );

      await expect(
        redeemParticipantVerificationCode(
          principal,
          "424242",
          dependencies({ now: () => justInTime })
        )
      ).resolves.toMatchObject({ outcome: "verified" });
    });

    it("reports an address with no challenge at all", async () => {
      await expect(
        redeemParticipantVerificationCode(
          principal,
          "424242",
          dependencies()
        )
      ).resolves.toMatchObject({ outcome: "noChallenge" });
      expect(await Participant.countDocuments({})).toBe(0);
    });

    it("re-verifying does not move the revocation counter", async () => {
      const first = new Date();
      await liveChallenge(first, "111111");
      const initial = await redeemParticipantVerificationCode(
        principal,
        "111111",
        dependencies({ now: () => first })
      );

      const later = new Date(
        first.getTime() + VERIFICATION_RESEND_COOLDOWN_MS + 1
      );
      await issueParticipantVerificationChallenge(
        principal,
        dependencies({ now: () => later, generateCode: () => "222222" })
      );
      const again = await redeemParticipantVerificationCode(
        principal,
        "222222",
        dependencies({ now: () => later })
      );

      expect(initial.outcome).toBe("verified");
      expect(again.outcome).toBe("verified");
      if (initial.outcome !== "verified" || again.outcome !== "verified") return;
      // The same person verifying again on one device must not revoke their
      // other device.
      expect(String(again.participant._id)).toBe(
        String(initial.participant._id)
      );
      expect(again.participant.authorityVersion).toBe(1);
      expect(await Participant.countDocuments({})).toBe(1);
    });

    it("makes an existing authority unusable once the version is raised", async () => {
      const now = new Date();
      await liveChallenge(now);
      const verified = await redeemParticipantVerificationCode(
        principal,
        "424242",
        dependencies({ now: () => now })
      );
      expect(verified.outcome).toBe("verified");
      if (verified.outcome !== "verified") return;
      const authority = issueParticipantAuthority(verified.participant, secret);
      const parsed = verifyParticipantAuthority(authority, secret)!;

      await Participant.updateOne(
        { _id: verified.participant._id },
        { $inc: { authorityVersion: 1 } }
      ).exec();

      // The signature still verifies — revocation is not forgery detection —
      // but the version it names no longer matches the stored one, which is
      // exactly what the gate checks against the database.
      expect(verifyParticipantAuthority(authority, secret)).toEqual(parsed);
      expect(
        await Participant.exists({
          _id: verified.participant._id,
          authorityVersion: parsed.authorityVersion,
        })
      ).toBeNull();
    });

    /**
     * The window after a successful redemption.
     *
     * Redemption does not end the challenge's usefulness to an attacker: until
     * the row stops matching, knowledge of those six digits still yields
     * participant authority. Everything here is about that window — guessing
     * into it must be bounded by the same five attempts, exhausting it must
     * retire the challenge outright, and the replay that keeps a duplicate
     * submission truthful must not last long enough to be a bearer credential.
     */
    describe("after a successful redemption", () => {
      async function redeemed(now: Date) {
        await liveChallenge(now);
        const result = await redeemParticipantVerificationCode(
          principal,
          "424242",
          dependencies({ now: () => now })
        );
        expect(result.outcome).toBe("verified");
      }

      it("spends an attempt for every wrong guess", async () => {
        const now = new Date();
        await redeemed(now);

        for (let attempt = 1; attempt <= 3; attempt += 1) {
          await expect(
            redeemParticipantVerificationCode(
              principal,
              "999999",
              dependencies({ now: () => now })
            )
          ).resolves.toMatchObject({ outcome: "invalidCode" });
          expect((await storedChallenge())!.attemptsRemaining).toBe(
            VERIFICATION_MAXIMUM_ATTEMPTS - attempt
          );
        }
      });

      it("spends exactly one attempt per concurrent wrong guess", async () => {
        const now = new Date();
        await redeemed(now);

        await Promise.all(
          Array.from({ length: 4 }, () =>
            redeemParticipantVerificationCode(
              principal,
              "999999",
              dependencies({ now: () => now })
            )
          )
        );

        expect((await storedChallenge())!.attemptsRemaining).toBe(
          VERIFICATION_MAXIMUM_ATTEMPTS - 4
        );
      });

      it("issues no further authority once the attempt bound is exhausted", async () => {
        const now = new Date();
        await redeemed(now);
        await Participant.deleteMany({});

        for (let attempt = 0; attempt < VERIFICATION_MAXIMUM_ATTEMPTS; attempt += 1) {
          await redeemParticipantVerificationCode(
            principal,
            "999999",
            dependencies({ now: () => now })
          );
        }
        expect((await storedChallenge())!.attemptsRemaining).toBe(0);

        // The right code, inside its lifetime, inside its replay window, and
        // against a challenge that was genuinely redeemed — and still refused,
        // because the challenge itself is spent.
        await expect(
          redeemParticipantVerificationCode(
            principal,
            "424242",
            dependencies({ now: () => now })
          )
        ).resolves.toMatchObject({ outcome: "tooManyAttempts" });
        expect(await Participant.countDocuments({})).toBe(0);
      });

      it("answers a duplicate submission inside the replay window", async () => {
        const now = new Date();
        await redeemed(now);
        const soon = new Date(
          now.getTime() + VERIFICATION_REDEMPTION_REPLAY_MS - 1
        );

        await expect(
          redeemParticipantVerificationCode(
            principal,
            "424242",
            dependencies({ now: () => soon })
          )
        ).resolves.toMatchObject({ outcome: "verified" });
        // Not a guess, so it spends nothing.
        expect((await storedChallenge())!.attemptsRemaining).toBe(
          VERIFICATION_MAXIMUM_ATTEMPTS
        );
      });

      it("stops issuing authority once the replay window closes", async () => {
        const now = new Date();
        await redeemed(now);
        await Participant.deleteMany({});
        const later = new Date(
          now.getTime() + VERIFICATION_REDEMPTION_REPLAY_MS + 1
        );
        // Still well inside the code's own lifetime, which is the point: the
        // spent code stops being an answer long before the challenge lapses.
        expect(later.getTime()).toBeLessThan(
          now.getTime() + VERIFICATION_CODE_LIFETIME_MS
        );

        await expect(
          redeemParticipantVerificationCode(
            principal,
            "424242",
            dependencies({ now: () => later })
          )
        ).resolves.toMatchObject({ outcome: "expired" });
        expect(await Participant.countDocuments({})).toBe(0);
        // A right-but-spent code is not a wrong guess and spends no attempt.
        expect((await storedChallenge())!.attemptsRemaining).toBe(
          VERIFICATION_MAXIMUM_ATTEMPTS
        );
      });

      it("keeps concurrent redemption coherent for every caller", async () => {
        const now = new Date();
        await liveChallenge(now);

        const results = await Promise.all(
          Array.from({ length: 8 }, () =>
            redeemParticipantVerificationCode(
              principal,
              "424242",
              dependencies({ now: () => now })
            )
          )
        );

        expect(results.every((result) => result.outcome === "verified")).toBe(
          true
        );
        expect(await Participant.countDocuments({})).toBe(1);
        expect((await storedChallenge())!.attemptsRemaining).toBe(
          VERIFICATION_MAXIMUM_ATTEMPTS
        );
      });

      it("lets a resend restore a challenge exhausted after redemption", async () => {
        const now = new Date();
        await redeemed(now);
        for (let attempt = 0; attempt < VERIFICATION_MAXIMUM_ATTEMPTS; attempt += 1) {
          await redeemParticipantVerificationCode(
            principal,
            "999999",
            dependencies({ now: () => now })
          );
        }

        const later = new Date(
          now.getTime() + VERIFICATION_RESEND_COOLDOWN_MS + 1
        );
        await issueParticipantVerificationChallenge(
          principal,
          dependencies({ now: () => later, generateCode: () => "555555" })
        );

        const stored = await storedChallenge();
        expect(stored!.attemptsRemaining).toBe(VERIFICATION_MAXIMUM_ATTEMPTS);
        expect(stored!.redeemedAt).toBeUndefined();
        await expect(
          redeemParticipantVerificationCode(
            principal,
            "555555",
            dependencies({ now: () => later })
          )
        ).resolves.toMatchObject({ outcome: "verified" });
      });
    });

    it("keeps one participant per address under concurrent first verifications", async () => {
      // Two devices verifying the same brand-new address at once must produce
      // one participant, not a duplicate-key failure or two identities.
      const now = new Date();
      await liveChallenge(now);

      await Promise.all(
        Array.from({ length: 6 }, () =>
          redeemParticipantVerificationCode(
            principal,
            "424242",
            dependencies({ now: () => now })
          )
        )
      );

      expect(await Participant.countDocuments({ email: principal })).toBe(1);
    });

    it("refuses a duplicate participant row outright", async () => {
      await Participant.create({
        email: principal,
        authorityVersion: 1,
        verifiedAt: new Date(),
      });

      await expect(
        Participant.create({
          email: principal,
          authorityVersion: 1,
          verifiedAt: new Date(),
        })
      ).rejects.toMatchObject({ code: 11000 });
    });

    it("refuses a duplicate challenge row for one address outright", async () => {
      const base = {
        email: principal,
        codeDigest: "a".repeat(64),
        issuedAt: new Date(),
        expiresAt: new Date(Date.now() + 60_000),
        attemptsRemaining: VERIFICATION_MAXIMUM_ATTEMPTS,
        deleteAt: new Date(Date.now() + 3_600_000),
      };
      await ParticipantVerification.create(base);

      await expect(ParticipantVerification.create(base)).rejects.toMatchObject({
        code: 11000,
      });
    });
  });
});
