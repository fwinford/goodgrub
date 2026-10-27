import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { SeedSafetyError, UI_FIXTURE_EMAIL, buildFixtureDocument, runSeedTool } from "./seed-ui-request.js";

/**
 * Runs the seed tool end to end against a real MongoDB. It owns its own
 * database so it cannot interfere with the other Mongo suites, which vitest
 * executes concurrently.
 */
function seedDatabaseUri(uri: string): string {
  const parsed = new URL(uri);
  parsed.pathname = "/commonplate_qa_seed_test";
  return parsed.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? seedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const OWNER_EMAIL = "qa-owner@nyu.edu";
const OTHER_EMAIL = "qa-other@nyu.edu";

function environment(extra: Record<string, string> = {}) {
  return {
    NODE_ENV: "test",
    ALLOW_LOCAL_SEED: "true",
    MONGO_URI: mongoUri!,
    ...extra,
  };
}

describeMongo("W4-QA1 seed tool against real MongoDB", () => {
  // A native client separate from mongoose: `runSeedTool` ends by calling
  // `mongoose.disconnect()`, which also closes every mongoose connection.
  let client: InstanceType<typeof mongoose.mongo.MongoClient>;
  let inspector: ReturnType<typeof client.db>;
  let log: ReturnType<typeof vi.spyOn>;
  let ownerId: mongoose.Types.ObjectId;
  let otherId: mongoose.Types.ObjectId;

  const requests = () => inspector.collection("requests");

  async function insertParticipant(email: string) {
    const _id = new mongoose.Types.ObjectId();
    await inspector
      .collection("participants")
      .insertOne({ _id, email, authorityVersion: 1, verifiedAt: new Date() });
    return _id;
  }

  function realRequest(overrides: Record<string, unknown> = {}) {
    const expiresAt = new Date(Date.now() + 60 * 60 * 1000);
    return {
      vendor: "Cafe 370",
      food: "Chicken biryani",
      mealItems: [{ name: "Chicken biryani" }],
      menuPath: "meal-exchange",
      mealSwipes: 1,
      pickupWindowText: "ASAP",
      email: "real@nyu.edu",
      status: "open",
      expiresAt,
      deleteAt: expiresAt,
      ...overrides,
    };
  }

  beforeAll(async () => {
    client = await new mongoose.mongo.MongoClient(mongoUri!).connect();
    inspector = client.db("commonplate_qa_seed_test");
  });

  beforeEach(async () => {
    await requests().deleteMany({});
    await inspector.collection("participants").deleteMany({});
    ownerId = await insertParticipant(OWNER_EMAIL);
    otherId = await insertParticipant(OTHER_EMAIL);
    log = vi.spyOn(console, "log").mockImplementation(() => undefined);
  });

  afterEach(() => {
    log.mockRestore();
  });

  afterAll(async () => {
    await inspector.dropDatabase();
    await client.close();
  });

  const printed = () => log.mock.calls.map((call: unknown[]) => call.join(" ")).join("\n");

  it("seeds and cleans the legacy fixture without touching other requests", async () => {
    await requests().insertOne(realRequest());

    await runSeedTool("seed", environment());
    const seeded = await requests().find({ email: UI_FIXTURE_EMAIL }).toArray();
    expect(seeded).toHaveLength(1);
    const expected = buildFixtureDocument();
    expect(seeded[0]!.mealItems).toEqual(expected.mealItems);
    expect(seeded[0]!.food).toBe(expected.food);
    expect(seeded[0]!.vendor).toBe(expected.vendor);

    // Re-seeding replaces rather than accumulates.
    await runSeedTool("seed", environment());
    expect(await requests().countDocuments({ email: UI_FIXTURE_EMAIL })).toBe(1);

    await runSeedTool("cleanup", environment());
    expect(await requests().countDocuments({})).toBe(1);
    expect((await requests().findOne({}))!.food).toBe("Chicken biryani");
  });

  it("seeds owned fixtures for an existing verified participant only, and cleans only the recorded ones", async () => {
    await requests().insertMany([
      // The owner's own real requests, unrelated to any fixture.
      realRequest({ requesterParticipantId: ownerId }),
      // Another participant's request.
      realRequest({ requesterParticipantId: otherId }),
    ]);

    await runSeedTool("seed-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL, SEED_OWNER_COUNT: "6" }));
    const fixtures = await requests().find({ requesterParticipantId: ownerId, email: OWNER_EMAIL }).toArray();
    expect(fixtures).toHaveLength(6);
    const diningDollars = fixtures.filter((document) => document.menuPath === "dining-dollars");
    expect(diningDollars).toHaveLength(1);
    expect(diningDollars[0]!.mealItems).toEqual([]);
    expect(diningDollars[0]!.mealSwipes).toBe(0);
    expect(diningDollars[0]!.estimatedDiningDollarsCents).toBe(1450);
    for (const document of fixtures.filter((d) => d.menuPath === "meal-exchange")) {
      expect(document.mealItems).toHaveLength(document.mealSwipes);
    }
    // A scheduled fixture keeps the creation time chosen for it.
    const started = fixtures.find((d) => d.windowStart && d.windowStart <= new Date());
    expect(started!.createdAt.getTime()).toBeLessThan(started!.windowStart.getTime());

    // The manifest records exactly the seeded ids, and nothing else.
    const manifest = await inspector.collection("qa1OwnedFixtureManifest").findOne({ _id: ownerId } as never);
    expect(new Set(manifest!.requestIds.map(String))).toEqual(new Set(fixtures.map((d) => String(d._id))));

    // No private identifier is printed.
    expect(printed()).not.toContain(OWNER_EMAIL);
    expect(printed()).not.toContain(String(ownerId));

    await runSeedTool("cleanup-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL }));
    expect(await requests().countDocuments({ requesterParticipantId: ownerId, email: OWNER_EMAIL })).toBe(0);
    // The owner's real request and the other participant's request remain.
    expect(await requests().countDocuments({ requesterParticipantId: ownerId })).toBe(1);
    expect(await requests().countDocuments({ requesterParticipantId: otherId })).toBe(1);
    expect(await inspector.collection("qa1OwnedFixtureManifest").countDocuments({})).toBe(0);
    expect(printed()).not.toContain(OWNER_EMAIL);
    expect(printed()).not.toContain(String(ownerId));
  });

  it("never treats a real owned request that looks exactly like a fixture as a fixture", async () => {
    await runSeedTool("seed-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL, SEED_OWNER_COUNT: "6" }));
    const fixtures = await requests().find({ requesterParticipantId: ownerId }).toArray();

    // A real, product-style request by the same participant and address carrying
    // every visible value of each fixture: same vendor, items, details, food,
    // timing text, swipes, estimate and order details.
    const lookalikes = fixtures.map(({ _id, ...content }) => ({ ...content }));
    await requests().insertMany(lookalikes);
    expect(await requests().countDocuments({ requesterParticipantId: ownerId })).toBe(12);

    await runSeedTool("cleanup-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL }));
    const survivors = await requests().find({ requesterParticipantId: ownerId }).toArray();
    expect(survivors).toHaveLength(6);
    const fixtureIds = new Set(fixtures.map((d) => String(d._id)));
    expect(survivors.every((d) => !fixtureIds.has(String(d._id)))).toBe(true);
    for (const survivor of survivors) {
      expect(lookalikes.some((l) => l.food === survivor.food && l.vendor === survivor.vendor)).toBe(true);
    }

    // Re-seeding likewise leaves them alone.
    await runSeedTool("seed-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL, SEED_OWNER_COUNT: "2" }));
    await runSeedTool("seed-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL, SEED_OWNER_COUNT: "2" }));
    expect(await requests().countDocuments({ requesterParticipantId: ownerId })).toBe(6 + 2);
  });

  it("deletes nothing when no manifest exists, even for a request that is otherwise identical", async () => {
    await runSeedTool("seed-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL, SEED_OWNER_COUNT: "3" }));
    await inspector.collection("qa1OwnedFixtureManifest").deleteMany({});

    await runSeedTool("cleanup-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL }));
    expect(await requests().countDocuments({ requesterParticipantId: ownerId })).toBe(3);
  });

  it("does not delete a recorded id that no longer belongs to the owner or address", async () => {
    await runSeedTool("seed-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL, SEED_OWNER_COUNT: "2" }));
    const [first] = await requests().find({ requesterParticipantId: ownerId }).toArray();
    // Reassign one recorded request to someone else, as tampering or drift would.
    await requests().updateOne({ _id: first!._id }, { $set: { requesterParticipantId: otherId } });

    await runSeedTool("cleanup-owned", environment({ SEED_OWNER_EMAIL: OWNER_EMAIL }));
    expect(await requests().countDocuments({ requesterParticipantId: otherId })).toBe(1);
    expect(await requests().countDocuments({ requesterParticipantId: ownerId })).toBe(0);
  });

  it("refuses owned fixtures for an address with no verified participant and creates nothing", async () => {
    await expect(
      runSeedTool("seed-owned", environment({ SEED_OWNER_EMAIL: "nobody@nyu.edu" }))
    ).rejects.toThrow("No verified Participant found for SEED_OWNER_EMAIL");
    expect(await requests().countDocuments({})).toBe(0);
    expect(await inspector.collection("participants").countDocuments({})).toBe(2);
  });

  it("seeds unowned needs-help fixtures without creating any participant, and cleans only those", async () => {
    await requests().insertMany([
      // A real unowned request, and a real owned request that merely carries a
      // reserved-looking address: neither is a needs-help fixture.
      realRequest({ requesterParticipantId: null }),
      realRequest({
        email: "commonplate-ui-seed-needs-help-9@example.invalid",
        requesterParticipantId: ownerId,
      }),
    ]);

    await runSeedTool("seed-needs-help", environment({ SEED_NEEDS_HELP_COUNT: "6" }));
    const fixtures = await requests()
      .find({ email: { $regex: "^commonplate-ui-seed-needs-help-[0-9]+@example\\.invalid$" }, requesterParticipantId: null })
      .toArray();
    expect(fixtures).toHaveLength(6);
    for (const document of fixtures) {
      expect(document.mealItems).toHaveLength(document.mealSwipes);
    }
    expect(await inspector.collection("participants").countDocuments({})).toBe(2);

    await runSeedTool("cleanup-needs-help", environment());
    expect(await requests().countDocuments({})).toBe(2);
    expect(await requests().countDocuments({ food: "Chicken biryani", requesterParticipantId: null })).toBe(1);
    expect(await requests().countDocuments({ requesterParticipantId: ownerId })).toBe(1);
  });

  it("refuses an unsafe or unnamed database before connecting", async () => {
    const parsed = new URL(mongoUri!);
    for (const pathname of ["/commonplate_prod", "/commonplate", "/"]) {
      parsed.pathname = pathname;
      await expect(
        runSeedTool("seed", environment({ MONGO_URI: parsed.toString() }))
      ).rejects.toThrow(SeedSafetyError);
    }
    expect(await requests().countDocuments({})).toBe(0);
  });

  it("requires the explicit local-seed opt-in", async () => {
    await expect(
      runSeedTool("seed", environment({ ALLOW_LOCAL_SEED: "false" }))
    ).rejects.toThrow("ALLOW_LOCAL_SEED=true");
    expect(await requests().countDocuments({})).toBe(0);
  });
});
