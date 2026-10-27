import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import cron from "node-cron";
import { afterEach, describe, expect, it, vi } from "vitest";
import { RETENTION_SWEEP_CRON } from "./moderationConstants.js";
import { scheduleModerationRetentionSweep } from "./moderationRetentionSweep.js";

/**
 * W4-U1.2 Checkpoint 1 is a dormant foundation: no accepted hot path reads or
 * writes it. Like the other startup-wiring assertions in this repository, this
 * reads source as text, because `app.ts` connects and listens at module scope.
 */
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative: string) => readFileSync(path.join(root, relative), "utf8");
/** Source with comments removed, so prose that names a flag is not a read of it. */
const code = (relative: string) =>
  read(relative)
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "");

const FOUNDATION_MODULES = [
  "models/moderation.ts",
  "src/moderationAudit.ts",
  "src/moderationClocks.ts",
  "src/moderationConstants.ts",
  "src/moderationHolds.ts",
  "src/moderationRecords.ts",
  "src/moderationRetention.ts",
  "src/moderationRetentionSweep.ts",
  "src/reportRequestSnapshot.ts",
  "src/reportSubmissionLedger.ts",
  "src/safetyIdentity.ts",
  "src/safetyIdentityKeyring.ts",
];

function productionSources(directory: string): string[] {
  return readdirSync(path.join(root, directory), { withFileTypes: true }).flatMap((entry) => {
    const relative = path.join(directory, entry.name);
    if (entry.isDirectory()) return entry.name === "client" ? [] : productionSources(relative);
    if (!entry.name.endsWith(".ts") || /\.test\.ts$/.test(entry.name)) return [];
    return [relative];
  });
}

const FOUNDATION_IMPORT =
  /from\s+"(?:\.\.?\/)+(?:models\/moderation|src\/(?:moderation\w*|safetyIdentity\w*|reportSubmissionLedger|reportRequestSnapshot))\.js"|from\s+"\.\/(?:moderation\w*|safetyIdentity\w*|reportSubmissionLedger|reportRequestSnapshot)\.js"/;

// Checkpoint 2 (boundary contract EO) is the one accepted wiring of the
// foundation into hot paths, and only through `moderationEnforcement.ts`.
const ENFORCEMENT_CONSUMERS = [
  "src/moderationEnforcement.ts",
  "src/claimRoute.ts",
  "src/createRequestRoute.ts",
  "src/fulfillmentRoute.ts",
  "src/reservationRoute.ts",
  "src/pushEligibility.ts",
];

const CP3_CONSUMERS = [
  "src/messagingLifecycle.ts",
  "src/moderationRoutes.ts",
  "src/moderatorAuth.ts",
  "src/moderatorSecurity.ts",
  "src/participantBlockRoute.ts",
  "src/participantVerification.ts",
  "src/reportAlerts.ts",
  "src/reportAuthorization.ts",
  "src/reportRoutes.ts",
  "src/retentionAlertDelivery.ts",
];

// CP4's R5 integration consumes the same enforcement gate for requester
// Edit/Withdraw; it does not read moderation records directly.
const R5_INTEGRATION_CONSUMERS = ["src/requestUpdateRoute.ts"];

// P2 Checkpoint 8's single accepted exception (the "P2 fixed mechanism"):
// final irreversible deletion reads only the ordinary Participant's own
// `safetyIdentityRef` and calls U1.2's confirm-only `confirmSafetyIdentity`,
// inside its own transaction. No other P2 path reads moderation state.
const P2_COMPLETION_CONSUMERS = ["src/participantDeletionCompletion.ts"];

describe("the moderation foundation is consumed only by its authorized paths", () => {
  it("is imported only by its own modules and the authorized enforcement/reporting paths", () => {
    const importers = [...productionSources("src"), ...productionSources("models"), ...productionSources("scripts")]
      .map((file) => file.split(path.sep).join("/"))
      .filter((file) => !FOUNDATION_MODULES.includes(file))
      .filter((file) => FOUNDATION_IMPORT.test(read(file)));
    expect(importers.sort()).toEqual(
      [
        ...ENFORCEMENT_CONSUMERS,
        ...CP3_CONSUMERS,
        ...R5_INTEGRATION_CONSUMERS,
        ...P2_COMPLETION_CONSUMERS,
      ].sort()
    );
  });

  it("only the enforcement module reaches the CP1 records; hot paths import enforcement alone", () => {
    for (const file of [
      ...ENFORCEMENT_CONSUMERS,
      ...R5_INTEGRATION_CONSUMERS,
    ].filter((f) => f !== "src/moderationEnforcement.ts")) {
      const imports = read(file).match(/from\s+"\.\/(?:moderation\w*|safetyIdentity\w*)\.js"/g) ?? [];
      expect(imports.length, file).toBeGreaterThan(0);
      expect(new Set(imports), file).toEqual(new Set(['from "./moderationEnforcement.js"']));
    }
  });

  it("keeps moderation state private on the Participant and Request models", () => {
    const db = read("models/db.ts");
    expect(db).toMatch(/safetyIdentityRef: \{ type: Schema\.Types\.ObjectId, ref: "SafetyIdentity", select: false \}/);
    expect(db).toMatch(/suspended: \{ type: Boolean, select: false \}/);
    expect(db).toMatch(/moderationUnavailable: \{ type: Boolean, select: false \}/);
    expect(db).toMatch(/reservationLapseHold: \{ type: Boolean, select: false \}/);
    expect(db).not.toMatch(/from\s+"\.\/moderation/);
  });

  it("reads no credential namespace, pause flag or cron flag", () => {
    for (const file of FOUNDATION_MODULES) {
      const source = code(file);
      expect(source, file).not.toMatch(/PUBLIC_ACTIONS_PAUSED|isPublicActionsPaused|publicActionsPause/);
      expect(source, file).not.toMatch(/process\.env\.CRON_ENABLED|CRON_ENABLED\s*===/);
      expect(source, file).not.toMatch(
        /from\s+"\.\/(participantCredentials|claimToken|unsubscribeCredential|installationCredential)\.js"/
      );
      // The existing single-reader guards forbid even naming those secrets.
      expect(source, file).not.toMatch(
        /PARTICIPANT_SIGNING_SECRET|CLAIM_TOKEN_HMAC_SECRET|UNSUBSCRIBE_SIGNING_SECRET/
      );
    }
  });

  it("never logs a value: only error classes and counts", () => {
    for (const file of FOUNDATION_MODULES) {
      const lines = read(file)
        .split("\n")
        .filter((line) => /console\.(log|error|warn|info)/.test(line));
      for (const line of lines) {
        expect(line, `${file}: ${line}`).not.toMatch(/error\.message|\$\{error\}|, error\)|, err\)/);
      }
    }
  });
});

describe("app.ts registration", () => {
  const app = read("app.ts");

  it("establishes the moderation indexes exactly once, after the other index guarantees", () => {
    expect(app.match(/await establishModerationIndexes\(\);/g)).toHaveLength(1);
    const established = app.indexOf("await establishModerationIndexes();");
    expect(established).toBeGreaterThan(app.indexOf("await ParticipantBlock.createIndexes();"));
    expect(established).toBeLessThan(app.indexOf("app.listen("));
  });

  it("registers the retention sweep exactly once, at top level, outside CRON_ENABLED and the digest block", () => {
    expect(app.match(/scheduleModerationRetentionSweep\(\);/g)).toHaveLength(1);
    const registration = app.indexOf("scheduleModerationRetentionSweep();");
    expect(registration).toBeGreaterThan(app.indexOf("[cron] disabled"));
    const digestStart = app.indexOf('cron.schedule("5 * * * *"');
    expect(registration).toBeGreaterThan(app.indexOf('cron.schedule("0 3 * * *"', digestStart));
    // Unindented: not nested in the `if (process.env.CRON_ENABLED === ...)` block.
    expect(app.slice(app.lastIndexOf("\n", registration) + 1, registration)).toBe("");
  });

  it("schedules the sweep only after the database is connected and the moderation indexes exist (F6)", () => {
    const registration = app.indexOf("scheduleModerationRetentionSweep();");
    const connected = app.indexOf("await mongoose.connect(MONGO_URI, mongoOptions.options);");
    const transactionsChecked = app.indexOf("await assertMongoTransactionsSupported(");
    const established = app.indexOf("await establishModerationIndexes();");

    expect(connected).toBeGreaterThan(-1);
    expect(registration).toBeGreaterThan(connected);
    expect(registration).toBeGreaterThan(transactionsChecked);
    expect(registration).toBeGreaterThan(established);
    expect(registration).toBeLessThan(app.indexOf("app.listen("));
    // No other statement in app.ts schedules it, and it is not wrapped in a try
    // that could swallow a failed index build.
    expect(app.slice(established, registration)).not.toMatch(/try\s*\{|catch\s*\(/);
  });

  it("does not let a failed index build reach the scheduler: the awaited call rejects startup", () => {
    expect(app).toMatch(/^await establishModerationIndexes\(\);$/m);
  });

  it("adds only those two imports and two calls", () => {
    expect(app.match(/moderation/gi)?.length).toBeLessThanOrEqual(24);
    expect(app).toMatch(/import \{ establishModerationIndexes \} from "\.\/models\/moderation\.js";/);
    expect(app).toMatch(
      /import \{ scheduleModerationRetentionSweep \} from "\.\/src\/moderationRetentionSweep\.js";/
    );
    expect(app).toMatch(/registerReportRoutes\(app\);/);
    expect(app).toMatch(/registerModerationRoutes\(app\);/);
    expect(app.indexOf("registerReportRoutes(app);")).toBeLessThan(app.indexOf("app.use(express.json"));
    expect(app.indexOf("registerModerationRoutes(app);")).toBeLessThan(app.indexOf("app.use(express.json"));
  });
});

describe("scheduling", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  it("hands the environment-gated scheduler the hourly retention sweep", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SCHEDULER_ENABLED", "true");
    vi.stubEnv("CRON_ENABLED", "false");
    const schedule = vi.spyOn(cron, "schedule").mockImplementation(() => undefined as never);
    scheduleModerationRetentionSweep();
    expect(schedule).toHaveBeenCalledWith(
      RETENTION_SWEEP_CRON,
      expect.any(Function),
      { noOverlap: true }
    );
    expect(RETENTION_SWEEP_CRON).toBe("17 * * * *");
  });
});
