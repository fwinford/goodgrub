import mongoose from "mongoose";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { Request as MealRequest } from "../models/db.js";
import {
  applyRequestTtlIndexMigration,
  REQUEST_DELETE_AT_TTL_INDEX,
  RequestTtlMigrationError,
} from "./migrate-request-ttl-index.js";

/**
 * This suite rewrites indexes and empties the collection, so it runs against
 * its own database rather than sharing the claim suite's — vitest executes the
 * two files concurrently.
 */
function migrationDatabaseUri(uri: string): string {
  const parsed = new URL(uri);
  const database = parsed.pathname.replace(/^\//, "") || "commonplate";
  parsed.pathname = `${database}_ttl_migration`;
  return parsed.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? migrationDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const LEGACY_TTL_INDEX = "expiresAt_1";
// MongoDB rejects compound TTL indexes outright, so the only real-world
// neighbour to protect is a non-TTL index that also covers `expiresAt`.
const NON_TTL_EXPIRES_AT_INDEX = "expiresAt_1_status_1";

async function indexNames(): Promise<string[]> {
  const indexes = await MealRequest.collection.indexes();
  return indexes.map((index) => String(index.name));
}

function requestDocument(overrides: Record<string, unknown>) {
  const expiresAt = new Date(Date.now() + 60 * 60 * 1000);
  return {
    vendor: "Migration Cafe",
    food: "Rice bowl",
    pickupName: "Disposable Name",
    pickupWindowText: "ASAP",
    email: "legacy@example.edu",
    expiresAt,
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  };
}

describeMongo("request TTL index migration against real MongoDB", () => {
  beforeAll(async () => {
    // The migration owns index changes here; autoIndex would otherwise create
    // the replacement TTL index behind the assertions below.
    mongoose.set("autoIndex", false);
    await mongoose.connect(mongoUri!);
  });

  beforeEach(async () => {
    await MealRequest.collection.deleteMany({});
    await MealRequest.collection.dropIndexes();
    // Rebuild the pre-Day-4 shape: TTL responsibility still on `expiresAt`.
    await MealRequest.collection.createIndex(
      { expiresAt: 1 },
      { name: LEGACY_TTL_INDEX, expireAfterSeconds: 0 }
    );
  });

  afterAll(async () => {
    await mongoose.disconnect();
    mongoose.set("autoIndex", true);
  });

  it("refuses while a legacy requested row exists and keeps the expiresAt TTL index", async () => {
    // Inserted through the driver so schema enum casting cannot mask the row.
    await MealRequest.collection.insertOne(
      requestDocument({
        status: "requested",
        deleteAt: new Date(Date.now() + 60 * 60 * 1000),
      })
    );

    await expect(applyRequestTtlIndexMigration()).rejects.toThrow(
      RequestTtlMigrationError
    );
    await expect(applyRequestTtlIndexMigration()).rejects.toThrow(
      /must be cleared|Clear them/i
    );

    const names = await indexNames();
    expect(names).toContain(LEGACY_TTL_INDEX);
    expect(names).not.toContain(REQUEST_DELETE_AT_TTL_INDEX);
  });

  it("refuses while a row is missing deleteAt and keeps the expiresAt TTL index", async () => {
    await MealRequest.collection.insertOne(
      requestDocument({ status: "open" })
    );

    await expect(applyRequestTtlIndexMigration()).rejects.toThrow(
      RequestTtlMigrationError
    );

    const names = await indexNames();
    expect(names).toContain(LEGACY_TTL_INDEX);
    expect(names).not.toContain(REQUEST_DELETE_AT_TTL_INDEX);
  });

  it("reports both legacy conditions with their counts", async () => {
    await MealRequest.collection.insertMany([
      requestDocument({ status: "requested", email: "a@example.edu" }),
      requestDocument({ status: "requested", email: "b@example.edu" }),
      requestDocument({ status: "open", email: "c@example.edu" }),
    ]);

    await expect(applyRequestTtlIndexMigration()).rejects.toThrow(
      /status "requested": 2[\s\S]*missing deleteAt: *3/
    );
  });

  it("migrates once the disposable rows are cleared, dropping only single-field expiresAt TTL indexes", async () => {
    await MealRequest.collection.createIndex(
      { expiresAt: 1, status: 1 },
      { name: NON_TTL_EXPIRES_AT_INDEX }
    );
    await MealRequest.collection.insertOne(
      requestDocument({ status: "requested" })
    );

    await expect(applyRequestTtlIndexMigration()).rejects.toThrow(
      RequestTtlMigrationError
    );

    // The documented remedy: clear the disposable rows, then write a
    // current-format record.
    await MealRequest.collection.deleteMany({});
    const expiresAt = new Date(Date.now() + 60 * 60 * 1000);
    await MealRequest.create({
      vendor: "Migration Cafe",
      food: "Rice bowl",
      pickupName: "New Format",
      pickupWindowText: "ASAP",
      email: "new@example.edu",
      status: "open",
      expiresAt,
      deleteAt: expiresAt,
    });

    await applyRequestTtlIndexMigration();

    const indexes = await MealRequest.collection.indexes();
    const names = indexes.map((index) => String(index.name));
    expect(names).toContain(REQUEST_DELETE_AT_TTL_INDEX);
    expect(names).not.toContain(LEGACY_TTL_INDEX);
    // Only single-field expiresAt *TTL* indexes are eligible for removal; a
    // plain index covering expiresAt is left alone.
    expect(names).toContain(NON_TTL_EXPIRES_AT_INDEX);
    expect(
      indexes.find((index) => index.name === REQUEST_DELETE_AT_TTL_INDEX)
    ).toEqual(
      expect.objectContaining({
        key: { deleteAt: 1 },
        expireAfterSeconds: 0,
      })
    );
  });
});
