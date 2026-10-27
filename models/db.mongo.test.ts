import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { Subscriber } from "./db.js";

/**
 * Schema projection against real MongoDB. `select: false` is a query-shaping
 * option, so only a real read proves that a document physically holding the
 * legacy raw credential does not hand it back on an ordinary query.
 */
const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

describeMongo("Subscriber projection against real MongoDB", () => {
  beforeAll(async () => {
    // Its own database: this suite clears the whole Subscriber collection and
    // the Mongo files run concurrently, so a shared database would let its
    // cleanup delete another suite's fixtures.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_subscriber_schema_test",
    });
  });

  afterEach(async () => {
    await Subscriber.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  async function insertLegacyConfirmed() {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "legacy@example.edu",
      status: "confirmed",
      unsubToken: "legacy-raw-unsubscribe-token",
      bounced: false,
      dailyCount: 0,
    });
    return id;
  }

  it("omits the legacy raw unsubscribe token from an ordinary read", async () => {
    const id = await insertLegacyConfirmed();

    const read = await Subscriber.findById(id).lean();

    expect(read).not.toHaveProperty("unsubToken");
    expect(JSON.stringify(read)).not.toContain("legacy-raw-unsubscribe-token");
    // The alert and digest paths read subscribers exactly this way.
    const listed = await Subscriber.find({ status: "confirmed" }).lean();
    expect(listed).toHaveLength(1);
    expect(listed[0]).not.toHaveProperty("unsubToken");
  });

  it("leaves the stored value in place rather than deleting it", async () => {
    const id = await insertLegacyConfirmed();

    await Subscriber.findById(id).lean();

    // No migration and no rewrite: the projection hides the value, and a
    // deliberate explicit selection is still the only way to see it.
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?.unsubToken).toBe("legacy-raw-unsubscribe-token");
    const explicit = await Subscriber.findById(id).select("+unsubToken").lean();
    expect(explicit).toHaveProperty("unsubToken", "legacy-raw-unsubscribe-token");
  });
});
