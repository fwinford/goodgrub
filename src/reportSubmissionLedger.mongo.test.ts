import crypto from "node:crypto";
import mongoose from "mongoose";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  MODERATION_MODELS,
  ReportCountBinding,
  ReportSubmissionLedger,
  establishModerationIndexes,
} from "../models/moderation.js";
import {
  HOUR_MS,
  REPORT_LEDGER_RETENTION_MS,
  REPORT_PER_REQUEST_CAP,
  REPORT_SUBMISSION_WINDOW_MS,
  REPORT_VOLUME_CAP,
} from "./moderationConstants.js";
import { SafetyIdentityUnavailableError, runModerationTransaction } from "./safetyIdentity.js";
import {
  SAFETY_IDENTITY_KEYRING_ENV,
  readSafetyIdentityKeyring,
} from "./safetyIdentityKeyring.js";
import {
  createReportLedgerRow,
  reconcileReportOperation,
  type CreateLedgerResult,
} from "./reportSubmissionLedger.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_report_ledger`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const ringOf = (current: string, keys: Record<string, number>) =>
  readSafetyIdentityKeyring({
    [SAFETY_IDENTITY_KEYRING_ENV]: JSON.stringify({
      current,
      keys: Object.fromEntries(
        Object.entries(keys).map(([id, byte]) => [id, Buffer.alloc(32, byte).toString("base64url")])
      ),
    }),
  });
const k1 = ringOf("k1", { k1: 0x51 });
const k1k2 = ringOf("k2", { k1: 0x51, k2: 0x52 });
// Two instances of a rolling rotation: both hold every key, different current.
const instanceA = ringOf("k1", { k1: 0x51, k2: 0x52 });
const instanceB = ringOf("k2", { k1: 0x51, k2: 0x52 });
const k1Reused = ringOf("k1", { k1: 0x77 });
const k2Only = ringOf("k2", { k2: 0x52 });

const NOW = new Date("2026-10-18T12:00:00Z");
const operationId = (mintedAt: Date = NOW) =>
  `rp1.${String(mintedAt.getTime()).padStart(13, "0")}.${crypto.randomBytes(16).toString("base64url")}`;

const ada = new mongoose.Types.ObjectId().toString();
const bea = new mongoose.Types.ObjectId().toString();
const requestA = new mongoose.Types.ObjectId().toString();
const requestB = new mongoose.Types.ObjectId().toString();

const create = (
  input: Partial<Parameters<typeof createReportLedgerRow>[1]> & { operationId: string },
  when: Date = NOW,
  ring = k1
) =>
  runModerationTransaction((session) =>
    createReportLedgerRow(
      session,
      { keyring: ring, participantId: ada, requestId: requestA, ...input },
      when
    )
  );

const reconcile = (id: string, participantId = ada, when: Date = NOW, ring = k1) =>
  runModerationTransaction((session) =>
    reconcileReportOperation(session, { keyring: ring, operationId: id, participantId }, when)
  );

describeMongo("report-submission ledger and counting bindings (real MongoDB)", () => {
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
  });

  describe("creation and replay", () => {
    it("records keyed digests only: no raw operation, participant, request or case reference", async () => {
      const id = operationId();
      expect(await create({ operationId: id, handoffValue: "post-block-handoff-value" })).toEqual({
        status: "created",
      });

      const row = await ReportSubmissionLedger.collection.findOne({});
      expect(Object.keys(row!).sort()).toEqual(
        ["__v", "_id", "createdAt", "handoffDigests", "keyId", "operationDigests", "outcome", "participantBinding"]
      );
      const binding = await ReportCountBinding.collection.findOne({});
      const serialized = JSON.stringify([row, binding]);
      for (const secret of [id, ada, requestA, "post-block-handoff-value"]) {
        expect(serialized).not.toContain(secret);
      }
      expect(serialized).not.toMatch(/report(Id|Ref)|case|safetyIdentity/i);
    });

    it("returns the original for a replay and writes nothing more", async () => {
      const id = operationId();
      await create({ operationId: id });
      expect(await create({ operationId: id })).toEqual({ status: "replay" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
      expect(await ReportCountBinding.countDocuments()).toBe(1);
    });

    it("refuses a second report from the same reporter for the same request", async () => {
      expect((await create({ operationId: operationId() })).status).toBe("created");
      expect((await create({ operationId: operationId() })).status).toBe("capped");
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
    });

    it("refuses another participant's use of an operation generically", async () => {
      const id = operationId();
      await create({ operationId: id });
      expect(await create({ operationId: id, participantId: bea })).toEqual({ status: "refused" });
      expect(await reconcile(id, bea)).toEqual({ status: "refused" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
    });

    it("refuses a malformed identity and a mint in the future, writing nothing", async () => {
      expect(await create({ operationId: "not-an-operation" })).toEqual({ status: "refused" });
      expect(await create({ operationId: operationId(new Date(NOW.getTime() + 6 * 60_000)) })).toEqual({
        status: "future",
      });
      expect(await reconcile("not-an-operation")).toEqual({ status: "refused" });
      expect(await reconcile(operationId(new Date(NOW.getTime() + 6 * 60_000)))).toEqual({
        status: "refused",
      });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(0);
    });

    it("tolerates a small clock skew", async () => {
      expect((await create({ operationId: operationId(new Date(NOW.getTime() + 4 * 60_000)) })).status).toBe(
        "created"
      );
    });
  });

  describe("the submission window W against retention R", () => {
    it("refuses creation at or beyond W and writes nothing", async () => {
      const minted = new Date(NOW.getTime() - REPORT_SUBMISSION_WINDOW_MS);
      expect(await create({ operationId: operationId(minted) })).toEqual({ status: "expired" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(0);
    });

    it("always has a created row within W: a reconcile before W returns created", async () => {
      const minted = new Date(NOW.getTime() - (REPORT_SUBMISSION_WINDOW_MS - HOUR_MS));
      const id = operationId(minted);
      await create({ operationId: id }, minted);
      expect(await reconcile(id, ada, NOW)).toEqual({ status: "created" });
    });

    it("answers OPERATION_EXPIRED, never not-sent, once the row is gone beyond W", async () => {
      const minted = new Date(NOW.getTime() - (REPORT_LEDGER_RETENTION_MS + HOUR_MS));
      const id = operationId(minted);
      // The row was created within W and has since been removed by TTL at R.
      expect(await reconcile(id)).toEqual({ status: "expired" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(0);
    });

    it("keeps returning a still-present row's original result between W and R", async () => {
      const minted = new Date(NOW.getTime() - (REPORT_SUBMISSION_WINDOW_MS + HOUR_MS));
      const id = operationId(minted);
      await create({ operationId: id }, new Date(minted.getTime() + HOUR_MS));
      expect(await reconcile(id)).toEqual({ status: "created" });
      expect(await create({ operationId: id })).toEqual({ status: "replay" });
    });

    it("never terminalizes an operation beyond W", async () => {
      const minted = new Date(NOW.getTime() - (REPORT_SUBMISSION_WINDOW_MS + 1));
      expect(await reconcile(operationId(minted))).toEqual({ status: "expired" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(0);
    });
  });

  describe("terminal no-create", () => {
    it("is established atomically within W so a later-arriving original cannot commit", async () => {
      const id = operationId();
      expect(await reconcile(id)).toEqual({ status: "no-create" });
      expect(await reconcile(id)).toEqual({ status: "no-create" });
      expect(await create({ operationId: id })).toEqual({ status: "terminal-no-create" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
      expect(await ReportCountBinding.countDocuments()).toBe(0);
    });

    it("lets a reconcile and the original race to exactly one coherent outcome", async () => {
      for (let attempt = 0; attempt < 12; attempt += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        const id = operationId();
        const [created, reconciled] = await Promise.all([
          create({ operationId: id }),
          reconcile(id),
        ]);

        const rows = await ReportSubmissionLedger.find({}).lean();
        expect(rows, `attempt ${attempt}`).toHaveLength(1);
        if (created.status === "created") {
          expect(rows[0].outcome).toBe("created");
          expect(reconciled.status).toBe("created");
          expect(await ReportCountBinding.countDocuments()).toBe(1);
        } else {
          expect(created.status).toBe("terminal-no-create");
          expect(rows[0].outcome).toBe("no-create");
          expect(reconciled.status).toBe("no-create");
          expect(await ReportCountBinding.countDocuments()).toBe(0);
        }
      }
    }, 60_000);

    it("lets concurrent duplicates of one operation create exactly once", async () => {
      const id = operationId();
      const results = await Promise.all(Array.from({ length: 8 }, () => create({ operationId: id })));
      expect(results.filter((r) => r.status === "created")).toHaveLength(1);
      expect(results.filter((r) => r.status === "replay")).toHaveLength(7);
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
    }, 30_000);
  });

  describe("the post-Block handoff is consumed by the first committed report", () => {
    it("refuses a second operation presenting a consumed handoff, without writing", async () => {
      expect((await create({ operationId: operationId(), handoffValue: "handoff-1" })).status).toBe("created");
      expect(await create({ operationId: operationId(), handoffValue: "handoff-1" })).toEqual({
        status: "handoff-consumed",
      });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
    });

    it("yields exactly one report for two concurrent submissions on one handoff", async () => {
      const results = await Promise.all([
        create({ operationId: operationId(), handoffValue: "handoff-race" }),
        create({ operationId: operationId(), handoffValue: "handoff-race" }),
        create({ operationId: operationId(), handoffValue: "handoff-race" }),
      ]);
      expect(results.filter((r) => r.status === "created")).toHaveLength(1);
      expect(results.filter((r) => r.status === "handoff-consumed")).toHaveLength(2);
      expect(await ReportSubmissionLedger.countDocuments({ handoffDigests: { $exists: true } })).toBe(1);
    }, 30_000);

    it("does not consume the handoff on a definitive no-write failure", async () => {
      expect(await create({ operationId: "bad", handoffValue: "handoff-keep" })).toEqual({ status: "refused" });
      expect(
        await create({
          operationId: operationId(new Date(NOW.getTime() - REPORT_SUBMISSION_WINDOW_MS)),
          handoffValue: "handoff-keep",
        })
      ).toEqual({ status: "expired" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(0);
      expect((await create({ operationId: operationId(), handoffValue: "handoff-keep" })).status).toBe("created");
    });

    it("lets many reports without a handoff coexist (the handoff index is partial)", async () => {
      for (let i = 0; i < 4; i += 1) {
        await create({
          operationId: operationId(),
          requestId: new mongoose.Types.ObjectId().toString(),
        });
      }
      expect(await ReportSubmissionLedger.countDocuments({ handoffDigests: { $exists: false } })).toBe(4);
    });
  });

  describe("abuse controls", () => {
    it("caps volume per reporter at 10 per rolling 24 hours, refusing the 11th without writing", async () => {
      for (let i = 0; i < REPORT_VOLUME_CAP; i += 1) {
        const requestId = new mongoose.Types.ObjectId().toString();
        expect((await create({ operationId: operationId(), requestId })).status).toBe("created");
      }
      const refused = await create({
        operationId: operationId(),
        requestId: new mongoose.Types.ObjectId().toString(),
      });
      expect(refused).toEqual({ status: "capped", cap: "volume" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(REPORT_VOLUME_CAP);

      // Another participant is unaffected.
      expect((await create({ operationId: operationId(), participantId: bea })).status).toBe("created");
    });

    it("caps one reporter against one request at one report, while other requests stay open", async () => {
      for (let i = 0; i < REPORT_PER_REQUEST_CAP; i += 1) {
        expect((await create({ operationId: operationId(), requestId: requestA })).status).toBe("created");
      }
      expect(await create({ operationId: operationId(), requestId: requestA })).toEqual({
        status: "capped",
        cap: "request",
      });
      expect((await create({ operationId: operationId(), requestId: requestB })).status).toBe("created");
    });

    it("returns the original for a replay even after the cap is reached", async () => {
      const first = operationId();
      await create({ operationId: first, requestId: requestA });
      for (let i = 1; i < REPORT_PER_REQUEST_CAP; i += 1) {
        await create({ operationId: operationId(), requestId: requestA });
      }
      expect((await create({ operationId: operationId(), requestId: requestA })).status).toBe("capped");
      expect(await create({ operationId: first, requestId: requestA })).toEqual({ status: "replay" });
    });

    it("rolls the window: counts older than 24 hours no longer apply", async () => {
      for (let i = 0; i < REPORT_PER_REQUEST_CAP; i += 1) {
        await create({ operationId: operationId(), requestId: requestA });
      }
      const later = new Date(NOW.getTime() + 25 * HOUR_MS);
      expect((await create({ operationId: operationId(later), requestId: requestA }, later)).status).toBe(
        "created"
      );
    });

    it("never drops a committed report: every created result has a row, even under a burst", async () => {
      const results: CreateLedgerResult[] = await Promise.all(
        Array.from({ length: 14 }, () =>
          create({
            operationId: operationId(),
            requestId: new mongoose.Types.ObjectId().toString(),
          })
        )
      );
      const created = results.filter((r) => r.status === "created").length;
      expect(created).toBeGreaterThanOrEqual(REPORT_VOLUME_CAP);
      expect(await ReportSubmissionLedger.countDocuments({ outcome: "created" })).toBe(created);
      expect(await ReportCountBinding.countDocuments()).toBe(created);
      for (const result of results) {
        if (result.status !== "created") expect(result).toEqual({ status: "capped", cap: "volume" });
      }
    }, 60_000);
  });

  describe("mixed current keys (F1)", () => {
    it("creates one report for one operation when instances with different current keys race", async () => {
      for (let round = 0; round < 6; round += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        const id = operationId();
        const results = await Promise.all(
          Array.from({ length: 8 }, (_, i) => create({ operationId: id }, NOW, i % 2 === 0 ? instanceA : instanceB))
        );
        expect(results.filter((r) => r.status === "created"), `round ${round}`).toHaveLength(1);
        expect(results.filter((r) => r.status === "replay")).toHaveLength(7);
        expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
        expect(await ReportCountBinding.countDocuments()).toBe(1);
      }
    }, 90_000);

    it("reconciles coherently against a create from the instance with the other current key", async () => {
      for (let round = 0; round < 8; round += 1) {
        for (const model of MODERATION_MODELS) await model.deleteMany({});
        const id = operationId();
        const [created, reconciled] = await Promise.all([
          create({ operationId: id }, NOW, instanceA),
          reconcile(id, ada, NOW, instanceB),
        ]);
        const rows = await ReportSubmissionLedger.find({}).lean();
        expect(rows, `round ${round}`).toHaveLength(1);
        if (created.status === "created") {
          expect(rows[0].outcome).toBe("created");
          expect(reconciled.status).toBe("created");
        } else {
          expect(created.status).toBe("terminal-no-create");
          expect(rows[0].outcome).toBe("no-create");
          expect(reconciled.status).toBe("no-create");
        }
      }
    }, 90_000);

    it("consumes one handoff once across instances with different current keys", async () => {
      const results = await Promise.all(
        Array.from({ length: 6 }, (_, i) =>
          create({ operationId: operationId(), handoffValue: "mixed-handoff" }, NOW, i % 2 === 0 ? instanceA : instanceB)
        )
      );
      expect(results.filter((r) => r.status === "created")).toHaveLength(1);
      expect(results.filter((r) => r.status === "handoff-consumed")).toHaveLength(5);
    }, 60_000);

    it("refuses a key id reused with different material, creating no second row", async () => {
      const id = operationId();
      await create({ operationId: id }, NOW, k1);
      await expect(create({ operationId: id }, NOW, k1Reused)).rejects.toBeInstanceOf(
        SafetyIdentityUnavailableError
      );
      await expect(reconcile(id, ada, NOW, k1Reused)).rejects.toBeInstanceOf(SafetyIdentityUnavailableError);
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
    });

    it("enforces operation uniqueness in the database across keys, not just in code", async () => {
      const shared = "d".repeat(64);
      const row = (digests: string[]) => ({
        keyId: "k1",
        operationDigests: digests,
        participantBinding: "a".repeat(64),
        outcome: "created" as const,
      });
      await ReportSubmissionLedger.create(row([shared, "e".repeat(64)]));
      await expect(ReportSubmissionLedger.create(row(["f".repeat(64), shared]))).rejects.toMatchObject({
        code: 11000,
      });
    });
  });

  describe("key rotation and fail-closed behavior", () => {
    it("recognizes a row created under a superseded key after rotation", async () => {
      const id = operationId();
      await create({ operationId: id }, NOW, k1);
      expect(await create({ operationId: id }, NOW, k1k2)).toEqual({ status: "replay" });
      expect(await reconcile(id, ada, NOW, k1k2)).toEqual({ status: "created" });
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
    });

    it("refuses rather than duplicating when a key a live row records is gone", async () => {
      const id = operationId();
      await create({ operationId: id }, NOW, k1);
      await expect(create({ operationId: id }, NOW, k2Only)).rejects.toBeInstanceOf(
        SafetyIdentityUnavailableError
      );
      await expect(reconcile(id, ada, NOW, k2Only)).rejects.toBeInstanceOf(SafetyIdentityUnavailableError);
      expect(await ReportSubmissionLedger.countDocuments()).toBe(1);
    });

    it("fails closed with no keyring", async () => {
      await expect(
        runModerationTransaction((session) =>
          createReportLedgerRow(
            session,
            { keyring: null, operationId: operationId(), participantId: ada, requestId: requestA },
            NOW
          )
        )
      ).rejects.toBeInstanceOf(SafetyIdentityUnavailableError);
    });
  });
});
