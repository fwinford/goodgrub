// W5-INF1 probe: model discovery and index verification. Dev/test tooling only.
//
// Inventory rules (the only place a model list is decided):
//  - Production-database models are every model registered on the default
//    mongoose instance by `models/db.ts` and `models/messaging.ts`, except the
//    documented dormant exclusion below. A model added to either module is
//    therefore probed with no edit here.
//  - Review-database models come from `createReviewModels()` itself, run on a
//    connection that satisfies its own `assertReviewDatabase` contract.
//  - A model registered in any OTHER source file is not discovered by import.
//    `findModelRegistrationFiles()` scans the source tree so a unit test fails
//    until such a file is added to the inventory or documented as excluded.
//
// Index requirements are verified by running the application's own
// `Model.createIndexes()` through a least-privilege connection, then comparing
// the server's index list with the schema declaration.
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import mongoose, { type Connection, type Model } from "mongoose";

// Messaging is dormant: `app.ts` neither imports it nor builds its indexes at
// startup, so its indexes are not a production runtime requirement yet. They
// are still verified as a separate "dormant" group. `messagingIsWiredIntoApp()`
// fails the probe if this exclusion becomes stale.
export const DORMANT_MESSAGING_MODELS: readonly string[] = [
  "MessageConversation",
  "ConversationMessage",
  "MessageReceipt",
];

// Source files that legitimately register Mongoose models, and why.
export const MODEL_REGISTRATION_FILES: Readonly<Record<string, string>> = {
  "models/db.ts": "production models (discovered by import)",
  "models/messaging.ts": "dormant messaging models (discovered by import, verified separately)",
  "models/moderation.ts": "moderation models (discovered by import; app.ts establishes their indexes)",
  "models/reviewDb.ts": "review models (verified through createReviewModels)",
  "scripts/atlas-qualification-probe-indexes.ts": "re-registers discovered schemas on the probe connection",
};

export interface DiscoveredModels {
  production: Model<any>[];
  dormantMessaging: Model<any>[];
}

export async function discoverModels(): Promise<DiscoveredModels> {
  await import("../models/db.js");
  await import("../models/messaging.js");
  await import("../models/moderation.js");
  const dormant = new Set(DORMANT_MESSAGING_MODELS);
  const all = Object.values(mongoose.models) as Model<any>[];
  return {
    production: all.filter((model) => !dormant.has(model.modelName)),
    dormantMessaging: all.filter((model) => dormant.has(model.modelName)),
  };
}

export function messagingIsWiredIntoApp(root: string): boolean {
  return /models\/messaging(\.js)?["']/.test(readFileSync(path.join(root, "app.ts"), "utf8"));
}

const REGISTRATION_PATTERN = /(?:^|[^\w])(?:\w+\.)?model\s*(?:<[^>]*>)?\s*\(/;

export function findModelRegistrationFiles(root: string): string[] {
  const found: string[] = [];
  const visit = (relative: string) => {
    const absolute = path.join(root, relative);
    if (statSync(absolute).isDirectory()) {
      for (const entry of readdirSync(absolute)) {
        if (entry === "node_modules" || entry.startsWith(".")) continue;
        visit(path.join(relative, entry));
      }
    } else if (/\.ts$/.test(relative) && !/\.test\.ts$/.test(relative) && !/\.d\.ts$/.test(relative)) {
      if (REGISTRATION_PATTERN.test(readFileSync(absolute, "utf8"))) found.push(relative);
    }
  };
  for (const entry of ["app.ts", "models", "src", "scripts"]) visit(entry);
  return found.sort();
}

export interface ExpectedIndex {
  name: string;
  key: [string, unknown][];
  unique: boolean;
  sparse: boolean;
  expireAfterSeconds: number | undefined;
  partialFilterExpression: unknown;
}

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object" && !(value instanceof Date)) {
    const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${stable(v)}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "undefined";
}

export function expectedIndexes(model: Model<any>): ExpectedIndex[] {
  return model.schema.indexes().map(([fields, options]) => {
    const key = Object.entries(fields as Record<string, unknown>);
    return {
      name: (options.name as string | undefined) ?? key.map(([field, direction]) => `${field}_${direction}`).join("_"),
      key,
      unique: Boolean(options.unique),
      sparse: Boolean(options.sparse),
      expireAfterSeconds: options.expireAfterSeconds as number | undefined,
      partialFilterExpression: options.partialFilterExpression,
    };
  });
}

interface ServerIndex {
  name: string;
  key: Record<string, unknown>;
  unique?: boolean;
  sparse?: boolean;
  expireAfterSeconds?: number;
  partialFilterExpression?: unknown;
}

/** Pure comparison of one collection: returns problems, empty when exact. */
export function compareIndexes(modelName: string, expected: ExpectedIndex[], actual: ServerIndex[]): string[] {
  const problems: string[] = [];
  const server = actual.filter((index) => index.name !== "_id_");
  for (const want of expected) {
    const have = server.find((index) => index.name === want.name);
    if (!have) {
      problems.push(`${modelName}: missing index ${want.name}`);
      continue;
    }
    if (stable(Object.entries(have.key)) !== stable(want.key)) problems.push(`${modelName}.${want.name}: key differs`);
    if (Boolean(have.unique) !== want.unique) problems.push(`${modelName}.${want.name}: unique differs`);
    if (Boolean(have.sparse) !== want.sparse) problems.push(`${modelName}.${want.name}: sparse differs`);
    if (have.expireAfterSeconds !== want.expireAfterSeconds) problems.push(`${modelName}.${want.name}: TTL differs`);
    if (stable(have.partialFilterExpression) !== stable(want.partialFilterExpression)) {
      problems.push(`${modelName}.${want.name}: partial filter differs`);
    }
  }
  for (const have of server) {
    if (!expected.some((want) => want.name === have.name)) problems.push(`${modelName}: unexpected index ${have.name}`);
  }
  return problems;
}

export interface IndexVerification {
  models: number;
  indexes: number;
  problems: string[];
}

async function verifyOne(model: Model<any>, expected: ExpectedIndex[], problems: string[]): Promise<void> {
  await model.createIndexes();
  // A model with no declared index never gets a collection from createIndexes (code 26 = no namespace).
  const actual = (await model.listIndexes().catch((error: { code?: number }) => {
    if (error.code === 26 && expected.length === 0) return [];
    throw error;
  })) as ServerIndex[];
  problems.push(...compareIndexes(model.modelName, expected, actual));
}

/** Builds each discovered schema's indexes through `Model.createIndexes()` on the probe connection. */
export async function verifyProductionIndexes(connection: Connection, models: Model<any>[]): Promise<IndexVerification> {
  const problems: string[] = [];
  let indexes = 0;
  for (const source of models) {
    const bound = connection.model(source.modelName, source.schema, source.collection.name);
    const expected = expectedIndexes(source);
    indexes += expected.length;
    await verifyOne(bound, expected, problems);
  }
  return { models: models.length, indexes, problems };
}

/** Uses the application's own `createReviewModels`; `connection` must satisfy its review-database contract. */
export async function verifyReviewIndexes(connection: Connection): Promise<IndexVerification> {
  const { createReviewModels } = await import("../models/reviewDb.js");
  const previous = process.env.NODE_ENV;
  process.env.NODE_ENV = "review";
  try {
    const models = Object.values(createReviewModels(connection)) as Model<any>[];
    const problems: string[] = [];
    let indexes = 0;
    for (const model of models) {
      const expected = expectedIndexes(model);
      indexes += expected.length;
      await verifyOne(model, expected, problems);
    }
    return { models: models.length, indexes, problems };
  } finally {
    if (previous === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = previous;
  }
}
