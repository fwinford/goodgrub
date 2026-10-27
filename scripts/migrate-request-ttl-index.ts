import "dotenv/config";
import { pathToFileURL } from "node:url";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";

export const REQUEST_DELETE_AT_TTL_INDEX = "request_deleteAt_ttl";

interface MongoIndexDescription {
  name?: string;
  key?: Record<string, number>;
  expireAfterSeconds?: number;
}

export function isExpiresAtTtlIndex(
  index: MongoIndexDescription
): index is MongoIndexDescription & { name: string } {
  return (
    typeof index.name === "string" &&
    index.expireAfterSeconds !== undefined &&
    !!index.key &&
    Object.keys(index.key).length === 1 &&
    index.key.expiresAt === 1
  );
}

export class RequestTtlMigrationError extends Error {}

/**
 * Refuses the index swap while any request uses the obsolete `requested`
 * status or lacks `deleteAt`, because such a record would otherwise lose its
 * deletion path when the `expiresAt` TTL index is removed.
 */
export function describeLegacyRequestData(
  legacyStatusCount: number,
  missingDeleteAtCount: number
): string | null {
  if (legacyStatusCount === 0 && missingDeleteAtCount === 0) {
    return null;
  }

  return [
    "Refusing to migrate the Request TTL index: this database still holds",
    "pre-Day-4 request records.",
    `  requests with status "requested": ${legacyStatusCount}`,
    `  requests missing deleteAt:        ${missingDeleteAtCount}`,
    "",
    "These records are disposable and are not backfilled. Clear them, let the",
    "deployed Day 4 code write new-format records, then run this migration",
    "again and reseed local UI data:",
    "",
    '  mongosh "$MONGO_URI" --eval \'db.requests.deleteMany({})\'',
    "  npm run migrate:request-ttl",
    "  npm run seed:ui",
    "",
    "No index was changed; the existing expiresAt TTL protection is intact.",
  ].join("\n");
}

async function assertNoLegacyRequestData(): Promise<void> {
  // Counted through the driver so no schema-level status casting can hide a
  // legacy value from the check.
  const legacyStatusCount = await MealRequest.collection.countDocuments({
    status: "requested",
  });
  const missingDeleteAtCount = await MealRequest.collection.countDocuments({
    deleteAt: { $exists: false },
  });

  const refusal = describeLegacyRequestData(
    legacyStatusCount,
    missingDeleteAtCount
  );
  if (refusal) {
    throw new RequestTtlMigrationError(refusal);
  }
}

/**
 * Index work against an already-connected mongoose instance. Every refusal is
 * raised before the first index write, so a failed run leaves the collection
 * exactly as it found it.
 */
export async function applyRequestTtlIndexMigration(): Promise<void> {
  await assertNoLegacyRequestData();

  // Create the `deleteAt` TTL index before dropping `expiresAt` TTL indexes, so
  // current-format records always retain a deletion path.
  await MealRequest.collection.createIndex(
    { deleteAt: 1 },
    {
      name: REQUEST_DELETE_AT_TTL_INDEX,
      expireAfterSeconds: 0,
    }
  );

  const indexes =
    (await MealRequest.collection.indexes()) as MongoIndexDescription[];
  const legacyTtlIndexes = indexes.filter(isExpiresAtTtlIndex);
  for (const index of legacyTtlIndexes) {
    await MealRequest.collection.dropIndex(index.name);
  }

  console.log(
    `Request TTL now uses ${REQUEST_DELETE_AT_TTL_INDEX}; removed ${legacyTtlIndexes.length} expiresAt TTL index(es).`
  );
}

export async function migrateRequestTtlIndex(
  mongoUri: string
): Promise<void> {
  await mongoose.connect(mongoUri);
  try {
    await applyRequestTtlIndexMigration();
  } finally {
    await mongoose.disconnect();
  }
}

const entryPath = process.argv[1];
if (entryPath && import.meta.url === pathToFileURL(entryPath).href) {
  if (!process.env.MONGO_URI) {
    console.error("Missing required environment variable: MONGO_URI");
    process.exitCode = 1;
  } else {
    try {
      await migrateRequestTtlIndex(process.env.MONGO_URI);
    } catch (error) {
      console.error(
        error instanceof Error
          ? error.message
          : "Request TTL migration failed"
      );
      process.exitCode = 1;
    }
  }
}
