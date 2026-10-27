// W5-INF1 reusable database qualification probe: dev/test tooling only. Never
// imported by the app and never run by the release builder.
//
// The probe proves, against a DISPOSABLE LOCAL replica set only, that the
// application's database contract holds: transaction commit and abort, the
// application's own index definitions, the least-privilege runtime roles
// (allowed actions and expected denials), and the bounded pool configuration.
//
// It is NOT Atlas compatibility proof. Local role behavior, local index builds
// and a one-node local replica set say nothing about Atlas Flex limits,
// privilege-action semantics, networking or backups; see ATLAS_ONLY_REQUIREMENTS.
//
// There is deliberately no entry point here that accepts a caller-chosen
// database: destructive work runs only through `runLocalQualificationProbe`,
// which refuses unless the target server proves it is the throwaway harness.
// Importing this module opens no connection and reads no environment.
import { readFileSync, realpathSync } from "node:fs";
import mongoose from "mongoose";
import {
  mongoConnectionOptions,
  MAX_POOL_SIZE_CEILING,
  PRODUCTION_MAX_POOL_SIZE,
  REVIEW_MAX_POOL_SIZE,
} from "../src/mongoConnectionOptions.js";
import { isTransactionCapableMongo } from "../src/mongoTransactions.js";
import {
  discoverModels,
  messagingIsWiredIntoApp,
  verifyProductionIndexes,
  verifyReviewIndexes,
  type IndexVerification,
} from "./atlas-qualification-probe-indexes.js";

export const PROBE_OPT_IN_ENV = "ATLAS_PROBE_LOCAL_DISPOSABLE";
export const PROBE_DATABASE_PREFIX = "cp_atlas_probe_";
export const PRODUCTION_DATABASE = "commonplate_production";
export const REVIEW_DATABASE_NAME = "commonplate_review";
const PROBE_DATABASE_PATTERN = /^cp_atlas_probe_[a-z0-9_]{1,32}$/;
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);
const SYSTEM_DATABASES = new Set(["admin", "config", "local"]);

export type ProbeScope = "local-proof" | "definition";
export type ProbeStatus = "pass" | "fail" | "skipped";

export interface ProbeCheckResult {
  name: string;
  scope: ProbeScope;
  status: ProbeStatus;
  detail: string;
}

export interface ProbeReport {
  ok: boolean;
  results: ProbeCheckResult[];
  atlasOnly: readonly string[];
}

// Everything below must still be proven on the real Atlas cluster. A green local
// report never covers these.
export const ATLAS_ONLY_REQUIREMENTS: readonly string[] = [
  "Cluster tier, region and version: Flex is unavailable in us-east-2; the tier/region decision and purchase authorization are still open.",
  "Transactions, index builds and the Mongoose createIndexes() path on the real cluster (Flex support is inferred, not proven).",
  "The real runtime database users, and that Atlas accepts deploy/atlas/runtime-role.json and review-runtime-role.json (Atlas privilege-action names and semantics differ from local mongod roles).",
  "Atlas-side denials: no admin, dropDatabase, dropIndexes, other-database or Atlas-management access for the runtime users (local mongod lets a createIndex holder drop indexes).",
  "Network access: IP allowlist, TLS-only mongodb+srv connection from the Lightsail host (Flex has no private networking).",
  "Flex limits: 500 connections and 500 operations per second against the configured pool budget.",
  "Backup and restore drill (Flex: daily snapshots, no point-in-time recovery).",
  "Startup refusal behavior with the real connection string and the credential-launcher path.",
];

export class ProbeSafetyError extends Error {}

/** Removes connection strings and credentials from any text that may be printed. */
export function redactProbeText(text: string): string {
  return text
    .replace(/mongodb(?:\+srv)?:\/\/[^\s"'`]+/gi, "mongodb://[redacted]")
    .replace(/(password|pwd|secret|token)(["'\s:=]+)[^\s,"'}]+/gi, "$1$2[redacted]");
}

export function safeErrorSummary(error: unknown): string {
  if (error instanceof ProbeSafetyError) return redactProbeText(error.message);
  const code =
    error && typeof error === "object" && "code" in error
      ? String((error as { code?: unknown }).code)
      : undefined;
  const name = error instanceof Error ? error.name : "UnknownError";
  const message = error instanceof Error ? error.message : "";
  return redactProbeText(
    `${name}${code ? ` code=${code}` : ""}${message ? `: ${message.slice(0, 160)}` : ""}`
  );
}

export interface DisposableTarget {
  hosts: string[];
  databaseName: string;
}

/**
 * First, string-level gate. It accepts only a plain mongodb:// loopback
 * replica-set URI without TLS/proxy/alternative-auth options, a database in the
 * closed disposable name space and an explicit opt-in. Its errors never echo
 * the URI. A loopback TUNNEL to a remote cluster passes this gate by design;
 * `assertIsolatedLocalServer` is the gate that stops it.
 */
export function assertDisposableTarget(
  uri: string,
  databaseName: string,
  environment: NodeJS.ProcessEnv
): DisposableTarget {
  if (environment[PROBE_OPT_IN_ENV] !== "1") {
    throw new ProbeSafetyError(`Refusing to run: ${PROBE_OPT_IN_ENV}=1 is required.`);
  }
  if (!PROBE_DATABASE_PATTERN.test(databaseName)) {
    throw new ProbeSafetyError(
      `Refusing to run: database name must match ${PROBE_DATABASE_PATTERN.source}.`
    );
  }
  if (!/^mongodb:\/\//i.test(uri)) {
    throw new ProbeSafetyError("Refusing to run: only plain mongodb:// loopback URIs are allowed.");
  }
  const rest = uri.slice("mongodb://".length);
  const authority = rest.split(/[/?]/, 1)[0] ?? "";
  const hostList = authority.slice(authority.lastIndexOf("@") + 1);
  const hosts = hostList
    .split(",")
    .map((entry) =>
      entry.startsWith("[") ? entry.slice(0, entry.indexOf("]") + 1) : (entry.split(":")[0] ?? "")
    )
    .filter((host) => host.length > 0);
  if (hosts.length === 0 || !hosts.every((host) => LOOPBACK_HOSTS.has(host.toLowerCase()))) {
    throw new ProbeSafetyError("Refusing to run: every host must be loopback.");
  }
  const query = rest.includes("?") ? rest.slice(rest.indexOf("?") + 1) : "";
  const parameters = new Map(
    query
      .split("&")
      .filter((entry) => entry.length > 0)
      .map((entry) => {
        const [name = "", ...value] = entry.split("=");
        return [name.toLowerCase(), value.join("=").toLowerCase()] as const;
      })
  );
  if (!parameters.get("replicaset")) {
    throw new ProbeSafetyError("Refusing to run: a replicaSet parameter is required.");
  }
  for (const [name, value] of parameters) {
    const allowed =
      (name === "tls" || name === "ssl") && value === "false"
        ? true
        : ["replicaset", "authsource", "directconnection", "maxpoolsize", "minpoolsize", "waitqueuetimeoutms", "appname", "retrywrites", "w"].includes(name);
    if (!allowed) {
      throw new ProbeSafetyError("Refusing to run: only a minimal set of plain local connection options is allowed.");
    }
  }
  return { hosts, databaseName };
}

export interface CommandRunner {
  command(command: Record<string, unknown>): Promise<any>;
}

const hostName = (entry: string) =>
  (entry.startsWith("[") ? entry.slice(0, entry.indexOf("]") + 1) : (entry.split(":")[0] ?? "")).toLowerCase();

/**
 * Second, server-side gate, run before any write. A loopback tunnel or proxy to
 * Atlas passes the URI gate, so the SERVER must prove it is the throwaway
 * harness: its replica-set members are all loopback, its data directory is the
 * exact one the harness created, and it holds no user databases. Atlas rejects
 * the privileged `getCmdLineOpts` command, which also fails closed.
 */
export async function assertIsolatedLocalServer(
  adminDb: CommandRunner,
  expectedDataDirectory: string
): Promise<void> {
  const refuse = (): never => {
    throw new ProbeSafetyError("Refusing to run: the server did not prove it is the isolated local harness.");
  };
  let hello: { setName?: string; hosts?: string[]; me?: string };
  let options: { parsed?: { storage?: { dbPath?: string } } };
  let databases: { databases?: { name: string }[] };
  try {
    hello = await adminDb.command({ hello: 1 });
    options = await adminDb.command({ getCmdLineOpts: 1 });
    databases = await adminDb.command({ listDatabases: 1, nameOnly: true });
  } catch {
    return refuse();
  }
  const members = [...(hello.hosts ?? []), ...(hello.me ? [hello.me] : [])];
  if (!hello.setName || members.length === 0) refuse();
  if (!members.every((member) => LOOPBACK_HOSTS.has(hostName(member)))) refuse();
  const dbPath = options.parsed?.storage?.dbPath;
  if (!dbPath) refuse();
  try {
    if (realpathSync(dbPath as string) !== realpathSync(expectedDataDirectory)) refuse();
  } catch (error) {
    if (error instanceof ProbeSafetyError) throw error;
    refuse();
  }
  if ((databases.databases ?? []).some((entry) => !SYSTEM_DATABASES.has(entry.name))) refuse();
}

export interface RoleDefinitionFile {
  roleName: string;
  actions: { action: string; resources: { db: string; collection: string }[] }[];
  inheritedRoles: unknown[];
}

// Atlas custom-role action names mapped to the local mongod privilege actions
// they approximate. The mapping is the reason local role results are not proof.
const ATLAS_TO_LOCAL_ACTION: Record<string, string> = {
  FIND: "find",
  INSERT: "insert",
  UPDATE: "update",
  REMOVE: "remove",
  CREATE_COLLECTION: "createCollection",
  CREATE_INDEX: "createIndex",
  LIST_INDEXES: "listIndexes",
};

export function loadRoleDefinition(filePath: string): RoleDefinitionFile {
  return JSON.parse(readFileSync(filePath, "utf8")) as RoleDefinitionFile;
}

/** Static check of a committed role file: closed action set, one database, no inherited roles. */
export function checkRoleDefinition(
  definition: RoleDefinitionFile,
  expectedDatabase: string
): ProbeCheckResult {
  const problems: string[] = [];
  const actions = definition.actions.map((entry) => entry.action);
  for (const action of actions) {
    if (!(action in ATLAS_TO_LOCAL_ACTION)) problems.push(`unexpected action ${action}`);
  }
  for (const action of Object.keys(ATLAS_TO_LOCAL_ACTION)) {
    if (!actions.includes(action)) problems.push(`missing action ${action}`);
  }
  for (const entry of definition.actions) {
    for (const resource of entry.resources) {
      if (resource.db !== expectedDatabase || resource.collection !== "") {
        problems.push(`${entry.action} is not scoped to the whole ${expectedDatabase} database only`);
      }
    }
  }
  if (definition.inheritedRoles.length > 0) problems.push("inherited roles present");
  return {
    name: `role definition ${definition.roleName}`,
    scope: "definition",
    status: problems.length === 0 ? "pass" : "fail",
    detail:
      problems.length === 0
        ? "closed 7-action set, single database, no inherited roles"
        : problems.join("; "),
  };
}

/** Privileges for the local approximation of an Atlas role on the given (disposable) database. */
export function localPrivilegesFor(definition: RoleDefinitionFile, databaseName: string) {
  return definition.actions.map((entry) => ({
    resource: { db: databaseName, collection: "" },
    actions: [ATLAS_TO_LOCAL_ACTION[entry.action] as string],
  }));
}

async function check(
  name: string,
  scope: ProbeScope,
  run: () => Promise<string>
): Promise<ProbeCheckResult> {
  try {
    return { name, scope, status: "pass", detail: await run() };
  } catch (error) {
    return { name, scope, status: "fail", detail: safeErrorSummary(error) };
  }
}

async function expectDenied(label: string, operation: () => Promise<unknown>): Promise<string | null> {
  try {
    await operation();
    return `${label} unexpectedly succeeded`;
  } catch (error) {
    // 13 is Unauthorized; any other failure is a different problem, not a denial.
    const code = (error as { code?: number }).code;
    return code === 13
      ? null
      : `${label} failed for a reason other than authorization (${safeErrorSummary(error)})`;
  }
}

/** Configuration only: what `mongoConnectionOptions` returns and what the driver actually adopts. */
export function poolConfigurationChecks(): ProbeCheckResult[] {
  const results: ProbeCheckResult[] = [];
  const record = (name: string, problems: string[], ok: string) =>
    results.push({
      name,
      scope: "local-proof",
      status: problems.length === 0 ? "pass" : "fail",
      detail: problems.length === 0 ? ok : problems.join("; "),
    });
  const prod = mongoConnectionOptions({});
  const review = mongoConnectionOptions({ NODE_ENV: "review" });
  const problems: string[] = [];
  if (!prod.ok || prod.options.maxPoolSize !== PRODUCTION_MAX_POOL_SIZE) problems.push("production default pool wrong");
  if (!review.ok || review.options.maxPoolSize !== REVIEW_MAX_POOL_SIZE) problems.push("review default pool wrong");
  if (prod.ok && (prod.options.minPoolSize !== 0 || prod.options.waitQueueTimeoutMS !== 5000)) {
    problems.push("minPoolSize/waitQueueTimeoutMS default wrong");
  }
  if (prod.ok) {
    // Constructing a client does not connect; it only parses options.
    const { MongoClient } = mongoose.mongo;
    const adopted = new MongoClient("mongodb://127.0.0.1:1/?replicaSet=none", {
      maxPoolSize: prod.options.maxPoolSize,
      minPoolSize: prod.options.minPoolSize,
      waitQueueTimeoutMS: prod.options.waitQueueTimeoutMS,
    }).options;
    if (
      adopted.maxPoolSize !== PRODUCTION_MAX_POOL_SIZE ||
      adopted.minPoolSize !== 0 ||
      adopted.waitQueueTimeoutMS !== 5000
    ) {
      problems.push("driver did not adopt the configured pool options");
    }
  }
  record(
    "pool configuration",
    problems,
    `production ${PRODUCTION_MAX_POOL_SIZE}, review ${REVIEW_MAX_POOL_SIZE}, wait queue 5000 ms, adopted by the driver options; the combined budget is well under Atlas Flex's 500 connections (the Atlas limit itself is not verified)`
  );
  const accepted = [
    { MONGO_MAX_POOL_SIZE: "0" },
    { MONGO_MAX_POOL_SIZE: String(MAX_POOL_SIZE_CEILING + 1) },
    { MONGO_MAX_POOL_SIZE: "abc" },
    { MONGO_WAIT_QUEUE_TIMEOUT_MS: "99" },
    { MONGO_WAIT_QUEUE_TIMEOUT_MS: "30001" },
  ].filter((environment) => mongoConnectionOptions(environment).ok);
  record(
    "pool bounds rejected",
    accepted.length === 0 ? [] : ["out-of-range pool settings were accepted"],
    "out-of-range or non-numeric pool settings fail closed"
  );
  return results;
}

export interface ProbeInput {
  /** Administrator URI for the disposable local replica set; used to create roles/users and clean up. */
  adminUri: string;
  runtimeUriFor: (username: string, password: string) => string;
  /** The exact data directory the harness created; the server must report it. */
  expectedDataDirectory: string;
  databaseName: string;
  environment: NodeJS.ProcessEnv;
  roleDefinition: RoleDefinitionFile;
  reviewRoleDefinition: RoleDefinitionFile;
  /** Repository root, used to check the dormant-messaging exclusion. */
  repositoryRoot: string;
}

function indexResult(name: string, verification: IndexVerification, extra: string): ProbeCheckResult {
  return {
    name,
    scope: "local-proof",
    status: verification.problems.length === 0 ? "pass" : "fail",
    detail:
      verification.problems.length === 0
        ? `${verification.models} models, ${verification.indexes} schema-declared indexes: keys, uniqueness, names, TTL and partial filters match after Model.createIndexes() as the least-privilege user${extra}`
        : verification.problems.join("; "),
  };
}

/** Runs every local check and reports; never prints connection strings. */
export async function runLocalQualificationProbe(input: ProbeInput): Promise<ProbeReport> {
  const results: ProbeCheckResult[] = [];
  const finish = (): ProbeReport => ({
    ok: results.every((entry) => entry.status !== "fail"),
    results,
    atlasOnly: ATLAS_ONLY_REQUIREMENTS,
  });
  const fail = (name: string, error: unknown) =>
    results.push({ name, scope: "local-proof", status: "fail", detail: safeErrorSummary(error) });
  try {
    assertDisposableTarget(input.adminUri, input.databaseName, input.environment);
    assertDisposableTarget(input.runtimeUriFor("u", "p"), input.databaseName, input.environment);
  } catch (error) {
    fail("disposable-target guard", error);
    return finish();
  }

  const { MongoClient } = mongoose.mongo;
  const admin = new MongoClient(input.adminUri);
  try {
    await admin.connect();
    await assertIsolatedLocalServer(admin.db("admin"), input.expectedDataDirectory);
  } catch (error) {
    fail("isolated local server guard", error);
    await admin.close().catch(() => undefined);
    return finish();
  }
  results.push({
    name: "isolation guards",
    scope: "local-proof",
    status: "pass",
    detail: "loopback replica-set URI, disposable database name, explicit opt-in; server reports loopback members, the harness data directory and no user databases",
  });
  results.push(checkRoleDefinition(input.roleDefinition, PRODUCTION_DATABASE));
  results.push(checkRoleDefinition(input.reviewRoleDefinition, REVIEW_DATABASE_NAME));
  results.push(...poolConfigurationChecks());

  const suffix = input.databaseName.slice(PROBE_DATABASE_PREFIX.length);
  const runtimeUser = { name: "cp_probe_runtime", role: `probe_role_${suffix}`, password: `p-${Math.random().toString(36).slice(2)}${Date.now().toString(36)}` };
  const reviewUser = { name: "cp_probe_review", role: `probe_review_role_${suffix}`, password: `p-${Math.random().toString(36).slice(2)}${Date.now().toString(36)}` };
  let runtime: InstanceType<typeof MongoClient> | undefined;
  try {
    const hello = (await admin.db("admin").command({ hello: 1 })) as { setName?: string; msg?: string };
    const capable = isTransactionCapableMongo(hello);
    results.push({
      name: "replica set / transaction capability",
      scope: "local-proof",
      status: capable ? "pass" : "fail",
      detail: capable ? "hello reports a replica set" : "not a replica set",
    });
    for (const [user, definition, database] of [
      [runtimeUser, input.roleDefinition, input.databaseName],
      [reviewUser, input.reviewRoleDefinition, REVIEW_DATABASE_NAME],
    ] as const) {
      await admin.db("admin").command({
        createRole: user.role,
        privileges: localPrivilegesFor(definition, database),
        roles: [],
      });
      await admin.db("admin").command({
        createUser: user.name,
        pwd: user.password,
        roles: [{ role: user.role, db: "admin" }],
      });
    }
    runtime = new MongoClient(input.runtimeUriFor(runtimeUser.name, runtimeUser.password), { maxPoolSize: 5 });
    await runtime.connect();
  } catch (error) {
    fail("role and user setup", error);
    await admin.close().catch(() => undefined);
    return finish();
  }

  const client = runtime;
  const db = client.db(input.databaseName);
  const other = client.db(`${PROBE_DATABASE_PREFIX}other`);
  try {
    results.push(
      await check("runtime role allowed actions", "local-proof", async () => {
        await db.createCollection("probe_items");
        const items = db.collection("probe_items");
        await items.createIndex({ key: 1 }, { unique: true });
        await items.insertOne({ key: "a", n: 1 });
        await items.updateOne({ key: "a" }, { $set: { n: 2 } });
        const found = await items.findOne({ key: "a" });
        if (found?.n !== 2) throw new Error("find/update did not round-trip");
        await items.listIndexes().toArray();
        await items.deleteOne({ key: "a" });
        return "find, insert, update, remove, createCollection, createIndex, listIndexes all permitted";
      })
    );
    results.push(
      await check("runtime role expected denials", "local-proof", async () => {
        const items = db.collection("probe_items");
        const failures = (
          await Promise.all([
            expectDenied("dropCollection", () => db.dropCollection("probe_items")),
            expectDenied("dropDatabase", () => db.dropDatabase()),
            expectDenied("renameCollection", () => items.rename("probe_renamed")),
            expectDenied("collMod", () => db.command({ collMod: "probe_items", validator: {} })),
            expectDenied("other-database insert", () => other.collection("x").insertOne({ a: 1 })),
            expectDenied("other-database find", () => other.collection("x").findOne({})),
            expectDenied("createUser", () => client.db("admin").command({ createUser: "x", pwd: "y", roles: [] })),
          ])
        ).filter((entry): entry is string => entry !== null);
        // listDatabases is not privilege-gated for authenticated users; it must only reveal this database.
        const visible = (
          (await client.db("admin").command({ listDatabases: 1, nameOnly: true })) as { databases: { name: string }[] }
        ).databases.map((entry) => entry.name);
        if (visible.some((name) => name !== input.databaseName)) {
          failures.push(`listDatabases exposed other databases: ${visible.join(",")}`);
        }
        if (failures.length > 0) throw new Error(failures.join("; "));
        // dropIndexes is deliberately not asserted: the role has no dropIndex action, but mongod lets
        // the createIndex holder drop indexes, and Atlas behavior is unproven (see ATLAS_ONLY_REQUIREMENTS).
        return "dropCollection, dropDatabase, rename, collMod, other-database access and user management denied with Unauthorized; listDatabases reveals only the probe database";
      })
    );
    results.push(
      await check("transaction commit and abort", "local-proof", async () => {
        await db.createCollection("probe_tx");
        const items = db.collection("probe_tx");
        await items.createIndex({ key: 1 }, { unique: true });
        const session = client.startSession();
        try {
          await session.withTransaction(async () => {
            await items.insertOne({ key: "committed" }, { session });
          });
          if (!(await items.findOne({ key: "committed" }))) throw new Error("committed write is missing");
          session.startTransaction();
          await items.insertOne({ key: "aborted" }, { session });
          if (await items.findOne({ key: "aborted" })) throw new Error("uncommitted write visible outside the transaction");
          await session.abortTransaction();
          if (await items.findOne({ key: "aborted" })) throw new Error("aborted write persisted");
          let conflictCode: unknown;
          try {
            await session.withTransaction(async () => {
              await items.insertOne({ key: "second" }, { session });
              await items.insertOne({ key: "committed" }, { session });
            });
          } catch (error) {
            conflictCode = (error as { code?: unknown }).code;
          }
          if (conflictCode !== 11000) {
            throw new Error(`expected duplicate-key error 11000 inside the transaction, got ${String(conflictCode)}`);
          }
          if (await items.findOne({ key: "second" })) throw new Error("failed transaction left a partial write");
        } finally {
          await session.endSession();
        }
        return "commit persists; abort and a duplicate-key (11000) transaction failure leave no writes";
      })
    );

    const models = await discoverModels();
    results.push({
      name: "dormant-messaging exclusion still valid",
      scope: "local-proof",
      status: messagingIsWiredIntoApp(input.repositoryRoot) ? "fail" : "pass",
      detail: messagingIsWiredIntoApp(input.repositoryRoot)
        ? "app.ts now imports models/messaging: move its models into the production group"
        : "app.ts does not import models/messaging; its indexes are verified as a separate dormant group",
    });
    const productionConnection = await mongoose
      .createConnection(input.runtimeUriFor(runtimeUser.name, runtimeUser.password), { dbName: input.databaseName, maxPoolSize: 2 })
      .asPromise();
    try {
      results.push(
        await check("production indexes via Mongoose createIndexes", "local-proof", async () => {
          const verification = await verifyProductionIndexes(productionConnection, models.production);
          const outcome = indexResult("x", verification, `; models: ${models.production.map((model) => model.modelName).join(", ")}`);
          if (outcome.status === "fail") throw new Error(outcome.detail);
          return outcome.detail;
        })
      );
      results.push(
        await check("dormant messaging indexes via Mongoose createIndexes", "local-proof", async () => {
          const verification = await verifyProductionIndexes(productionConnection, models.dormantMessaging);
          const outcome = indexResult("x", verification, "; dormant: not started by app.ts");
          if (outcome.status === "fail") throw new Error(outcome.detail);
          return outcome.detail;
        })
      );
    } finally {
      await productionConnection.close().catch(() => undefined);
    }
    results.push(
      await check("review indexes via createReviewModels", "local-proof", async () => {
        const reviewConnection = await mongoose
          .createConnection(input.runtimeUriFor(reviewUser.name, reviewUser.password), { dbName: REVIEW_DATABASE_NAME, maxPoolSize: 2 })
          .asPromise();
        try {
          const verification = await verifyReviewIndexes(reviewConnection);
          const outcome = indexResult("x", verification, "; as the review runtime user");
          if (outcome.status === "fail") throw new Error(outcome.detail);
          return outcome.detail;
        } finally {
          await reviewConnection.close().catch(() => undefined);
        }
      })
    );
    results.push(
      await check("pool burst fails fast", "local-proof", async () => {
        const small = new MongoClient(input.runtimeUriFor(runtimeUser.name, runtimeUser.password), {
          maxPoolSize: 1,
          minPoolSize: 0,
          waitQueueTimeoutMS: 20,
        });
        try {
          // No explicit connect(): the driver connects on first use, and an eager checkout would itself time out.
          const items = small.db(input.databaseName).collection("probe_items");
          // Many concurrent operations on a one-connection pool: those that cannot check out a
          // connection within the bounded wait must fail with the driver's wait-queue error.
          const outcomes = await Promise.allSettled(Array.from({ length: 300 }, () => items.findOne({})));
          const names = outcomes.map((outcome) => (outcome.status === "rejected" ? (outcome.reason as Error).name : "ok"));
          const timedOut = names.filter((name) => name === "MongoWaitQueueTimeoutError").length;
          const other = names.filter((name) => name !== "ok" && name !== "MongoWaitQueueTimeoutError").length;
          if (timedOut === 0) throw new Error("no operation failed with a wait-queue timeout");
          if (other > 0) throw new Error(`${other} operations failed for another reason`);
          return `${timedOut} of 300 concurrent operations failed fast with MongoWaitQueueTimeoutError on a 1-connection/20 ms pool; a non-deterministic burst that shows the driver bounds waiting, not that production 20/5000 ms suits real load or Atlas limits`;
        } finally {
          await small.close();
        }
      })
    );
  } finally {
    await client.close().catch(() => undefined);
    await admin.db(input.databaseName).dropDatabase().catch(() => undefined);
    await admin.db(REVIEW_DATABASE_NAME).dropDatabase().catch(() => undefined);
    for (const user of [runtimeUser, reviewUser]) {
      await admin.db("admin").command({ dropUser: user.name }).catch(() => undefined);
      await admin.db("admin").command({ dropRole: user.role }).catch(() => undefined);
    }
    await admin.close().catch(() => undefined);
  }
  return finish();
}

export function formatProbeReport(report: ProbeReport): string {
  const lines = ["W5-INF1 database qualification probe (LOCAL DISPOSABLE REPLICA SET ONLY)"];
  for (const entry of report.results) {
    lines.push(`${entry.status.toUpperCase().padEnd(7)} [${entry.scope}] ${entry.name}: ${entry.detail}`);
  }
  lines.push(report.ok ? "RESULT: local checks passed" : "RESULT: local checks FAILED");
  lines.push("NOT VERIFIED (requires the real Atlas cluster):");
  for (const item of report.atlasOnly) lines.push(`  - ${item}`);
  return redactProbeText(lines.join("\n"));
}
