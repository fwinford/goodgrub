// W4-QA1 named local QA environments: dev/test tooling only. Not a product
// model, not a runtime route, and never imported by the app.
//
// One named environment is one dedicated local database (`commonplate_qa_<slug>`)
// and one reset domain. Everything here is gated on an explicit environment
// config file, a loopback MongoDB, the closed database-name rule, and a marker
// document stored in that same database that must agree with the config. There
// is deliberately no `.env`, no `MONGO_URI`, and no default database in this
// module: importing it loads nothing, and the config file is the only input that
// can name a destructive target.
//
// Three destructive operations, kept distinct:
//  - fixture cleanup (`seed-ui-request.ts`): unchanged and narrow;
//  - normal reset (`resetEnvironment`): removes every Request in this one
//    environment plus the records that belong to those Requests, and preserves
//    identity and the D1/D2 operation ledger;
//  - full teardown (`dropEnvironment`): drops the whole database, behind a
//    separate command and a typed confirmation.
//
// The daily quota is not touched anywhere. It counts Request rows, so removing
// the Request rows is what restores eligibility.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import mongoose, { Types } from "mongoose";
import {
  Fulfillment,
  Participant,
  PlacementEvidence,
  PushDelivery,
  Request as MealRequest,
  RequestOperation,
  RequestOperationAuthority,
  RequestParticipation,
  RequestUpdateOperation,
  SendLog,
  Installation,
  Subscriber,
  ParticipantVerification,
  System,
} from "../models/db.js";
import { assertMongoTransactionsSupported } from "../src/mongoTransactions.js";
import {
  OWNED_MANIFEST_COLLECTION,
  SeedOperationError,
  SeedSafetyError,
  assertLoopbackMongoTarget,
  assertSafeDatabaseName,
  buildNeedsHelpFixtureDocument,
  buildOwnedFixtureDocument,
  describeSeedFailure,
  findOwnerParticipantId,
  parseExplicitDatabaseName,
  type SeedPhase,
} from "./seed-ui-request.js";

const TOOL_SUBJECT = "QA environment operation";

/* ============================ environment config ============================ */

export const QA_DATABASE_PREFIX = "commonplate_qa_";
// Closed on purpose: lowercase words joined by single underscores. Anything
// that merely resembles a production name is additionally refused by
// `assertSafeDatabaseName` (prod/production/live tokens).
const QA_SLUG_PATTERN = /^[a-z0-9]{1,16}(?:_[a-z0-9]{1,16}){0,3}$/;
// Names the config field (not `MONGO_URI`) in shared-parser diagnostics.
const QA_URI_SUBJECT = "QA environment mongoUri";
const CONFIG_KEYS = [
  "slug",
  "database",
  "mongoUri",
  "backendPort",
  "mailSinkPort",
] as const;

export type QaEnvironmentConfig = {
  slug: string;
  database: string;
  mongoUri: string;
  backendPort: number;
  mailSinkPort: number;
};

export function qaDatabaseNameForSlug(slug: string): string {
  return `${QA_DATABASE_PREFIX}${slug}`;
}

function parsePort(value: unknown, field: string): number {
  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value < 1024 ||
    value > 65535
  ) {
    throw new SeedSafetyError(
      `QA environment ${field} must be an integer between 1024 and 65535.`
    );
  }
  return value;
}

/**
 * Validates an environment config without touching the network. Every value is
 * explicit; the database name is not derived from anything implicit and must
 * equal `commonplate_qa_<slug>` exactly. Messages never quote the supplied
 * values (the URI can carry credentials).
 */
export function parseQaEnvironmentConfig(raw: unknown): QaEnvironmentConfig {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new SeedSafetyError("QA environment config must be a JSON object.");
  }
  const record = raw as Record<string, unknown>;
  const unknownKeys = Object.keys(record).filter(
    (key) => !(CONFIG_KEYS as readonly string[]).includes(key)
  );
  if (unknownKeys.length > 0) {
    throw new SeedSafetyError(
      "QA environment config has unsupported fields; refusing an open-ended config."
    );
  }
  const { slug, database, mongoUri } = record;
  if (typeof slug !== "string" || !QA_SLUG_PATTERN.test(slug)) {
    throw new SeedSafetyError(
      "QA environment slug must be 1-4 lowercase words (letters/digits) joined by single underscores."
    );
  }
  if (typeof database !== "string" || database === "") {
    throw new SeedSafetyError("QA environment database name is required.");
  }
  if (database !== qaDatabaseNameForSlug(slug)) {
    throw new SeedSafetyError(
      `QA environment database must be exactly "${QA_DATABASE_PREFIX}<slug>" for its slug.`
    );
  }
  assertSafeDatabaseName(database);
  if (typeof mongoUri !== "string" || mongoUri.trim() === "") {
    throw new SeedSafetyError("QA environment mongoUri is required.");
  }
  assertLoopbackMongoTarget(mongoUri, QA_URI_SUBJECT);
  const uriDatabase = parseExplicitDatabaseName(mongoUri, QA_URI_SUBJECT);
  if (!uriDatabase) {
    throw new SeedSafetyError(
      "QA environment mongoUri must name the database explicitly; refusing an unnamed target."
    );
  }
  if (uriDatabase !== database) {
    throw new SeedSafetyError(
      "QA environment mongoUri names a different database than the config; refusing a mismatched target."
    );
  }
  const backendPort = parsePort(record.backendPort, "backendPort");
  const mailSinkPort = parsePort(record.mailSinkPort, "mailSinkPort");
  if (backendPort === mailSinkPort) {
    throw new SeedSafetyError(
      "QA environment backendPort and mailSinkPort must differ."
    );
  }
  return { slug, database, mongoUri, backendPort, mailSinkPort };
}

export function loadQaEnvironmentConfig(
  path: string | undefined
): QaEnvironmentConfig {
  if (!path) {
    throw new SeedSafetyError(
      "QA_ENV_FILE is required: name the environment config file explicitly."
    );
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new SeedSafetyError(
      "QA_ENV_FILE could not be read as a JSON config file."
    );
  }
  return parseQaEnvironmentConfig(parsed);
}

export function qaBackendBaseUrl(config: QaEnvironmentConfig): string {
  return `http://127.0.0.1:${config.backendPort}`;
}

/* ============================ environment marker ============================ */

// Dev-tool bookkeeping stored in the QA database itself, like the owned-fixture
// manifest. A config that names a database whose marker names a different
// environment (or no marker at all) is refused before any mutation.
export const ENVIRONMENT_MARKER_COLLECTION = "qa1Environment";
const ENVIRONMENT_MARKER_ID = "environment";

type QaToolEnvironment = {
  [key: string]: string | undefined;
  NODE_ENV?: string;
  ALLOW_LOCAL_SEED?: string;
  QA_ENV_FILE?: string;
  QA_REQUESTER_EMAIL?: string;
};

function markerCollection() {
  return mongoose.connection.collection(ENVIRONMENT_MARKER_COLLECTION);
}

type MarkerState = "absent" | "matches" | "mismatch";

async function readMarkerState(config: QaEnvironmentConfig): Promise<MarkerState> {
  const marker = await markerCollection().findOne({
    _id: ENVIRONMENT_MARKER_ID,
  } as never);
  if (!marker) return "absent";
  return marker.slug === config.slug && marker.database === config.database
    ? "matches"
    : "mismatch";
}

function assertLocalQaOptIn(environment: QaToolEnvironment): void {
  if (environment.NODE_ENV?.toLowerCase() === "production") {
    throw new SeedSafetyError(
      "Refusing to run QA environment tooling while NODE_ENV=production."
    );
  }
  if (environment.ALLOW_LOCAL_SEED !== "true") {
    throw new SeedSafetyError(
      "Refusing to continue without ALLOW_LOCAL_SEED=true."
    );
  }
}

async function inPhase<T>(phase: SeedPhase, work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof SeedSafetyError) throw error;
    throw new SeedOperationError(
      describeSeedFailure(error, phase, TOOL_SUBJECT)
    );
  }
}

/**
 * Connects to exactly the configured database and proves it is the configured
 * environment before `work` runs. `autoIndex`/`autoCreate` are off so that
 * connecting (which happens before the marker is checked) creates nothing in a
 * database that turns out not to be ours. `work` therefore only ever runs
 * against a verified environment, and nothing before it writes.
 */
async function withEnvironment<T>(
  config: QaEnvironmentConfig,
  mode: "marker-required" | "marker-optional",
  work: (marker: MarkerState) => Promise<T>
): Promise<T> {
  try {
    await inPhase("database connection", async () => {
      await mongoose.connect(config.mongoUri, {
        dbName: config.database,
        autoIndex: false,
        autoCreate: false,
      });
    });
    if (mongoose.connection.name !== config.database) {
      throw new SeedSafetyError(
        "Connected database does not match the configured QA database; refusing to continue."
      );
    }
    const marker = await inPhase("environment verification", () =>
      readMarkerState(config)
    );
    if (marker === "mismatch") {
      throw new SeedSafetyError(
        "The database's QA environment marker names a different environment; refusing to continue."
      );
    }
    if (mode === "marker-required" && marker !== "matches") {
      throw new SeedSafetyError(
        "This database has no QA environment marker. Run the `init` command for this environment first."
      );
    }
    return await work(marker);
  } finally {
    await mongoose.disconnect().catch(() => undefined);
  }
}

/* ============================== normal reset ============================== */

// Every collection that points at a Request, and what a normal reset does with
// it. The guard test discovers every schema path with `ref: "Request"` and
// fails if one is missing from this table, so a request-scoped model must be
// classified here deliberately rather than silently surviving or being
// silently deleted. `PlacementEvidence` (W4-H1a) is deleted with its Request:
// it exists only to support that placement, so leaving it behind would orphan
// a private screenshot with nothing left to authorize reading it.
export type RequestReferenceHandling = "delete" | "clear-lock" | "preserve";
export const REQUEST_REFERENCE_HANDLING: Readonly<
  Record<string, RequestReferenceHandling>
> = {
  "RequestParticipation.requestId": "delete",
  "Fulfillment.requestId": "delete",
  "PlacementEvidence.requestId": "delete",
  "PushDelivery.requestId": "delete",
  "SendLog.requestId": "delete",
  "Participant.activeReservationRequestId": "clear-lock",
  // D1/D2: the identity tombstone must outlive its Request.
  "RequestOperation.requestId": "preserve",
  // W4-R5: the same identity-tombstone reasoning for an Edit/Withdraw ledger
  // row. An exact replay after its Request is gone must still answer
  // "expired", never look like a fresh operation.
  "RequestUpdateOperation.requestId": "preserve",
};

export type ResetSummary = {
  requestsRemoved: number;
  participationsRemoved: number;
  fulfillmentsRemoved: number;
  placementEvidenceRemoved: number;
  pushDeliveriesRemoved: number;
  sendLogsRemoved: number;
  manifestEntriesRemoved: number;
  reservationLocksCleared: number;
};

/**
 * Removes every Request in the (already verified) environment and the records
 * owned by those Requests, in one transaction. Dependent rows are matched by the
 * ids of the Requests removed here, never by content, so a row that points at
 * some other (or already-gone) Request is left alone.
 *
 * Preserved by construction (never touched): Participant identity (only the two
 * lock fields below, and only when they point at a removed Request),
 * ParticipantVerification, RequestOperation, RequestUpdateOperation,
 * RequestOperationAuthority,
 * Installation, Subscriber, System.
 */
export async function resetEnvironment(): Promise<ResetSummary> {
  await assertMongoTransactionsSupported(mongoose.connection).catch(() => {
    throw new SeedSafetyError(
      "Normal reset requires a replica-set MongoDB so the reset commits atomically."
    );
  });
  const summary: ResetSummary = {
    requestsRemoved: 0,
    participationsRemoved: 0,
    fulfillmentsRemoved: 0,
    placementEvidenceRemoved: 0,
    pushDeliveriesRemoved: 0,
    sendLogsRemoved: 0,
    manifestEntriesRemoved: 0,
    reservationLocksCleared: 0,
  };
  const session = await mongoose.startSession();
  try {
    await session.withTransaction(async () => {
      const ids = (
        await MealRequest.collection
          .find({}, { projection: { _id: 1 }, session })
          .toArray()
      ).map((document) => document._id as Types.ObjectId);
      // `withTransaction` can retry the callback; each attempt starts clean.
      Object.assign(summary, {
        requestsRemoved: 0,
        participationsRemoved: 0,
        fulfillmentsRemoved: 0,
        placementEvidenceRemoved: 0,
        pushDeliveriesRemoved: 0,
        sendLogsRemoved: 0,
        manifestEntriesRemoved: 0,
        reservationLocksCleared: 0,
      });
      if (ids.length === 0) return;

      // Only a lock that points at a Request this reset removes, and only the
      // two lock fields (native update: no `updatedAt` bump either).
      summary.reservationLocksCleared = (
        await Participant.collection.updateMany(
          { activeReservationRequestId: { $in: ids } },
          {
            $set: {
              activeReservationRequestId: null,
              activeReservationClaimExpiresAt: null,
            },
          },
          { session }
        )
      ).modifiedCount;

      const byRequest = { requestId: { $in: ids } };
      summary.participationsRemoved = (
        await RequestParticipation.collection.deleteMany(byRequest, { session })
      ).deletedCount;
      summary.fulfillmentsRemoved = (
        await Fulfillment.collection.deleteMany(byRequest, { session })
      ).deletedCount;
      summary.placementEvidenceRemoved = (
        await PlacementEvidence.collection.deleteMany(byRequest, { session })
      ).deletedCount;
      summary.pushDeliveriesRemoved = (
        await PushDelivery.collection.deleteMany(byRequest, { session })
      ).deletedCount;
      summary.sendLogsRemoved = (
        await SendLog.collection.deleteMany(byRequest, { session })
      ).deletedCount;

      // Manifest rows record Request ids per owner: drop the removed ids, and
      // the row itself once nothing it recorded remains.
      const removed = new Set(ids.map(String));
      const manifest = mongoose.connection.collection(OWNED_MANIFEST_COLLECTION);
      const entries = await manifest
        .find({ requestIds: { $in: ids } } as never, { session })
        .toArray();
      for (const entry of entries) {
        const remaining = (entry.requestIds as unknown[]).filter(
          (id) => !removed.has(String(id))
        );
        if (remaining.length === 0) {
          await manifest.deleteOne({ _id: entry._id } as never, { session });
          summary.manifestEntriesRemoved += 1;
        } else {
          await manifest.updateOne(
            { _id: entry._id } as never,
            { $set: { requestIds: remaining } },
            { session }
          );
        }
      }

      summary.requestsRemoved = (
        await MealRequest.collection.deleteMany({ _id: { $in: ids } }, { session })
      ).deletedCount;
    });
  } finally {
    await session.endSession();
  }
  return summary;
}

/* =============================== scenario presets =============================== */

export type ScenarioPresetName =
  | "clean"
  | "helper-board"
  | "future-later"
  | "requester-below-quota"
  | "requester-quota-boundary";

type PresetDefinition = {
  description: string;
  /** Requests owned by the verified requester Participant (counts toward quota). */
  ownedAsapCount: number;
  /** Unowned needs-help fixture indexes (see `buildNeedsHelpFixtureDocument`). */
  unownedIndexes: readonly number[];
};

// Smallest useful catalog. Needs-help indexes 0-4 are ASAP, two currently
// visible Later, ASAP-with-estimate and Dining-Dollars-only; index 5 is the one
// future Later request, which helpers must not see yet. Nothing here fabricates
// ambiguous D1/D2, fulfillment, placed-order, blocking or moderation state.
export const SCENARIO_PRESETS: Readonly<Record<ScenarioPresetName, PresetDefinition>> = {
  clean: {
    description: "Zero Requests (a reset and nothing else).",
    ownedAsapCount: 0,
    unownedIndexes: [],
  },
  "helper-board": {
    description:
      "Five unowned helper-visible Requests: ASAP, two currently visible Later, ASAP with estimate, Dining Dollars only.",
    ownedAsapCount: 0,
    unownedIndexes: [0, 1, 2, 3, 4],
  },
  "future-later": {
    description: "One unowned future Later Request, invisible to helpers until its start.",
    ownedAsapCount: 0,
    unownedIndexes: [5],
  },
  "requester-below-quota": {
    description:
      "One current-day ASAP Request owned by the verified requester (QA_REQUESTER_EMAIL).",
    ownedAsapCount: 1,
    unownedIndexes: [],
  },
  "requester-quota-boundary": {
    description:
      "Two current-day ASAP Requests owned by the verified requester, so their next real app submission is the third of the day.",
    ownedAsapCount: 2,
    unownedIndexes: [],
  },
};

export function parseScenarioPresets(names: readonly string[]): ScenarioPresetName[] {
  if (names.length === 0) {
    throw new SeedSafetyError(
      `Name at least one preset: ${Object.keys(SCENARIO_PRESETS).join(", ")}.`
    );
  }
  const presets: ScenarioPresetName[] = [];
  for (const name of names) {
    if (!Object.prototype.hasOwnProperty.call(SCENARIO_PRESETS, name)) {
      throw new SeedSafetyError(
        `Unknown preset. Available: ${Object.keys(SCENARIO_PRESETS).join(", ")}.`
      );
    }
    if (presets.includes(name as ScenarioPresetName)) {
      throw new SeedSafetyError("A preset can be named only once per scenario.");
    }
    presets.push(name as ScenarioPresetName);
  }
  const owning = presets.filter((name) => SCENARIO_PRESETS[name].ownedAsapCount > 0);
  if (owning.length > 1) {
    throw new SeedSafetyError(
      "Name at most one requester-owned preset; combining them would change the requester's quota count."
    );
  }
  return presets;
}

export function presetNeedsRequester(presets: readonly ScenarioPresetName[]): boolean {
  return presets.some((name) => SCENARIO_PRESETS[name].ownedAsapCount > 0);
}

export function normalizeRequesterEmail(email: string | undefined): string {
  const trimmed = email?.trim();
  if (!trimmed) {
    throw new SeedSafetyError(
      "QA_REQUESTER_EMAIL is required for requester-owned presets."
    );
  }
  return trimmed.toLowerCase();
}

/** The Request documents a set of presets inserts. Pure, so it is unit-testable. */
export function buildScenarioDocuments(
  presets: readonly ScenarioPresetName[],
  requester: { email: string; participantId: Types.ObjectId } | null,
  now: Date
) {
  const owned: ReturnType<typeof buildOwnedFixtureDocument>[] = [];
  const unowned: ReturnType<typeof buildNeedsHelpFixtureDocument>[] = [];
  for (const name of presets) {
    const definition = SCENARIO_PRESETS[name];
    for (const index of definition.unownedIndexes) {
      unowned.push(buildNeedsHelpFixtureDocument(index, now));
    }
    for (let index = 0; index < definition.ownedAsapCount; index += 1) {
      if (!requester) {
        throw new SeedSafetyError("A verified requester is required for this preset.");
      }
      owned.push(
        buildOwnedFixtureDocument(
          index,
          requester.email,
          requester.participantId,
          now,
          undefined,
          "asap"
        )
      );
    }
  }
  return { owned, unowned };
}

type PreparedScenario = {
  now: Date;
  owned: ReturnType<typeof buildOwnedFixtureDocument>[];
  unowned: ReturnType<typeof buildNeedsHelpFixtureDocument>[];
};

/**
 * Builds and schema-validates every preset document without touching the
 * database, so invalid preset data fails before the reset removes anything.
 */
async function prepareScenario(
  presets: readonly ScenarioPresetName[],
  requester: { email: string; participantId: Types.ObjectId } | null
): Promise<PreparedScenario> {
  const now = new Date();
  const { owned, unowned } = buildScenarioDocuments(presets, requester, now);
  // Current-schema validation of every document before the first write.
  for (const document of [...owned, ...unowned]) {
    await new MealRequest(document).validate();
  }
  return { now, owned, unowned };
}

async function loadScenario(
  prepared: PreparedScenario,
  requester: { email: string; participantId: Types.ObjectId } | null
) {
  const { now, owned, unowned } = prepared;
  if (owned.length > 0 && requester) {
    // Recorded before inserting (like `seed-owned`) so the existing narrow
    // fixture cleanup can still find these Requests.
    await mongoose.connection.collection(OWNED_MANIFEST_COLLECTION).updateOne(
      { _id: requester.participantId } as never,
      {
        $addToSet: { requestIds: { $each: owned.map((document) => document._id) } },
        $set: { seededAt: now },
      },
      { upsert: true }
    );
  }
  const documents = [...owned, ...unowned];
  if (documents.length > 0) await MealRequest.insertMany(documents);
  return { owned: owned.length, unowned: unowned.length };
}

/* ================================ full teardown ================================ */

export function assertDropConfirmation(
  config: QaEnvironmentConfig,
  confirmation: string | undefined
): void {
  if (confirmation !== config.database) {
    throw new SeedSafetyError(
      "Full teardown requires --confirm-database with this environment's exact database name."
    );
  }
}

/* ================================== commands ================================== */

const COLLECTION_COUNTS = [
  ["requests", MealRequest],
  ["requestParticipations", RequestParticipation],
  ["fulfillments", Fulfillment],
  ["placementEvidence", PlacementEvidence],
  ["pushDeliveries", PushDelivery],
  ["sendLogs", SendLog],
  ["participants", Participant],
  ["participantVerifications", ParticipantVerification],
  ["requestOperations", RequestOperation],
  ["requestUpdateOperations", RequestUpdateOperation],
  ["requestOperationAuthorities", RequestOperationAuthority],
  ["installations", Installation],
  ["subscribers", Subscriber],
  ["systemRecords", System],
] as const;

async function printStatus(config: QaEnvironmentConfig, marker: MarkerState) {
  console.log(`environment: ${config.slug}`);
  console.log(`database name: ${config.database}`);
  console.log(`environment marker: ${marker}`);
  console.log(`backend base URL: ${qaBackendBaseUrl(config)}`);
  console.log(`mail sink port: ${config.mailSinkPort}`);
  for (const [label, model] of COLLECTION_COUNTS) {
    console.log(`${label}: ${await model.collection.countDocuments({})}`);
  }
  console.log(
    `owned-fixture manifest entries: ${await mongoose.connection
      .collection(OWNED_MANIFEST_COLLECTION)
      .countDocuments({})}`
  );
}

function printResetSummary(config: QaEnvironmentConfig, summary: ResetSummary) {
  console.log(`environment: ${config.slug}`);
  console.log(`database name: ${config.database}`);
  console.log(`requests removed: ${summary.requestsRemoved}`);
  console.log(`request participations removed: ${summary.participationsRemoved}`);
  console.log(`fulfillments removed: ${summary.fulfillmentsRemoved}`);
  console.log(`placement evidence removed: ${summary.placementEvidenceRemoved}`);
  console.log(`push deliveries removed: ${summary.pushDeliveriesRemoved}`);
  console.log(`send logs removed: ${summary.sendLogsRemoved}`);
  console.log(`fixture manifest entries removed: ${summary.manifestEntriesRemoved}`);
  console.log(`participant reservation locks cleared: ${summary.reservationLocksCleared}`);
  console.log(
    "preserved: participants, verification challenges, request-operation ledger and authority, installations, subscribers, system records."
  );
  console.log(
    "A request-create that was still pending in an app may now reconcile as expired/unrecoverable; its operation identity is never reusable."
  );
}

const USAGE =
  "Usage: tsx scripts/qa-environment.ts <init|status|reset|scenario <preset>...|drop --confirm-database <name>>";

/**
 * Entry point shared by the CLI and the tests. Configuration comes only from
 * `environment.QA_ENV_FILE`; `MONGO_URI` and `.env` play no part.
 */
export async function runQaEnvironmentTool(
  args: readonly string[],
  environment: QaToolEnvironment = process.env
): Promise<void> {
  const [command, ...rest] = args;
  const noExtraArguments = () => {
    if (rest.length > 0) throw new SeedSafetyError(USAGE);
  };

  // Everything that can fail without a database fails before connecting.
  if (
    command !== "init" &&
    command !== "status" &&
    command !== "reset" &&
    command !== "scenario" &&
    command !== "drop"
  ) {
    throw new SeedSafetyError(USAGE);
  }
  const config = loadQaEnvironmentConfig(environment.QA_ENV_FILE);

  if (command === "status") {
    noExtraArguments();
    await withEnvironment(config, "marker-optional", (marker) =>
      inPhase("environment verification", () => printStatus(config, marker))
    );
    return;
  }

  assertLocalQaOptIn(environment);

  if (command === "init") {
    noExtraArguments();
    await withEnvironment(config, "marker-optional", async (marker) => {
      if (marker === "absent") {
        await inPhase("environment verification", () =>
          markerCollection().insertOne({
            _id: ENVIRONMENT_MARKER_ID,
            slug: config.slug,
            database: config.database,
            initializedAt: new Date(),
          } as never)
        );
      }
      console.log(`environment: ${config.slug}`);
      console.log(`database name: ${config.database}`);
      console.log(
        marker === "absent"
          ? "environment marker created."
          : "environment marker already present and matching."
      );
    });
    return;
  }

  if (command === "reset") {
    noExtraArguments();
    await withEnvironment(config, "marker-required", async () => {
      const summary = await inPhase("environment reset", resetEnvironment);
      printResetSummary(config, summary);
    });
    return;
  }

  if (command === "scenario") {
    const presets = parseScenarioPresets(rest);
    const requesterEmail = presetNeedsRequester(presets)
      ? normalizeRequesterEmail(environment.QA_REQUESTER_EMAIL)
      : null;
    await withEnvironment(config, "marker-required", async () => {
      // Resolved before the reset, so a missing verified requester fails with
      // nothing removed. This only looks the Participant up; it never creates
      // identity.
      const requester = requesterEmail
        ? {
            email: requesterEmail,
            participantId: await inPhase("participant lookup", () =>
              findOwnerParticipantId(requesterEmail, "QA_REQUESTER_EMAIL")
            ),
          }
        : null;
      // Documents are built and validated before the reset, so invalid
      // preset data fails with nothing removed.
      const prepared = await inPhase("scenario load", () =>
        prepareScenario(presets, requester)
      );
      const summary = await inPhase("environment reset", resetEnvironment);
      printResetSummary(config, summary);
      const loaded = await inPhase("scenario load", () =>
        loadScenario(prepared, requester)
      );
      console.log(`presets loaded: ${presets.join(", ")}`);
      console.log(`requester-owned requests inserted: ${loaded.owned}`);
      console.log(`unowned requests inserted: ${loaded.unowned}`);
    });
    return;
  }

  // drop
  const confirmation =
    rest.length === 2 && rest[0] === "--confirm-database" ? rest[1] : undefined;
  assertDropConfirmation(config, confirmation);
  await withEnvironment(config, "marker-required", async () => {
    await inPhase("environment teardown", async () => {
      await mongoose.connection.db!.dropDatabase();
    });
    console.log(`environment: ${config.slug}`);
    console.log(`database name: ${config.database}`);
    console.log("database dropped: participants, verification challenges, requests, request-operation ledger and authority, and every other record in this environment are gone.");
    console.log(
      "Existing simulator participant credentials for this environment will no longer validate; verify through the normal flow again."
    );
    console.log(
      "Restart this environment's backend so it re-establishes its indexes and operation authority, then run `init` again."
    );
  });
}

const entryPath = process.argv[1];
if (entryPath && import.meta.url === pathToFileURL(entryPath).href) {
  try {
    // Deliberately no `dotenv`: a private `.env` must never be an input here.
    await runQaEnvironmentTool(process.argv.slice(2));
  } catch (error) {
    const message =
      error instanceof SeedSafetyError || error instanceof SeedOperationError
        ? error.message
        : "QA environment operation failed; nothing sensitive was printed.";
    console.error(message);
    process.exitCode = 1;
  }
}
