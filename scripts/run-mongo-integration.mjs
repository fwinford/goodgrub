import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createConnection, createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";

function freePort() {
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

function waitForMongo(port, processHandle) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 15_000;
    const attempt = () => {
      if (processHandle.exitCode !== null) {
        reject(new Error("mongod exited before accepting connections"));
        return;
      }
      const connection = createConnection(
        { port, host: "127.0.0.1" },
        () => {
          connection.destroy();
          resolve();
        }
      );
      connection.once("error", () => {
        connection.destroy();
        if (Date.now() >= deadline) {
          reject(new Error("timed out waiting for mongod"));
        } else {
          setTimeout(attempt, 100);
        }
      });
    };
    attempt();
  });
}

function waitForExit(child) {
  return new Promise((resolve) => {
    if (child.exitCode !== null) {
      resolve(child.exitCode);
      return;
    }
    child.once("exit", (code) => resolve(code));
  });
}

function runProcess(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.once("exit", (code) => {
      if (code === 0) {
        resolve(stdout.trim());
      } else {
        reject(
          new Error(
            `${command} exited with ${code}: ${stderr.trim() || stdout.trim()}`
          )
        );
      }
    });
  });
}

async function waitForPrimary(uri) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    try {
      const result = await runProcess("mongosh", [
        uri,
        "--quiet",
        "--eval",
        "db.hello().isWritablePrimary",
      ]);
      if (result === "true") return;
    } catch {
      // Replica-set initialization briefly closes connections while electing
      // the single member. Keep probing until it becomes writable.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("timed out waiting for transaction-capable MongoDB primary");
}

// Every file shares one single-member mongod and vitest's default sizes its
// worker pool from the CPU count, so ~9 files contend for that one server and
// setup hooks and 5s tests time out. Files run one at a time by default;
// MONGO_TEST_MAX_WORKERS=<n> (positive integer) opts in to more for diagnosis.
function vitestConcurrencyArgs() {
  const configured = process.env.MONGO_TEST_MAX_WORKERS;
  if (configured === undefined || configured === "") return ["--no-file-parallelism"];
  if (!/^[1-9][0-9]*$/.test(configured)) {
    throw new Error("MONGO_TEST_MAX_WORKERS must be a positive integer");
  }
  return configured === "1" ? ["--no-file-parallelism"] : [`--maxWorkers=${configured}`];
}

const databaseDirectory = await mkdtemp(
  path.join(tmpdir(), "commonplate-mongo-")
);
const port = await freePort();
const replicaSetName = "commonplateTestReplica";
const adminUri = `mongodb://127.0.0.1:${port}/admin`;
const mongod = spawn(
  "mongod",
  [
    "--dbpath",
    databaseDirectory,
    "--port",
    String(port),
    "--bind_ip",
    "127.0.0.1",
    "--replSet",
    replicaSetName,
    "--quiet",
  ],
  { stdio: ["ignore", "ignore", "pipe"] }
);
let mongoError = "";
mongod.stderr.on("data", (chunk) => {
  mongoError += String(chunk);
});

let exitCode = 1;
try {
  await waitForMongo(port, mongod);
  await runProcess("mongosh", [
    adminUri,
    "--quiet",
    "--eval",
    `rs.initiate({_id: "${replicaSetName}", members: [{_id: 0, host: "127.0.0.1:${port}"}]})`,
  ]);
  await waitForPrimary(adminUri);
  const vitest = spawn(
    path.join(process.cwd(), "node_modules", ".bin", "vitest"),
    ["run", ".mongo.test.ts", ...vitestConcurrencyArgs()],
    {
      cwd: process.cwd(),
      env: {
        ...process.env,
        MONGO_INTEGRATION_URI: `mongodb://127.0.0.1:${port}/commonplate_claim_test?replicaSet=${replicaSetName}`,
        CLAIM_TOKEN_HMAC_SECRET:
          "real-mongo-test-secret-material-32-bytes",
        PARTICIPATION_HMAC_KEYRING: JSON.stringify({
          currentVersion: 1,
          keys: { "1": Buffer.alloc(32, 0x31).toString("base64") },
        }),
        BLOCK_SAFETY_HMAC_KEYRING: JSON.stringify({
          currentVersion: 1,
          keys: { "1": Buffer.alloc(32, 0x52).toString("base64") },
        }),
      },
      stdio: "inherit",
    }
  );
  exitCode = (await waitForExit(vitest)) ?? 1;
} catch (error) {
  console.error(
    error instanceof Error ? error.message : "MongoDB integration failed"
  );
  if (mongoError) console.error(mongoError);
} finally {
  mongod.kill("SIGTERM");
  await waitForExit(mongod);
  await rm(databaseDirectory, { recursive: true, force: true });
}

process.exitCode = exitCode;
