// W5-INF1: real Atlas Flex qualification tool. Dev/test tooling only.
//
// NOT the local probe and shares none of its destructive code. It refuses any
// target that is not the pinned Atlas cluster (see the guards module).
//
//   check-target <qual|runtime|review>   parse/validate the URI env var only; never connects
//   print-qual-role <yyyymmdd>           print the temporary Atlas custom-role definition
//   qual                                  writes ONLY as goodgrub_qual inside cpq_qual_<date>
//   runtime | review                      real users: read-only and denial probes, no writes
//
// Credentials arrive only through the stage's URI environment variable (filled by a
// hidden prompt), never argv, and are never printed. Writes need the exact
// confirmation string in ATLAS_REAL_QUAL_CONFIRM and Faith's separate authorization.
import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { randomBytes } from "node:crypto";
import mongoose from "mongoose";
import { MAX_POOL_SIZE_CEILING, PRODUCTION_MAX_POOL_SIZE, mongoConnectionOptions } from "../src/mongoConnectionOptions.js";
import {
  CONFIRM_ENV,
  EXPECTED_CLUSTER,
  RealQualSafetyError,
  STAGES,
  VANTAGE_ENV,
  assertAtlasTarget,
  classifyAttempt,
  evaluateSession,
  expectedActions,
  formatReport,
  qualDatabaseNames,
  qualRoleDefinition,
  summarizeError,
  summarizeLatency,
  type AtlasTarget,
  type CheckResult,
  type RoleDefinition,
  type Stage,
} from "./atlas-real-qualification-guards.js";
import { discoverModels, verifyProductionIndexes, messagingIsWiredIntoApp } from "./atlas-qualification-probe-indexes.js";

type MongoClient = InstanceType<typeof mongoose.mongo.MongoClient>;

// Proposed (not yet accepted by Faith) round-trip thresholds from the runbook.
const LATENCY_MEDIAN_MS = 60;
const LATENCY_P95_MS = 150;

export interface StageInput {
  stage: Stage;
  uri: string;
  environment: NodeJS.ProcessEnv;
  repositoryRoot: string;
  /** Test seam: defaults to the real driver. Guards run before it is ever called. */
  createClient?: (uri: string, options: Record<string, unknown>) => MongoClient;
}

async function check(name: string, run: () => Promise<{ status?: CheckResult["status"]; detail: string }>): Promise<CheckResult> {
  try {
    const outcome = await run();
    return { name, status: outcome.status ?? "pass", detail: outcome.detail };
  } catch (error) {
    return { name, status: "fail", detail: summarizeError(error) };
  }
}

/** Runs an operation that must be denied; records one problem string per unexpected outcome. */
async function mustBeDenied(label: string, operation: () => Promise<unknown>, problems: string[], inconclusive: string[]) {
  let thrown: unknown;
  try {
    await operation();
  } catch (error) {
    thrown = error ?? new Error("unknown");
  }
  const outcome = classifyAttempt(thrown);
  if (outcome === "authorized") problems.push(`${label} was NOT denied`);
  else if (outcome === "inconclusive") inconclusive.push(`${label}: ${summarizeError(thrown)}`);
}

/**
 * The qualification role has no LIST_COLLECTIONS action (and GoodGrub's runtime does not use one).
 * MongoDB's names-only, authorized listing returns the collections the user can already access.
 */
async function authorizedCollectionNames(db: ReturnType<MongoClient["db"]>): Promise<string[]> {
  const found = await db.listCollections({}, { nameOnly: true, authorizedCollections: true }).toArray();
  return found.map((entry) => entry.name);
}

const ONLY_ENV = "ATLAS_QUAL_ONLY";
const QUAL_GROUPS = ["allowed", "transactions", "indexes", "denials", "rename", "pool", "failfast"];

/** Optional targeted re-run of named check groups; unknown names are refused rather than ignored. */
export function parseOnly(value: string | undefined): Set<string> | null {
  if (!value) return null;
  const groups = value.split(",").map((entry) => entry.trim());
  const unknown = groups.filter((entry) => !QUAL_GROUPS.includes(entry));
  if (unknown.length > 0) throw new RealQualSafetyError(`${ONLY_ENV} has unknown groups: ${unknown.join(",")}. Allowed: ${QUAL_GROUPS.join(",")}.`);
  return new Set(groups);
}

function describeAttempt(thrown: unknown): string {
  if (thrown === undefined) return "the command succeeded";
  const { code, codeName } = thrown as { code?: number; codeName?: string };
  return `code ${code ?? "none"}${codeName ? ` ${codeName}` : ""}: ${summarizeError(thrown)}`;
}

async function attempt(operation: () => Promise<unknown>): Promise<{ outcome: ReturnType<typeof classifyAttempt>; thrown: unknown }> {
  try {
    await operation();
    return { outcome: "authorized", thrown: undefined };
  } catch (error) {
    return { outcome: classifyAttempt(error), thrown: error ?? new Error("unknown") };
  }
}

/** A per-run name is only used for destructive denial probes after the server proves it does not exist. */
async function proveAbsent(db: ReturnType<MongoClient["db"]>, name: string): Promise<void> {
  try {
    await db.collection(name).listIndexes().toArray();
  } catch (error) {
    if ((error as { code?: number }).code === 26) return;
    throw new RealQualSafetyError(`could not prove ${name} is absent (${summarizeError(error)}); no destructive probe was sent.`);
  }
  throw new RealQualSafetyError(`${name} unexpectedly exists; no destructive probe was sent.`);
}

/** listDatabases may be refused (13) or filtered to authorized databases; either is fine, exposure is not. */
async function checkListDatabases(client: MongoClient, own: string, problems: string[], inconclusive: string[]) {
  try {
    const reply = (await client.db("admin").command({ listDatabases: 1, nameOnly: true })) as { databases?: { name: string }[] };
    const exposed = (reply.databases ?? []).map((entry) => entry.name).filter((name) => name !== own);
    if (exposed.length > 0) problems.push(`listDatabases exposed: ${exposed.join(",")}`);
  } catch (error) {
    if (classifyAttempt(error) === "inconclusive") inconclusive.push(`listDatabases: ${summarizeError(error)}`);
  }
}

function newAbsentName(): string {
  return `cpq_absent_${randomBytes(6).toString("hex")}`;
}

function poolConfigurationResult(): CheckResult {
  const prod = mongoConnectionOptions({});
  const review = mongoConnectionOptions({ NODE_ENV: "review" });
  const bad = [
    { MONGO_MAX_POOL_SIZE: "0" },
    { MONGO_MAX_POOL_SIZE: String(MAX_POOL_SIZE_CEILING + 1) },
    { MONGO_WAIT_QUEUE_TIMEOUT_MS: "99" },
  ].filter((environment) => mongoConnectionOptions(environment).ok);
  const ok =
    prod.ok && prod.options.maxPoolSize === PRODUCTION_MAX_POOL_SIZE && prod.options.waitQueueTimeoutMS === 5000 &&
    review.ok && review.options.maxPoolSize === 5 && bad.length === 0;
  return {
    name: "pool configuration (static)",
    status: ok ? "pass" : "fail",
    detail: ok ? "production 20, review 5, wait queue 5000 ms; out-of-range values refused" : "configuration differs from the accepted pool bounds",
  };
}

async function latencyResult(client: MongoClient, environment: NodeJS.ProcessEnv): Promise<CheckResult> {
  const admin = client.db("admin");
  await admin.command({ ping: 1 });
  const samples: number[] = [];
  for (let index = 0; index < 20; index += 1) {
    const started = process.hrtime.bigint();
    await admin.command({ ping: 1 });
    samples.push(Number(process.hrtime.bigint() - started) / 1e6);
  }
  const summary = summarizeLatency(samples);
  const detail = `ping round trips over the driver: median ${summary.medianMs.toFixed(1)} ms, p95 ${summary.p95Ms.toFixed(1)} ms (n=${summary.samples})`;
  if (environment[VANTAGE_ENV] !== "lightsail") {
    return { name: "cross-region latency", status: "informational", detail: `${detail}; not run from Lightsail, so not representative (set ${VANTAGE_ENV}=lightsail there)` };
  }
  const withinProposal = summary.medianMs <= LATENCY_MEDIAN_MS && summary.p95Ms <= LATENCY_P95_MS;
  return {
    name: "cross-region latency",
    status: withinProposal ? "pass" : "fail",
    detail: `${detail}; proposed thresholds median <= ${LATENCY_MEDIAN_MS} ms, p95 <= ${LATENCY_P95_MS} ms (pending Faith's acceptance)`,
  };
}

async function sessionGate(client: MongoClient, stage: Stage, database: string): Promise<void> {
  const admin = client.db("admin");
  const status = await admin.command({ connectionStatus: 1, showPrivileges: true });
  const hello = await admin.command({ hello: 1 });
  const problems = evaluateSession(status, hello, { stage, database, actions: expectedActions(stage) });
  if (problems.length > 0) {
    throw new RealQualSafetyError(`session gate failed before any operation: ${problems.join("; ")}`);
  }
}

async function qualificationChecks(
  client: MongoClient,
  uri: string,
  target: AtlasTarget,
  input: StageInput,
  arm: () => void
): Promise<CheckResult[]> {
  const results: CheckResult[] = [];
  const names = qualDatabaseNames(target.database.slice("cpq_qual_".length));
  const absent = newAbsentName();
  const only = parseOnly(input.environment[ONLY_ENV]);
  const runs = (group: string) => only === null || only.has(group);
  const db = client.db(target.database);
  const existing = await authorizedCollectionNames(db);
  if (existing.length > 0) throw new RealQualSafetyError("the qualification database is not empty; refusing to reuse it.");
  arm(); // only now may cleanup drop collections: they are this run's own

  if (runs("allowed")) results.push(
    await check("allowed actions", async () => {
      await db.createCollection("probe_items");
      const items = db.collection("probe_items");
      await items.createIndex({ key: 1 }, { unique: true });
      await items.insertOne({ key: "a", n: 1 });
      await items.updateOne({ key: "a" }, { $set: { n: 2 } });
      if ((await items.findOne({ key: "a" }))?.n !== 2) throw new Error("find/update did not round-trip");
      await items.listIndexes().toArray();
      await items.deleteOne({ key: "a" });
      return { detail: "createCollection, createIndex, insert, update, find, listIndexes, remove permitted" };
    })
  );

  if (runs("transactions")) results.push(
    await check("transactions: commit, abort, duplicate-key 11000 rollback", async () => {
      await db.createCollection("probe_tx");
      const items = db.collection("probe_tx");
      await items.createIndex({ key: 1 }, { unique: true });
      const session = client.startSession();
      try {
        const started = process.hrtime.bigint();
        await session.withTransaction(async () => {
          await items.insertOne({ key: "committed" }, { session });
        });
        const commitMs = Number(process.hrtime.bigint() - started) / 1e6;
        if (!(await items.findOne({ key: "committed" }))) throw new Error("committed write is missing");
        session.startTransaction();
        await items.insertOne({ key: "aborted" }, { session });
        if (await items.findOne({ key: "aborted" })) throw new Error("uncommitted write visible outside the transaction");
        await session.abortTransaction();
        if (await items.findOne({ key: "aborted" })) throw new Error("aborted write persisted");
        let code: unknown;
        try {
          await session.withTransaction(async () => {
            await items.insertOne({ key: "second" }, { session });
            await items.insertOne({ key: "committed" }, { session });
          });
        } catch (error) {
          code = (error as { code?: unknown }).code;
        }
        if (code !== 11000) throw new Error(`expected duplicate-key error 11000, got ${String(code)}`);
        if (await items.findOne({ key: "second" })) throw new Error("failed transaction left a partial write");
        return { detail: `commit persisted (${commitMs.toFixed(0)} ms incl. one insert round trip); abort and duplicate-key rollback left no writes` };
      } finally {
        await session.endSession();
      }
    })
  );

  if (runs("indexes")) results.push(
    await check("indexes through the application's Mongoose createIndexes()", async () => {
      if (messagingIsWiredIntoApp(input.repositoryRoot)) throw new Error("app.ts now imports models/messaging: update the inventory");
      const models = await discoverModels();
      const connection = await mongoose.createConnection(uri, { dbName: target.database, maxPoolSize: 2 }).asPromise();
      try {
        await sessionGate(connection.getClient() as unknown as MongoClient, "qual", target.database);
        const production = await verifyProductionIndexes(connection, models.production);
        const dormant = await verifyProductionIndexes(connection, models.dormantMessaging);
        const problems = [...production.problems, ...dormant.problems];
        if (problems.length > 0) throw new Error(problems.join("; "));
        return {
          detail: `${production.models} production models / ${production.indexes} indexes and ${dormant.models} dormant messaging models / ${dormant.indexes} indexes match keys, uniqueness, names, sparse, TTL and partial filters`,
        };
      } finally {
        await connection.close().catch(() => undefined);
      }
    })
  );

  if (runs("denials")) results.push(
    await check("expected denials", async () => {
      const problems: string[] = [];
      const inconclusive: string[] = [];
      let dropEvidence = "";
      // A dedicated fixture with a real secondary index, so each result is checked against server state.
      await db.createCollection("probe_denials");
      const fixture = db.collection("probe_denials");
      await fixture.createIndex({ key: 1 }, { unique: true, name: "key_1" });
      await fixture.insertOne({ key: "keep" });
      const indexNames = async () => (await fixture.listIndexes().toArray()).map((index) => index.name).sort().join(",");
      const before = await indexNames();
      // Collection.dropIndexes() in driver 6.20 swallows every server error and returns false, so it cannot
      // distinguish "denied" from "succeeded"; send the raw command and inspect the actual reply.
      let reply: Record<string, unknown> | undefined;
      const dropped = await attempt(async () => {
        reply = (await db.command({ dropIndexes: "probe_denials", index: "key_1" })) as Record<string, unknown>;
      });
      const afterDrop = await indexNames();
      dropEvidence = `dropIndexes {namespace ${target.database}.probe_denials, index key_1}: indexes ${before} -> ${afterDrop}; ` +
        (reply ? `reply ok=${String(reply.ok)} nIndexesWas=${String(reply.nIndexesWas)}` : `error ${describeAttempt(dropped.thrown)}`);
      if (dropped.outcome === "denied" && afterDrop === before) {
        // denied and the index is still present
      } else if (dropped.outcome === "inconclusive" && afterDrop === before) {
        inconclusive.push(`dropIndexes: ${describeAttempt(dropped.thrown)}`);
      } else {
        problems.push(`dropIndexes was NOT denied (${dropEvidence})`);
      }
      const items = db.collection("probe_items");
      await mustBeDenied("dropDatabase", () => db.dropDatabase(), problems, inconclusive);
      await mustBeDenied("collMod", () => db.command({ collMod: "probe_denials", validator: {} }), problems, inconclusive);
      await mustBeDenied("write to another disposable database", () => client.db(names.denied).collection("x").insertOne({ a: 1 }), problems, inconclusive);
      await mustBeDenied("read commonplate_production", () => client.db("commonplate_production").collection(absent).findOne({}), problems, inconclusive);
      await mustBeDenied("read commonplate_review", () => client.db("commonplate_review").collection(absent).findOne({}), problems, inconclusive);
      await mustBeDenied("read admin.system.users", () => client.db("admin").collection("system.users").findOne({}), problems, inconclusive);
      await mustBeDenied("createUser", () => client.db("admin").command({ createUser: "cpq_denied_user", pwd: `${Math.random()}`, roles: [] }), problems, inconclusive);
      await checkListDatabases(client, target.database, problems, inconclusive);
      if (problems.length > 0) throw new Error(problems.join("; "));
      return {
        status: inconclusive.length > 0 ? "informational" : "pass",
        detail: inconclusive.length > 0 ? `no unexpected success; inconclusive: ${inconclusive.join(" | ")}` : `every probed operation was denied with Unauthorized (listDatabases refused or limited to the qualification database). Evidence: ${dropEvidence}`,
      };
    })
  );

  if (runs("rename")) results.push(
    await check("renameCollection with the granted find/dropCollection/createCollection/createIndex/insert", async () => {
      await db.createCollection("probe_rename_src");
      await db.collection("probe_rename_src").insertOne({ key: "r" });
      const renamed = await attempt(() => client.db("admin").command({ renameCollection: `${target.database}.probe_rename_src`, to: `${target.database}.probe_rename_dst` }));
      const names = await authorizedCollectionNames(db);
      const moved = names.includes("probe_rename_dst") && !names.includes("probe_rename_src");
      if (renamed.outcome === "authorized" && moved) {
        return {
          status: "informational",
          detail: "PERMITTED, state verified (source gone, target present). Not a denial: MongoDB authorizes a same-database rename from find+dropCollection on the source and createCollection+createIndex+insert on the target, all of which this temporary role holds, so RENAME_COLLECTION_SAME_DB is not needed. The permanent runtime role lacks DROP_COLLECTION; its rename denial is proven by the runtime/review stages.",
        };
      }
      if (renamed.outcome === "denied" && !moved && names.includes("probe_rename_src")) return { detail: "denied and the source collection is unchanged" };
      throw new Error(`unexpected rename result (${describeAttempt(renamed.thrown)}); collections: ${names.join(",")}`);
    })
  );

  results.push(poolConfigurationResult());
  if (runs("pool")) results.push(
    await check("production pool options under a 100-operation burst", async () => {
      const probe = (input.createClient ?? ((u, o) => new mongoose.mongo.MongoClient(u, o)))(uri, {
        maxPoolSize: PRODUCTION_MAX_POOL_SIZE,
        minPoolSize: 0,
        waitQueueTimeoutMS: 5000,
      });
      try {
        await sessionGate(probe, "qual", target.database);
        const items = probe.db(target.database).collection("probe_items");
        const times: number[] = [];
        const outcomes = await Promise.allSettled(
          Array.from({ length: 100 }, async () => {
            const started = process.hrtime.bigint();
            await items.findOne({});
            times.push(Number(process.hrtime.bigint() - started) / 1e6);
          })
        );
        const failed = outcomes.filter((outcome) => outcome.status === "rejected").length;
        if (failed > 0) throw new Error(`${failed} of 100 operations failed under the production pool`);
        const summary = summarizeLatency(times);
        return { detail: `100 concurrent finds succeeded on pool 20/5000 ms; per-operation median ${summary.medianMs.toFixed(0)} ms, p95 ${summary.p95Ms.toFixed(0)} ms. Read connection counts and ops/s in the Atlas console.` };
      } finally {
        await probe.close().catch(() => undefined);
      }
    })
  );
  if (runs("failfast")) results.push(
    await check("pool checkout deadline is enforced (1 connection, deadline below one round trip)", async () => {
      const make = input.createClient ?? ((u, o) => new mongoose.mongo.MongoClient(u, o));
      // The deadline is derived from the measured round trip so the second concurrent operation must wait longer than it.
      const meter = make(uri, { maxPoolSize: 1, minPoolSize: 0 });
      let medianMs: number;
      try {
        await sessionGate(meter, "qual", target.database);
        const samples: number[] = [];
        for (let i = 0; i < 9; i += 1) {
          const started = process.hrtime.bigint();
          await meter.db(target.database).command({ ping: 1 });
          samples.push(Number(process.hrtime.bigint() - started) / 1e6);
        }
        medianMs = summarizeLatency(samples).medianMs;
      } finally {
        await meter.close().catch(() => undefined);
      }
      if (medianMs < 4) return { status: "informational", detail: `round trip ${medianMs.toFixed(1)} ms is too small to force a checkout wait deterministically; NOT VERIFIED` };
      const deadlineMs = Math.max(1, Math.floor(medianMs / 2));
      const probe = make(uri, { maxPoolSize: 1, minPoolSize: 0, waitQueueTimeoutMS: deadlineMs });
      try {
        // Connection setup can itself exceed the deliberately tiny deadline; warm up (bounded) before measuring.
        let warmed = false;
        for (let attempts = 0; attempts < 20 && !warmed; attempts += 1) {
          try {
            await sessionGate(probe, "qual", target.database);
            warmed = true;
          } catch (error) {
            if ((error as Error).name !== "MongoWaitQueueTimeoutError") throw error;
            await new Promise((resolve) => setTimeout(resolve, 100));
          }
        }
        if (!warmed) return { status: "informational", detail: "the constrained pool could not be warmed up within 20 attempts, so the deadline behavior is NOT VERIFIED" };
        const items = probe.db(target.database).collection("probe_items");
        const startedAt = process.hrtime.bigint();
        const settled = await Promise.allSettled(
          Array.from({ length: 4 }, async () => {
            await items.findOne({});
            return 0;
          }).map((operation) => operation.catch((error: Error) => {
            throw Object.assign(error, { elapsedMs: Number(process.hrtime.bigint() - startedAt) / 1e6 });
          }))
        );
        const rejected = settled.filter((entry): entry is PromiseRejectedResult => entry.status === "rejected").map((entry) => entry.reason as Error & { elapsedMs: number });
        const succeeded = settled.length - rejected.length;
        const perOperation = settled
          .map((entry, index) => (entry.status === "fulfilled" ? `op${index}: ok` : `op${index}: ${(entry.reason as Error).name} @${((entry.reason as { elapsedMs: number }).elapsedMs ?? 0).toFixed(0)}ms`))
          .join("; ");
        const timeouts = rejected.filter((error) => error.name === "MongoWaitQueueTimeoutError");
        const others = rejected.filter((error) => error.name !== "MongoWaitQueueTimeoutError");
        if (others.length > 0) throw new Error(`unrelated failure(s): ${others.map((error) => error.name).join(",")} [${perOperation}]`);
        if (timeouts.length === 0) throw new Error(`no checkout timed out with a ${deadlineMs} ms deadline against a ${medianMs.toFixed(0)} ms round trip [${perOperation}]`);
        if (succeeded === 0) throw new Error(`no operation succeeded; the pool did not serve the first checkout [${perOperation}]`);
        const late = timeouts.filter((error) => error.elapsedMs < deadlineMs - 1 || error.elapsedMs > deadlineMs + 1000);
        if (late.length > 0) throw new Error(`checkout failures were not bounded by the ${deadlineMs} ms deadline (observed ${late.map((error) => error.elapsedMs.toFixed(0)).join(",")} ms) [${perOperation}]`);
        return { detail: `maxPoolSize 1, waitQueueTimeoutMS ${deadlineMs} (half the ${medianMs.toFixed(0)} ms median round trip): ${succeeded} operation(s) served, ${timeouts.length} failed with MongoWaitQueueTimeoutError after ${timeouts.map((error) => error.elapsedMs.toFixed(0)).join("/")} ms. Per-operation: [${perOperation}]. Shows the configured driver checkout deadline fails fast; says nothing about Atlas service limits.` };
      } finally {
        await probe.close().catch(() => undefined);
      }
    })
  );
  results.push(await check("cross-region latency", () => latencyResult(client, input.environment).then((r) => ({ status: r.status, detail: r.detail }))));
  return results;
}

async function realUserChecks(client: MongoClient, target: AtlasTarget, stage: Stage, environment: NodeJS.ProcessEnv): Promise<CheckResult[]> {
  const results: CheckResult[] = [];
  const absent = newAbsentName();
  const db = client.db(target.database);
  const other = target.database === "commonplate_production" ? "commonplate_review" : "commonplate_production";
  results.push(
    await check("read-only shape on a nonexistent collection", async () => {
      await proveAbsent(db, absent);
      await db.collection(absent).findOne({});
      return { detail: "find and listIndexes are authorized; the probe namespace was proven absent (nothing was written)" };
    })
  );
  results.push(
    await check("expected denials on nonexistent targets (no writes)", async () => {
      await proveAbsent(db, absent);
      const problems: string[] = [];
      const inconclusive: string[] = [];
      const missing = db.collection(absent);
      await mustBeDenied("dropIndexes", () => missing.dropIndexes(), problems, inconclusive);
      await mustBeDenied("dropCollection", () => db.dropCollection(absent), problems, inconclusive);
      await mustBeDenied("collMod", () => db.command({ collMod: absent, validator: {} }), problems, inconclusive);
      await mustBeDenied(
        "renameCollection",
        () => client.db("admin").command({ renameCollection: `${target.database}.${absent}`, to: `${target.database}.${absent}_2` }),
        problems,
        inconclusive
      );
      await mustBeDenied(`read ${other}`, () => client.db(other).collection(absent).findOne({}), problems, inconclusive);
      await mustBeDenied("read admin.system.users", () => client.db("admin").collection("system.users").findOne({}), problems, inconclusive);
      await mustBeDenied("createUser", () => client.db("admin").command({ createUser: "cpq_denied_user", pwd: `${Math.random()}`, roles: [] }), problems, inconclusive);
      await checkListDatabases(client, target.database, problems, inconclusive);
      if (problems.length > 0) throw new Error(problems.join("; "));
      return {
        status: inconclusive.length > 0 ? "informational" : "pass",
        detail: inconclusive.length > 0 ? `no unexpected success; inconclusive: ${inconclusive.join(" | ")}` : "every probed operation was denied with Unauthorized (dropDatabase is checked through the privilege set, never attempted)",
      };
    })
  );
  results.push(poolConfigurationResult());
  results.push(await check("cross-region latency", () => latencyResult(client, environment).then((r) => ({ status: r.status, detail: r.detail }))));
  void stage;
  return results;
}

export interface StageOutcome {
  target: AtlasTarget | null;
  results: CheckResult[];
}

/** Guards first, then connect, then the server-side session gate, then the stage's checks. */
export async function runStage(input: StageInput): Promise<StageOutcome> {
  let target: AtlasTarget;
  try {
    target = assertAtlasTarget(input.uri, input.stage, input.environment);
  } catch (error) {
    return { target: null, results: [{ name: "target guard", status: "fail", detail: summarizeError(error) }] };
  }
  const makeClient = input.createClient ?? ((uri, options) => new mongoose.mongo.MongoClient(uri, options));
  const client = makeClient(input.uri, { maxPoolSize: 5, serverSelectionTimeoutMS: 15_000 });
  const results: CheckResult[] = [{ name: "target guard", status: "pass", detail: "pinned Atlas SRV host, TLS, exact stage user and database, explicit confirmation" }];
  let cleanedUp = false;
  let armed = false;
  const cleanup = async () => {
    if (cleanedUp || !armed || input.stage !== "qual") return;
    cleanedUp = true;
    try {
      const db = client.db(target.database);
      for (const name of await authorizedCollectionNames(db)) {
        await db.dropCollection(name).catch(() => undefined);
      }
      const left = await authorizedCollectionNames(db);
      results.push({ name: "cleanup", status: left.length === 0 ? "pass" : "fail", detail: left.length === 0 ? "qualification database is empty again" : `${left.length} collections remain; remove them in the Atlas console` });
    } catch (error) {
      results.push({ name: "cleanup", status: "fail", detail: summarizeError(error) });
    }
  };
  const onSignal = (signal: NodeJS.Signals) => {
    void cleanup().finally(() => {
      console.error(formatReport(input.stage, target, results));
      process.exit(signal === "SIGINT" ? 130 : 143);
    });
  };
  process.once("SIGINT", onSignal);
  process.once("SIGTERM", onSignal);
  try {
    await client.connect();
    await sessionGate(client, input.stage, target.database);
    results.push({ name: "session gate", status: "pass", detail: `exactly ${STAGES[input.stage].username} / ${STAGES[input.stage].role}, only the closed action set on ${target.database}, Atlas replica-set members` });
    results.push(
      ...(input.stage === "qual"
        ? await qualificationChecks(client, input.uri, target, input, () => {
            armed = true;
          })
        : await realUserChecks(client, target, input.stage, input.environment))
    );
  } catch (error) {
    results.push({ name: "stage aborted", status: "fail", detail: summarizeError(error) });
  } finally {
    await cleanup();
    process.off("SIGINT", onSignal);
    process.off("SIGTERM", onSignal);
    await client.close().catch(() => undefined);
  }
  return { target, results };
}

function parseDate(value: string | undefined): string {
  if (!value || !/^\d{8}$/.test(value)) throw new RealQualSafetyError("a --date yyyymmdd argument is required.");
  return value;
}

async function main(argv: string[]): Promise<number> {
  const [command, argument] = argv;
  const root = process.cwd();
  if (command === "print-qual-role") {
    const runtime = JSON.parse(readFileSync(path.join(root, "deploy/atlas/runtime-role.json"), "utf8")) as RoleDefinition;
    console.log(JSON.stringify(qualRoleDefinition(runtime, parseDate(argument)), null, 2));
    return 0;
  }
  if (command === "check-target" || command === "qual" || command === "runtime" || command === "review") {
    const stage = (command === "check-target" ? argument : command) as Stage;
    if (!(stage in STAGES)) throw new RealQualSafetyError("stage must be qual, runtime or review.");
    const uri = process.env[STAGES[stage].uriEnv] ?? "";
    if (command === "check-target") {
      const target = assertAtlasTarget(uri, stage, process.env);
      console.log(`target OK (no connection made): ${target.srvHost} database ${target.database} user ${target.username}`);
      return 0;
    }
    const outcome = await runStage({ stage, uri, environment: process.env, repositoryRoot: root });
    console.log(formatReport(stage, outcome.target, outcome.results));
    return outcome.results.every((result) => result.status !== "fail") ? 0 : 1;
  }
  console.error(`usage: atlas-real-qualification <check-target <stage>|print-qual-role <date>|qual|runtime|review> (cluster ${EXPECTED_CLUSTER}; every run needs ${CONFIRM_ENV})`);
  return 2;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2)).catch((error) => {
    console.error(`failed: ${summarizeError(error)}`);
    return 1;
  });
  process.exit(process.exitCode);
}
