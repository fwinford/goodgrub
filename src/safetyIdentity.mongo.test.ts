import mongoose, { type ClientSession } from "mongoose";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { Participant } from "../models/db.js";
import {
  MODERATION_MODELS,
  ModerationReport,
  RetentionHold,
  SafetyIdentity,
  SafetyKeyCheck,
  Suspension,
  establishModerationIndexes,
} from "../models/moderation.js";
import { createRetentionHold } from "./moderationHolds.js";
import { liftSuspension, closeReportCase, recordReportCase, recordSuspension } from "./moderationRecords.js";
import {
  InvalidSafetyIdentityPrincipalError,
  SafetyIdentityUnavailableError,
  assertSafetyIdentityKeysAvailable,
  checkParticipantCreationRestriction,
  confirmSafetyIdentity,
  ensureSafetyIdentity,
  findSafetyIdentity,
  isSafetyIdentityOperable,
  releaseSafetyIdentityIfUnreferenced,
  releaseUnreferencedSafetyIdentity,
  runModerationTransaction,
} from "./safetyIdentity.js";
import {
  SAFETY_IDENTITY_KEYRING_ENV,
  readSafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_safety_identity`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

function keyringOf(current: string, keys: Record<string, number>) {
  return readSafetyIdentityKeyring({
    [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
      current,
      keys: Object.fromEntries(
        Object.entries(keys).map(([id, byte]) => [id, Buffer.alloc(32, byte).toString("base64url")])
      ),
    }),
  });
}

const k1Only = keyringOf("k1", { k1: 0x11 });
const k1k2 = keyringOf("k2", { k1: 0x11, k2: 0x22 });
const k2Only = keyringOf("k2", { k2: 0x22 });
// Two instances of a rolling rotation: both hold every key, different current.
const instanceA = keyringOf("k1", { k1: 0x11, k2: 0x22 });
const instanceB = keyringOf("k2", { k1: 0x11, k2: 0x22 });
// The same key id with different material.
const k1Reused = keyringOf("k1", { k1: 0x99 });

const snapshot = () => ({
  requestId: new mongoose.Types.ObjectId(),
  reportedRole: "helper" as const,
  requestStatus: "claimed" as const,
  food: "soup",
});

const now = () => new Date();

const restriction = (ring: Parameters<typeof checkParticipantCreationRestriction>[0], email: string) =>
  runModerationTransaction((s) => checkParticipantCreationRestriction(ring, email, s));
const confirm = (id: mongoose.Types.ObjectId | string, ring: Parameters<typeof confirmSafetyIdentity>[1]) =>
  runModerationTransaction((s) => confirmSafetyIdentity(id, ring, s));
const manualSuspension = (ring: typeof k1Only, email: string) =>
  runModerationTransaction((s) =>
    recordSuspension(s, {
      keyring: ring,
      suspendedEmail: email,
      origin: "manual",
      rationale: "Verified safety concern.",
    })
  );
const openReport = (ring: typeof k1Only, email: string) =>
  runModerationTransaction((s) =>
    recordReportCase(s, {
      keyring: ring,
      reportedEmail: email,
      snapshot: snapshot(),
      reason: "Other concern",
    })
  );

async function dumpModerationCollections(): Promise<string> {
  const rows: unknown[] = [];
  for (const model of MODERATION_MODELS) {
    rows.push(...(await model.collection.find({}).toArray()));
  }
  return JSON.stringify(rows);
}

/** Stand-in for the Checkpoint 2 participant row, so interleavings are observable. */
const fakeParticipants = () => mongoose.connection.collection("u12_fake_participants");

describeMongo("restricted safety identity (real MongoDB)", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
    await establishModerationIndexes();
  });

  afterAll(async () => {
    await mongoose.connection.dropDatabase();
    await mongoose.disconnect();
  });

  beforeEach(async () => {
    for (const model of MODERATION_MODELS) await model.deleteMany({});
    await Participant.deleteMany({});
    await fakeParticipants().deleteMany({});
  });

  it("stores only keyed digests and key ids: no email, participant ID or reporter", async () => {
    const participant = await Participant.create({
      email: "ada.privacy@nyu.edu",
      authorityVersion: 1,
      verifiedAt: now(),
    });
    await openReport(k1Only, "ada.privacy@nyu.edu");

    const identity = await SafetyIdentity.collection.findOne({});
    expect(Object.keys(identity!).sort()).toEqual(["__v", "_id", "createdAt", "entries", "serial"]);
    for (const entry of identity!.entries) expect(Object.keys(entry).sort()).toEqual(["digest", "keyId"]);

    const everything = await dumpModerationCollections();
    expect(everything).not.toContain("ada.privacy");
    expect(everything).not.toContain("nyu.edu");
    expect(everything).not.toContain(String(participant._id));
  });

  it("creates once and reuses the identity for the same verified email", async () => {
    const first = await runModerationTransaction((s) => ensureSafetyIdentity(k1Only, "ada@nyu.edu", s));
    const second = await runModerationTransaction((s) =>
      ensureSafetyIdentity(k1Only, "  ADA@nyu.edu ", s)
    );
    expect(first.created).toBe(true);
    expect(second.created).toBe(false);
    expect(String(second.identityId)).toBe(String(first.identityId));
    expect(await SafetyIdentity.countDocuments()).toBe(1);
    expect((await SafetyIdentity.findById(first.identityId).lean())?.serial).toBe(2);
  });

  it("keeps +tag and dotted variants as distinct principals", async () => {
    const ids = new Set<string>();
    for (const email of ["ada@nyu.edu", "ada+x@nyu.edu", "a.da@nyu.edu"]) {
      const result = await runModerationTransaction((s) => ensureSafetyIdentity(k1Only, email, s));
      ids.add(String(result.identityId));
    }
    expect(ids.size).toBe(3);
  });

  it("converges concurrent creators on exactly one identity", async () => {
    const results = await Promise.all(
      Array.from({ length: 12 }, () =>
        runModerationTransaction((s) => ensureSafetyIdentity(k1Only, "race@nyu.edu", s))
      )
    );
    expect(new Set(results.map((r) => String(r.identityId))).size).toBe(1);
    expect(results.filter((r) => r.created)).toHaveLength(1);
    expect(await SafetyIdentity.countDocuments()).toBe(1);
  }, 30_000);

  it("refuses a value that is not an eligible principal and writes nothing", async () => {
    await expect(
      runModerationTransaction((s) => ensureSafetyIdentity(k1Only, "someone@example.com", s))
    ).rejects.toBeInstanceOf(InvalidSafetyIdentityPrincipalError);
    expect(await SafetyIdentity.countDocuments()).toBe(0);
  });

  describe("one identity per principal across keys (F1)", () => {
    it("never mints two identities when instances with different current keys create concurrently", async () => {
      for (let round = 0; round < 6; round += 1) {
        await SafetyIdentity.deleteMany({});
        const email = `mixed${round}@nyu.edu`;
        const results = await Promise.all(
          Array.from({ length: 10 }, (_, i) =>
            runModerationTransaction((s) =>
              ensureSafetyIdentity(i % 2 === 0 ? instanceA : instanceB, email, s)
            )
          )
        );
        expect(new Set(results.map((r) => String(r.identityId))).size, `round ${round}`).toBe(1);
        expect(await SafetyIdentity.countDocuments()).toBe(1);
        // The one identity carries a digest for every key, so either instance finds it.
        const identity = await SafetyIdentity.findOne({}).lean();
        expect(identity?.entries.map((e) => e.keyId).sort()).toEqual(["k1", "k2"]);
      }
    }, 90_000);

    it("lets a database-level unique index refuse two identities that share any digest", async () => {
      const shared = "a".repeat(64);
      await SafetyIdentity.create({ entries: [{ keyId: "k1", digest: shared }] });
      await expect(
        SafetyIdentity.create({
          entries: [
            { keyId: "k2", digest: "b".repeat(64) },
            { keyId: "k1", digest: shared },
          ],
        })
      ).rejects.toMatchObject({ code: 11000 });
      await expect(
        SafetyIdentity.create({ entries: [{ keyId: "k2", digest: "c".repeat(64) }] })
      ).resolves.toBeDefined();
    });

    it("tops an identity up with a newly configured key at the next use, so the old key can retire", async () => {
      await manualSuspension(k1Only, "rot@nyu.edu");
      expect((await SafetyIdentity.findOne({}).lean())?.entries.map((e) => e.keyId)).toEqual(["k1"]);

      // k2 is added, then verification of that email happens (raw email in hand).
      const during = await restriction(k1k2, "rot@nyu.edu");
      expect(during.restricted).toBe(true);
      expect((await SafetyIdentity.findOne({}).lean())?.entries.map((e) => e.keyId).sort()).toEqual([
        "k1",
        "k2",
      ]);

      // With k1 retired the identity is still reachable and the suspension still holds.
      const after = await restriction(k2Only, "rot@nyu.edu");
      expect(after.restricted).toBe(true);
      expect(String(after.identityId)).toBe(String(during.identityId));
    });
  });

  describe("key rotation and fail-closed behavior", () => {
    it("never lifts a suspension when a key is added", async () => {
      await manualSuspension(k1Only, "add@nyu.edu");
      expect((await restriction(k1k2, "add@nyu.edu")).restricted).toBe(true);
      expect((await restriction(k1Only, "add@nyu.edu")).restricted).toBe(true);
    });

    it("fails closed for every email once an identity has no usable key left", async () => {
      const { suspensionId } = await manualSuspension(k1Only, "gone@nyu.edu");

      await expect(restriction(k2Only, "gone@nyu.edu")).rejects.toBeInstanceOf(SafetyIdentityUnavailableError);
      // An unrelated email cannot be cleared either: the missing key might be its identity's.
      await expect(restriction(k2Only, "someone.else@nyu.edu")).rejects.toBeInstanceOf(
        SafetyIdentityUnavailableError
      );
      await expect(findSafetyIdentity(k2Only, "gone@nyu.edu")).rejects.toBeInstanceOf(
        SafetyIdentityUnavailableError
      );
      await expect(
        runModerationTransaction((s) => ensureSafetyIdentity(k2Only, "new@nyu.edu", s))
      ).rejects.toBeInstanceOf(SafetyIdentityUnavailableError);
      expect(await isSafetyIdentityOperable(k2Only)).toBe(false);
      expect(await isSafetyIdentityOperable(k1Only)).toBe(true);

      expect(await Suspension.findById(suspensionId).lean()).toMatchObject({ state: "active" });
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });

    it("fails closed with no keyring at all", async () => {
      await expect(assertSafetyIdentityKeysAvailable(null)).rejects.toBeInstanceOf(
        SafetyIdentityUnavailableError
      );
      await expect(restriction(null, "a@nyu.edu")).rejects.toBeInstanceOf(SafetyIdentityUnavailableError);
      expect(await isSafetyIdentityOperable(null)).toBe(false);
    });

    it("is operable on an empty database with a valid keyring", async () => {
      expect(await isSafetyIdentityOperable(k1Only)).toBe(true);
    });

    describe("a key id reused with different material (F1)", () => {
      it("is detected and every guarded operation fails closed, creating no second identity", async () => {
        await manualSuspension(k1Only, "reuse@nyu.edu");
        expect(await SafetyKeyCheck.countDocuments({ keyId: "k1" })).toBe(1);

        // Same id, different bytes: the old digests would be unfindable, so a
        // lookup would read "no restriction" and mint a fresh identity.
        await expect(restriction(k1Reused, "reuse@nyu.edu")).rejects.toBeInstanceOf(
          SafetyIdentityUnavailableError
        );
        await expect(
          runModerationTransaction((s) => ensureSafetyIdentity(k1Reused, "reuse@nyu.edu", s))
        ).rejects.toBeInstanceOf(SafetyIdentityUnavailableError);
        await expect(findSafetyIdentity(k1Reused, "reuse@nyu.edu")).rejects.toBeInstanceOf(
          SafetyIdentityUnavailableError
        );
        expect(await isSafetyIdentityOperable(k1Reused)).toBe(false);
        expect(await SafetyIdentity.countDocuments()).toBe(1);

        // The original material still works.
        expect((await restriction(k1Only, "reuse@nyu.edu")).restricted).toBe(true);
      });

      it("blocks confirmation and release for the reused id, keeping the identity", async () => {
        const { identityId } = await runModerationTransaction((s) =>
          ensureSafetyIdentity(k1Only, "reuse2@nyu.edu", s)
        );
        expect(await confirm(identityId, k1Reused)).toBe(false);
        expect(await releaseUnreferencedSafetyIdentity(identityId, k1Reused)).toBe("kept-key-unavailable");
        expect(await SafetyIdentity.countDocuments()).toBe(1);
      });

      it("detects a lost first-registration race by re-reading the winner", async () => {
        const results = await Promise.allSettled([
          runModerationTransaction((s) => ensureSafetyIdentity(k1Only, "race1@nyu.edu", s)),
          runModerationTransaction((s) => ensureSafetyIdentity(k1Reused, "race2@nyu.edu", s)),
        ]);
        // Exactly one of the two materials owns the id; the other fails closed.
        expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(1);
        expect(await SafetyKeyCheck.countDocuments({ keyId: "k1" })).toBe(1);
      });
    });
  });

  describe("the confirm-only operation", () => {
    it("answers ok or not-ok and nothing else", async () => {
      const { identityId } = await runModerationTransaction((s) =>
        ensureSafetyIdentity(k1Only, "confirm@nyu.edu", s)
      );
      expect(await confirm(identityId, k1Only)).toBe(true);
      expect(await confirm(String(identityId), k1k2)).toBe(true);
      expect(await confirm(identityId, k2Only)).toBe(false);
      expect(await confirm(identityId, null)).toBe(false);
      expect(await confirm(new mongoose.Types.ObjectId(), k1Only)).toBe(false);
      expect(await confirm("not-an-object-id", k1Only)).toBe(false);
    });
  });

  describe("serialization on the identity record (F2)", () => {
    /**
     * Opens two transactions on two sessions and runs `second` while `first`'s
     * writes are uncommitted. The loser must fail with a transient write
     * conflict: that conflict is what orders the two. Returns both outcomes.
     */
    async function interleave(
      first: (session: ClientSession) => Promise<unknown>,
      second: (session: ClientSession) => Promise<unknown>
    ) {
      const a = await mongoose.startSession();
      const b = await mongoose.startSession();
      try {
        a.startTransaction();
        b.startTransaction();
        await first(a);
        let conflict: unknown;
        try {
          await second(b);
        } catch (error) {
          conflict = error;
        }
        await a.commitTransaction();
        if (!conflict) await b.commitTransaction();
        else await b.abortTransaction();
        return conflict as { codeName?: string; errorLabels?: string[]; hasErrorLabel?: (l: string) => boolean } | undefined;
      } finally {
        await a.endSession();
        await b.endSession();
      }
    }

    const isWriteConflict = (error: unknown) =>
      (error as { codeName?: string })?.codeName === "WriteConflict" ||
      (error as { hasErrorLabel?: (l: string) => boolean })?.hasErrorLabel?.("TransientTransactionError") === true;

    it("makes P2 confirmation conflict with a concurrent release of the same identity", async () => {
      const { identityId } = await runModerationTransaction((s) =>
        ensureSafetyIdentity(k1Only, "p2.release@nyu.edu", s)
      );
      const conflict = await interleave(
        (s) => confirmSafetyIdentity(identityId, k1Only, s),
        (s) => releaseSafetyIdentityIfUnreferenced(identityId, k1Only, s)
      );
      expect(isWriteConflict(conflict)).toBe(true);
    });

    it("makes P2 confirmation conflict with a concurrent attachment (a report naming the identity)", async () => {
      const { identityId } = await runModerationTransaction((s) =>
        ensureSafetyIdentity(k1Only, "p2.attach@nyu.edu", s)
      );
      const conflict = await interleave(
        (s) => confirmSafetyIdentity(identityId, k1Only, s),
        (s) =>
          recordReportCase(s, {
            keyring: k1Only,
            reportedEmail: "p2.attach@nyu.edu",
            snapshot: snapshot(),
            reason: "Other concern",
          })
      );
      expect(isWriteConflict(conflict)).toBe(true);
    });

    it("makes verification of an existing identity conflict with a concurrent reinstatement", async () => {
      const { suspensionId } = await manualSuspension(k1Only, "verify.lift@nyu.edu");
      const conflict = await interleave(
        (s) => checkParticipantCreationRestriction(k1Only, "verify.lift@nyu.edu", s),
        (s) => liftSuspension(s, { suspensionId, keyring: k1Only }, now())
      );
      expect(isWriteConflict(conflict)).toBe(true);
    });

    it("makes verification of an email with no identity conflict with a concurrent first suspension", async () => {
      const conflict = await interleave(
        (s) => checkParticipantCreationRestriction(k1Only, "verify.fresh@nyu.edu", s),
        (s) =>
          recordSuspension(s, {
            keyring: k1Only,
            suspendedEmail: "verify.fresh@nyu.edu",
            origin: "manual",
            rationale: "Verified safety concern.",
          })
      );
      expect(isWriteConflict(conflict) || (conflict as { code?: number })?.code === 11000).toBe(true);
      expect(await SafetyIdentity.countDocuments()).toBe(0);
    });

    it("leaves no keyed record behind when verification finds no identity", async () => {
      const result = await restriction(k1Only, "nobody@nyu.edu");
      expect(result).toEqual({ restricted: false, identityId: null });
      expect(await SafetyIdentity.countDocuments()).toBe(0);
    });

    it("yields no recreated, unrestricted participant when verification races a first suspension", async () => {
      for (let attempt = 0; attempt < 15; attempt += 1) {
        await SafetyIdentity.deleteMany({});
        await Suspension.deleteMany({});
        await fakeParticipants().deleteMany({});
        const email = `skew${attempt}@nyu.edu`;

        await Promise.all([
          // Verification: decide restriction, create the participant accordingly.
          runModerationTransaction(async (s) => {
            const decision = await checkParticipantCreationRestriction(k1Only, email, s);
            await fakeParticipants().deleteMany({ email }, { session: s });
            await fakeParticipants().insertOne({ email, suspended: decision.restricted }, { session: s });
          }),
          // Suspension: record it, then mark any participant that already exists.
          runModerationTransaction(async (s) => {
            await recordSuspension(s, {
              keyring: k1Only,
              suspendedEmail: email,
              origin: "manual",
              rationale: "Verified safety concern.",
            });
            await fakeParticipants().updateMany({ email }, { $set: { suspended: true } }, { session: s });
          }),
        ]);

        expect(await Suspension.countDocuments({ state: "active" })).toBe(1);
        const participant = await fakeParticipants().findOne({ email });
        expect(participant, `attempt ${attempt}`).not.toBeNull();
        expect(participant!.suspended, `attempt ${attempt}`).toBe(true);
      }
    }, 120_000);

    it("leaves no stale restriction when verification races a reinstatement", async () => {
      for (let attempt = 0; attempt < 15; attempt += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        await fakeParticipants().deleteMany({});
        const email = `unskew${attempt}@nyu.edu`;
        const { suspensionId } = await manualSuspension(k1Only, email);

        await Promise.all([
          runModerationTransaction(async (s) => {
            const decision = await checkParticipantCreationRestriction(k1Only, email, s);
            await fakeParticipants().deleteMany({ email }, { session: s });
            await fakeParticipants().insertOne({ email, suspended: decision.restricted }, { session: s });
          }),
          runModerationTransaction(async (s) => {
            await liftSuspension(s, { suspensionId, keyring: k1Only }, now());
            await fakeParticipants().updateMany({ email }, { $set: { suspended: false } }, { session: s });
          }),
        ]);

        expect(await Suspension.countDocuments({ state: "active" })).toBe(0);
        const participant = await fakeParticipants().findOne({ email });
        expect(participant!.suspended, `attempt ${attempt}`).toBe(false);
      }
    }, 120_000);

    it("keeps a report's identity when verification races its creation", async () => {
      for (let attempt = 0; attempt < 15; attempt += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        const email = `attach${attempt}@nyu.edu`;
        await Promise.all([
          restriction(k1Only, email),
          openReport(k1Only, email),
        ]);
        const report = await ModerationReport.findOne({}).lean();
        expect(report, `attempt ${attempt}`).not.toBeNull();
        expect(await SafetyIdentity.findById(report!.safetyIdentityRef).lean()).not.toBeNull();
        expect(await SafetyIdentity.countDocuments()).toBe(1);
      }
    }, 120_000);
  });

  describe("active suspension across ordinary account deletion", () => {
    it("restricts a recreated participant with the same verified email, then releases at reinstatement", async () => {
      const email = "survive@nyu.edu";
      const original = await Participant.create({ email, authorityVersion: 1, verifiedAt: now() });
      const { suspensionId } = await manualSuspension(k1Only, email);

      await Participant.deleteOne({ _id: original._id });
      expect(await Participant.countDocuments()).toBe(0);
      expect(await dumpModerationCollections()).not.toContain(String(original._id));

      const recreated = await restriction(k1Only, email);
      expect(recreated.restricted).toBe(true);
      expect(recreated.identityId).not.toBeNull();
      expect((await restriction(k1Only, "survive2@nyu.edu")).restricted).toBe(false);

      await runModerationTransaction((s) => liftSuspension(s, { suspensionId, keyring: k1Only }, now()));
      expect(await restriction(k1Only, email)).toEqual({ restricted: false, identityId: null });
      expect(await SafetyIdentity.countDocuments()).toBe(0);
    });

    it("never restricts a recreated participant because of closed history", async () => {
      const email = "history@nyu.edu";
      const { reportId } = await openReport(k1Only, email);
      // While the report is Open the identity exists but restricts nothing.
      const open = await restriction(k1Only, email);
      expect(open.restricted).toBe(false);
      expect(open.identityId).not.toBeNull();

      await runModerationTransaction((s) =>
        closeReportCase(s, { reportId, outcome: "no-action", enforcementApplied: true, keyring: k1Only }, now())
      );
      expect(await restriction(k1Only, email)).toEqual({ restricted: false, identityId: null });
      expect(await SafetyIdentity.countDocuments()).toBe(0);
      expect(await ModerationReport.countDocuments({ safetyIdentityRef: { $exists: true } })).toBe(0);
    });
  });

  describe("the release guard", () => {
    it("keeps an identity referenced by an Open report", async () => {
      const { identityId } = await openReport(k1Only, "open@nyu.edu");
      expect(await releaseUnreferencedSafetyIdentity(identityId, k1Only)).toBe("referenced");
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });

    it("keeps an identity referenced by an Active suspension", async () => {
      const { identityId } = await manualSuspension(k1Only, "active@nyu.edu");
      expect(await releaseUnreferencedSafetyIdentity(identityId, k1Only)).toBe("referenced");
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });

    it("keeps an identity referenced by an unreleased identity-bearing hold", async () => {
      const { reportId, identityId } = await openReport(k1Only, "hold@nyu.edu");
      await runModerationTransaction((s) =>
        createRetentionHold(
          s,
          {
            targetKind: "case",
            targetId: reportId,
            holdClass: "legal-preservation",
            reasonCode: "legal-preservation",
            endingCondition: "Counsel withdraws the preservation request.",
            reviewAt: new Date(Date.now() + 30 * 86_400_000),
            keepSafetyIdentity: true,
          },
          now()
        )
      );
      await runModerationTransaction((s) =>
        closeReportCase(s, { reportId, outcome: "no-action", enforcementApplied: true, keyring: k1Only }, now())
      );
      expect(await SafetyIdentity.countDocuments()).toBe(1);
      expect(await releaseUnreferencedSafetyIdentity(identityId, k1Only)).toBe("referenced");
      expect(await RetentionHold.countDocuments({ safetyIdentityRef: identityId })).toBe(1);
    });

    it("keeps an identity whose key is unavailable, even with zero references", async () => {
      const { identityId } = await runModerationTransaction((s) =>
        ensureSafetyIdentity(k1Only, "orphan@nyu.edu", s)
      );
      expect(await releaseUnreferencedSafetyIdentity(identityId, k2Only)).toBe("kept-key-unavailable");
      expect(await releaseUnreferencedSafetyIdentity(identityId, null)).toBe("kept-key-unavailable");
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });

    it("releases only at verified zero references, and a stale retry of a gone identity is a no-op", async () => {
      const { identityId } = await runModerationTransaction((s) =>
        ensureSafetyIdentity(k1Only, "free@nyu.edu", s)
      );
      expect(await releaseUnreferencedSafetyIdentity(identityId, k1Only)).toBe("released");
      expect(await releaseUnreferencedSafetyIdentity(identityId, k1Only)).toBe("absent");
    });

    it("does not release an identity that gained a reference after the sweep listed it (stale retry)", async () => {
      const { identityId } = await runModerationTransaction((s) =>
        ensureSafetyIdentity(k1Only, "stale@nyu.edu", s)
      );
      await openReport(k1Only, "stale@nyu.edu");
      expect(await releaseUnreferencedSafetyIdentity(identityId, k1Only)).toBe("referenced");
      expect(await SafetyIdentity.countDocuments()).toBe(1);
    });

    it("serializes a concurrent release against a concurrent report on the same identity", async () => {
      for (let attempt = 0; attempt < 15; attempt += 1) {
        await ModerationReport.deleteMany({});
        await SafetyIdentity.deleteMany({});
        const email = `race${attempt}@nyu.edu`;
        const { identityId } = await runModerationTransaction((s) => ensureSafetyIdentity(k1Only, email, s));

        await Promise.all([releaseUnreferencedSafetyIdentity(identityId, k1Only), openReport(k1Only, email)]);

        const report = await ModerationReport.findOne({}).lean();
        expect(report).not.toBeNull();
        expect(await SafetyIdentity.findById(report!.safetyIdentityRef).lean(), `attempt ${attempt}`).not.toBeNull();
        expect(await SafetyIdentity.countDocuments()).toBe(1);
      }
    }, 60_000);

    it("serializes a concurrent closure against a concurrent suspension on the same identity", async () => {
      for (let attempt = 0; attempt < 10; attempt += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        const email = `close${attempt}@nyu.edu`;
        const { reportId } = await openReport(k1Only, email);

        await Promise.allSettled([
          runModerationTransaction((s) =>
            closeReportCase(s, { reportId, outcome: "no-action", enforcementApplied: true, keyring: k1Only }, now())
          ),
          manualSuspension(k1Only, email),
        ]);

        const suspension = await Suspension.findOne({ state: "active" }).lean();
        expect(suspension, `attempt ${attempt}`).not.toBeNull();
        expect(await SafetyIdentity.findById(suspension!.safetyIdentityRef).lean()).not.toBeNull();
        expect((await restriction(k1Only, email)).restricted).toBe(true);
      }
    }, 60_000);
  });
});
