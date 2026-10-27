import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Request as MealRequest } from "../models/db.js";
import {
  isEffectivelyAvailable,
  isVisibleNow,
} from "../src/requestAvailability.js";
import { isUnderDailyLimit } from "../src/requestDailyQuota.js";
import { deriveFoodSummary } from "../src/structuredRequest.js";
import { startOfCampusDay } from "../src/utils/date.js";
import {
  REQUEST_REFERENCE_HANDLING,
  SCENARIO_PRESETS,
  assertDropConfirmation,
  buildScenarioDocuments,
  parseQaEnvironmentConfig,
  parseScenarioPresets,
  qaBackendBaseUrl,
  runQaEnvironmentTool,
  type ScenarioPresetName,
} from "./qa-environment.js";
import { SeedSafetyError, assertLoopbackMongoTarget } from "./seed-ui-request.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function validConfig(overrides: Record<string, unknown> = {}) {
  return {
    slug: "alpha",
    database: "commonplate_qa_alpha",
    mongoUri: "mongodb://127.0.0.1:27040/commonplate_qa_alpha?replicaSet=rs",
    backendPort: 3021,
    mailSinkPort: 8031,
    ...overrides,
  };
}

function expectSafetyError(work: () => unknown, message?: string | RegExp) {
  expect(work).toThrow(SeedSafetyError);
  if (message) expect(work).toThrow(message);
}

describe("W4-QA1 QA environment config", () => {
  it("accepts an explicit, closed-form environment", () => {
    expect(parseQaEnvironmentConfig(validConfig())).toEqual(validConfig());
    expect(
      parseQaEnvironmentConfig(
        validConfig({
          slug: "h3_board",
          database: "commonplate_qa_h3_board",
          mongoUri: "mongodb://localhost:27040/commonplate_qa_h3_board",
        })
      )
    ).toBeTruthy();
  });

  it("rejects a non-object or open-ended config", () => {
    for (const raw of [null, "x", 3, [], undefined]) {
      expectSafetyError(() => parseQaEnvironmentConfig(raw));
    }
    expectSafetyError(
      () => parseQaEnvironmentConfig(validConfig({ extra: "field" })),
      "unsupported fields"
    );
  });

  it("rejects slugs outside the closed rule", () => {
    for (const slug of ["", "Alpha", "a-b", "a__b", "_a", "a_", "a b", "a/b", "../x", "a_b_c_d_e", "x".repeat(17), 7]) {
      expectSafetyError(
        () =>
          parseQaEnvironmentConfig(
            validConfig({ slug, database: `commonplate_qa_${String(slug)}` })
          ),
        "slug"
      );
    }
  });

  it("requires the database to be exactly commonplate_qa_<slug>", () => {
    for (const database of [
      undefined,
      "",
      "commonplate",
      "commonplate_prod",
      "commonplate_qa_beta",
      "commonplate_qa_alpha_",
      "qa_alpha",
      "commonplate_qa_alpha2",
    ]) {
      expectSafetyError(() => parseQaEnvironmentConfig(validConfig({ database })));
    }
  });

  it("refuses a production-like slug even though it fits the pattern", () => {
    for (const slug of ["prod", "production", "live", "x_prod"]) {
      expectSafetyError(
        () =>
          parseQaEnvironmentConfig(
            validConfig({
              slug,
              database: `commonplate_qa_${slug}`,
              mongoUri: `mongodb://127.0.0.1:27040/commonplate_qa_${slug}`,
            })
          ),
        "production-like"
      );
    }
  });

  it("requires a loopback MongoDB that names the same database", () => {
    for (const mongoUri of [
      "mongodb://db.example.com:27017/commonplate_qa_alpha",
      "mongodb://10.0.0.5:27017/commonplate_qa_alpha",
      "mongodb+srv://cluster.example.net/commonplate_qa_alpha",
      "mongodb://127.0.0.1:27017,db.example.com:27017/commonplate_qa_alpha",
    ]) {
      expectSafetyError(() => parseQaEnvironmentConfig(validConfig({ mongoUri })), /non-loopback/);
    }
    expectSafetyError(
      () => parseQaEnvironmentConfig(validConfig({ mongoUri: "mongodb://127.0.0.1:27040" })),
      "name the database explicitly"
    );
    expectSafetyError(
      () =>
        parseQaEnvironmentConfig(
          validConfig({ mongoUri: "mongodb://127.0.0.1:27040/commonplate_qa_beta" })
        ),
      "different database"
    );
    expectSafetyError(() => parseQaEnvironmentConfig(validConfig({ mongoUri: "" })));
    expectSafetyError(() => parseQaEnvironmentConfig(validConfig({ mongoUri: 3 })));
  });

  it("describes URI problems in terms of the config field, not MONGO_URI (F4)", () => {
    const messageFor = (mongoUri: string) => {
      try {
        parseQaEnvironmentConfig(validConfig({ mongoUri }));
      } catch (error) {
        return (error as Error).message;
      }
      throw new Error("expected refusal");
    };
    const unparsable = messageFor("mongodb://");
    const ambiguous = messageFor(
      "mongodb://127.0.0.1:27040/commonplate_qa_alpha?dbName=commonplate_qa_beta"
    );
    expect(unparsable).toBe("QA environment mongoUri could not be parsed safely.");
    expect(ambiguous).toBe(
      "QA environment mongoUri names two different databases; refusing an ambiguous target."
    );
    for (const message of [unparsable, ambiguous]) {
      expect(message).not.toContain("MONGO_URI");
      expect(message).not.toContain("27040");
    }
    // The shared seed:ui parser keeps its own wording, since MONGO_URI is its input.
    expect(() => assertLoopbackMongoTarget("mongodb://")).toThrow(
      "MONGO_URI could not be parsed safely."
    );
  });

  it("validates ports and keeps backend and mail sink apart", () => {
    for (const backendPort of [0, 80, 70000, 3000.5, "3000", null]) {
      expectSafetyError(() => parseQaEnvironmentConfig(validConfig({ backendPort })), "backendPort");
    }
    expectSafetyError(() => parseQaEnvironmentConfig(validConfig({ mailSinkPort: 22 })), "mailSinkPort");
    expectSafetyError(
      () => parseQaEnvironmentConfig(validConfig({ mailSinkPort: 3021 })),
      "must differ"
    );
  });

  it("never quotes a URI or credential in a refusal", () => {
    const secretUri = "mongodb://qa:hunter2@db.example.com:27017/commonplate_qa_alpha";
    try {
      parseQaEnvironmentConfig(validConfig({ mongoUri: secretUri }));
      throw new Error("expected refusal");
    } catch (error) {
      expect((error as Error).message).not.toContain("hunter2");
      expect((error as Error).message).not.toContain("mongodb://");
    }
  });

  it("gives two environments distinct, environment-specific targets", () => {
    const a = parseQaEnvironmentConfig(validConfig());
    const b = parseQaEnvironmentConfig(
      validConfig({
        slug: "beta",
        database: "commonplate_qa_beta",
        mongoUri: "mongodb://127.0.0.1:27040/commonplate_qa_beta?replicaSet=rs",
        backendPort: 3022,
        mailSinkPort: 8032,
      })
    );
    expect(a.database).not.toBe(b.database);
    expect(qaBackendBaseUrl(a)).toBe("http://127.0.0.1:3021");
    expect(qaBackendBaseUrl(b)).toBe("http://127.0.0.1:3022");
    // A config cannot be pointed at the other environment's database.
    expectSafetyError(() =>
      parseQaEnvironmentConfig({ ...a, database: b.database, mongoUri: b.mongoUri })
    );
  });
});

describe("W4-QA1 QA environment command gates (all fail before any connection)", () => {
  let directory: string;
  let configPath: string;

  beforeEach(() => {
    directory = mkdtempSync(path.join(tmpdir(), "qa1-env-"));
    configPath = path.join(directory, "alpha.json");
    writeFileSync(configPath, JSON.stringify(validConfig()));
  });

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  const optIn = () => ({ NODE_ENV: "test", ALLOW_LOCAL_SEED: "true", QA_ENV_FILE: configPath });

  async function expectRefusedWithoutConnecting(
    args: string[],
    environment: Record<string, string | undefined>,
    message?: string | RegExp
  ) {
    const connect = vi.spyOn(mongoose, "connect");
    const rejection = expect(runQaEnvironmentTool(args, environment)).rejects;
    await rejection.toThrow(SeedSafetyError);
    if (message) await expect(runQaEnvironmentTool(args, environment)).rejects.toThrow(message);
    expect(connect).not.toHaveBeenCalled();
  }

  it("requires an explicit environment file; MONGO_URI and .env are not inputs", async () => {
    await expectRefusedWithoutConnecting(
      ["reset"],
      {
        NODE_ENV: "test",
        ALLOW_LOCAL_SEED: "true",
        MONGO_URI: "mongodb://127.0.0.1:27040/commonplate_qa_alpha",
      },
      "QA_ENV_FILE is required"
    );
  });

  it("rejects an unreadable or malformed environment file", async () => {
    await expectRefusedWithoutConnecting(
      ["reset"],
      { ...optIn(), QA_ENV_FILE: path.join(directory, "missing.json") },
      "could not be read"
    );
    writeFileSync(configPath, "{ not json");
    await expectRefusedWithoutConnecting(["reset"], optIn(), "could not be read");
  });

  it("rejects an unsafe config before connecting", async () => {
    writeFileSync(
      configPath,
      JSON.stringify(validConfig({ mongoUri: "mongodb://prod.example.com/commonplate_qa_alpha" }))
    );
    await expectRefusedWithoutConnecting(["reset"], optIn(), /non-loopback/);
    writeFileSync(configPath, JSON.stringify(validConfig({ database: "commonplate" })));
    await expectRefusedWithoutConnecting(["reset"], optIn());
  });

  it("requires the local opt-in and refuses production mode for every mutating command", async () => {
    for (const args of [["init"], ["reset"], ["scenario", "clean"], ["drop", "--confirm-database", "commonplate_qa_alpha"]]) {
      await expectRefusedWithoutConnecting(args, { ...optIn(), ALLOW_LOCAL_SEED: undefined }, "ALLOW_LOCAL_SEED=true");
      await expectRefusedWithoutConnecting(args, { ...optIn(), ALLOW_LOCAL_SEED: "false" });
      await expectRefusedWithoutConnecting(args, { ...optIn(), NODE_ENV: "production" }, "NODE_ENV=production");
    }
  });

  it("rejects unknown commands and stray arguments, so reset can never be a drop", async () => {
    await expectRefusedWithoutConnecting([], optIn());
    await expectRefusedWithoutConnecting(["wipe"], optIn());
    await expectRefusedWithoutConnecting(["reset", "--confirm-database", "commonplate_qa_alpha"], optIn());
    await expectRefusedWithoutConnecting(["reset", "--drop"], optIn());
    await expectRefusedWithoutConnecting(["init", "x"], optIn());
    await expectRefusedWithoutConnecting(["status", "x"], optIn());
  });

  it("requires the exact database name as a typed confirmation for a full drop", async () => {
    for (const args of [
      ["drop"],
      ["drop", "--confirm-database"],
      ["drop", "--confirm-database", ""],
      ["drop", "--confirm-database", "alpha"],
      ["drop", "--confirm-database", "commonplate_qa_beta"],
      ["drop", "--confirm-database", "commonplate_qa_alpha", "extra"],
      ["drop", "--yes"],
    ]) {
      await expectRefusedWithoutConnecting(args, optIn(), "Full teardown requires");
    }
  });

  it("checks the drop confirmation as an exact match", () => {
    const config = parseQaEnvironmentConfig(validConfig());
    expect(() => assertDropConfirmation(config, config.database)).not.toThrow();
    expectSafetyError(() => assertDropConfirmation(config, `${config.database} `));
    expectSafetyError(() => assertDropConfirmation(config, undefined));
  });

  it("validates scenario presets and the requester before connecting", async () => {
    await expectRefusedWithoutConnecting(["scenario"], optIn(), "at least one preset");
    await expectRefusedWithoutConnecting(["scenario", "everything"], optIn(), "Unknown preset");
    await expectRefusedWithoutConnecting(["scenario", "__proto__"], optIn(), "Unknown preset");
    await expectRefusedWithoutConnecting(["scenario", "clean", "clean"], optIn(), "only once");
    await expectRefusedWithoutConnecting(
      ["scenario", "requester-below-quota", "requester-quota-boundary"],
      { ...optIn(), QA_REQUESTER_EMAIL: "r@nyu.edu" },
      "at most one requester-owned preset"
    );
    await expectRefusedWithoutConnecting(["scenario", "requester-quota-boundary"], optIn(), "QA_REQUESTER_EMAIL is required");
  });
});

describe("W4-QA1 scenario presets", () => {
  const now = new Date("2026-10-08T15:00:00.000Z");
  const requester = {
    email: "qa-requester@nyu.edu",
    participantId: new mongoose.Types.ObjectId(),
  };
  const all = Object.keys(SCENARIO_PRESETS) as ScenarioPresetName[];

  function documentsFor(name: ScenarioPresetName) {
    const { owned, unowned } = buildScenarioDocuments([name], requester, now);
    return { owned, unowned, all: [...owned, ...unowned] };
  }

  it("builds only documents the current Request schema accepts", () => {
    const vendors = new Set(
      (JSON.parse(
        // Same shared catalog the product validates against.
        readFileSync(path.join(repoRoot, "shared", "vendors.json"), "utf8")
      ) as Array<{ name: string }>).map((vendor) => vendor.name)
    );
    for (const name of all) {
      for (const document of documentsFor(name).all) {
        expect(new MealRequest(document).validateSync()).toBeUndefined();
        expect(vendors.has(document.vendor)).toBe(true);
        expect(document.food).toBe(
          deriveFoodSummary({
            menuPath: document.menuPath,
            mealSwipes: document.mealSwipes,
            mealItems: document.mealItems,
            orderDetails: (document as { orderDetails?: string }).orderDetails,
            estimatedDiningDollarsCents: (document as { estimatedDiningDollarsCents?: number })
              .estimatedDiningDollarsCents,
          } as never)
        );
        if (document.menuPath === "meal-exchange") {
          expect(document.mealItems).toHaveLength(document.mealSwipes);
          expect(document.mealItems.every((item: { name: string }) => item.name.length > 0)).toBe(true);
        } else {
          expect(document.mealSwipes).toBe(0);
          expect(document.mealItems).toEqual([]);
          expect(document.estimatedDiningDollarsCents).toBeGreaterThan(0);
        }
        expect(document.expiresAt.getTime()).toBe(document.visibleFrom.getTime() + 3 * 60 * 60 * 1000);
      }
    }
  });

  it("fabricates no unaccepted lifecycle state", () => {
    for (const name of all) {
      for (const document of documentsFor(name).all as Array<Record<string, unknown>>) {
        expect(document.status).toBe("open");
        for (const field of [
          "claimedAt",
          "claimExpiresAt",
          "claimTokenDigest",
          "helperParticipantId",
          "orderNumber",
          "placedAt",
          "fulfillerEmail",
          "installationId",
        ]) {
          expect(document[field]).toBeUndefined();
        }
      }
    }
  });

  it("lists exactly the documented catalog, with clean inserting nothing", () => {
    expect(all.sort()).toEqual(
      ["clean", "future-later", "helper-board", "requester-below-quota", "requester-quota-boundary"].sort()
    );
    expect(documentsFor("clean").all).toHaveLength(0);
  });

  it("helper-board is entirely helper-visible and covers each accepted shape", () => {
    const { unowned } = documentsFor("helper-board");
    expect(unowned).toHaveLength(5);
    for (const document of unowned) {
      expect(isEffectivelyAvailable(document, now)).toBe(true);
      expect(document.requesterParticipantId).toBeNull();
      expect(document.email).toMatch(/^commonplate-ui-seed-needs-help-\d+@example\.invalid$/);
    }
    expect(unowned.some((d) => d.pickupWindowText === "ASAP")).toBe(true);
    expect(unowned.some((d) => d.windowStart && d.windowStart <= now)).toBe(true);
    expect(unowned.some((d) => d.menuPath === "dining-dollars")).toBe(true);
    expect(unowned.some((d) => d.estimatedDiningDollarsCents && d.menuPath === "meal-exchange")).toBe(true);
  });

  it("future-later stays helper-invisible before visibleFrom and becomes visible at it", () => {
    const { unowned } = documentsFor("future-later");
    expect(unowned).toHaveLength(1);
    const [document] = unowned;
    expect(document!.visibleFrom.getTime()).toBeGreaterThan(now.getTime());
    expect(isVisibleNow(document!.visibleFrom, now)).toBe(false);
    expect(isEffectivelyAvailable(document!, now)).toBe(false);
    expect(isVisibleNow(document!.visibleFrom, document!.visibleFrom)).toBe(true);
    expect(document!.helperNotification).toBe("awaiting-eligibility");
  });

  it("requester-owned presets are counted by the real daily-quota filter and shape", () => {
    const campusDayStart = startOfCampusDay(now);
    for (const [name, expectedCount] of [
      ["requester-below-quota", 1],
      ["requester-quota-boundary", 2],
    ] as const) {
      const { owned, unowned } = documentsFor(name);
      expect(unowned).toHaveLength(0);
      expect(owned).toHaveLength(expectedCount);
      // Exactly what `countTodaysRequests` selects on: the principal address and
      // a creation instant inside the current campus day.
      const counted = owned.filter(
        (document) => document.email === requester.email && document.createdAt >= campusDayStart
      );
      expect(counted).toHaveLength(expectedCount);
      expect(owned.every((d) => String(d.requesterParticipantId) === String(requester.participantId))).toBe(true);
      expect(isUnderDailyLimit(counted.length)).toBe(true);
      // The next real submission is the (count + 1)th; at the boundary preset it is the 3rd.
      expect(isUnderDailyLimit(counted.length + 1)).toBe(name === "requester-below-quota");
    }
  });

  it("a requester-owned preset without a verified requester is refused", () => {
    expectSafetyError(() => buildScenarioDocuments(["requester-quota-boundary"], null, now));
  });

  it("parses preset lists strictly", () => {
    expect(parseScenarioPresets(["helper-board", "future-later"])).toEqual(["helper-board", "future-later"]);
    expect(parseScenarioPresets(["helper-board", "requester-quota-boundary"])).toHaveLength(2);
  });
});

describe("W4-QA1 reset ownership table", () => {
  it("classifies every schema path that references a Request", () => {
    const discovered = new Set<string>();
    for (const name of mongoose.modelNames()) {
      mongoose.model(name).schema.eachPath((schemaPath, type) => {
        const options = type.options as { ref?: unknown; type?: unknown } | undefined;
        const caster = (type as { caster?: { options?: { ref?: unknown } } }).caster;
        if (options?.ref === "Request" || caster?.options?.ref === "Request") {
          discovered.add(`${name}.${schemaPath}`);
        }
      });
    }
    // A new request-scoped model must be added to REQUEST_REFERENCE_HANDLING on
    // purpose: deleted with its Request, lock-cleared, or explicitly preserved.
    // Until then this fails.
    expect([...discovered].sort()).toEqual(Object.keys(REQUEST_REFERENCE_HANDLING).sort());
  });

  it("preserves the D1/D2 operation ledger and deletes PlacementEvidence with its Request", () => {
    expect(REQUEST_REFERENCE_HANDLING["RequestOperation.requestId"]).toBe("preserve");
    expect(mongoose.modelNames()).toContain("PlacementEvidence");
    expect(REQUEST_REFERENCE_HANDLING["PlacementEvidence.requestId"]).toBe("delete");
  });
});

describe("W4-QA1 QA environment CLI isolation", () => {
  it("does not load a working-directory .env or MONGO_URI, and prints nothing sensitive", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "qa1-env-cli-"));
    try {
      writeFileSync(
        path.join(directory, ".env"),
        "MONGO_URI=mongodb://qa:hunter2@127.0.0.1:1/commonplate_qa_alpha\nALLOW_LOCAL_SEED=true\nQA_ENV_FILE=\n"
      );
      const result = spawnSync(
        path.join(repoRoot, "node_modules", ".bin", "tsx"),
        [path.join(repoRoot, "scripts", "qa-environment.ts"), "reset"],
        { cwd: directory, encoding: "utf8", env: { PATH: process.env.PATH } }
      );
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("QA_ENV_FILE is required");
      expect(`${result.stdout}${result.stderr}`).not.toContain("hunter2");
      expect(`${result.stdout}${result.stderr}`).not.toContain("mongodb://");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
