import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ENVIRONMENT_MARKER_COLLECTION,
  SCENARIO_PRESETS,
  runQaEnvironmentTool,
} from "./qa-environment.js";
import { SeedSafetyError, runSeedTool } from "./seed-ui-request.js";

/**
 * Runs the QA environment tool end to end against a real replica-set MongoDB.
 * Two named environments (`commonplate_qa_envtest_a` / `_b`) are used at once so
 * the isolation claim is exercised, not assumed. The suite owns these databases
 * and drops them afterwards.
 */
const baseUri = process.env.MONGO_INTEGRATION_URI;
// Every test here drives the QA tool through several commands, and each command
// opens and closes its own Mongo connection (about 0.4-1.5 s per test in
// isolation). Under a concurrent Xcode build two of them took 5.3 s and 7.0 s
// against Vitest's 5 s default, so the whole suite gets the same bounded budget.
const QA_CLI_WORKFLOW_TIMEOUT_MS = 15_000;
const describeMongo = (name: string, define: () => void) =>
  (baseUri ? describe : describe.skip)(name, { timeout: QA_CLI_WORKFLOW_TIMEOUT_MS }, define);

const SLUG_A = "envtest_a";
const SLUG_B = "envtest_b";
const databaseOf = (slug: string) => `commonplate_qa_${slug}`;

function uriFor(slug: string): string {
  const parsed = new URL(baseUri!);
  parsed.pathname = `/${databaseOf(slug)}`;
  return parsed.toString();
}

const REQUESTER_EMAIL = "qa-requester@nyu.edu";
const HELPER_EMAIL = "qa-helper@nyu.edu";
const OTHER_HELPER_EMAIL = "qa-other-helper@nyu.edu";

describeMongo("W4-QA1 QA environment tool against real MongoDB", () => {
  let client: InstanceType<typeof mongoose.mongo.MongoClient>;
  let directory: string;
  let log: ReturnType<typeof vi.spyOn>;
  const configFiles = new Map<string, string>();

  const dbOf = (slug: string) => client.db(databaseOf(slug));

  async function run(
    slug: string,
    args: string[],
    extra: Record<string, string | undefined> = {}
  ) {
    await runQaEnvironmentTool(args, {
      NODE_ENV: "test",
      ALLOW_LOCAL_SEED: "true",
      QA_ENV_FILE: configFiles.get(slug)!,
      ...extra,
    });
  }

  const printed = () => log.mock.calls.map((call: unknown[]) => call.join(" ")).join("\n");

  beforeAll(async () => {
    client = await new mongoose.mongo.MongoClient(baseUri!).connect();
    directory = mkdtempSync(path.join(tmpdir(), "qa1-env-mongo-"));
    for (const [index, slug] of [SLUG_A, SLUG_B].entries()) {
      const file = path.join(directory, `${slug}.json`);
      writeFileSync(
        file,
        JSON.stringify({
          slug,
          database: databaseOf(slug),
          mongoUri: uriFor(slug),
          backendPort: 3040 + index,
          mailSinkPort: 8040 + index,
        })
      );
      configFiles.set(slug, file);
    }
  });

  beforeEach(async () => {
    for (const slug of [SLUG_A, SLUG_B]) await dbOf(slug).dropDatabase();
    log = vi.spyOn(console, "log").mockImplementation(() => undefined);
  });

  afterEach(() => {
    log.mockRestore();
  });

  afterAll(async () => {
    for (const slug of [SLUG_A, SLUG_B]) await dbOf(slug).dropDatabase();
    await client.close();
    rmSync(directory, { recursive: true, force: true });
  });

  /** Similarly shaped data in one environment, including rows reset must keep. */
  async function populate(slug: string) {
    const db = dbOf(slug);
    const id = () => new mongoose.Types.ObjectId();
    const ghostRequestId = id(); // a Request that is not in this database
    const requester = { _id: id(), email: REQUESTER_EMAIL };
    const helper = { _id: id(), email: HELPER_EMAIL };
    const otherHelper = { _id: id(), email: OTHER_HELPER_EMAIL };
    const requestA = id(); // claimed by `helper`
    const requestB = id(); // placed
    const requestC = id(); // open
    const expiresAt = new Date(Date.now() + 60 * 60 * 1000);
    const request = (_id: mongoose.Types.ObjectId, overrides: Record<string, unknown> = {}) => ({
      _id,
      vendor: "Cafe 370",
      food: "Chicken biryani",
      mealItems: [{ name: "Chicken biryani" }],
      menuPath: "meal-exchange",
      mealSwipes: 1,
      pickupWindowText: "ASAP",
      email: REQUESTER_EMAIL,
      requesterParticipantId: requester._id,
      status: "open",
      createdAt: new Date(),
      expiresAt,
      deleteAt: expiresAt,
      ...overrides,
    });
    const lockExpiry = new Date(Date.now() + 10 * 60 * 1000);
    const verifiedAt = new Date("2026-10-01T12:00:00.000Z");
    await db.collection("participants").insertMany([
      { ...requester, authorityVersion: 3, verifiedAt, createdAt: verifiedAt, updatedAt: verifiedAt, activeReservationRequestId: null, activeReservationClaimExpiresAt: null },
      // Locked to a Request that this reset removes.
      { ...helper, authorityVersion: 2, verifiedAt, createdAt: verifiedAt, updatedAt: verifiedAt, activeReservationRequestId: requestA, activeReservationClaimExpiresAt: lockExpiry },
      // Locked to a Request that is NOT removed by this reset (it is not here).
      { ...otherHelper, authorityVersion: 1, verifiedAt, createdAt: verifiedAt, updatedAt: verifiedAt, activeReservationRequestId: ghostRequestId, activeReservationClaimExpiresAt: lockExpiry },
    ] as never[]);
    await db.collection("requests").insertMany([
      request(requestA, { status: "claimed", helperParticipantId: helper._id, claimedAt: new Date(), claimExpiresAt: lockExpiry }),
      request(requestB, { status: "placed", helperParticipantId: helper._id, orderNumber: "A1" }),
      request(requestC),
    ] as never[]);
    const forRequests = (extra: (requestId: mongoose.Types.ObjectId) => Record<string, unknown>) =>
      [requestA, requestB, ghostRequestId].map((requestId) => ({ _id: id(), requestId, ...extra(requestId) }));
    await db.collection("requestparticipations").insertMany(
      forRequests(() => ({ participantId: helper._id })) as never[]
    );
    await db.collection("fulfillments").insertMany(
      forRequests(() => ({ orderNumber: "A1", placedAt: new Date() })) as never[]
    );
    // W4-H1a: private placed-order evidence is Request-scoped, so a normal reset
    // removes it with its Request and leaves any row for an absent Request alone.
    await db.collection("placementevidences").insertMany(
      forRequests(() => ({ image: Buffer.from("qa-evidence"), mimeType: "image/jpeg", byteLength: 11, deleteAt: expiresAt })) as never[]
    );
    await db.collection("pushdeliveries").insertMany(
      forRequests(() => ({ installationId: id(), purpose: "helper-new-request", status: "accepted", deleteAt: expiresAt })) as never[]
    );
    await db.collection("sendlogs").insertMany(
      forRequests(() => ({ subscriberId: id(), status: "sent", sentAt: new Date() })) as never[]
    );
    // Preserved by a normal reset.
    await db.collection("participantverifications").insertOne({ _id: id(), email: "pending@nyu.edu", codeDigest: "x", expiresAt });
    await db.collection("requestoperations").insertMany([
      { _id: id(), operationId: `${slug}-op-created`, participantId: requester._id, outcome: "created", requestId: requestC },
      { _id: id(), operationId: `${slug}-op-no-create`, participantId: requester._id, outcome: "no-create" },
    ] as never[]);
    await db.collection("requestoperationauthorities").insertOne({ _id: "request-operation-ledger", authorityId: `${slug}-authority`, createdAt: verifiedAt } as never);
    await db.collection("installations").insertOne({ _id: id(), marker: slug });
    await db.collection("subscribers").insertOne({ _id: id(), email: "sub@nyu.edu", status: "confirmed" });
    await db.collection("systems").insertOne({ _id: id(), marker: slug });
    // One owner's manifest: two removed ids plus the ghost id (still not a removed Request).
    await db.collection("qa1OwnedFixtureManifest").insertMany([
      { _id: requester._id, requestIds: [requestA, requestB, ghostRequestId] },
      { _id: helper._id, requestIds: [requestC] },
    ] as never[]);
    return { requester, helper, otherHelper, requestA, requestB, requestC, ghostRequestId, verifiedAt, lockExpiry };
  }

  async function snapshot(slug: string) {
    const db = dbOf(slug);
    const collections = (await db.listCollections().toArray()).map((c) => c.name).sort();
    const contents: Record<string, unknown[]> = {};
    for (const name of collections) {
      contents[name] = await db.collection(name).find({}).sort({ _id: 1 }).toArray();
    }
    return contents;
  }

  const count = (slug: string, collection: string, filter: Record<string, unknown> = {}) =>
    dbOf(slug).collection(collection).countDocuments(filter);

  describe("environment marker gate", () => {
    it("refuses every mutation before the marker exists, and mutates nothing", async () => {
      await populate(SLUG_A);
      const before = await snapshot(SLUG_A);
      await expect(run(SLUG_A, ["reset"])).rejects.toThrow("no QA environment marker");
      await expect(run(SLUG_A, ["scenario", "clean"])).rejects.toThrow("no QA environment marker");
      await expect(
        run(SLUG_A, ["drop", "--confirm-database", databaseOf(SLUG_A)])
      ).rejects.toThrow("no QA environment marker");
      expect(await snapshot(SLUG_A)).toEqual(before);
    });

    it("creates the marker once, idempotently, and never alters data", async () => {
      await populate(SLUG_A);
      const before = await snapshot(SLUG_A);
      await run(SLUG_A, ["init"]);
      const marker = await dbOf(SLUG_A).collection(ENVIRONMENT_MARKER_COLLECTION).findOne({});
      expect(marker).toMatchObject({ slug: SLUG_A, database: databaseOf(SLUG_A) });
      await run(SLUG_A, ["init"]);
      expect(await count(SLUG_A, ENVIRONMENT_MARKER_COLLECTION)).toBe(1);
      const { [ENVIRONMENT_MARKER_COLLECTION]: _marker, ...rest } = await snapshot(SLUG_A);
      expect(rest).toEqual(before);
    });

    it("refuses a marker naming another environment, before the first mutation", async () => {
      await populate(SLUG_A);
      await dbOf(SLUG_A).collection(ENVIRONMENT_MARKER_COLLECTION).insertOne({
        _id: "environment",
        slug: SLUG_B,
        database: databaseOf(SLUG_B),
      } as never);
      const before = await snapshot(SLUG_A);
      for (const args of [["init"], ["reset"], ["scenario", "helper-board"], ["drop", "--confirm-database", databaseOf(SLUG_A)]]) {
        await expect(run(SLUG_A, args)).rejects.toThrow("different environment");
      }
      expect(await snapshot(SLUG_A)).toEqual(before);
    });

    it("does not create collections or indexes in a database before verifying it", async () => {
      await expect(run(SLUG_A, ["reset"])).rejects.toThrow("no QA environment marker");
      expect(await dbOf(SLUG_A).listCollections().toArray()).toEqual([]);
    });
  });

  describe("normal reset", () => {
    it("removes the Request graph and preserves identity, ledger and unrelated rows", async () => {
      const seeded = await populate(SLUG_A);
      await run(SLUG_A, ["init"]);
      const participantsBefore = await dbOf(SLUG_A).collection("participants").find({}).sort({ _id: 1 }).toArray();
      const preservedBefore = {} as Record<string, unknown[]>;
      for (const name of ["participantverifications", "requestoperations", "requestoperationauthorities", "installations", "subscribers", "systems"]) {
        preservedBefore[name] = await dbOf(SLUG_A).collection(name).find({}).sort({ _id: 1 }).toArray();
      }

      await run(SLUG_A, ["reset"]);

      // Request graph: gone.
      expect(await count(SLUG_A, "requests")).toBe(0);
      for (const collection of ["requestparticipations", "fulfillments", "placementevidences", "pushdeliveries", "sendlogs"]) {
        expect(await count(SLUG_A, collection, { requestId: { $in: [seeded.requestA, seeded.requestB] } })).toBe(0);
        // The row pointing at a Request that was never in this database survives.
        expect(await count(SLUG_A, collection, { requestId: seeded.ghostRequestId })).toBe(1);
        expect(await count(SLUG_A, collection)).toBe(1);
      }
      // Manifest: removed ids pruned, the unrelated one kept, an emptied entry deleted.
      const manifests = await dbOf(SLUG_A).collection("qa1OwnedFixtureManifest").find({}).toArray();
      expect(manifests).toHaveLength(1);
      expect(manifests[0]).toEqual({ _id: seeded.requester._id, requestIds: [seeded.ghostRequestId] });
      // (the helper's manifest entry only listed requestC, which was removed)

      // Identity: every Participant document survives; only the lock that pointed
      // at a removed Request lost exactly its two lock fields.
      const participantsAfter = await dbOf(SLUG_A).collection("participants").find({}).sort({ _id: 1 }).toArray();
      expect(participantsAfter).toHaveLength(participantsBefore.length);
      for (const before of participantsBefore) {
        const after = participantsAfter.find((p) => String(p._id) === String(before._id))!;
        if (String(before._id) === String(seeded.helper._id)) {
          expect(after).toEqual({
            ...before,
            activeReservationRequestId: null,
            activeReservationClaimExpiresAt: null,
          });
        } else {
          expect(after).toEqual(before); // incl. authorityVersion, verifiedAt, updatedAt
        }
      }
      const otherHelper = participantsAfter.find((p) => String(p._id) === String(seeded.otherHelper._id))!;
      expect(otherHelper.activeReservationRequestId).toEqual(seeded.ghostRequestId);

      // Everything else is untouched, including the D1/D2 ledger.
      for (const [name, rows] of Object.entries(preservedBefore)) {
        expect(await dbOf(SLUG_A).collection(name).find({}).sort({ _id: 1 }).toArray()).toEqual(rows);
      }
      expect(await count(SLUG_A, "requestoperations")).toBe(2);
      expect(await count(SLUG_A, "requestoperations", { outcome: "no-create" })).toBe(1);

      // Reported counts match what was done.
      expect(printed()).toContain("requests removed: 3");
      expect(printed()).toContain("placement evidence removed: 2");
      expect(printed()).toContain("participant reservation locks cleared: 1");
    });

    it("is repeatable and a no-op on an empty environment", async () => {
      await populate(SLUG_A);
      await run(SLUG_A, ["init"]);
      await run(SLUG_A, ["reset"]);
      const after = await snapshot(SLUG_A);
      await run(SLUG_A, ["reset"]);
      expect(await snapshot(SLUG_A)).toEqual(after);
      expect(printed()).toContain("requests removed: 0");
    });

    it("never prints a URI, address, or participant/request identifier", async () => {
      const seeded = await populate(SLUG_A);
      await run(SLUG_A, ["init"]);
      await run(SLUG_A, ["status"]);
      await run(SLUG_A, ["reset"]);
      await run(SLUG_A, ["scenario", "helper-board"]);
      const output = printed();
      expect(output).not.toContain("mongodb://");
      expect(output).not.toContain("replicaSet");
      for (const value of [REQUESTER_EMAIL, HELPER_EMAIL, OTHER_HELPER_EMAIL, "pending@nyu.edu", "sub@nyu.edu", `${SLUG_A}-authority`]) {
        expect(output).not.toContain(value);
      }
      for (const identifier of [seeded.requester._id, seeded.helper._id, seeded.requestA, seeded.ghostRequestId]) {
        expect(output).not.toContain(String(identifier));
      }
    });

    it("reports sanitized status without requiring the opt-in", async () => {
      await populate(SLUG_A);
      await run(SLUG_A, ["init"]);
      await runQaEnvironmentTool(["status"], { QA_ENV_FILE: configFiles.get(SLUG_A) });
      expect(printed()).toContain("environment marker: matches");
      expect(printed()).toContain("requests: 3");
      expect(printed()).toContain("backend base URL: http://127.0.0.1:3040");
    });
  });

  describe("scenario presets", () => {
    async function verifiedRequester(slug: string) {
      const _id = new mongoose.Types.ObjectId();
      await dbOf(slug).collection("participants").insertOne({ _id, email: REQUESTER_EMAIL, authorityVersion: 1, verifiedAt: new Date() } as never);
      return _id;
    }

    it("loads the helper board and future Later fixtures after resetting", async () => {
      await populate(SLUG_A);
      await run(SLUG_A, ["init"]);
      await run(SLUG_A, ["scenario", "helper-board", "future-later"]);
      const requests = await dbOf(SLUG_A).collection("requests").find({}).toArray();
      expect(requests).toHaveLength(6);
      expect(requests.every((r) => /@example\.invalid$/.test(String(r.email)) && r.requesterParticipantId === null)).toBe(true);
      const future = requests.filter((r) => r.visibleFrom > new Date());
      expect(future).toHaveLength(1);
      // The old Request graph went with the reset; participants and the ledger stayed.
      expect(await count(SLUG_A, "participants")).toBe(3);
      expect(await count(SLUG_A, "requestoperations")).toBe(2);
    });

    it("loads requester-owned boundary fixtures and records them for the narrow fixture cleanup", async () => {
      await run(SLUG_A, ["init"]);
      const requesterId = await verifiedRequester(SLUG_A);
      await run(SLUG_A, ["scenario", "requester-quota-boundary"], { QA_REQUESTER_EMAIL: REQUESTER_EMAIL });

      const owned = await dbOf(SLUG_A).collection("requests").find({ requesterParticipantId: requesterId }).toArray();
      expect(owned).toHaveLength(2);
      const manifest = await dbOf(SLUG_A).collection("qa1OwnedFixtureManifest").findOne({ _id: requesterId } as never);
      expect(new Set(manifest!.requestIds.map(String))).toEqual(new Set(owned.map((d) => String(d._id))));

      // The pre-existing manifest-based cleanup still finds and removes exactly them.
      await runSeedTool("cleanup-owned", {
        NODE_ENV: "test",
        ALLOW_LOCAL_SEED: "true",
        MONGO_URI: uriFor(SLUG_A),
        SEED_OWNER_EMAIL: REQUESTER_EMAIL,
      });
      expect(await count(SLUG_A, "requests")).toBe(0);
      expect(await count(SLUG_A, "participants")).toBe(1);
    });

    it("fails before removing anything when the requester is not a verified Participant", async () => {
      await populate(SLUG_A);
      await run(SLUG_A, ["init"]);
      const before = await snapshot(SLUG_A);
      const failure = await run(SLUG_A, ["scenario", "requester-below-quota"], {
        QA_REQUESTER_EMAIL: "nobody@nyu.edu",
      }).then(
        () => {
          throw new Error("expected refusal");
        },
        (error: Error) => error
      );
      expect(failure.message).toContain(
        "No verified Participant found for QA_REQUESTER_EMAIL in this database."
      );
      expect(failure.message).not.toContain("SEED_OWNER_EMAIL");
      expect(failure.message).not.toContain("nobody@nyu.edu");
      expect(await snapshot(SLUG_A)).toEqual(before);
    });

    it("fails before removing anything when preset data cannot be built (F1)", async () => {
      await populate(SLUG_A);
      await run(SLUG_A, ["init"]);
      const before = await snapshot(SLUG_A);
      // Corrupt one preset in memory only: a fixture index no builder can turn
      // into a valid Request document. Restored in `finally`.
      const preset = SCENARIO_PRESETS["helper-board"] as { unownedIndexes: readonly number[] };
      const original = preset.unownedIndexes;
      preset.unownedIndexes = [0, Number.NaN];
      try {
        await expect(run(SLUG_A, ["scenario", "helper-board"])).rejects.toThrow();
      } finally {
        preset.unownedIndexes = original;
      }
      // Existing Requests, dependents, locks, ledger and manifest are untouched.
      expect(await snapshot(SLUG_A)).toEqual(before);
      expect(await count(SLUG_A, "requests")).toBe(3);
    });

    it("`clean` resets and inserts nothing", async () => {
      await populate(SLUG_A);
      await run(SLUG_A, ["init"]);
      await run(SLUG_A, ["scenario", "clean"]);
      expect(await count(SLUG_A, "requests")).toBe(0);
    });
  });

  describe("two environments at once", () => {
    it("resets A without changing B, and each config can only reach its own database", async () => {
      await populate(SLUG_A);
      await populate(SLUG_B);
      await run(SLUG_A, ["init"]);
      await run(SLUG_B, ["init"]);
      const bBefore = await snapshot(SLUG_B);

      await run(SLUG_A, ["scenario", "helper-board"]);
      await run(SLUG_A, ["reset"]);

      expect(await count(SLUG_A, "requests")).toBe(0);
      expect(await snapshot(SLUG_B)).toEqual(bBefore);
      expect(await count(SLUG_B, "requests")).toBe(3);

      // A config cannot be edited to reach B: its slug, database, and marker must agree.
      const crossed = path.join(directory, "crossed.json");
      for (const body of [
        { slug: SLUG_A, database: databaseOf(SLUG_B), mongoUri: uriFor(SLUG_B), backendPort: 3050, mailSinkPort: 8050 },
        { slug: SLUG_A, database: databaseOf(SLUG_A), mongoUri: uriFor(SLUG_B), backendPort: 3050, mailSinkPort: 8050 },
        { slug: SLUG_B, database: databaseOf(SLUG_A), mongoUri: uriFor(SLUG_A), backendPort: 3050, mailSinkPort: 8050 },
      ]) {
        writeFileSync(crossed, JSON.stringify(body));
        await expect(
          runQaEnvironmentTool(["reset"], { NODE_ENV: "test", ALLOW_LOCAL_SEED: "true", QA_ENV_FILE: crossed })
        ).rejects.toThrow(SeedSafetyError);
      }
      expect(await snapshot(SLUG_B)).toEqual(bBefore);

      // And a marker copied across environments is refused too.
      await dbOf(SLUG_A).collection(ENVIRONMENT_MARKER_COLLECTION).deleteMany({});
      await dbOf(SLUG_A).collection(ENVIRONMENT_MARKER_COLLECTION).insertOne({ _id: "environment", slug: SLUG_B, database: databaseOf(SLUG_B) } as never);
      await expect(run(SLUG_A, ["reset"])).rejects.toThrow("different environment");
      expect(await snapshot(SLUG_B)).toEqual(bBefore);
    });
  });

  describe("full teardown", () => {
    it("is only reachable through `drop` with the typed database name, and reset never drops", async () => {
      await populate(SLUG_A);
      await run(SLUG_A, ["init"]);

      await run(SLUG_A, ["reset"]);
      expect(await count(SLUG_A, "participants")).toBe(3);
      expect(await count(SLUG_A, "requestoperations")).toBe(2);

      await expect(run(SLUG_A, ["drop"])).rejects.toThrow("Full teardown requires");
      await expect(run(SLUG_A, ["drop", "--confirm-database", databaseOf(SLUG_B)])).rejects.toThrow("Full teardown requires");
      expect(await count(SLUG_A, "participants")).toBe(3);
    });

    it("drops only the confirmed environment and reports that identity must be re-established", async () => {
      await populate(SLUG_A);
      await populate(SLUG_B);
      await run(SLUG_A, ["init"]);
      await run(SLUG_B, ["init"]);
      const bBefore = await snapshot(SLUG_B);

      await run(SLUG_A, ["drop", "--confirm-database", databaseOf(SLUG_A)]);

      // Participants, the operation ledger, and its authority are gone with the database.
      expect(await dbOf(SLUG_A).listCollections().toArray()).toEqual([]);
      expect(await snapshot(SLUG_B)).toEqual(bBefore);
      const output = printed();
      expect(output).toContain("no longer validate");
      expect(output).toContain("verify through the normal flow again");
      expect(output).toContain("operation authority");
      expect(output).not.toContain("mongodb://");

      // The marker went too, so nothing destructive is reachable until `init` again.
      await expect(run(SLUG_A, ["reset"])).rejects.toThrow("no QA environment marker");
    });
  });
});
