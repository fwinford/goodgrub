// Starts a throwaway authenticated single-node replica set on loopback with a
// temporary data directory and key file. This is the ONLY place the probe's
// destructive checks can run: there is no option to point it at another server.
//
// Cleanup: normal exit, a thrown error, SIGINT/SIGTERM/SIGHUP and an `exit`
// handler all terminate mongod and remove the data directory (which also holds
// the key file). The administrator password lives only in memory. SIGKILL of
// this process cannot be intercepted; the leftover mongod then listens only on
// loopback and its directory is under the OS temp directory.
import { spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import mongoose from "mongoose";
import {
  PROBE_DATABASE_PREFIX,
  PROBE_OPT_IN_ENV,
  formatProbeReport,
  loadRoleDefinition,
  runLocalQualificationProbe,
  safeErrorSummary,
} from "./atlas-qualification-probe.js";

const REPLICA_SET = "cpProbeReplica";
export const HELD_MARKER = "[probe] held for interruption test";

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

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export interface LocalAuthReplicaSet {
  dataDirectory: string;
  pid: number | undefined;
  adminUri: string;
  runtimeUriFor: (username: string, password: string) => string;
  stop(): Promise<void>;
}

export async function startLocalAuthReplicaSet(): Promise<LocalAuthReplicaSet> {
  const directory = mkdtempSync(path.join(tmpdir(), "cp-atlas-probe-"));
  let mongod: ChildProcess | undefined;
  let cleaned = false;
  const signals: NodeJS.Signals[] = ["SIGINT", "SIGTERM", "SIGHUP"];
  const cleanupSync = () => {
    if (cleaned) return;
    cleaned = true;
    if (mongod && mongod.exitCode === null && mongod.signalCode === null) mongod.kill("SIGKILL");
    rmSync(directory, { recursive: true, force: true });
    process.off("exit", cleanupSync);
    for (const signal of signals) process.off(signal, onSignal);
  };
  const onSignal = (signal: NodeJS.Signals) => {
    cleanupSync();
    process.kill(process.pid, signal);
  };
  process.on("exit", cleanupSync);
  for (const signal of signals) process.on(signal, onSignal);
  const stop = async () => {
    if (!cleaned && mongod && mongod.exitCode === null && mongod.signalCode === null) {
      const exited = new Promise((resolve) => mongod!.once("exit", resolve));
      mongod.kill("SIGTERM");
      await exited;
    }
    cleanupSync();
  };
  try {
    const keyFile = path.join(directory, "keyfile");
    writeFileSync(keyFile, randomBytes(48).toString("base64"));
    chmodSync(keyFile, 0o600);
    const port = await freePort();
    mongod = spawn(
      "mongod",
      [
        "--dbpath", directory,
        "--port", String(port),
        "--bind_ip", "127.0.0.1",
        "--replSet", REPLICA_SET,
        "--keyFile", keyFile,
        "--quiet",
      ],
      { stdio: ["ignore", "ignore", "ignore"] }
    );
    const { MongoClient } = mongoose.mongo;
    const direct = `mongodb://127.0.0.1:${port}/?directConnection=true`;
    let initiated = false;
    for (let attempt = 0; attempt < 100 && !initiated; attempt += 1) {
      if (mongod.exitCode !== null) throw new Error("mongod exited before accepting connections");
      const client = new MongoClient(direct, { serverSelectionTimeoutMS: 300 });
      try {
        await client.connect();
        await client.db("admin").command({
          replSetInitiate: { _id: REPLICA_SET, members: [{ _id: 0, host: `127.0.0.1:${port}` }] },
        });
        initiated = true;
      } catch {
        await sleep(100);
      } finally {
        await client.close().catch(() => undefined);
      }
    }
    if (!initiated) throw new Error("timed out starting the local replica set");
    // The localhost exception allows creating the first administrator without credentials.
    const adminPassword = randomBytes(18).toString("hex");
    let created = false;
    for (let attempt = 0; attempt < 200 && !created; attempt += 1) {
      const setup = new MongoClient(direct, { serverSelectionTimeoutMS: 500 });
      try {
        await setup.connect();
        await setup.db("admin").command({
          createUser: "cp_probe_admin",
          pwd: adminPassword,
          roles: [{ role: "root", db: "admin" }],
        });
        created = true;
      } catch {
        await sleep(150);
      } finally {
        await setup.close().catch(() => undefined);
      }
    }
    if (!created) throw new Error("timed out creating the local probe administrator");
    const hostPart = `127.0.0.1:${port}`;
    return {
      dataDirectory: directory,
      pid: mongod.pid,
      adminUri: `mongodb://cp_probe_admin:${adminPassword}@${hostPart}/admin?replicaSet=${REPLICA_SET}&authSource=admin`,
      runtimeUriFor: (username, password) =>
        `mongodb://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${hostPart}/?replicaSet=${REPLICA_SET}&authSource=admin`,
      stop,
    };
  } catch (error) {
    await stop();
    throw error;
  }
}

async function main(): Promise<number> {
  process.env[PROBE_OPT_IN_ENV] = "1";
  console.error("[probe] starting disposable local replica set");
  const replicaSet = await startLocalAuthReplicaSet();
  try {
    if (process.env.PROBE_HOLD_FOR_INTERRUPT_TEST === "1") {
      console.error(`${HELD_MARKER} dir=${replicaSet.dataDirectory} pid=${replicaSet.pid}`);
      await new Promise(() => undefined);
    }
    const report = await runLocalQualificationProbe({
      adminUri: replicaSet.adminUri,
      runtimeUriFor: replicaSet.runtimeUriFor,
      expectedDataDirectory: replicaSet.dataDirectory,
      databaseName: `${PROBE_DATABASE_PREFIX}${Date.now().toString(36)}`,
      environment: process.env,
      roleDefinition: loadRoleDefinition(path.join(process.cwd(), "deploy/atlas/runtime-role.json")),
      reviewRoleDefinition: loadRoleDefinition(path.join(process.cwd(), "deploy/atlas/review-runtime-role.json")),
      repositoryRoot: process.cwd(),
    });
    console.log(formatProbeReport(report));
    return report.ok ? 0 : 1;
  } catch (error) {
    console.error(`probe failed: ${safeErrorSummary(error)}`);
    return 1;
  } finally {
    await replicaSet.stop();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main();
  process.exit(process.exitCode);
}
