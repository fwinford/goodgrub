import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  ATLAS_ONLY_REQUIREMENTS,
  PROBE_OPT_IN_ENV,
  assertDisposableTarget,
  assertIsolatedLocalServer,
  checkRoleDefinition,
  formatProbeReport,
  loadRoleDefinition,
  localPrivilegesFor,
  poolConfigurationChecks,
  redactProbeText,
  safeErrorSummary,
} from "./atlas-qualification-probe.js";
import {
  DORMANT_MESSAGING_MODELS,
  MODEL_REGISTRATION_FILES,
  compareIndexes,
  discoverModels,
  expectedIndexes,
  findModelRegistrationFiles,
  messagingIsWiredIntoApp,
} from "./atlas-qualification-probe-indexes.js";

const OPT_IN = { [PROBE_OPT_IN_ENV]: "1" };
const GOOD_URI = "mongodb://u:p@127.0.0.1:27017/?replicaSet=rs0";
const GOOD_DB = "cp_atlas_probe_abc123";

describe("assertDisposableTarget", () => {
  it("accepts a loopback replica set and disposable database with opt-in", () => {
    expect(assertDisposableTarget(GOOD_URI, GOOD_DB, OPT_IN).hosts).toEqual(["127.0.0.1"]);
    expect(
      assertDisposableTarget("mongodb://u:p@127.0.0.1:1/admin?replicaSet=rs0&authSource=admin", GOOD_DB, OPT_IN).hosts
    ).toEqual(["127.0.0.1"]);
  });

  it.each([
    ["no opt-in", GOOD_URI, GOOD_DB, {}],
    ["production database", GOOD_URI, "commonplate_production", OPT_IN],
    ["review database", GOOD_URI, "commonplate_review", OPT_IN],
    ["atlas srv", "mongodb+srv://u:p@cluster0.abc.mongodb.net/?replicaSet=rs0", GOOD_DB, OPT_IN],
    ["atlas host", "mongodb://u:p@cluster0-shard-00-00.abc.mongodb.net:27017/?replicaSet=rs0", GOOD_DB, OPT_IN],
    ["mixed hosts", "mongodb://127.0.0.1:1,db.example.com:2/?replicaSet=rs0", GOOD_DB, OPT_IN],
    ["host smuggled in credentials", "mongodb://127.0.0.1@db.example.com:27017/?replicaSet=rs0", GOOD_DB, OPT_IN],
    ["standalone", "mongodb://127.0.0.1:27017/", GOOD_DB, OPT_IN],
    ["opt-in not exactly 1", GOOD_URI, GOOD_DB, { [PROBE_OPT_IN_ENV]: "true" }],
    ["database path traversal", GOOD_URI, "cp_atlas_probe_../x", OPT_IN],
    ["tunnel with tls", "mongodb://u:p@127.0.0.1:27018/?replicaSet=atlas-xyz&tls=true", GOOD_DB, OPT_IN],
    ["tunnel with ssl", "mongodb://u:p@127.0.0.1:27018/?replicaSet=atlas-xyz&ssl=true", GOOD_DB, OPT_IN],
    ["proxy option", "mongodb://127.0.0.1:1/?replicaSet=rs0&proxyHost=10.0.0.1", GOOD_DB, OPT_IN],
    ["x509 auth", "mongodb://127.0.0.1:1/?replicaSet=rs0&authMechanism=MONGODB-X509", GOOD_DB, OPT_IN],
    ["tls casing", "mongodb://127.0.0.1:1/?replicaSet=rs0&TLS=True", GOOD_DB, OPT_IN],
  ])("refuses %s", (_label, uri, database, environment) => {
    expect(() => assertDisposableTarget(uri, database, environment)).toThrow(/Refusing to run/);
  });

  it("never echoes the URI or credentials in its refusal", () => {
    try {
      assertDisposableTarget("mongodb://admin:hunter2@db.example.com/?replicaSet=rs0", GOOD_DB, OPT_IN);
    } catch (error) {
      expect(String((error as Error).message)).not.toMatch(/hunter2|db\.example\.com/);
      return;
    }
    throw new Error("expected refusal");
  });
});

describe("assertIsolatedLocalServer (loopback tunnel defense)", () => {
  const directory = mkdtempSync(path.join(tmpdir(), "cp-atlas-probe-unit-"));
  const runner = (overrides: Record<string, unknown>) => ({
    async command(command: Record<string, unknown>) {
      const name = Object.keys(command)[0] as string;
      const value = overrides[name];
      if (value instanceof Error) throw value;
      return value;
    },
  });
  const healthy = {
    hello: { setName: "cpProbeReplica", hosts: ["127.0.0.1:27018"], me: "127.0.0.1:27018" },
    getCmdLineOpts: { parsed: { storage: { dbPath: directory } } },
    listDatabases: { databases: [{ name: "admin" }, { name: "config" }, { name: "local" }] },
  };

  it("accepts only the server that reports the harness directory", async () => {
    await expect(assertIsolatedLocalServer(runner(healthy), directory)).resolves.toBeUndefined();
    rmSync(directory, { recursive: true, force: true });
  });

  it.each([
    ["remote replica-set members behind a loopback tunnel", { hello: { setName: "atlas-abc", hosts: ["cluster0-shard-00-00.abc.mongodb.net:27017"] } }],
    ["a standalone server", { hello: { hosts: [], me: "127.0.0.1:27018" } }],
    ["Atlas denying getCmdLineOpts", { getCmdLineOpts: Object.assign(new Error("not authorized"), { code: 13 }) }],
    ["a different data directory", { getCmdLineOpts: { parsed: { storage: { dbPath: "/data/db" } } } }],
    ["a non-empty server", { listDatabases: { databases: [{ name: "admin" }, { name: "commonplate_production" }] } }],
  ])("refuses %s", async (_label, overrides) => {
    const dir = mkdtempSync(path.join(tmpdir(), "cp-atlas-probe-unit-"));
    try {
      await expect(
        assertIsolatedLocalServer(runner({ ...healthy, getCmdLineOpts: { parsed: { storage: { dbPath: dir } } }, ...overrides }), dir)
      ).rejects.toThrow(/Refusing to run/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("safe failure reporting", () => {
  it("redacts connection strings and secrets", () => {
    const text = redactProbeText("failed mongodb+srv://u:hunter2@c.mongodb.net/db password=abc123 token: xyz");
    expect(text).not.toMatch(/hunter2|abc123|xyz|c\.mongodb\.net/);
  });

  it("summarizes errors without raw URIs", () => {
    const error = Object.assign(new Error("bad auth for mongodb://u:hunter2@127.0.0.1:1/x"), { code: 18 });
    const summary = safeErrorSummary(error);
    expect(summary).toContain("code=18");
    expect(summary).not.toContain("hunter2");
  });

  it("always lists what only Atlas can prove", () => {
    const text = formatProbeReport({ ok: true, results: [], atlasOnly: ATLAS_ONLY_REQUIREMENTS });
    expect(text).toContain("NOT VERIFIED (requires the real Atlas cluster)");
    expect(text).toContain("LOCAL DISPOSABLE REPLICA SET ONLY");
  });
});

describe("role definitions", () => {
  const production = loadRoleDefinition("deploy/atlas/runtime-role.json");
  const review = loadRoleDefinition("deploy/atlas/review-runtime-role.json");

  it("accepts the committed runtime and review roles", () => {
    expect(checkRoleDefinition(production, "commonplate_production").status).toBe("pass");
    expect(checkRoleDefinition(review, "commonplate_review").status).toBe("pass");
    expect(checkRoleDefinition(review, "commonplate_production").status).toBe("fail");
  });

  it("rejects extra actions, other databases and inherited roles", () => {
    const widened = structuredClone(production);
    widened.actions.push({ action: "DROP_DATABASE", resources: [{ db: "commonplate_production", collection: "" }] });
    widened.actions[0]!.resources[0]!.db = "admin";
    widened.inheritedRoles.push({ role: "atlasAdmin" });
    const result = checkRoleDefinition(widened, "commonplate_production");
    expect(result.status).toBe("fail");
    expect(result.detail).toMatch(/DROP_DATABASE/);
    expect(result.detail).toMatch(/inherited/);
  });

  it("maps every action onto the requested database only", () => {
    const privileges = localPrivilegesFor(production, GOOD_DB);
    expect(privileges).toHaveLength(7);
    expect(privileges.every((entry) => entry.resource.db === GOOD_DB)).toBe(true);
  });
});

describe("pool configuration checks", () => {
  it("passes against the committed options and the driver's adopted values", () => {
    const results = poolConfigurationChecks();
    expect(results.map((entry) => entry.name)).toEqual(["pool configuration", "pool bounds rejected"]);
    expect(results.every((entry) => entry.status === "pass")).toBe(true);
  });
});

describe("index inventory", () => {
  it("discovers production and dormant models from the schema modules", async () => {
    const { production, dormantMessaging } = await discoverModels();
    const names = production.map((model) => model.modelName);
    expect(names).toEqual(expect.arrayContaining(["Request", "Fulfillment", "Participant", "ParticipantBlock", "RequestOperationAuthority"]));
    expect(names.some((name) => DORMANT_MESSAGING_MODELS.includes(name))).toBe(false);
    expect(dormantMessaging.map((model) => model.modelName).sort()).toEqual([...DORMANT_MESSAGING_MODELS].sort());
  });

  it("knows every source file that registers a Mongoose model", () => {
    expect(findModelRegistrationFiles(process.cwd())).toEqual(Object.keys(MODEL_REGISTRATION_FILES).sort());
  });

  it("keeps the dormant-messaging exclusion honest", () => {
    expect(messagingIsWiredIntoApp(process.cwd())).toBe(false);
  });

  it("extracts names, TTL and partial filters from schemas", async () => {
    const { production, dormantMessaging } = await discoverModels();
    const all = [...production, ...dormantMessaging].flatMap((model) => expectedIndexes(model));
    expect(all.some((entry) => entry.expireAfterSeconds !== undefined)).toBe(true);
    expect(all.some((entry) => entry.partialFilterExpression !== undefined)).toBe(true);
    expect(all.some((entry) => entry.name === "conversation_relationship_unique" && entry.unique)).toBe(true);
  });
});

describe("compareIndexes detects drift", () => {
  const expected = [
    { name: "a_1", key: [["a", 1]] as [string, unknown][], unique: true, sparse: false, expireAfterSeconds: 60, partialFilterExpression: { s: { $in: ["x"] } } },
  ];
  const exact = [{ name: "_id_", key: { _id: 1 } }, { name: "a_1", key: { a: 1 }, unique: true, expireAfterSeconds: 60, partialFilterExpression: { s: { $in: ["x"] } } }];

  it("passes an exact match", () => {
    expect(compareIndexes("M", expected, exact)).toEqual([]);
  });

  it.each([
    ["missing", [{ name: "_id_", key: { _id: 1 } }], /missing index/],
    ["key", [{ ...exact[1]!, key: { b: 1 } }], /key differs/],
    ["uniqueness", [{ ...exact[1]!, unique: false }], /unique differs/],
    ["TTL", [{ ...exact[1]!, expireAfterSeconds: 61 }], /TTL differs/],
    ["partial filter", [{ ...exact[1]!, partialFilterExpression: { s: "x" } }], /partial filter differs/],
    ["name", [{ ...exact[1]!, name: "renamed" }], /missing index a_1/],
    ["extra index", [...exact, { name: "z_1", key: { z: 1 } }], /unexpected index z_1/],
  ])("flags %s", (_label, actual, pattern) => {
    expect(compareIndexes("M", expected, actual as never).join(";")).toMatch(pattern);
  });
});
