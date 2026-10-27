import { spawn, type ChildProcess } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { once } from "node:events";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import {
  APNS_AUTH_KEY_P8_ENV,
  APNS_BUNDLE_ID_ENV,
  APNS_KEY_ID_ENV,
  APNS_TEAM_ID_ENV,
} from "./apnsConfig.js";
import {
  MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES,
  PARTICIPANT_SIGNING_SECRET_ENV,
} from "./participantCredentials.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES,
  UNSUBSCRIBE_SIGNING_SECRET_ENV,
} from "./unsubscribeCredential.js";
import {
  BLOCK_SAFETY_HMAC_KEYRING_ENV,
  PARTICIPANT_DELETION_SIGNING_SECRET_ENV,
  PARTICIPATION_HMAC_KEYRING_ENV,
} from "./participantIdentityKeys.js";

/**
 * The activation prerequisite: an unpaused process must not be able to start
 * without a signing secret for the unsubscribe links its emails will carry.
 *
 * Two kinds of assertion, because neither alone is enough. The wiring group
 * reads `app.ts` as text — it connects to MongoDB and listens at module scope,
 * so it cannot be imported — and pins where the check sits relative to the
 * Express app, the route registrations, the database connection, and `listen`.
 * The startup group then runs the real file in a child process and observes
 * what a deployment would actually do, which is the only way to prove that the
 * refusal happens before any of that work rather than merely above it in the
 * source.
 *
 * `unsubscribeCredential.test.ts` owns the validation rule itself.
 */
const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
const appPath = fileURLToPath(new URL("../app.ts", import.meta.url));
const appSource = readFileSync(appPath, "utf8");

const ACTIVATION_CALL = "assertUnsubscribeSigningSecretForActivation()";
const APNS_ACTIVATION_CALL = "assertApnsConfigurationForActivation()";
const PARTICIPANT_ACTIVATION_CALL =
  "assertParticipantSigningSecretForActivation()";
const IDENTITY_ACTIVATION_CALL =
  "assertParticipantIdentityCredentialsForActivation()";

const VALID_IDENTITY_CREDENTIALS: Record<string, string> = {
  [PARTICIPATION_HMAC_KEYRING_ENV]: JSON.stringify({
    currentVersion: 1,
    keys: { "1": Buffer.alloc(32, 0x11).toString("base64") },
  }),
  [BLOCK_SAFETY_HMAC_KEYRING_ENV]: JSON.stringify({
    currentVersion: 1,
    keys: { "1": Buffer.alloc(32, 0x22).toString("base64") },
  }),
  [PARTICIPANT_DELETION_SIGNING_SECRET_ENV]:
    "participant-deletion-signing-fixture-with-independent-key-material",
};

/**
 * Every production source a deployment secret's name could reach.
 * `src/client` is listed on its own: browser bundles are built from it, and a
 * server secret's name has no business reaching one.
 */
function productionSources(): (readonly [string, string])[] {
  return ["src", "src/client", "models", "scripts"].flatMap((directory) =>
    readdirSync(new URL(`../${directory}`, import.meta.url), {
      withFileTypes: true,
    })
      .filter(
        (entry) =>
          entry.isFile() &&
          /\.(ts|mjs)$/.test(entry.name) &&
          !entry.name.endsWith(".test.ts")
      )
      .map(
        (entry) =>
          [
            `${directory}/${entry.name}`,
            readFileSync(
              new URL(`../${directory}/${entry.name}`, import.meta.url),
              "utf8"
            ),
          ] as const
      )
  );
}

function indexIn(needle: string): number {
  const index = appSource.indexOf(needle);
  expect(index, `app.ts does not contain ${needle}`).toBeGreaterThan(-1);
  return index;
}

describe("unsubscribe signing secret activation wiring", () => {
  it("validates from the existing startup-validation block", () => {
    // One validation architecture, not a second one: the claim-token secret is
    // already checked here, and both refusals log a message and exit.
    const claimTokenCheck = indexIn("readClaimTokenHmacSecret();");
    const activationCheck = indexIn(ACTIVATION_CALL);
    const resendClient = indexIn("const resend = new Resend(isReviewRuntime() ? \"review-disabled\" : resendApiKey);");

    expect(activationCheck).toBeGreaterThan(claimTokenCheck);
    expect(activationCheck).toBeLessThan(resendClient);
    expect(appSource).toContain("process.exit(1)");
  });

  describe("participant identity credential activation wiring", () => {
    it("validates once before app setup and outside review-only runtime", () => {
      const activationCheck = indexIn(IDENTITY_ACTIVATION_CALL);

      expect(appSource.match(
        /assertParticipantIdentityCredentialsForActivation\(\)/g
      )).toHaveLength(1);
      expect(activationCheck).toBeLessThan(indexIn("const app = express();"));
      expect(activationCheck).toBeLessThan(
        indexIn("await mongoose.connect(MONGO_URI, mongoOptions.options);")
      );
      expect(appSource).toContain(
        'console.error("[config] participant identity credentials unavailable")'
      );
    });
  });

  it("is checked exactly once", () => {
    // A second call site is how two validation paths with different rules
    // start to drift apart.
    expect(
      appSource.match(/assertUnsubscribeSigningSecretForActivation\(/g)
    ).toHaveLength(1);
  });

  it("runs before the app, its routes, the database, and listening", () => {
    const activationCheck = indexIn(ACTIVATION_CALL);

    for (const later of [
      "const app = express();",
      "app.get(",
      "app.post(",
      "app.use(",
      "await mongoose.connect(MONGO_URI, mongoOptions.options);",
      "await Fulfillment.createIndexes();",
      "app.listen(",
    ]) {
      expect(
        activationCheck,
        `the activation check must run before ${later}`
      ).toBeLessThan(indexIn(later));
    }
  });

  it("runs before the first point at which the process can yield", () => {
    // The scheduled digest is registered at the top of the file, above this
    // check. Registration is not delivery: a cron callback needs the event
    // loop, and module evaluation up to this point is synchronous, so the
    // process exits before any scheduled job can run. This pins that property
    // rather than assuming it.
    const activationCheck = indexIn(ACTIVATION_CALL);
    // Module-level awaits only: the ones inside the scheduled callbacks are
    // indented, and they cannot run before the module finishes evaluating.
    const firstTopLevelAwait = appSource.search(/^await\s/m);

    expect(firstTopLevelAwait).toBeGreaterThan(-1);
    expect(activationCheck).toBeLessThan(firstTopLevelAwait);
  });

  it("logs the reported message and no configured value", () => {
    const activationCheck = indexIn(ACTIVATION_CALL);
    // The catch block this call owns, ending at the first unindented brace
    // after it, rather than a fixed-width window that would run into the
    // unrelated configuration reads below.
    const blockEnd = appSource.indexOf("\n}\n", activationCheck);
    expect(blockEnd).toBeGreaterThan(activationCheck);
    const block = appSource.slice(activationCheck, blockEnd);

    expect(block).toContain("error.message");
    // Nothing may reach the log except the fixed message the validator built.
    expect(block).not.toContain("process.env");
    expect(block).not.toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
  });

  it("keeps one module able to read the secret", () => {
    // Every path capable of reading the variable, enumerated: a second reader
    // is how an inconsistent rule — or a silent substitution of another
    // secret — would appear.
    const sources = [["app.ts", appSource] as const, ...productionSources()];

    const readers = sources
      .filter(([, text]) => text.includes(UNSUBSCRIBE_SIGNING_SECRET_ENV))
      .map(([name]) => name);

    expect(readers).toEqual([
      "src/credentialLauncher.ts",
      "src/participantIdentityKeys.ts",
      "src/productionRuntimeConfig.ts",
      "src/unsubscribeCredential.ts",
    ]);
  });
});

describe("review runtime startup integration wiring", () => {
  it("registers the composed review boundary exactly once before shared routes", () => {
    expect(appSource.match(/registerReviewRuntimeIntegration\(app,\s*\{/g)).toHaveLength(1);
    expect(appSource.match(/registerReviewBoundary\(app/g)).toBeNull();
    expect(indexIn("registerReviewRuntimeIntegration(app, {"))
      .toBeGreaterThan(indexIn("app.use(helmet());"));
    expect(indexIn("registerReviewRuntimeIntegration(app, {"))
      .toBeLessThan(indexIn("app.use(express.json"));
  });

  it("awaits review initialization inside guarded startup after the ledger and before readiness/listen", () => {
    expect(appSource.match(/await reviewBoundary\.initialize\(\);/g)).toHaveLength(1);
    const initialization = indexIn("await reviewBoundary.initialize();");
    expect(indexIn("await establishRequestOperationLedger();")).toBeLessThan(initialization);
    expect(initialization).toBeLessThan(indexIn("runtimeReady = true;"));
    expect(initialization).toBeLessThan(indexIn("app.listen("));
    expect(appSource.slice(indexIn("let startupStage = \"Atlas connection\";"), initialization))
      .toContain("try {");
  });

  it("does not install a lifecycle binding or weaken the public-action pause", () => {
    const registration = appSource.slice(
      indexIn("registerReviewRuntimeIntegration(app, {"),
      indexIn("// If the app is running behind a proxy")
    );
    expect(registration).toContain("isRuntimeReady: () => runtimeReady");
    expect(registration).not.toContain("binding:");
    expect(appSource).not.toMatch(/process\.env\.PUBLIC_ACTIONS_PAUSED\s*=/);
    expect(appSource).toContain("pauseRequestAction");
  });
});

/**
 * The same activation architecture, for the APNs provider configuration that
 * helper new-request push delivery needs (Week 3 Day 6 Slice 6D). An
 * installation can already turn push on, and the accepted meaning of "push
 * alerts are on" is that this deployment is configured to submit through APNs,
 * so an unpaused process without provider configuration must not start.
 *
 * `apnsConfig.test.ts` owns the validation rule itself.
 */
describe("APNs provider configuration activation wiring", () => {
  it("validates from the same startup-validation block, after the signing secret", () => {
    const activationCheck = indexIn(ACTIVATION_CALL);
    const apnsCheck = indexIn(APNS_ACTIVATION_CALL);
    const resendClient = indexIn("const resend = new Resend(isReviewRuntime() ? \"review-disabled\" : resendApiKey);");

    expect(apnsCheck).toBeGreaterThan(activationCheck);
    expect(apnsCheck).toBeLessThan(resendClient);
  });

  it("is checked exactly once", () => {
    expect(
      appSource.match(/assertApnsConfigurationForActivation\(/g)
    ).toHaveLength(1);
  });

  it("runs before the app, its routes, the database, and listening", () => {
    const apnsCheck = indexIn(APNS_ACTIVATION_CALL);

    for (const later of [
      "const app = express();",
      "app.get(",
      "app.post(",
      "app.use(",
      "await mongoose.connect(MONGO_URI, mongoOptions.options);",
      "await PushDelivery.createIndexes();",
      "app.listen(",
    ]) {
      expect(
        apnsCheck,
        `the APNs activation check must run before ${later}`
      ).toBeLessThan(indexIn(later));
    }
    expect(apnsCheck).toBeLessThan(appSource.search(/^await\s/m));
  });

  it("logs the reported message and no configured value", () => {
    const apnsCheck = indexIn(APNS_ACTIVATION_CALL);
    const blockEnd = appSource.indexOf("\n}\n", apnsCheck);
    expect(blockEnd).toBeGreaterThan(apnsCheck);
    const block = appSource.slice(apnsCheck, blockEnd);

    expect(block).toContain("error.message");
    expect(block).not.toContain("process.env");
    for (const name of [
      APNS_TEAM_ID_ENV,
      APNS_KEY_ID_ENV,
      APNS_BUNDLE_ID_ENV,
      APNS_AUTH_KEY_P8_ENV,
    ]) {
      expect(block).not.toContain(name);
    }
  });

  it("keeps one module able to read the provider configuration", () => {
    // A second reader is how an inconsistent rule — or a silent substitution
    // of other key material — would appear.
    const readers = ["app.ts", ...productionSources()]
      .filter(([, text]) => text.includes(APNS_AUTH_KEY_P8_ENV))
      .map(([name]) => name);

    expect(readers).toEqual([
      "src/apnsConfig.ts",
      "src/credentialLauncher.ts",
      "src/productionRuntimeConfig.ts",
    ]);
  });

  it("creates the push deduplication index before listening", () => {
    // Two concurrent dispatches would otherwise both submit for the same
    // installation, and V1 has no retry path that could repair a duplicate.
    expect(indexIn("await PushDelivery.createIndexes();")).toBeLessThan(
      indexIn("app.listen(")
    );
  });
});

/**
 * The same activation architecture again, for the participant signing secret
 * W3-I1 introduces. Unpaused means requests can be created and claimed, and
 * both now require a participant credential this process must be able to sign
 * and verify — so a deployment without the secret has no usable participant
 * surface at all and must not start.
 *
 * `participantCredentials.test.ts` owns the validation rule itself.
 */
describe("participant signing secret activation wiring", () => {
  it("validates from the same startup-validation block, after the APNs check", () => {
    const apnsCheck = indexIn(APNS_ACTIVATION_CALL);
    const participantCheck = indexIn(PARTICIPANT_ACTIVATION_CALL);
    const resendClient = indexIn("const resend = new Resend(isReviewRuntime() ? \"review-disabled\" : resendApiKey);");

    expect(participantCheck).toBeGreaterThan(apnsCheck);
    expect(participantCheck).toBeLessThan(resendClient);
  });

  it("is checked exactly once", () => {
    expect(
      appSource.match(/assertParticipantSigningSecretForActivation\(/g)
    ).toHaveLength(1);
  });

  it("runs before the app, its routes, the database, and listening", () => {
    const participantCheck = indexIn(PARTICIPANT_ACTIVATION_CALL);

    for (const later of [
      "const app = express();",
      "app.get(",
      "app.post(",
      "app.use(",
      "await mongoose.connect(MONGO_URI, mongoOptions.options);",
      "await Participant.createIndexes();",
      "app.listen(",
    ]) {
      expect(
        participantCheck,
        `the participant activation check must run before ${later}`
      ).toBeLessThan(indexIn(later));
    }
    expect(participantCheck).toBeLessThan(appSource.search(/^await\s/m));
  });

  it("logs the reported message and no configured value", () => {
    const participantCheck = indexIn(PARTICIPANT_ACTIVATION_CALL);
    const blockEnd = appSource.indexOf("\n}\n", participantCheck);
    expect(blockEnd).toBeGreaterThan(participantCheck);
    const block = appSource.slice(participantCheck, blockEnd);

    expect(block).toContain("error.message");
    expect(block).not.toContain("process.env");
    expect(block).not.toContain(PARTICIPANT_SIGNING_SECRET_ENV);
  });

  it("keeps one module able to read the secret", () => {
    // A second reader is how an inconsistent rule — or a silent substitution of
    // one of the other credential namespaces — would appear. Participant
    // identity must not share key material with subscription confirmation,
    // unsubscribe links, installation credentials, or claim tokens.
    const readers = [["app.ts", appSource] as const, ...productionSources()]
      .filter(([, text]) => text.includes(PARTICIPANT_SIGNING_SECRET_ENV))
      .map(([name]) => name);

    expect(readers).toEqual([
      "src/credentialLauncher.ts",
      "src/participantCredentials.ts",
      "src/participantIdentityKeys.ts",
      "src/productionRuntimeConfig.ts",
    ]);
  });

  it("creates the participant uniqueness indexes before listening", () => {
    // Without them two concurrent verifications could create two Participant
    // rows for one address, and a resend could leave two live codes for one
    // inbox instead of superseding the first.
    for (const index of [
      "await Participant.createIndexes();",
      "await ParticipantDeletionOperation.createIndexes();",
      "await ParticipantVerification.createIndexes();",
    ]) {
      expect(indexIn(index)).toBeLessThan(indexIn("app.listen("));
    }
  });
});

/**
 * W4-D2: the request-operation identity index is the created-vs-NO-CREATE
 * one-winner primitive, so it — and the ledger authority identity clients
 * record — must be established after connecting and before listening.
 * `requestOperationStartup.mongo.test.ts` proves the same against a real
 * fresh database with auto-indexing disabled.
 */
describe("request-operation ledger startup barrier wiring", () => {
  const barrier = "await establishRequestOperationLedger();";

  it("is awaited exactly once, after connecting and before listening", () => {
    expect(appSource.split(barrier)).toHaveLength(2);
    expect(indexIn(barrier)).toBeGreaterThan(
      indexIn("await mongoose.connect(MONGO_URI, mongoOptions.options);")
    );
    expect(indexIn(barrier)).toBeLessThan(indexIn("app.listen("));
    // A module-level await, not one inside a callback that could run later.
    expect(appSource).toMatch(/^await establishRequestOperationLedger\(\);$/m);
  });
});

describe("QA-only loopback bind startup wiring", () => {
  it("validates the QA override before app setup and passes only the configured host", () => {
    const validation = indexIn("assertQaBindHostConfiguration();");

    expect(validation).toBeLessThan(indexIn("const app = express();"));
    expect(validation).toBeLessThan(indexIn("await mongoose.connect(MONGO_URI, mongoOptions.options);"));
    expect(validation).toBeLessThan(indexIn("app.listen("));
    expect(appSource).toContain(
      'const HOST = process.env.QA_BIND_HOST || process.env.HOST || "0.0.0.0";'
    );
    expect(appSource).toContain("app.listen(PORT, HOST, () => {");
  });
});

interface StartupResult {
  code: number | null;
  stderr: string;
  stdout: string;
}

/**
 * Children spawned by {@link startApp} that have not been observed exiting yet.
 *
 * A case normally learns its result from the child's own `exit`, so the entry
 * removes itself and this set stays empty. It exists for the paths where the
 * case stops waiting instead: a rejected spawn, a failed assertion on an
 * earlier line, or a Vitest timeout. A timeout in particular abandons the test
 * function without ever resuming it, so no `try`/`finally` inside the case can
 * run — the `afterEach` below is the only place an abandoned `app.ts` can still
 * be reaped, and it is deliberately the single cleanup mechanism so that
 * nothing races it.
 */
const liveStartupChildren = new Set<ChildProcess>();

/** Grace period before a child that ignored `SIGTERM` is killed outright. */
const TERMINATION_GRACE_MS = 2_000;

/**
 * Signals the whole process group led by one spawned child.
 *
 * `startApp` spawns detached, so the child leads a brand-new group containing
 * only itself and its own descendants. That matters because the child is
 * `tsx`, which runs an `esbuild` service of its own: signalling just the leader
 * would leave that grandchild reparented to `launchd`, which is the very leak
 * this cleanup exists to prevent. A negative pid reaches exactly this child's
 * subtree, so nothing else on the machine is reachable from here — not a
 * developer's own servers, and not another test's child.
 */
function signalStartupGroup(
  child: ChildProcess,
  signal: NodeJS.Signals
): void {
  if (child.pid === undefined) {
    return;
  }
  try {
    process.kill(-child.pid, signal);
  } catch {
    // ESRCH: the group has already gone, which is the outcome being asked for.
  }
}

/**
 * Stops one spawned `app.ts`, with its descendants, and waits for it to be
 * reaped.
 */
async function terminateStartupChild(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }

  // Registered before the signal: Node sets `exitCode` only as it emits
  // `exit`, so the check above guarantees the event is still to come.
  const exited = once(child, "exit");
  signalStartupGroup(child, "SIGTERM");

  const escalation = setTimeout(() => {
    signalStartupGroup(child, "SIGKILL");
  }, TERMINATION_GRACE_MS);
  escalation.unref();

  try {
    await exited;
  } finally {
    clearTimeout(escalation);
  }
}

afterEach(async () => {
  const abandoned = [...liveStartupChildren];
  liveStartupChildren.clear();

  for (const child of abandoned) {
    try {
      await terminateStartupChild(child);
    } catch (error) {
      // Reported, never rethrown: a cleanup problem must not become the
      // failure the report shows instead of the assertion that actually broke.
      console.warn(
        "[startup-validation] could not terminate a spawned app.ts:",
        error
      );
    }
  }
});

/**
 * Starts the real `app.ts` with an explicitly built environment.
 *
 * The environment is constructed rather than inherited, and `DOTENV_CONFIG_PATH`
 * names a file that does not exist, so a developer's local `.env` cannot supply
 * a secret a case means to withhold. The database URI points at a closed port
 * with a short server-selection timeout: a process that gets as far as
 * connecting fails there quickly, which is exactly the signal that it passed
 * validation.
 *
 * The child is tracked in {@link liveStartupChildren} for as long as it might
 * still be running, so a case that never reaches its `await` cannot leave a
 * real service process behind it.
 */
function startApp(
  environment: Record<string, string>
): Promise<StartupResult> {
  const child = spawn(process.execPath, ["--import", "tsx", appPath], {
    cwd: repositoryRoot,
    env: {
      DOTENV_CONFIG_PATH: "/nonexistent/commonplate-startup-test/.env",
      MONGO_URI:
        "mongodb://127.0.0.1:1/commonplate_startup_test?serverSelectionTimeoutMS=750",
      RESEND_API_KEY: "startup-test-key",
      CLAIM_TOKEN_HMAC_SECRET: "c".repeat(64),
      ...environment,
    },
    stdio: ["ignore", "pipe", "pipe"],
    // Its own process group, so cleanup can take the child's descendants with
    // it rather than orphaning them. See {@link signalStartupGroup}.
    detached: true,
  });
  liveStartupChildren.add(child);

  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    let settled = false;

    const onStdout = (chunk: unknown): void => {
      stdout += String(chunk);
    };
    const onStderr = (chunk: unknown): void => {
      stderr += String(chunk);
    };

    /** Detaches every listener once, so neither outcome can fire twice. */
    const settle = (outcome: () => void): void => {
      if (settled) {
        return;
      }
      settled = true;
      child.stdout?.removeListener("data", onStdout);
      child.stderr?.removeListener("data", onStderr);
      child.removeListener("error", onError);
      child.removeListener("exit", onExit);
      outcome();
    };

    function onError(error: Error): void {
      // The failure may have come from stdio rather than from spawning, in
      // which case the process is alive and still ours to stop. The `afterEach`
      // owns that, so the child stays tracked.
      settle(() => reject(error));
    }

    function onExit(code: number | null): void {
      liveStartupChildren.delete(child);
      settle(() => resolve({ code, stderr, stdout }));
    }

    child.stdout.on("data", onStdout);
    child.stderr.on("data", onStderr);
    child.once("error", onError);
    child.once("exit", onExit);
  });
}

const VALID_SECRET = "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES);
const SHORT_SECRET = "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES - 1);

/** Generated per run: no key material is ever committed to the repository. */
const { privateKey: apnsAuthKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

const VALID_APNS: Record<string, string> = {
  [APNS_TEAM_ID_ENV]: "ABCDE12345",
  [APNS_KEY_ID_ENV]: "KEY1234567",
  [APNS_BUNDLE_ID_ENV]: "org.commonplatenyu.CommonPlateios",
  [APNS_AUTH_KEY_P8_ENV]: apnsAuthKey,
};

const VALID_PARTICIPANT_SECRET = "p".repeat(
  MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES
);
const SHORT_PARTICIPANT_SECRET = "p".repeat(
  MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES - 1
);

/**
 * A process that reached `mongoose.connect` passed activation validation: the
 * connection is attempted after the check, after the Express app is built, and
 * after every route is registered.
 */
function reachedTheDatabase(result: StartupResult): boolean {
  return result.stderr.includes(
    "[startup] Atlas connection failed; process will not listen"
  );
}

describe("real startup with QA bind configuration", () => {
  it("rejects wildcard binding before connecting to MongoDB", async () => {
    const result = await startApp({ QA_BIND_HOST: "0.0.0.0" });

    expect(result.code).toBe(1);
    expect(result.stderr).toContain("QA_BIND_HOST must be exactly 127.0.0.1.");
    expect(reachedTheDatabase(result)).toBe(false);
  }, 30_000);

  it("rejects loopback binding outside the disposable QA runtime", async () => {
    const result = await startApp({ QA_BIND_HOST: "127.0.0.1" });

    expect(result.code).toBe(1);
    expect(result.stderr).toContain(
      "QA_BIND_HOST is restricted to the disposable local QA runtime."
    );
    expect(reachedTheDatabase(result)).toBe(false);
  }, 30_000);
});

describe("real startup with and without the signing secret", () => {
  it(
    "refuses production startup until the approved HTTPS origin is configured",
    async () => {
      const result = await startApp({
        NODE_ENV: "production",
        HOST: "127.0.0.1",
        PORT: "3000",
        SCHEDULER_ENABLED: "true",
        MONGO_URI:
          "mongodb://127.0.0.1:1/commonplate_production?serverSelectionTimeoutMS=750",
      });

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(
        "[config] Production BASE_URL must be configured"
      );
      expect(result.stderr).not.toContain("Atlas connection failed");
      expect(result.stdout).not.toContain("ready on");
    },
    30_000
  );

  it(
    "refuses to start unpaused with no secret",
    async () => {
      const result = await startApp({ [PUBLIC_ACTIONS_PAUSED_ENV]: "false" });

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(
        `Missing required environment variable: ${UNSUBSCRIBE_SIGNING_SECRET_ENV}`
      );
      // It never got as far as the database, so it never registered a usable
      // public-action surface or began listening either.
      expect(reachedTheDatabase(result)).toBe(false);
      expect(result.stdout).not.toContain("http://localhost");
    },
    30_000
  );

  it(
    "refuses to start unpaused with an empty secret",
    async () => {
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: "",
      });

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      expect(reachedTheDatabase(result)).toBe(false);
    },
    30_000
  );

  it(
    "refuses to start unpaused with fewer than 32 UTF-8 bytes",
    async () => {
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: SHORT_SECRET,
      });

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(
        `${UNSUBSCRIBE_SIGNING_SECRET_ENV} must contain at least ${MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES} UTF-8 bytes`
      );
      // The refused value itself must not reach the deployment log.
      expect(result.stderr).not.toContain(SHORT_SECRET);
      expect(result.stdout).not.toContain(SHORT_SECRET);
      expect(reachedTheDatabase(result)).toBe(false);
    },
    30_000
  );

  it(
    "starts unpaused with a valid secret",
    async () => {
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: VALID_SECRET,
        ...VALID_IDENTITY_CREDENTIALS,
        // Unpaused startup also requires APNs provider configuration and a
        // participant signing secret; each rule has its own group below.
        ...VALID_APNS,
        [PARTICIPANT_SIGNING_SECRET_ENV]: VALID_PARTICIPANT_SECRET,
      });

      expect(result.stderr).not.toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      // Past validation and into the database connection this environment
      // deliberately cannot satisfy.
      expect(reachedTheDatabase(result)).toBe(true);
      expect(result.stderr).not.toContain(VALID_SECRET);
      expect(result.stdout).not.toContain(VALID_SECRET);
    },
    30_000
  );

  it.each([
    ["with no secret", {}],
    [
      "with a valid secret",
      { [UNSUBSCRIBE_SIGNING_SECRET_ENV]: VALID_SECRET },
    ],
  ])(
    "starts while paused %s",
    async (_label, secret) => {
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
        ...secret,
      });

      expect(result.stderr).not.toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      expect(reachedTheDatabase(result)).toBe(true);
    },
    30_000
  );

  it(
    "starts while paused by default, with no pause variable set at all",
    async () => {
      // The repository's existing reading of the variable: absent is paused.
      // A local process serving unrelated functionality must not be asked for
      // a secret no paused path can use.
      const result = await startApp({});

      expect(result.stderr).not.toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      expect(reachedTheDatabase(result)).toBe(true);
    },
    30_000
  );
});

describe("real startup with and without APNs provider configuration", () => {
  function unpaused(overrides: Record<string, string> = {}) {
    return {
      [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      [UNSUBSCRIBE_SIGNING_SECRET_ENV]: VALID_SECRET,
      ...VALID_IDENTITY_CREDENTIALS,
      ...VALID_APNS,
      [PARTICIPANT_SIGNING_SECRET_ENV]: VALID_PARTICIPANT_SECRET,
      ...overrides,
    };
  }

  it.each([
    APNS_TEAM_ID_ENV,
    APNS_KEY_ID_ENV,
    APNS_BUNDLE_ID_ENV,
    APNS_AUTH_KEY_P8_ENV,
  ])(
    "refuses to start unpaused without %s",
    async (name) => {
      const result = await startApp(unpaused({ [name]: "" }));

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(name);
      // It never got as far as the database, so it never registered a usable
      // public-action surface or began listening either.
      expect(reachedTheDatabase(result)).toBe(false);
      expect(result.stdout).not.toContain("http://localhost");
    },
    30_000
  );

  it.each([
    [APNS_TEAM_ID_ENV, "TOO-SHORT"],
    [APNS_KEY_ID_ENV, "ELEVENCHARS"],
    [APNS_BUNDLE_ID_ENV, "not a bundle id"],
    [APNS_AUTH_KEY_P8_ENV, "-----BEGIN PRIVATE KEY-----\nnot-a-key\n"],
  ])(
    "refuses to start unpaused with a malformed %s",
    async (name, value) => {
      const result = await startApp(unpaused({ [name]: value }));

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(name);
      // The refused value itself must not reach the deployment log.
      expect(result.stderr).not.toContain(value);
      expect(result.stdout).not.toContain(value);
      expect(reachedTheDatabase(result)).toBe(false);
    },
    30_000
  );

  it(
    "starts unpaused with complete provider configuration and never logs the key",
    async () => {
      const result = await startApp(unpaused());

      expect(reachedTheDatabase(result)).toBe(true);
      for (const output of [result.stderr, result.stdout]) {
        expect(output).not.toContain(apnsAuthKey);
        expect(output).not.toContain("BEGIN PRIVATE KEY");
        expect(output).not.toContain(VALID_APNS[APNS_TEAM_ID_ENV]);
      }
    },
    30_000
  );

  it(
    "starts while paused with no APNs configuration at all",
    async () => {
      // A paused process reads none of the four variables, exactly like the
      // unsubscribe signing secret above.
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
      });

      expect(reachedTheDatabase(result)).toBe(true);
      for (const name of [
        APNS_TEAM_ID_ENV,
        APNS_KEY_ID_ENV,
        APNS_BUNDLE_ID_ENV,
        APNS_AUTH_KEY_P8_ENV,
      ]) {
        expect(result.stderr).not.toContain(name);
      }
    },
    30_000
  );
});

describe("real startup with and without the participant signing secret", () => {
  function unpaused(overrides: Record<string, string> = {}) {
    return {
      [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      [UNSUBSCRIBE_SIGNING_SECRET_ENV]: VALID_SECRET,
      ...VALID_IDENTITY_CREDENTIALS,
      ...VALID_APNS,
      [PARTICIPANT_SIGNING_SECRET_ENV]: VALID_PARTICIPANT_SECRET,
      ...overrides,
    };
  }

  it.each([
    ["no secret", ""],
    ["fewer than 32 UTF-8 bytes", SHORT_PARTICIPANT_SECRET],
  ])(
    "refuses to start unpaused with %s",
    async (_label, secret) => {
      const result = await startApp(
        unpaused({ [PARTICIPANT_SIGNING_SECRET_ENV]: secret })
      );

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(PARTICIPANT_SIGNING_SECRET_ENV);
      // It never got as far as the database, so it never registered a usable
      // participant surface or began listening either.
      expect(reachedTheDatabase(result)).toBe(false);
      expect(result.stdout).not.toContain("http://localhost");
      if (secret) {
        // The refused value itself must not reach the deployment log.
        expect(result.stderr).not.toContain(secret);
        expect(result.stdout).not.toContain(secret);
      }
    },
    30_000
  );

  it(
    "starts unpaused with a valid secret and never logs it",
    async () => {
      const result = await startApp(unpaused());

      expect(reachedTheDatabase(result)).toBe(true);
      expect(result.stderr).not.toContain(VALID_PARTICIPANT_SECRET);
      expect(result.stdout).not.toContain(VALID_PARTICIPANT_SECRET);
    },
    30_000
  );

  it(
    "starts while paused with no participant secret at all",
    async () => {
      // A paused process reads nothing, exactly like the unsubscribe secret and
      // the APNs configuration: nobody can verify, and nobody can act, so there
      // is nothing for the secret to be needed for.
      const result = await startApp({ [PUBLIC_ACTIONS_PAUSED_ENV]: "true" });

      expect(reachedTheDatabase(result)).toBe(true);
      expect(result.stderr).not.toContain(PARTICIPANT_SIGNING_SECRET_ENV);
    },
    30_000
  );
});

describe("real startup with participant identity credentials", () => {
  function unpaused(
    overrides: Record<string, string> = {}
  ): Record<string, string> {
    return {
      [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      [UNSUBSCRIBE_SIGNING_SECRET_ENV]: VALID_SECRET,
      ...VALID_APNS,
      [PARTICIPANT_SIGNING_SECRET_ENV]: VALID_PARTICIPANT_SECRET,
      ...VALID_IDENTITY_CREDENTIALS,
      ...overrides,
    };
  }

  it.each([
    PARTICIPATION_HMAC_KEYRING_ENV,
    BLOCK_SAFETY_HMAC_KEYRING_ENV,
    PARTICIPANT_DELETION_SIGNING_SECRET_ENV,
  ])("refuses unpaused startup when %s is missing", async (name) => {
    const environment = unpaused();
    delete environment[name];
    const result = await startApp(environment);

    expect(result.code).toBe(1);
    expect(result.stderr).toContain(
      "[config] participant identity credentials unavailable"
    );
    expect(result.stderr).not.toContain(name);
    expect(reachedTheDatabase(result)).toBe(false);
  }, 30_000);

  it.each([
    [
      PARTICIPATION_HMAC_KEYRING_ENV,
      "not-json",
    ],
    [
      BLOCK_SAFETY_HMAC_KEYRING_ENV,
      JSON.stringify({ currentVersion: 1, keys: { "1": "short" } }),
    ],
    [PARTICIPANT_DELETION_SIGNING_SECRET_ENV, "short"],
  ])("refuses unpaused startup with malformed %s without logging it", async (
    name,
    value
  ) => {
    const result = await startApp(unpaused({ [name]: value }));

    expect(result.code).toBe(1);
    expect(result.stderr).toContain(
      "[config] participant identity credentials unavailable"
    );
    expect(result.stderr).not.toContain(value);
    expect(result.stdout).not.toContain(value);
    expect(reachedTheDatabase(result)).toBe(false);
  }, 30_000);

  it("reaches the database with valid credentials without logging any secret", async () => {
    const result = await startApp(unpaused());

    expect(reachedTheDatabase(result)).toBe(true);
    for (const value of Object.values(VALID_IDENTITY_CREDENTIALS)) {
      expect(result.stderr).not.toContain(value);
      expect(result.stdout).not.toContain(value);
    }
  }, 30_000);

  it("preserves paused production startup when all three credentials are absent", async () => {
    const result = await startApp({
      [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
      NODE_ENV: "production",
      HOST: "127.0.0.1",
      PORT: "3000",
      SCHEDULER_ENABLED: "true",
      BASE_URL: "https://api.goodgrubapp.com",
      FROM_EMAIL: "GoodGrub <noreply@goodgrubapp.com>",
      MONGO_URI:
        "mongodb://127.0.0.1:1/commonplate_production?serverSelectionTimeoutMS=750",
    });

    expect(reachedTheDatabase(result)).toBe(true);
    expect(result.stderr).not.toContain("participant identity credentials");
  }, 30_000);

  it("starts paused review without inheriting production identity credentials", async () => {
    const result = await startApp({
      NODE_ENV: "review",
      HOST: "127.0.0.1",
      PORT: "3001",
      SCHEDULER_ENABLED: "false",
      CRON_ENABLED: "false",
      EXTERNAL_PROVIDERS: "disabled",
      [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
      RESEND_API_KEY: "",
      MONGO_URI:
        "mongodb://127.0.0.1:1/commonplate_review?serverSelectionTimeoutMS=750",
      BASE_URL: "https://review-api.goodgrubapp.com",
      PRODUCTION_BASE_URL: "https://api.goodgrubapp.com",
    });

    expect(reachedTheDatabase(result)).toBe(true);
    expect(result.stderr).not.toContain("PARTICIPATION_HMAC_KEYRING");
    expect(result.stderr).not.toContain("BLOCK_SAFETY_HMAC_KEYRING");
    expect(result.stderr).not.toContain(
      "PARTICIPANT_DELETION_SIGNING_SECRET"
    );
  }, 30_000);
});
