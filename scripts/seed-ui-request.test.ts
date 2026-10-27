import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import mongoose from "mongoose";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import { Request as MealRequest } from "../models/db.js";
import { REQUEST_VISIBLE_DURATION_MS } from "../src/requestTiming.js";
import {
  deriveFoodSummary,
  refineStructuredRequest,
  structuredRequestFields,
} from "../src/structuredRequest.js";
import { formatMealRequestWindow } from "../src/utils/date.js";
import {
  SeedSafetyError,
  UI_FIXTURE_EMAIL,
  assertLoopbackMongoTarget,
  assertSafeDatabaseName,
  describeSeedFailure,
  resolveSeedTarget,
  buildExactFixtureFilter,
  buildFixtureDocument,
  buildNeedsHelpFixtureDocument,
  buildNeedsHelpFixtureFilter,
  buildOwnedFixtureDocument,
  buildOwnedFixtureFilter,
  normalizeOwnerEmail,
  parseExplicitDatabaseName,
  parseNeedsHelpFixtureCount,
  parseOwnedFixtureCount,
  validateRuntimeSafety,
} from "./seed-ui-request.js";

describe("UI request seed safety", () => {
  it("refuses production mode", () => {
    expect(() =>
      validateRuntimeSafety({
        NODE_ENV: "production",
        ALLOW_LOCAL_SEED: "true",
        MONGO_URI: "mongodb://localhost/commonplate_test",
      })
    ).toThrow(SeedSafetyError);
  });

  it("requires explicit confirmation", () => {
    expect(() =>
      validateRuntimeSafety({
        NODE_ENV: "development",
        ALLOW_LOCAL_SEED: "false",
        MONGO_URI: "mongodb://localhost/commonplate_test",
      })
    ).toThrow("ALLOW_LOCAL_SEED=true");
  });

  it("requires a MongoDB URI", () => {
    expect(() =>
      validateRuntimeSafety({
        NODE_ENV: "development",
        ALLOW_LOCAL_SEED: "true",
      })
    ).toThrow("MONGO_URI is required");
  });

  it.each(["prod", "production", "commonplate", "commonplate-production"])(
    "refuses production-like database name %s",
    (databaseName) => {
      expect(() => assertSafeDatabaseName(databaseName)).toThrow(
        "production-like"
      );
    }
  );

  it.each(["test", "commonplate_dev", "commonplate_test", "commonplate_local"])(
    "accepts clearly non-production database name %s",
    (databaseName) => {
      expect(() => assertSafeDatabaseName(databaseName)).not.toThrow();
    }
  );

  it("parses only the database name from a URI", () => {
    expect(
      parseExplicitDatabaseName(
        "mongodb://localhost:27017/commonplate_test?retryWrites=true"
      )
    ).toBe("commonplate_test");
  });
});

// The accepted create contract, applied to what the tool writes.
const acceptedStructuredShape = z
  .object(structuredRequestFields)
  .strict()
  .superRefine(refineStructuredRequest);

const supportedVendors = (
  JSON.parse(readFileSync(new URL("../shared/vendors.json", import.meta.url), "utf8")) as Array<{
    name: string;
  }>
).map((vendor) => vendor.name);

describe("fixture identity", () => {
  it("keys the legacy fixture on the reserved address and no owner", () => {
    expect(buildExactFixtureFilter()).toEqual({
      email: UI_FIXTURE_EMAIL,
      requesterParticipantId: null,
    });
    expect(UI_FIXTURE_EMAIL).toMatch(/@example\.invalid$/);
  });

  it("keys needs-help fixtures on the reserved address pattern and no owner", () => {
    const filter = buildNeedsHelpFixtureFilter();
    const pattern = new RegExp(filter.email.$regex);
    expect(filter.requesterParticipantId).toBeNull();
    expect(pattern.test("commonplate-ui-seed-needs-help-3@example.invalid")).toBe(true);
    expect(pattern.test("student@nyu.edu")).toBe(false);
    expect(pattern.test("commonplate-ui-seed-needs-help-3@example.invalid.evil.com")).toBe(false);
  });

  it("identifies an owned fixture only by recorded id AND owner id AND requester address", () => {
    const owner = new mongoose.Types.ObjectId();
    const recorded = [new mongoose.Types.ObjectId(), new mongoose.Types.ObjectId()];
    const filter = buildOwnedFixtureFilter(owner, "owner@nyu.edu", recorded);
    expect(filter).toEqual({
      _id: { $in: recorded },
      requesterParticipantId: owner,
      email: "owner@nyu.edu",
    });
    // Nothing about the visible content takes part in the match.
    expect(Object.keys(filter).sort()).toEqual(["_id", "email", "requesterParticipantId"]);
  });

  it("matches nothing when nothing was recorded", () => {
    const filter = buildOwnedFixtureFilter(new mongoose.Types.ObjectId(), "owner@nyu.edu", []);
    expect(filter._id).toEqual({ $in: [] });
  });
});

describe("fixture option parsing", () => {
  it("requires an owner email and normalizes it", () => {
    expect(() => normalizeOwnerEmail(undefined)).toThrow(SeedSafetyError);
    expect(() => normalizeOwnerEmail("   ")).toThrow("SEED_OWNER_EMAIL");
    expect(normalizeOwnerEmail("  Student@NYU.edu  ")).toBe("student@nyu.edu");
  });

  it.each([
    ["owned", parseOwnedFixtureCount],
    ["needs-help", parseNeedsHelpFixtureCount],
  ] as const)("defaults and bounds the %s fixture count", (_label, parse) => {
    expect(parse(undefined)).toBe(8);
    expect(parse("")).toBe(8);
    expect(parse("10")).toBe(10);
    for (const bad of ["0", "21", "abc", "3.5"]) {
      expect(() => parse(bad)).toThrow(SeedSafetyError);
    }
  });
});

describe("W4-QA1 fixtures satisfy the real request constraints", () => {
  const now = new Date("2026-10-08T17:00:00.000Z");
  const owner = new mongoose.Types.ObjectId();
  const indexes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
  const documents = [
    ["legacy", buildFixtureDocument(now)],
    ...indexes.map((index) => [`owned #${index + 1}`, buildOwnedFixtureDocument(index, "owner@nyu.edu", owner, now)] as const),
    ...indexes.map((index) => [`needs-help #${index + 1}`, buildNeedsHelpFixtureDocument(index, now)] as const),
  ] as const;

  it.each(documents)("%s uses the structured shape the create contract accepts", (_label, document) => {
    expect(
      acceptedStructuredShape.safeParse({
        menuPath: document.menuPath,
        mealSwipes: document.mealSwipes,
        mealItems: document.mealItems,
        ...("orderDetails" in document ? { orderDetails: document.orderDetails } : {}),
        ...("estimatedDiningDollarsCents" in document
          ? { estimatedDiningDollarsCents: document.estimatedDiningDollarsCents }
          : {}),
      }).success
    ).toBe(true);
  });

  it.each(documents)("%s passes Request schema validation", (_label, document) => {
    expect(new MealRequest(document).validateSync()).toBeUndefined();
  });

  it.each(documents)("%s names a supported vendor", (_label, document) => {
    expect(supportedVendors).toContain(document.vendor);
  });

  it.each(documents)("%s food is exactly the summary derived from its structured fields", (_label, document) => {
    expect(document.food).toBe(
      deriveFoodSummary({
        menuPath: document.menuPath,
        mealSwipes: document.mealSwipes,
        mealItems: document.mealItems,
        ...("orderDetails" in document ? { orderDetails: document.orderDetails } : {}),
        ...("estimatedDiningDollarsCents" in document
          ? { estimatedDiningDollarsCents: document.estimatedDiningDollarsCents }
          : {}),
      })
    );
  });

  it.each(documents)("%s follows the three-hour visibility window", (_label, document) => {
    expect(document.expiresAt.getTime() - document.visibleFrom.getTime()).toBe(REQUEST_VISIBLE_DURATION_MS);
    expect(document.deleteAt).toEqual(document.expiresAt);
    expect(document.createdAt.getTime()).toBeLessThanOrEqual(now.getTime());
    if (document.pickupWindowText === "ASAP") {
      expect(document.visibleFrom).toEqual(now);
      expect(document).not.toHaveProperty("windowStart");
      expect(document).not.toHaveProperty("windowEnd");
      expect(document.helperNotification).toBe("initiated");
    } else {
      const timing = document as { windowStart?: Date; windowEnd?: Date };
      expect(timing.windowStart).toEqual(document.visibleFrom);
      expect(timing.windowEnd).toEqual(document.expiresAt);
      expect(document.pickupWindowText).toBe(formatMealRequestWindow(document.visibleFrom, document.expiresAt));
      // A request created for a later start is created before that start.
      expect(document.createdAt.getTime()).toBeLessThanOrEqual(document.visibleFrom.getTime());
      expect(document.helperNotification).toBe(
        document.visibleFrom.getTime() <= now.getTime() ? "initiated" : "awaiting-eligibility"
      );
    }
  });

  it("covers every request shape, including one helpers cannot see yet", () => {
    const needsHelp = indexes.map((index) => buildNeedsHelpFixtureDocument(index, now));
    expect(needsHelp.some((d) => d.menuPath === "dining-dollars" && d.mealSwipes === 0)).toBe(true);
    expect(needsHelp.some((d) => d.menuPath === "meal-exchange" && "estimatedDiningDollarsCents" in d)).toBe(true);
    expect(needsHelp.some((d) => d.pickupWindowText === "ASAP")).toBe(true);
    expect(needsHelp.some((d) => d.visibleFrom.getTime() > now.getTime())).toBe(true);
    expect(needsHelp.some((d) => d.visibleFrom.getTime() < now.getTime())).toBe(true);
    expect(new Set(needsHelp.map((d) => d.mealSwipes)).size).toBeGreaterThan(3);
  });

  it("needs-help fixtures carry the reserved address and no owner", () => {
    for (const index of indexes) {
      const needsHelp = buildNeedsHelpFixtureDocument(index, now);
      expect(needsHelp.requesterParticipantId).toBeNull();
      expect(needsHelp.email).toMatch(new RegExp(buildNeedsHelpFixtureFilter().email.$regex));
    }
  });

  it("keeps the first owned fixtures visually distinct from the default needs-help and legacy ones", () => {
    const others = [
      buildFixtureDocument(now),
      ...[0, 1, 2, 3, 4, 5, 6, 7].map((index) => buildNeedsHelpFixtureDocument(index, now)),
    ];
    for (const index of [0, 1]) {
      const owned = buildOwnedFixtureDocument(index, "owner@nyu.edu", owner, now);
      expect(others.some((other) => other.vendor === owned.vendor)).toBe(false);
    }
  });

  it("binds owned fixtures only to the id and address they were given", () => {
    const document = buildOwnedFixtureDocument(0, "owner@nyu.edu", owner, now);
    expect(document.requesterParticipantId).toBe(owner);
    expect(document.email).toBe("owner@nyu.edu");
  });

  it("casts every cleanup filter under the current Request model", () => {
    for (const filter of [
      buildExactFixtureFilter(),
      buildOwnedFixtureFilter(new mongoose.Types.ObjectId(), "owner@nyu.edu", [new mongoose.Types.ObjectId()]),
      buildNeedsHelpFixtureFilter(),
    ]) {
      expect(() => MealRequest.find(filter as Record<string, unknown>).cast(MealRequest)).not.toThrow();
    }
  });

  it("contains no visible marker text a real request would not carry", () => {
    for (const [, document] of documents) {
      expect(`${document.food} ${document.pickupWindowText} ${document.vendor}`).not.toMatch(/fixture|QA|safe to delete|H4/i);
    }
  });
});

describe("W4-QA1 database target isolation", () => {
  const base = { ALLOW_LOCAL_SEED: "true", NODE_ENV: "development" };

  it("accepts a loopback target with an explicit safe database", () => {
    expect(
      resolveSeedTarget({
        ...base,
        MONGO_URI: "mongodb://127.0.0.1:27018/commonplate_qa?replicaSet=rs0",
      }).databaseName
    ).toBe("commonplate_qa");
    expect(() =>
      assertLoopbackMongoTarget("mongodb://localhost:1,[::1]:2/commonplate_test")
    ).not.toThrow();
  });

  it("requires the explicit local-seed opt-in", () => {
    expect(() =>
      resolveSeedTarget({ NODE_ENV: "development", MONGO_URI: "mongodb://127.0.0.1/commonplate_qa" })
    ).toThrow("ALLOW_LOCAL_SEED=true");
  });

  it.each([
    "mongodb://127.0.0.1:27017",
    "mongodb://127.0.0.1:27017/",
    "mongodb://127.0.0.1:27017/?replicaSet=rs0",
  ])("refuses an unnamed database target %s", (uri) => {
    expect(() => resolveSeedTarget({ ...base, MONGO_URI: uri })).toThrow("unnamed target");
  });

  it.each([
    "mongodb://db.example.com/commonplate_qa",
    "mongodb://10.0.0.5/commonplate_qa",
    "mongodb://192.168.1.20:27017/commonplate_qa",
    "mongodb://127.0.0.1,db.example.com/commonplate_qa",
    "mongodb://127.0.0.1@db.example.com/commonplate_qa",
    "mongodb://user:pw@cluster0.mongodb.net/commonplate_qa",
    "mongodb+srv://user:pw@cluster0.mongodb.net/commonplate_qa",
    "mongodb://0.0.0.0/commonplate_qa",
  ])("refuses a non-loopback target", (uri) => {
    expect(() => resolveSeedTarget({ ...base, MONGO_URI: uri })).toThrow(SeedSafetyError);
  });

  it.each([
    "mongodb://127.0.0.1/commonplate",
    "mongodb://127.0.0.1/prod",
    "mongodb://127.0.0.1/commonplate_production",
    "mongodb://127.0.0.1/commonplate_staging",
    "mongodb://127.0.0.1/mydata",
  ])("refuses an unsafe database name in %s", (uri) => {
    expect(() => resolveSeedTarget({ ...base, MONGO_URI: uri })).toThrow(SeedSafetyError);
  });

  it("refuses a URI that names two different databases", () => {
    expect(() =>
      resolveSeedTarget({
        ...base,
        MONGO_URI: "mongodb://127.0.0.1/commonplate_qa?dbName=commonplate_prod",
      })
    ).toThrow("ambiguous");
  });

  it("never quotes the MongoDB URI in a refusal", () => {
    const uri = "mongodb://secretuser:secretpass@db.example.com/commonplate_qa";
    try {
      resolveSeedTarget({ ...base, MONGO_URI: uri });
      throw new Error("expected refusal");
    } catch (error) {
      expect((error as Error).message).not.toContain("secretpass");
      expect((error as Error).message).not.toContain("db.example.com");
    }
  });
});

describe("W4-QA1 sanitized failures", () => {
  it("classifies a validation failure by field path without quoting values", () => {
    const invalid = new MealRequest({ vendor: "v", food: "SECRET-VALUE", mealSwipes: 99 });
    const error = invalid.validateSync()!;
    const message = describeSeedFailure(error, "fixture write");
    expect(message).toContain("fixture write");
    expect(message).toContain("mealSwipes");
    expect(message).not.toContain("SECRET-VALUE");
  });

  it("classifies a cast failure by path", () => {
    let caught: unknown;
    try {
      MealRequest.find({ mealItems: ["flat string"] } as never).cast(MealRequest);
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeDefined();
    expect(describeSeedFailure(caught, "fixture cleanup")).toContain("fixture cleanup");
  });

  it("does not echo a connection URI carried in an unexpected error", () => {
    const error = new Error("failed for mongodb://user:hunter2@db.example.com/x");
    error.name = "MongoServerSelectionError";
    const message = describeSeedFailure(error, "database connection");
    expect(message).toContain("database connection");
    expect(message).toContain("unreachable");
    expect(message).not.toContain("hunter2");
    expect(message).not.toContain("mongodb://");
  });

  it("does not echo an unclassified error's message", () => {
    const message = describeSeedFailure(new Error("token=abc123"), "fixture write");
    expect(message).not.toContain("abc123");
  });
});

describe("W4-QA1 environment isolation", () => {
  it("importing the seed module does not load the working directory's .env", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "qa1-dotenv-"));
    try {
      const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
      writeFileSync(path.join(directory, ".env"), "QA1_DOTENV_SENTINEL=loaded\n");
      writeFileSync(
        path.join(directory, "probe.mts"),
        `await import(${JSON.stringify(path.join(repoRoot, "scripts", "seed-ui-request.ts"))});\n` +
          "console.log(process.env.QA1_DOTENV_SENTINEL ?? 'not-loaded');\n"
      );
      const result = spawnSync(
        path.join(repoRoot, "node_modules", ".bin", "tsx"),
        [path.join(directory, "probe.mts")],
        { cwd: directory, encoding: "utf8", env: { PATH: process.env.PATH } }
      );
      expect(result.stdout.trim()).toBe("not-loaded");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
