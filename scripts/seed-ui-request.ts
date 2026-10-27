// This module is imported by tests, so it must not load the developer's
// private `.env` as an import side effect. Only the command-line entry point at
// the bottom loads it; test harnesses supply configuration explicitly.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import mongoose, { Types } from "mongoose";
import { Participant, Request as MealRequest } from "../models/db.js";
import { REQUEST_VISIBLE_DURATION_MS } from "../src/requestTiming.js";
import {
  deriveFoodSummary,
  type StructuredMealItem,
} from "../src/structuredRequest.js";
import { formatMealRequestWindow } from "../src/utils/date.js";

// Fixtures are built to satisfy the same constraints a request created through
// the app does, so a layout or behavior problem seen with them is a real one:
// a vendor from the supported catalog, the fixed three-hour visibility window,
// the structured `mealItems`/`food` relationship (W4-R4), and the timing text
// the create route would have written. What is open text in the product
// (meal items, order details) is free text here too.
//
// Because the visible fields carry no "QA" marker, a fixture is recognized for
// cleanup by identity the product cannot produce instead:
//  - legacy and needs-help fixtures: a reserved `@example.invalid` address (no
//    real request can carry one — the create route only accepts NYU addresses)
//    and no owner;
//  - owned fixtures: these are ordinary requests under the owner's real address
//    and participant id, so nothing about them can tell them from a real one.
//    The tool therefore records the exact ids it inserted in a dev-only
//    manifest collection in the same (loopback, safe-named) database, and
//    cleanup deletes a request only if its id is in that manifest AND its
//    owner id AND requester address still match. Visible content never
//    decides, so a real request that looks identical to a fixture is never
//    eligible. No manifest means nothing is deleted.
export const UI_FIXTURE_EMAIL = "commonplate-ui-seed@example.invalid";
const NEEDS_HELP_EMAIL_PATTERN = "^commonplate-ui-seed-needs-help-\\d+@example\\.invalid$";

const FIXTURE_MEAL_ITEMS: readonly StructuredMealItem[] = [
  { name: "Chicken tenders", details: "Crispy, no sauce" },
  { name: "Veggie wrap" },
  { name: "Cheeseburger", details: "No onions" },
  { name: "Caesar salad", details: "Dressing on the side" },
  { name: "Breakfast sandwich" },
  { name: "Poke bowl", details: "Extra edamame" },
  { name: "Chicken quesadilla" },
  { name: "Large fries" },
];
const FIXTURE_ORDER_DETAILS: readonly string[] = [
  "Large iced latte and a blueberry muffin",
  "Two bagels with cream cheese and a coffee",
  "Chicken burrito bowl and a bottled water",
];

let cachedVendorNames: string[] | undefined;
/** The supported-vendor catalog both clients and the backend share, read
 * relative to this file so it does not depend on the working directory. */
function supportedVendorNames(): string[] {
  cachedVendorNames ??= (
    JSON.parse(
      readFileSync(new URL("../shared/vendors.json", import.meta.url), "utf8")
    ) as Array<{ name: string }>
  ).map((vendor) => vendor.name);
  return cachedVendorNames;
}

export type FixtureShape =
  | "asap"
  | "later-started"
  | "asap-with-estimate"
  | "dining-dollars"
  | "later-upcoming";

// Repeats every six fixtures. `later-upcoming` is a scheduled request whose
// start is still ahead, so helpers correctly do not see it yet.
const FIXTURE_SHAPES: readonly FixtureShape[] = [
  "asap",
  "later-started",
  "asap-with-estimate",
  "dining-dollars",
  "later-started",
  "later-upcoming",
];

const MINUTE_MS = 60 * 1000;
const FIXTURE_ESTIMATE_CENTS = 650;
const FIXTURE_DINING_DOLLARS_ONLY_CENTS = 1450;

/**
 * Everything about a fixture request except who it belongs to, shaped like what
 * `POST /api/request` persists for the same kind of request.
 */
function buildFixtureFields(
  index: number,
  now: Date,
  shapeOverride?: FixtureShape
) {
  const shape = shapeOverride ?? FIXTURE_SHAPES[index % FIXTURE_SHAPES.length]!;
  const vendors = supportedVendorNames();
  const vendor = vendors[index % vendors.length]!;

  // Timing, per `src/requestTiming.ts`: visible for exactly three hours from
  // `visibleFrom` (the creation instant for ASAP, the scheduled start for
  // Later).
  const isLater = shape === "later-started" || shape === "later-upcoming";
  const windowStart = isLater
    ? new Date(now.getTime() + (shape === "later-upcoming" ? 60 : -30) * MINUTE_MS)
    : undefined;
  const visibleFrom = windowStart ?? now;
  const expiresAt = new Date(visibleFrom.getTime() + REQUEST_VISIBLE_DURATION_MS);
  const createdAt =
    shape === "later-started" ? new Date(windowStart!.getTime() - 15 * MINUTE_MS) : now;

  // Structure, per `src/structuredRequest.ts`.
  const structured =
    shape === "dining-dollars"
      ? {
          menuPath: "dining-dollars" as const,
          mealSwipes: 0,
          mealItems: [] as StructuredMealItem[],
          orderDetails: FIXTURE_ORDER_DETAILS[index % FIXTURE_ORDER_DETAILS.length]!,
          estimatedDiningDollarsCents: FIXTURE_DINING_DOLLARS_ONLY_CENTS,
        }
      : {
          menuPath: "meal-exchange" as const,
          mealSwipes: (index % 5) + 1,
          mealItems: Array.from({ length: (index % 5) + 1 }, (_, position) => ({
            ...FIXTURE_MEAL_ITEMS[(index * 3 + position) % FIXTURE_MEAL_ITEMS.length]!,
          })),
          ...(shape === "asap-with-estimate"
            ? { estimatedDiningDollarsCents: FIXTURE_ESTIMATE_CENTS }
            : {}),
        };

  return {
    vendor,
    ...structured,
    food: deriveFoodSummary(structured),
    pickupWindowText: windowStart
      ? formatMealRequestWindow(windowStart, expiresAt)
      : "ASAP",
    ...(windowStart ? { windowStart, windowEnd: expiresAt } : {}),
    status: "open" as const,
    visibleFrom,
    helperNotification: (visibleFrom.getTime() <= now.getTime()
      ? "initiated"
      : "awaiting-eligibility") as "initiated" | "awaiting-eligibility",
    createdAt,
    expiresAt,
    deleteAt: expiresAt,
  };
}

const MIN_OWNED_FIXTURE_COUNT = 1;
const MAX_OWNED_FIXTURE_COUNT = 20;
const DEFAULT_OWNED_FIXTURE_COUNT = 8;
const MIN_NEEDS_HELP_FIXTURE_COUNT = 1;
const MAX_NEEDS_HELP_FIXTURE_COUNT = 20;
const DEFAULT_NEEDS_HELP_FIXTURE_COUNT = 8;
const SAFE_DATABASE_NAME =
  /^(test|testing|dev|development|local|qa|sandbox)$|(^|[-_])(test|testing|dev|development|local|qa|sandbox)([-_]|$)/i;
const LOOPBACK_MONGO_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const PRODUCTION_DATABASE_NAME =
  /^(commonplate|prod|production|live)$|(^|[-_])(prod|production|live)([-_]|$)/i;

type SeedEnvironment = {
  [key: string]: string | undefined;
  ALLOW_LOCAL_SEED?: string;
  MONGO_URI?: string;
  NODE_ENV?: string;
  SEED_OWNER_EMAIL?: string;
  SEED_OWNER_COUNT?: string;
  SEED_NEEDS_HELP_COUNT?: string;
};

type SeedOperation =
  | "seed"
  | "cleanup"
  | "seed-owned"
  | "cleanup-owned"
  | "seed-needs-help"
  | "cleanup-needs-help";

export class SeedSafetyError extends Error {}

export function validateRuntimeSafety(environment: SeedEnvironment): string {
  if (environment.NODE_ENV?.toLowerCase() === "production") {
    throw new SeedSafetyError(
      "Refusing to seed or clean up while NODE_ENV=production."
    );
  }

  if (environment.ALLOW_LOCAL_SEED !== "true") {
    throw new SeedSafetyError(
      "Refusing to continue without ALLOW_LOCAL_SEED=true."
    );
  }

  if (!environment.MONGO_URI) {
    throw new SeedSafetyError("MONGO_URI is required.");
  }

  return environment.MONGO_URI;
}

type MongoTarget = {
  hosts: string[];
  databaseName: string | null;
};

// Parsed by hand because `new URL` rejects the comma-separated multi-host form
// a replica-set URI uses. No message below may quote the URI: it can carry
// credentials.
function parseMongoTarget(uri: string, subject = "MONGO_URI"): MongoTarget {
  const match = /^(mongodb(?:\+srv)?):\/\/([^/?#]*)(?:\/([^?#]*))?(?:\?([^#]*))?$/.exec(
    uri.trim()
  );
  if (!match) {
    throw new SeedSafetyError(`${subject} could not be parsed safely.`);
  }
  const [, scheme, authority, pathPart, queryPart] = match;
  if (scheme !== "mongodb") {
    throw new SeedSafetyError(
      "Refusing a non-loopback MongoDB target: only mongodb:// URIs on this machine are allowed."
    );
  }

  const hostList = authority!.slice(authority!.lastIndexOf("@") + 1);
  const hosts = hostList
    .split(",")
    .map((entry) => entry.replace(/:\d*$/, "").toLowerCase());
  if (hosts.length === 0 || hosts.some((host) => host === "")) {
    throw new SeedSafetyError(`${subject} could not be parsed safely.`);
  }

  let pathDatabaseName: string | null = null;
  let queryDatabaseName: string | null = null;
  try {
    pathDatabaseName = pathPart ? decodeURIComponent(pathPart.split("/")[0]!) : null;
    queryDatabaseName =
      new URLSearchParams(queryPart ?? "").get("dbName") || null;
  } catch {
    throw new SeedSafetyError(`${subject} could not be parsed safely.`);
  }
  if (
    pathDatabaseName &&
    queryDatabaseName &&
    pathDatabaseName !== queryDatabaseName
  ) {
    throw new SeedSafetyError(
      `${subject} names two different databases; refusing an ambiguous target.`
    );
  }
  return { hosts, databaseName: queryDatabaseName || pathDatabaseName || null };
}

export function parseExplicitDatabaseName(
  uri: string,
  subject = "MONGO_URI"
): string | null {
  return parseMongoTarget(uri, subject).databaseName;
}

/** Seed and cleanup only ever touch a MongoDB on this machine. */
export function assertLoopbackMongoTarget(uri: string, subject = "MONGO_URI"): void {
  const { hosts } = parseMongoTarget(uri, subject);
  if (!hosts.every((host) => LOOPBACK_MONGO_HOSTS.has(host))) {
    throw new SeedSafetyError(
      "Refusing a non-loopback MongoDB target: only localhost, 127.0.0.1, or [::1] are allowed."
    );
  }
}

/**
 * The single target gate for seed and cleanup: loopback host, and an explicit,
 * clearly development/test database name in the URI itself. A URI that names no
 * database is refused rather than left to the driver's default.
 */
export function resolveSeedTarget(environment: SeedEnvironment): {
  uri: string;
  databaseName: string;
} {
  const uri = validateRuntimeSafety(environment);
  assertLoopbackMongoTarget(uri);
  const databaseName = parseExplicitDatabaseName(uri);
  if (!databaseName) {
    throw new SeedSafetyError(
      "MONGO_URI must name the target database explicitly; refusing an unnamed target."
    );
  }
  assertSafeDatabaseName(databaseName);
  return { uri, databaseName };
}

export function assertSafeDatabaseName(databaseName: string): void {
  if (PRODUCTION_DATABASE_NAME.test(databaseName)) {
    throw new SeedSafetyError(
      `Refusing to modify production-like database "${databaseName}".`
    );
  }

  if (!SAFE_DATABASE_NAME.test(databaseName)) {
    throw new SeedSafetyError(
      `Refusing to modify database "${databaseName}" because its name is not clearly development/test.`
    );
  }
}

// The legacy fixture is a single unowned request under the reserved address.
export function buildExactFixtureFilter() {
  return { email: UI_FIXTURE_EMAIL, requesterParticipantId: null };
}

// A fixture index no default needs-help or owned run reaches, so this request
// does not duplicate one of theirs on screen.
const LEGACY_FIXTURE_INDEX = 12;

export function buildFixtureDocument(now = new Date()) {
  return {
    ...buildFixtureFields(LEGACY_FIXTURE_INDEX, now),
    email: UI_FIXTURE_EMAIL,
    requesterParticipantId: null,
  };
}

// W4-H4 device-walkthrough support (dev/test tooling only, not part of the
// H4 SwiftUI contract). `ownerEmail` must be the exact address of a
// Participant that already independently completed the app's own email-code
// verification — this tool only looks that record up, it never creates or
// otherwise fabricates verified-participant authority.
export function normalizeOwnerEmail(email: string | undefined): string {
  const trimmed = email?.trim();
  if (!trimmed) {
    throw new SeedSafetyError(
      "SEED_OWNER_EMAIL is required for seed-owned/cleanup-owned."
    );
  }
  return trimmed.toLowerCase();
}

export function parseOwnedFixtureCount(argument: string | undefined): number {
  if (argument === undefined || argument === "") {
    return DEFAULT_OWNED_FIXTURE_COUNT;
  }
  const parsed = Number(argument);
  if (
    !Number.isInteger(parsed) ||
    parsed < MIN_OWNED_FIXTURE_COUNT ||
    parsed > MAX_OWNED_FIXTURE_COUNT
  ) {
    throw new SeedSafetyError(
      `SEED_OWNER_COUNT must be an integer between ${MIN_OWNED_FIXTURE_COUNT} and ${MAX_OWNED_FIXTURE_COUNT}.`
    );
  }
  return parsed;
}

// A multiple of the shape cycle (so the first fixtures keep the same request
// shapes) chosen so the first two owned fixtures use the supported vendors the
// default needs-help and legacy fixtures do not, and so cannot be mistaken for
// them on a helper's screen. With the 10-spot catalog only two vendors are left
// unused by those defaults.
const OWNED_FIXTURE_INDEX_OFFSET = 48;

export function buildOwnedFixtureDocument(
  index: number,
  ownerEmail: string,
  requesterParticipantId: unknown,
  now = new Date(),
  // Assigned before insertion so the manifest can be written first.
  _id: Types.ObjectId = new Types.ObjectId(),
  // Lets a QA preset pin the shape (e.g. `asap`, which is created "now" and so
  // is always inside the current campus day the daily quota counts).
  shape?: FixtureShape
) {
  return {
    _id,
    ...buildFixtureFields(index + OWNED_FIXTURE_INDEX_OFFSET, now, shape),
    email: ownerEmail,
    requesterParticipantId,
  };
}

// The full hidden identity: a request this tool recorded (its id is in the
// manifest) that is still bound to this owner's participant id and requester
// address. An empty manifest matches nothing.
export function buildOwnedFixtureFilter(
  requesterParticipantId: unknown,
  ownerEmail: string,
  manifestRequestIds: readonly Types.ObjectId[]
) {
  return {
    _id: { $in: [...manifestRequestIds] },
    requesterParticipantId,
    email: ownerEmail,
  };
}

export function parseNeedsHelpFixtureCount(argument: string | undefined): number {
  if (argument === undefined || argument === "") {
    return DEFAULT_NEEDS_HELP_FIXTURE_COUNT;
  }
  const parsed = Number(argument);
  if (
    !Number.isInteger(parsed) ||
    parsed < MIN_NEEDS_HELP_FIXTURE_COUNT ||
    parsed > MAX_NEEDS_HELP_FIXTURE_COUNT
  ) {
    throw new SeedSafetyError(
      `SEED_NEEDS_HELP_COUNT must be an integer between ${MIN_NEEDS_HELP_FIXTURE_COUNT} and ${MAX_NEEDS_HELP_FIXTURE_COUNT}.`
    );
  }
  return parsed;
}

export function buildNeedsHelpFixtureDocument(index: number, now = new Date()) {
  return {
    ...buildFixtureFields(index, now),
    email: `commonplate-ui-seed-needs-help-${index + 1}@example.invalid`,
    requesterParticipantId: null,
  };
}

// Never owned, and under the reserved fixture address no real request can use.
export function buildNeedsHelpFixtureFilter() {
  return {
    email: { $regex: NEEDS_HELP_EMAIL_PATTERN },
    requesterParticipantId: null,
  };
}

function parseOperation(argument: string | undefined): SeedOperation {
  if (
    argument === "seed" ||
    argument === "cleanup" ||
    argument === "seed-owned" ||
    argument === "cleanup-owned" ||
    argument === "seed-needs-help" ||
    argument === "cleanup-needs-help"
  ) {
    return argument;
  }
  throw new SeedSafetyError(
    "Usage: tsx scripts/seed-ui-request.ts <seed|cleanup|seed-owned|cleanup-owned|seed-needs-help|cleanup-needs-help>"
  );
}

// Looks up an *already verified* Participant by email — never creates one.
// A missing record means that address has not yet been verified in the app on
// this database, which this tool must not work around. Neither the address nor
// the resolved identifier is ever echoed back.
export async function findOwnerParticipantId(
  ownerEmail: string,
  emailVariable = "SEED_OWNER_EMAIL"
): Promise<Types.ObjectId> {
  const participant = await Participant.findOne({ email: ownerEmail })
    .select("_id")
    .lean()
    .exec();
  if (!participant) {
    throw new SeedSafetyError(
      `No verified Participant found for ${emailVariable} in this database. ` +
        "Verify that email in the app first (this tool never creates or " +
        "fabricates participant identity)."
    );
  }
  return participant._id as Types.ObjectId;
}

// The step a failure happened in, so a sanitized failure still says what broke.
export type SeedPhase =
  | "configuration"
  | "database connection"
  | "participant lookup"
  | "fixture cleanup"
  | "fixture write"
  | "environment verification"
  | "environment reset"
  | "scenario load"
  | "environment teardown";

/** An unexpected failure, already reduced to text that is safe to print. */
export class SeedOperationError extends Error {}

/**
 * Reduces any thrown value to a diagnosis that names the failing step and its
 * category without ever quoting the underlying message, which can contain a
 * connection URI, a credential, or a document value. Only schema paths, driver
 * error codes, and error class names are used.
 */
export function describeSeedFailure(
  error: unknown,
  phase: SeedPhase,
  subject = "UI seed operation"
): string {
  const name =
    error instanceof Error && /^[A-Za-z]{1,60}$/.test(error.name)
      ? error.name
      : "unknown error";
  let detail: string;
  if (error instanceof mongoose.Error.ValidationError) {
    const paths = Object.keys(error.errors)
      .filter((path) => /^[A-Za-z0-9_.]{1,80}$/.test(path))
      .join(", ");
    detail = `document validation failed for: ${paths || "unknown fields"}`;
  } else if (error instanceof mongoose.Error.CastError) {
    const path = /^[A-Za-z0-9_.]{1,80}$/.test(error.path) ? error.path : "unknown";
    detail = `a value could not be cast at path "${path}"`;
  } else if (/ServerSelection|Network|Timeout|ParseError/.test(name)) {
    detail = "MongoDB was unreachable or the connection settings were rejected";
  } else if (name === "MongoServerError") {
    const code = (error as { code?: unknown }).code;
    detail = `MongoDB rejected the operation${typeof code === "number" ? ` (code ${code})` : ""}`;
  } else {
    detail = `unexpected ${name}`;
  }
  return `${subject} failed during ${phase}: ${detail}. Nothing sensitive was printed.`;
}

async function inPhase<T>(phase: SeedPhase, work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof SeedSafetyError) throw error;
    throw new SeedOperationError(describeSeedFailure(error, phase));
  }
}

// Dev-tool bookkeeping only: not a product model, not in `models/db.ts`, and
// never read by the app. Lives in the same validated local database as the
// fixtures it describes, one document per owner (`_id` = participant id).
export const OWNED_MANIFEST_COLLECTION = "qa1OwnedFixtureManifest";

function ownedManifest() {
  return mongoose.connection.collection(OWNED_MANIFEST_COLLECTION);
}

async function readOwnedManifest(
  participantId: Types.ObjectId
): Promise<Types.ObjectId[]> {
  const entry = await ownedManifest().findOne({ _id: participantId } as never);
  const ids: unknown = entry?.requestIds;
  return Array.isArray(ids)
    ? ids.filter((id): id is Types.ObjectId => id instanceof Types.ObjectId)
    : [];
}

async function deleteRecordedOwnedFixtures(
  participantId: Types.ObjectId,
  ownerEmail: string
): Promise<number> {
  const recorded = await readOwnedManifest(participantId);
  // Fail closed: nothing recorded means nothing is eligible.
  if (recorded.length === 0) return 0;
  const result = await MealRequest.deleteMany(
    buildOwnedFixtureFilter(participantId, ownerEmail, recorded)
  ).exec();
  await ownedManifest().deleteOne({ _id: participantId } as never);
  return result.deletedCount;
}

async function seedOwned(
  databaseName: string,
  ownerEmail: string,
  count: number
): Promise<void> {
  const participantId = await inPhase("participant lookup", () =>
    findOwnerParticipantId(ownerEmail)
  );
  const removed = await inPhase("fixture cleanup", () =>
    deleteRecordedOwnedFixtures(participantId, ownerEmail)
  );

  const now = new Date();
  const documents = Array.from({ length: count }, (_, index) =>
    buildOwnedFixtureDocument(index, ownerEmail, participantId, now)
  );
  // Recorded before inserting, so a failure part-way through still leaves
  // every request that may exist reachable by cleanup.
  await inPhase("fixture write", () =>
    ownedManifest().updateOne(
      { _id: participantId } as never,
      { $set: { requestIds: documents.map((document) => document._id), seededAt: now } },
      { upsert: true }
    )
  );
  const created = await inPhase("fixture write", () =>
    MealRequest.insertMany(documents)
  );

  console.log(`database name: ${databaseName}`);
  console.log(`removed prior recorded owned fixtures: ${removed}`);
  console.log(`inserted owned fixtures: ${created.length}`);
  console.log(`expiration: ${documents[0]!.expiresAt.toISOString()}`);
  console.log(
    "cleanup command: ALLOW_LOCAL_SEED=true SEED_OWNER_EMAIL=<owner email> npm run seed:ui:owned:cleanup"
  );
}

async function cleanupOwned(databaseName: string, ownerEmail: string): Promise<void> {
  const participantId = await inPhase("participant lookup", () =>
    findOwnerParticipantId(ownerEmail)
  );
  const removed = await inPhase("fixture cleanup", () =>
    deleteRecordedOwnedFixtures(participantId, ownerEmail)
  );

  console.log(`database name: ${databaseName}`);
  console.log(`recorded owned fixtures removed: ${removed}`);
}

async function seedNeedsHelp(databaseName: string, count: number): Promise<void> {
  const filter = buildNeedsHelpFixtureFilter();
  const removed = await inPhase("fixture cleanup", () =>
    MealRequest.deleteMany(filter).exec()
  );

  const now = new Date();
  const documents = Array.from({ length: count }, (_, index) =>
    buildNeedsHelpFixtureDocument(index, now)
  );
  const created = await inPhase("fixture write", () =>
    MealRequest.insertMany(documents)
  );

  console.log(`database name: ${databaseName}`);
  console.log(`removed prior matching needs-help fixtures: ${removed.deletedCount}`);
  console.log(`inserted needs-help fixtures: ${created.length}`);
  console.log(`expiration: ${documents[0]!.expiresAt.toISOString()}`);
  console.log(
    "cleanup command: ALLOW_LOCAL_SEED=true npm run seed:ui:needs-help:cleanup"
  );
}

async function cleanupNeedsHelp(databaseName: string): Promise<void> {
  const result = await inPhase("fixture cleanup", () =>
    MealRequest.deleteMany(buildNeedsHelpFixtureFilter()).exec()
  );

  console.log(`database name: ${databaseName}`);
  console.log(`matching needs-help fixtures removed: ${result.deletedCount}`);
}

async function seed(databaseName: string): Promise<void> {
  const filter = buildExactFixtureFilter();
  const removed = await inPhase("fixture cleanup", () =>
    MealRequest.deleteMany(filter).exec()
  );
  const request = await inPhase("fixture write", () =>
    MealRequest.create(buildFixtureDocument())
  );

  console.log(`database name: ${databaseName}`);
  console.log(`removed prior matching fixtures: ${removed.deletedCount}`);
  console.log(`inserted request ID: ${String(request._id)}`);
  console.log(`expiration: ${request.expiresAt?.toISOString()}`);
  console.log(
    "cleanup command: ALLOW_LOCAL_SEED=true npm run seed:ui:cleanup"
  );
}

async function cleanup(databaseName: string): Promise<void> {
  const result = await inPhase("fixture cleanup", () =>
    MealRequest.deleteMany(buildExactFixtureFilter()).exec()
  );

  console.log(`database name: ${databaseName}`);
  console.log(`matching fixtures removed: ${result.deletedCount}`);
}

export async function runSeedTool(
  operationArgument: string | undefined,
  environment: SeedEnvironment = process.env
): Promise<void> {
  const operation = parseOperation(operationArgument);
  const { uri, databaseName: expectedDatabaseName } = resolveSeedTarget(environment);
  // Validated before connecting, so a missing owner or a bad count never opens
  // a connection.
  const ownerEmail =
    operation === "seed-owned" || operation === "cleanup-owned"
      ? normalizeOwnerEmail(environment.SEED_OWNER_EMAIL)
      : null;
  const ownedCount =
    operation === "seed-owned"
      ? parseOwnedFixtureCount(environment.SEED_OWNER_COUNT)
      : 0;
  const needsHelpCount =
    operation === "seed-needs-help"
      ? parseNeedsHelpFixtureCount(environment.SEED_NEEDS_HELP_COUNT)
      : 0;

  try {
    await inPhase("database connection", async () => {
      await mongoose.connect(uri, { dbName: expectedDatabaseName });
    });
    // The connection must land on exactly the database that was validated.
    const databaseName = mongoose.connection.name;
    if (databaseName !== expectedDatabaseName) {
      throw new SeedSafetyError(
        "Connected database does not match the validated MONGO_URI database; refusing to continue."
      );
    }
    assertSafeDatabaseName(databaseName);

    if (operation === "seed") {
      await seed(databaseName);
    } else if (operation === "cleanup") {
      await cleanup(databaseName);
    } else if (operation === "seed-owned") {
      await seedOwned(databaseName, ownerEmail!, ownedCount);
    } else if (operation === "cleanup-owned") {
      await cleanupOwned(databaseName, ownerEmail!);
    } else if (operation === "seed-needs-help") {
      await seedNeedsHelp(databaseName, needsHelpCount);
    } else {
      await cleanupNeedsHelp(databaseName);
    }
  } finally {
    await mongoose.disconnect().catch(() => undefined);
  }
}

const entryPath = process.argv[1];
if (entryPath && import.meta.url === pathToFileURL(entryPath).href) {
  try {
    // Command-line use only: configuration still comes from the environment
    // and any `.env`, but never as a side effect of importing this module.
    await import("dotenv/config");
    await runSeedTool(process.argv[2]);
  } catch (error) {
    const message =
      error instanceof SeedSafetyError || error instanceof SeedOperationError
        ? error.message
        : "UI seed operation failed; no credentials were printed.";
    console.error(message);
    process.exitCode = 1;
  }
}
