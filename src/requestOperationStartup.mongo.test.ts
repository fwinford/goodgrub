import { spawn, type ChildProcess } from "node:child_process";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { createConnection as connectTcp, createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import mongoose from "mongoose";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  APNS_AUTH_KEY_P8_ENV,
  APNS_BUNDLE_ID_ENV,
  APNS_KEY_ID_ENV,
  APNS_TEAM_ID_ENV,
} from "./apnsConfig.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  BLOCK_SAFETY_HMAC_KEYRING_ENV,
  PARTICIPANT_DELETION_SIGNING_SECRET_ENV,
  PARTICIPATION_HMAC_KEYRING_ENV,
} from "./participantIdentityKeys.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { UNSUBSCRIBE_SIGNING_SECRET_ENV } from "./unsubscribeCredential.js";

/**
 * W4-D2 proof against the real `app.ts`, run as a deployment would run it.
 *
 * Two properties cannot be shown by mounting a route in a miniature Express
 * app, because both are about what the whole process does:
 *
 * 1. Startup: a fresh database reaches `listen` only after the unique
 *    request-operation identity index — the created-vs-NO-CREATE one-winner
 *    primitive — and the ledger authority identity exist. Every child here
 *    runs with Mongoose auto-indexing and auto-creation disabled through a
 *    preload, so the explicit startup barrier is the only thing that can have
 *    built the index; a control child proves the preload really disables it.
 *    A database where the index cannot be established must stop startup
 *    before anything listens.
 * 2. Ordering: the terminal endpoint is registered ahead of the global body
 *    parsers, so a malformed or oversized body cannot let the generic parser
 *    and error handler answer before cache isolation, pause, the limiter, and
 *    participant authority.
 *
 * The test process never compiles models on a connected Mongoose instance: it
 * reads and seeds each fresh database through a separate connection with
 * auto-indexing off, so nothing here can create the index on the app's behalf.
 */
const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
const appPath = fileURLToPath(new URL("../app.ts", import.meta.url));
const baseUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = baseUri ? describe : describe.skip;

const IDENTITY_INDEX = "request_operation_ledger_identity_unique";
const AUTHORITY_HEADER = "x-commonplate-operation-authority";
const OPERATION_HEADER = "x-commonplate-operation-id";
const PARTICIPANT_HEADER = "x-commonplate-participant";

const participantSecretText = "p".repeat(32) + "-startup-proof";

// Test-only identity credentials, distinct from each other and from the
// signing secrets above, as startup requires when public actions are active.
const participationKeyringText = JSON.stringify({
  currentVersion: 1,
  keys: { "1": Buffer.alloc(32, 0x31).toString("base64") },
});
const blockSafetyKeyringText = JSON.stringify({
  currentVersion: 1,
  keys: { "1": Buffer.alloc(32, 0x52).toString("base64") },
});
const participantDeletionSecretText = "d".repeat(32) + "-startup-proof";
const participantId = new mongoose.Types.ObjectId("64f0000000000000000000d1");
const participantAuthority = signParticipantAuthority(
  participantId,
  1,
  Buffer.from(participantSecretText)
);

const { privateKey: apnsAuthKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

function freshDatabaseUri(label: string): string {
  const uri = new URL(baseUri!);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_startup_${label}_${randomBytes(4).toString("hex")}`;
  return uri.toString();
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => (error ? reject(error) : resolve(port)));
    });
  });
}

function isAcceptingConnections(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connectTcp({ port, host: "127.0.0.1" }, () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => {
      socket.destroy();
      resolve(false);
    });
  });
}

let preloadDirectory = "";
let preloadPath = "";

/** Disables Mongoose's implicit index and collection creation in a child. */
async function writePreload(): Promise<void> {
  preloadDirectory = await mkdtemp(path.join(tmpdir(), "commonplate-d2-"));
  preloadPath = path.join(preloadDirectory, "no-auto-index.cjs");
  const mongoosePath = createRequire(
    path.join(repositoryRoot, "package.json")
  ).resolve("mongoose");
  await writeFile(
    preloadPath,
    [
      `const mongoose = require(${JSON.stringify(mongoosePath)});`,
      `mongoose.set("autoIndex", false);`,
      `mongoose.set("autoCreate", false);`,
      "",
    ].join("\n")
  );
}

interface RunningApp {
  child: ChildProcess;
  port: number;
  stdout: () => string;
  stderr: () => string;
  exited: Promise<number | null>;
}

function startApp(
  mongoUri: string,
  port: number,
  environment: Record<string, string>
): RunningApp {
  const child = spawn(
    process.execPath,
    ["--require", preloadPath, "--import", "tsx", appPath],
    {
      cwd: repositoryRoot,
      env: {
        DOTENV_CONFIG_PATH: "/nonexistent/commonplate-d2-startup/.env",
        MONGO_URI: mongoUri,
        PORT: String(port),
        RESEND_API_KEY: "d2-startup-test-key",
        CLAIM_TOKEN_HMAC_SECRET: "c".repeat(64),
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: "u".repeat(64),
        [PARTICIPANT_SIGNING_SECRET_ENV]: participantSecretText,
        [PARTICIPATION_HMAC_KEYRING_ENV]: participationKeyringText,
        [BLOCK_SAFETY_HMAC_KEYRING_ENV]: blockSafetyKeyringText,
        [PARTICIPANT_DELETION_SIGNING_SECRET_ENV]: participantDeletionSecretText,
        [APNS_TEAM_ID_ENV]: "ABCDE12345",
        [APNS_KEY_ID_ENV]: "KEY1234567",
        [APNS_BUNDLE_ID_ENV]: "org.commonplatenyu.CommonPlateios",
        [APNS_AUTH_KEY_P8_ENV]: apnsAuthKey,
        ...environment,
      },
      stdio: ["ignore", "pipe", "pipe"],
    }
  );
  let stdout = "";
  let stderr = "";
  child.stdout!.on("data", (chunk) => {
    stdout += String(chunk);
  });
  child.stderr!.on("data", (chunk) => {
    stderr += String(chunk);
  });
  const exited = new Promise<number | null>((resolve) =>
    child.once("exit", (code) => resolve(code))
  );
  return { child, port, stdout: () => stdout, stderr: () => stderr, exited };
}

/** `app.ts` logs its base URL from inside the `listen` callback. */
async function waitForListening(app: RunningApp): Promise<void> {
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    if (app.stdout().includes(`http://localhost:${app.port}`)) return;
    if (app.child.exitCode !== null) {
      throw new Error(`app exited before listening: ${app.stderr()}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`app did not listen: ${app.stderr()}`);
}

async function stopApp(app: RunningApp): Promise<void> {
  if (app.child.exitCode === null) app.child.kill("SIGTERM");
  await app.exited;
}

async function withDatabase<T>(
  uri: string,
  run: (db: mongoose.mongo.Db) => Promise<T>
): Promise<T> {
  const connection = await mongoose
    .createConnection(uri, { autoIndex: false, autoCreate: false })
    .asPromise();
  try {
    return await run(connection.db!);
  } finally {
    await connection.close();
  }
}

async function identityIndex(db: mongoose.mongo.Db) {
  const collections = await db
    .listCollections({ name: "requestoperations" })
    .toArray();
  if (collections.length === 0) return undefined;
  const indexes = await db.collection("requestoperations").indexes();
  return indexes.find((index) => index.name === IDENTITY_INDEX);
}

async function deletionIndexes(db: mongoose.mongo.Db) {
  const collections = await db
    .listCollections({ name: "participantdeletionoperations" })
    .toArray();
  return collections.length === 0
    ? []
    : db.collection("participantdeletionoperations").indexes();
}

async function ledgerRowCount(uri: string, operationId?: string) {
  return withDatabase(uri, (db) =>
    db
      .collection("requestoperations")
      .countDocuments(operationId ? { operationId } : {})
  );
}

async function dropDatabase(uri: string) {
  await withDatabase(uri, (db) => db.dropDatabase());
}

function expectIsolated(response: Response) {
  expect(response.headers.get("cache-control")).toBe("private, no-store");
  expect(response.headers.get("vary")).toBe(PARTICIPANT_HEADER);
}

describeMongo("real app.ts request-operation startup barrier (W4-D2)", () => {
  beforeAll(writePreload);
  afterAll(async () => {
    await rm(preloadDirectory, { recursive: true, force: true });
  });

  it(
    "control: with the preload, compiling and initializing the model builds no index",
    async () => {
      const uri = freshDatabaseUri("control");
      const script = [
        `import mongoose from "mongoose";`,
        `import { RequestOperation } from ${JSON.stringify(
          path.join(repositoryRoot, "models/db.ts")
        )};`,
        `await mongoose.connect(${JSON.stringify(uri)});`,
        `await RequestOperation.init();`,
        `await mongoose.disconnect();`,
      ].join("\n");
      const child = spawn(
        process.execPath,
        ["--require", preloadPath, "--import", "tsx", "--input-type=module", "-e", script],
        { cwd: repositoryRoot, stdio: ["ignore", "pipe", "pipe"] }
      );
      let stderr = "";
      child.stderr!.on("data", (chunk) => {
        stderr += String(chunk);
      });
      const code = await new Promise<number | null>((resolve) =>
        child.once("exit", resolve)
      );
      try {
        expect(code, stderr).toBe(0);
        await withDatabase(uri, async (db) => {
          expect(await identityIndex(db)).toBeUndefined();
        });
      } finally {
        await dropDatabase(uri);
      }
    },
    60_000
  );

  it(
    "listens on a fresh database only once the unique identity index and ledger authority exist",
    async () => {
      const uri = freshDatabaseUri("fresh");
      await withDatabase(uri, async (db) => {
        expect(await identityIndex(db)).toBeUndefined();
      });
      const app = startApp(uri, await freePort(), {
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      });
      try {
        await waitForListening(app);
        await withDatabase(uri, async (db) => {
          const index = await identityIndex(db);
          expect(index).toMatchObject({
            key: { operationId: 1 },
            unique: true,
          });
          expect(index?.sparse).toBeFalsy();
          expect(index?.partialFilterExpression).toBeUndefined();

          const authority = await db
            .collection<{ _id: string; authorityId: string }>(
              "requestoperationauthorities"
            )
            .findOne({ _id: "request-operation-ledger" });
          expect(authority?.authorityId).toMatch(
            /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
          );

          const response = await fetch(
            `http://127.0.0.1:${app.port}/api/request-operation/authority`
          );
          expect(response.status).toBe(200);
          expect(response.headers.get("cache-control")).toBe("no-store");
          expect(await response.json()).toEqual({
            operationAuthority: authority!.authorityId,
          });
        });
      } finally {
        await stopApp(app);
        await dropDatabase(uri);
      }
    },
    90_000
  );

  it(
    "establishes both P2 uniqueness indexes before listening on a fresh database",
    async () => {
      const uri = freshDatabaseUri("p2_fresh");
      await withDatabase(uri, async (db) => {
        expect(await deletionIndexes(db)).toEqual([]);
      });
      const app = startApp(uri, await freePort(), {
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      });
      try {
        await waitForListening(app);
        await withDatabase(uri, async (db) => {
          const byName = new Map((await deletionIndexes(db)).map((index) => [index.name, index]));
          expect(byName.get("operationId_1")).toMatchObject({
            key: { operationId: 1 },
            unique: true,
          });
          expect(byName.get("participant_deletion_one_active_operation_per_participant")).toMatchObject({
            key: { participantId: 1 },
            unique: true,
            partialFilterExpression: {
              phase: { $in: ["waiting", "ready", "challengeIssued", "authorized"] },
            },
          });
        });
      } finally {
        await stopApp(app);
        await dropDatabase(uri);
      }
    },
    90_000
  );

  it.each([
    {
      label: "duplicate P2 operation IDs",
      rows: [
        { operationId: "p2-duplicate", participantId: new mongoose.Types.ObjectId(), phase: "waiting" },
        { operationId: "p2-duplicate", participantId: new mongoose.Types.ObjectId(), phase: "waiting" },
      ],
    },
    {
      label: "two active P2 operations for one participant",
      rows: (() => {
        const owner = new mongoose.Types.ObjectId();
        return [
          { operationId: "p2-first", participantId: owner, phase: "waiting" },
          { operationId: "p2-second", participantId: owner, phase: "ready" },
        ];
      })(),
    },
  ])(
    "stops before listening when $label prevent P2 index establishment",
    async ({ rows }) => {
      const uri = freshDatabaseUri("p2_unsafe");
      await withDatabase(uri, (db) => db.collection("participantdeletionoperations").insertMany(rows));
      const app = startApp(uri, await freePort(), {
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      });
      try {
        const outcome = await Promise.race([
          app.exited.then((code) => ({ exited: true as const, code })),
          waitForListening(app).then(
            () => ({ exited: false as const, code: null }),
            () => new Promise<never>(() => {})
          ),
        ]);
        expect(outcome.exited, "the app began listening").toBe(true);
        expect(outcome.code).not.toBe(0);
        expect(await isAcceptingConnections(app.port)).toBe(false);
      } finally {
        await stopApp(app);
        await dropDatabase(uri);
      }
    },
    90_000
  );

  it(
    "keeps the same ledger authority across restarts of the same database",
    async () => {
      const uri = freshDatabaseUri("restart");
      const read = async (port: number) =>
        (
          await (
            await fetch(`http://127.0.0.1:${port}/api/request-operation/authority`)
          ).json()
        ).operationAuthority as string;
      try {
        const first = startApp(uri, await freePort(), {
          [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
        });
        let before = "";
        try {
          await waitForListening(first);
          before = await read(first.port);
        } finally {
          await stopApp(first);
        }
        const second = startApp(uri, await freePort(), {
          [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
        });
        try {
          await waitForListening(second);
          expect(await read(second.port)).toBe(before);
        } finally {
          await stopApp(second);
        }

        // A different (fresh) database behind the same code gets its own.
        const otherUri = freshDatabaseUri("restart_other");
        const other = startApp(otherUri, await freePort(), {
          [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
        });
        try {
          await waitForListening(other);
          expect(await read(other.port)).not.toBe(before);
        } finally {
          await stopApp(other);
          await dropDatabase(otherUri);
        }
      } finally {
        await dropDatabase(uri);
      }
    },
    150_000
  );

  it.each([
    {
      label: "duplicate operation identities",
      seed: async (db: mongoose.mongo.Db) => {
        await db.collection("requestoperations").insertMany([
          { operationId: "dup", participantId: participantId, outcome: "no-create" },
          { operationId: "dup", participantId: participantId, outcome: "no-create" },
        ]);
      },
    },
    {
      label: "a non-unique index already holding the identity index name",
      seed: async (db: mongoose.mongo.Db) => {
        await db
          .collection("requestoperations")
          .createIndex({ operationId: 1 }, { name: IDENTITY_INDEX });
      },
    },
  ])(
    "exits before listening when $label prevent the unique index",
    async ({ seed }) => {
      const uri = freshDatabaseUri("unsafe");
      await withDatabase(uri, seed);
      const app = startApp(uri, await freePort(), {
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      });
      try {
        const outcome = await Promise.race([
          app.exited.then((code) => ({ exited: true as const, code })),
          waitForListening(app).then(
            () => ({ exited: false as const, code: null }),
            // Exiting first also rejects the listen wait; `exited` wins.
            () => new Promise<never>(() => {})
          ),
        ]);
        expect(outcome.exited, "the app began listening").toBe(true);
        expect(outcome.code).not.toBe(0);
        expect(app.stdout()).not.toContain(`http://localhost:${app.port}`);
        expect(await isAcceptingConnections(app.port)).toBe(false);
        await withDatabase(uri, async (db) => {
          expect((await identityIndex(db))?.unique).not.toBe(true);
          expect(
            await db
              .collection("requestoperationauthorities")
              .countDocuments({})
          ).toBe(0);
        });
      } finally {
        await stopApp(app);
        await dropDatabase(uri);
      }
    },
    90_000
  );
});

describeMongo("real app.ts terminal endpoint ordering (W4-D2)", () => {
  const uri = baseUri ? freshDatabaseUri("ordering") : "";
  let app: RunningApp;
  let paused: RunningApp;
  let ledgerAuthority = "";
  let operationCounter = 0;
  const nextOperation = () => `d2-order-${(operationCounter += 1)}`;

  const oversizedBody = JSON.stringify({ padding: "x".repeat(200_000) });

  function terminal(
    target: RunningApp,
    options: {
      participant?: string;
      operationId?: string;
      authority?: string;
      body?: string;
    }
  ) {
    const headers: Record<string, string> = {
      "content-type": "application/json",
    };
    if (options.participant) headers[PARTICIPANT_HEADER] = options.participant;
    if (options.operationId) headers[OPERATION_HEADER] = options.operationId;
    if (options.authority) headers[AUTHORITY_HEADER] = options.authority;
    return fetch(
      `http://127.0.0.1:${target.port}/api/request-operation/terminal`,
      { method: "POST", headers, body: options.body ?? "{" }
    );
  }

  beforeAll(async () => {
    await writePreload();
    await withDatabase(uri, async (db) => {
      await db.collection("participants").insertOne({
        _id: participantId,
        email: "d2-startup-proof@nyu.edu",
        authorityVersion: 1,
        verifiedAt: new Date(),
      });
    });
    app = startApp(uri, await freePort(), {
      [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
    });
    paused = startApp(uri, await freePort(), {
      [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
    });
    await Promise.all([waitForListening(app), waitForListening(paused)]);
    ledgerAuthority = (
      await (
        await fetch(`http://127.0.0.1:${app.port}/api/request-operation/authority`)
      ).json()
    ).operationAuthority;
  }, 120_000);

  afterAll(async () => {
    if (app) await stopApp(app);
    if (paused) await stopApp(paused);
    if (uri) await dropDatabase(uri);
    await rm(preloadDirectory, { recursive: true, force: true });
  });

  it("control: a route behind the global parser is answered by the generic error handler", async () => {
    const response = await fetch(`http://127.0.0.1:${app.port}/api/request`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        [PARTICIPANT_HEADER]: participantAuthority,
      },
      body: "{",
    });
    const body = await response.json();
    expect(body.error?.code).toBeUndefined();
  });

  it("answers a malformed body with participant refusal, isolated, before any ledger access", async () => {
    const operationId = nextOperation();
    const response = await terminal(app, {
      operationId,
      authority: ledgerAuthority,
      body: "{",
    });

    expect(response.status).toBe(401);
    expect((await response.json()).error.code).toBe(
      "PARTICIPANT_VERIFICATION_REQUIRED"
    );
    expectIsolated(response);
    expect(await ledgerRowCount(uri, operationId)).toBe(0);
  });

  it("answers an oversized body with participant refusal for a forged credential, before any ledger access", async () => {
    const operationId = nextOperation();
    const response = await terminal(app, {
      participant: `${participantId.toHexString()}.1.${"A".repeat(43)}`,
      operationId,
      authority: ledgerAuthority,
      body: oversizedBody,
    });

    expect(response.status).toBe(401);
    expect((await response.json()).error.code).toBe(
      "PARTICIPANT_AUTHORITY_INVALID"
    );
    expectIsolated(response);
    expect(await ledgerRowCount(uri, operationId)).toBe(0);
  });

  it("refuses a different ledger authority with an oversized body, writing nothing", async () => {
    const operationId = nextOperation();
    const response = await terminal(app, {
      participant: participantAuthority,
      operationId,
      authority: "0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3",
      body: oversizedBody,
    });

    expect(response.status).toBe(409);
    expect((await response.json()).error.code).toBe(
      "OPERATION_AUTHORITY_MISMATCH"
    );
    expectIsolated(response);
    expect(await ledgerRowCount(uri, operationId)).toBe(0);
  });

  it("terminalizes for the verified participant and matching ledger even with a malformed body", async () => {
    const operationId = nextOperation();
    const response = await terminal(app, {
      participant: participantAuthority,
      operationId,
      authority: ledgerAuthority,
      body: "{not json",
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ outcome: "not-created" });
    expectIsolated(response);
    expect(await ledgerRowCount(uri, operationId)).toBe(1);
  });

  it("refuses while paused ahead of the parser, limiter, and handler, writing nothing", async () => {
    const operationId = nextOperation();
    const response = await terminal(paused, {
      participant: participantAuthority,
      operationId,
      authority: ledgerAuthority,
      body: oversizedBody,
    });

    expect(response.status).toBe(503);
    expect((await response.json()).error.code).toBe("PUBLIC_ACTIONS_PAUSED");
    expectIsolated(response);
    expect(await ledgerRowCount(uri, operationId)).toBe(0);

    // The authority read is not a public action and stays available.
    const authority = await fetch(
      `http://127.0.0.1:${paused.port}/api/request-operation/authority`
    );
    expect(authority.status).toBe(200);
  });

  it("rate-limits in its own bucket ahead of the handler, isolated, writing nothing once limited", async () => {
    // Four terminal requests above already spent this window's allowance
    // (the paused process has its own limiter state).
    const statuses: number[] = [];
    let limited: Response | undefined;
    let limitedOperation = "";
    for (let attempt = 0; attempt < 12 && !limited; attempt += 1) {
      const operationId = nextOperation();
      const response = await terminal(app, {
        participant: participantAuthority,
        operationId,
        authority: ledgerAuthority,
        body: "{",
      });
      statuses.push(response.status);
      if (response.status === 429) {
        limited = response;
        limitedOperation = operationId;
      } else {
        await response.arrayBuffer();
      }
    }

    expect(limited, `statuses: ${statuses.join(",")}`).toBeDefined();
    expect((await limited!.json()).error.code).toBe("RATE_LIMITED");
    expectIsolated(limited!);
    expect(await ledgerRowCount(uri, limitedOperation)).toBe(0);
    // Exactly the limiter's allowance of ten reached the route before it.
    expect(statuses.filter((status) => status !== 429)).toHaveLength(10 - 4);

    // The create route's bucket is separate and untouched.
    const create = await fetch(`http://127.0.0.1:${app.port}/api/request`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(create.status).not.toBe(429);
  });
});
