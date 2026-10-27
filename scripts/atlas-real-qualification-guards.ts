// W5-INF1: guards for the REAL Atlas Flex qualification tool. Dev/test tooling only.
//
// This is deliberately the mirror image of the local probe's guards: the local
// probe refuses everything that is not its own loopback harness; this tool
// refuses everything that is not the pinned Atlas cluster. Neither tool
// imports the other's guard, and nothing here can be pointed at loopback.
//
// Writes are possible only as the temporary `goodgrub_qual` user inside
// `cpq_qual_<yyyymmdd>`. The real runtime/review users are exercised read-only
// or by denial. No credential is ever read from argv or printed.
import mongoose from "mongoose";

export const EXPECTED_CLUSTER = "goodgrub-prod-01";
export const QUAL_USER = "goodgrub_qual";
export const QUAL_ROLE = "commonplateQualRuntime";
export const QUAL_DATABASE_PATTERN = /^cpq_qual_\d{8}$/;
export const CONFIRM_ENV = "ATLAS_REAL_QUAL_CONFIRM";
export const EXPECTED_HOST_ENV = "ATLAS_EXPECTED_SRV_HOST";
export const VANTAGE_ENV = "ATLAS_QUAL_VANTAGE";

export type Stage = "qual" | "runtime" | "review";

export interface StageSpec {
  uriEnv: string;
  username: string;
  role: string;
  /** Fixed database for real users; qual databases are date-specific. */
  database: string | null;
  writes: boolean;
}

export const STAGES: Readonly<Record<Stage, StageSpec>> = {
  qual: { uriEnv: "ATLAS_QUAL_URI", username: QUAL_USER, role: QUAL_ROLE, database: null, writes: true },
  runtime: {
    uriEnv: "ATLAS_RUNTIME_URI",
    username: "goodgrub_runtime",
    role: "commonplateRuntime",
    database: "commonplate_production",
    writes: false,
  },
  review: {
    uriEnv: "ATLAS_REVIEW_URI",
    username: "goodgrub-review",
    role: "commonplateReviewRuntime",
    database: "commonplate_review",
    writes: false,
  },
};

export const PRODUCTION_DATABASES: readonly string[] = ["commonplate_production", "commonplate_review"];
const SYSTEM_DATABASES = new Set(["admin", "config", "local"]);
// The closed action set every runtime role may hold (mongod names).
export const RUNTIME_ACTIONS: readonly string[] = [
  "find", "insert", "update", "remove", "createCollection", "createIndex", "listIndexes",
];
export const QUAL_EXTRA_ACTIONS: readonly string[] = ["dropCollection"];

export class RealQualSafetyError extends Error {}

export function redact(text: string): string {
  return text
    .replace(/mongodb(?:\+srv)?:\/\/[^\s"'`]+/gi, "mongodb://[redacted]")
    .replace(/(password|pwd|secret|token)(["'\s:=]+)[^\s,"'}]+/gi, "$1$2[redacted]");
}

export function summarizeError(error: unknown): string {
  if (error instanceof RealQualSafetyError) return redact(error.message);
  const code =
    error && typeof error === "object" && "code" in error ? String((error as { code?: unknown }).code) : undefined;
  const name = error instanceof Error ? error.name : "UnknownError";
  const message = error instanceof Error ? error.message : "";
  return redact(`${name}${code ? ` code=${code}` : ""}${message ? `: ${message.slice(0, 160)}` : ""}`);
}

export interface AtlasTarget {
  srvHost: string;
  username: string;
  database: string;
}

const ALLOWED_QUERY = new Set(["retrywrites", "w", "appname", "authsource", "maxpoolsize", "minpoolsize", "waitqueuetimeoutms"]);
const CLUSTER_HOST = new RegExp(`^${EXPECTED_CLUSTER}\\.[a-z0-9]+\\.mongodb\\.net$`, "i");

export function qualDatabaseNames(date: string): { qual: string; denied: string } {
  return { qual: `cpq_qual_${date}`, denied: `cpq_denied_${date}` };
}

export function expectedConfirmation(stage: Stage, database: string): string {
  return stage === "qual" ? `${EXPECTED_CLUSTER}:${database}` : `${EXPECTED_CLUSTER}:read-only:${STAGES[stage].username}`;
}

/**
 * String/option-level gate. Parses the URI with the driver (never connects) and
 * accepts only the pinned Atlas SRV host, TLS, the exact stage user and the
 * exact stage database. Errors never echo the URI.
 */
export function assertAtlasTarget(uri: string, stage: Stage, environment: NodeJS.ProcessEnv): AtlasTarget {
  const spec = STAGES[stage];
  const refuse = (reason: string): never => {
    throw new RealQualSafetyError(`Refusing to run: ${reason}`);
  };
  if (!/^mongodb\+srv:\/\//i.test(uri)) refuse("only a mongodb+srv:// Atlas URI is allowed.");
  const query = uri.includes("?") ? uri.slice(uri.indexOf("?") + 1) : "";
  for (const entry of query.split("&").filter((part) => part.length > 0)) {
    const name = (entry.split("=")[0] ?? "").toLowerCase();
    const value = entry.split("=").slice(1).join("=").toLowerCase();
    const tlsTrue = (name === "tls" || name === "ssl") && value === "true";
    if (!tlsTrue && !ALLOWED_QUERY.has(name)) refuse("only a minimal set of connection options is allowed.");
    if (name === "authsource" && value !== "admin") refuse("authSource must be admin.");
  }
  let options: {
    srvHost?: string;
    dbName?: string;
    tls?: boolean;
    directConnection?: boolean;
    proxyHost?: string;
    credentials?: { username?: string; password?: string; mechanism?: string };
  };
  try {
    options = new mongoose.mongo.MongoClient(uri).options as unknown as typeof options;
  } catch {
    return refuse("the connection string could not be parsed.");
  }
  // The exact FQDN (including Atlas's project id) is recorded in the contract and supplied by the operator.
  const pinned = (environment[EXPECTED_HOST_ENV] ?? "").trim().toLowerCase();
  if (!CLUSTER_HOST.test(pinned)) refuse(`${EXPECTED_HOST_ENV} must be the recorded ${EXPECTED_CLUSTER}.<id>.mongodb.net host.`);
  if (!options.srvHost || options.srvHost.toLowerCase() !== pinned) refuse("the SRV host is not the pinned cluster host.");
  if (options.tls === false || options.directConnection || options.proxyHost) refuse("TLS must be on with no proxy or direct connection.");
  const credentials = options.credentials;
  if (!credentials?.password) refuse("a password-bearing URI is required.");
  if (credentials?.username !== spec.username) refuse(`the user must be ${spec.username}.`);
  if (credentials?.mechanism && !/^(DEFAULT|SCRAM-SHA-(1|256))$/.test(credentials.mechanism)) {
    refuse("only SCRAM authentication is allowed.");
  }
  const database = options.dbName ?? "";
  if (stage === "qual") {
    if (!QUAL_DATABASE_PATTERN.test(database)) refuse("the database must match cpq_qual_<yyyymmdd>.");
  } else if (database !== spec.database) {
    refuse(`the database must be ${spec.database}.`);
  }
  if (environment[CONFIRM_ENV] !== expectedConfirmation(stage, database)) {
    refuse(`${CONFIRM_ENV} must equal ${expectedConfirmation(stage, database)}.`);
  }
  return { srvHost: options.srvHost as string, username: spec.username, database };
}

export interface ConnectionStatusReply {
  authInfo?: {
    authenticatedUsers?: { user: string; db: string }[];
    authenticatedUserRoles?: { role: string; db: string }[];
    authenticatedUserPrivileges?: { resource: { db?: string; collection?: string; cluster?: boolean; anyResource?: boolean }; actions: string[] }[];
  };
}

export interface HelloReply {
  setName?: string;
  hosts?: string[];
  me?: string;
}

export interface SessionExpectation {
  stage: Stage;
  database: string;
  actions: readonly string[];
}

export function expectedActions(stage: Stage): string[] {
  return [...RUNTIME_ACTIONS, ...(stage === "qual" ? QUAL_EXTRA_ACTIONS : [])].sort();
}

/**
 * Server-side gate, run before any write or denial probe. The session must be
 * exactly the stage user, hold exactly the stage role, hold privileges only on
 * the stage database with exactly the closed action set, and reach Atlas
 * (non-loopback `.mongodb.net` members). Returns problems; empty means proven.
 */
export function evaluateSession(
  status: ConnectionStatusReply,
  hello: HelloReply,
  expectation: SessionExpectation
): string[] {
  const spec = STAGES[expectation.stage];
  const problems: string[] = [];
  const users = status.authInfo?.authenticatedUsers ?? [];
  if (users.length !== 1 || users[0]?.user !== spec.username || users[0]?.db !== "admin") {
    problems.push("authenticated user is not exactly the stage user");
  }
  const roles = status.authInfo?.authenticatedUserRoles ?? [];
  if (roles.length !== 1 || roles[0]?.role !== spec.role || roles[0]?.db !== "admin") {
    problems.push(`stage role is not exactly ${spec.role}`);
  }
  const granted = new Set<string>();
  for (const privilege of status.authInfo?.authenticatedUserPrivileges ?? []) {
    const resource = privilege.resource;
    if (resource.cluster || resource.anyResource || resource.db !== expectation.database || (resource.collection ?? "") !== "") {
      problems.push("a privilege is not scoped to the whole stage database only");
      continue;
    }
    for (const action of privilege.actions) granted.add(action);
  }
  const wanted = new Set(expectation.actions);
  for (const action of granted) if (!wanted.has(action)) problems.push(`extra privilege action ${action}`);
  for (const action of wanted) if (!granted.has(action)) problems.push(`missing privilege action ${action}`);
  const members = [...(hello.hosts ?? []), ...(hello.me ? [hello.me] : [])];
  const hostOf = (member: string) => member.split(":")[0]?.toLowerCase() ?? "";
  if (!hello.setName || members.length === 0) problems.push("server did not report a replica set");
  if (!members.every((member) => hostOf(member).endsWith(".mongodb.net"))) {
    problems.push("replica-set members are not Atlas .mongodb.net hosts");
  }
  const databaseOk =
    expectation.stage === "qual" ? QUAL_DATABASE_PATTERN.test(expectation.database) : expectation.database === spec.database;
  if (!databaseOk || SYSTEM_DATABASES.has(expectation.database)) problems.push("unexpected stage database");
  return [...new Set(problems)];
}

export type AttemptOutcome = "denied" | "authorized" | "inconclusive";

/**
 * Atlas Flex reports authorization refusals as code 8000 (AtlasError) instead of 13. Code 8000 is also used
 * for unrelated Atlas restrictions, so it only counts as a denial when the message states an authorization refusal.
 */
const ATLAS_AUTHORIZATION_REFUSAL = /\b(unauthorized|not authorized|not allowed to do action \[[A-Za-z]+\] on \[)/i;

function isAtlasAuthorizationRefusal(error: unknown): boolean {
  const { code, message } = (error ?? {}) as { code?: unknown; message?: unknown };
  return code === 8000 && typeof message === "string" && ATLAS_AUTHORIZATION_REFUSAL.test(message);
}

/**
 * Classifies an attempt that MUST be denied. Unauthorized (13), or an Atlas 8000 whose message is an
 * authorization refusal, is a denial. Success or
 * NamespaceNotFound (26, which an unauthorized user never reaches) proves the privilege
 * exists. Any other error (for example an Atlas Flex command restriction) is inconclusive
 * and is reported for human judgment, never counted as a pass.
 */
export function classifyAttempt(error: unknown): AttemptOutcome {
  if (error === undefined) return "authorized";
  const code = (error as { code?: number } | null)?.code;
  if (code === 13 || isAtlasAuthorizationRefusal(error)) return "denied";
  if (code === 26) return "authorized";
  return "inconclusive";
}

export interface RoleDefinition {
  roleName: string;
  actions: { action: string; resources: { db: string; collection: string }[] }[];
  inheritedRoles: unknown[];
}

/** The Atlas custom-role definition to create for the temporary qualification role on one disposable database. */
const RUNTIME_ATLAS_ACTIONS = ["FIND", "INSERT", "UPDATE", "REMOVE", "CREATE_COLLECTION", "CREATE_INDEX", "LIST_INDEXES"];

export function qualRoleDefinition(runtime: RoleDefinition, date: string): RoleDefinition {
  const { qual } = qualDatabaseNames(date);
  if (!QUAL_DATABASE_PATTERN.test(qual)) throw new RealQualSafetyError("date must be yyyymmdd");
  // Built from the fixed allowlist; the committed file is only checked against it, never copied blindly.
  const have = runtime.actions.map((entry) => entry.action).sort();
  if (JSON.stringify(have) !== JSON.stringify([...RUNTIME_ATLAS_ACTIONS].sort()) || runtime.inheritedRoles.length > 0) {
    throw new RealQualSafetyError("runtime-role.json is not the closed seven-action role; refusing to derive a qualification role.");
  }
  const scoped = (action: string) => ({ action, resources: [{ db: qual, collection: "" }] });
  return {
    roleName: QUAL_ROLE,
    actions: [...RUNTIME_ATLAS_ACTIONS, "DROP_COLLECTION"].map(scoped),
    inheritedRoles: [],
  };
}

export interface LatencySummary {
  samples: number;
  medianMs: number;
  p95Ms: number;
}

export function summarizeLatency(samples: number[]): LatencySummary {
  const sorted = [...samples].sort((a, b) => a - b);
  const at = (fraction: number) => sorted[Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1)] ?? 0;
  return { samples: sorted.length, medianMs: at(0.5), p95Ms: at(0.95) };
}

export type CheckStatus = "pass" | "fail" | "informational";

export interface CheckResult {
  name: string;
  status: CheckStatus;
  detail: string;
}

export const NOT_COVERED: readonly string[] = [
  "Real GoodGrub startup, the credential launcher and startup index creation by goodgrub_runtime (H4).",
  "Review-model index creation (createReviewModels requires the literal commonplate_review database).",
  "Realistic load, 500 operations-per-second and Atlas connection-count metrics (read in the Atlas console).",
  "Backup availability and the restore drill.",
  "P2/U1.2 changes: re-run after the final inventory/role files are frozen.",
];

export function formatReport(stage: Stage, target: AtlasTarget | null, results: CheckResult[]): string {
  const lines = [`Atlas real-cluster qualification (${stage}): ${results.every((r) => r.status !== "fail") ? "PASS" : "FAIL"}`];
  if (target) lines.push(`cluster ${target.srvHost} database ${target.database} user ${target.username}`);
  for (const result of results) lines.push(`  [${result.status.toUpperCase()}] ${result.name}: ${result.detail}`);
  lines.push("NOT COVERED by this run:");
  for (const item of NOT_COVERED) lines.push(`  - ${item}`);
  return redact(lines.join("\n"));
}
