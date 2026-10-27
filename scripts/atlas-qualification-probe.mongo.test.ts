import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import mongoose from "mongoose";
import {
  PROBE_DATABASE_PREFIX,
  PROBE_OPT_IN_ENV,
  loadRoleDefinition,
  runLocalQualificationProbe,
} from "./atlas-qualification-probe.js";
import { HELD_MARKER, startLocalAuthReplicaSet } from "./atlas-qualification-probe-local.js";

/**
 * Starts its own throwaway authenticated replica set (role enforcement needs
 * auth, which the shared integration harness does not enable). Gated on
 * MONGO_INTEGRATION_URI only so it runs under `npm run test:mongo`; it never
 * connects to that server.
 */
const describeMongo = process.env.MONGO_INTEGRATION_URI ? describe : describe.skip;
const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};
const until = async (condition: () => boolean, ms: number) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline && !condition()) await new Promise((resolve) => setTimeout(resolve, 100));
  return condition();
};

const roles = () => ({
  roleDefinition: loadRoleDefinition("deploy/atlas/runtime-role.json"),
  reviewRoleDefinition: loadRoleDefinition("deploy/atlas/review-runtime-role.json"),
  repositoryRoot: process.cwd(),
});

describeMongo("atlas qualification probe (local authenticated replica set)", { timeout: 180_000 }, () => {
  it("passes every local check and cleans up the harness", async () => {
    process.env[PROBE_OPT_IN_ENV] = "1";
    const replicaSet = await startLocalAuthReplicaSet();
    const { pid, dataDirectory } = replicaSet;
    let names: string[] = [];
    try {
      const report = await runLocalQualificationProbe({
        adminUri: replicaSet.adminUri,
        runtimeUriFor: replicaSet.runtimeUriFor,
        expectedDataDirectory: dataDirectory,
        databaseName: `${PROBE_DATABASE_PREFIX}test_${Date.now().toString(36)}`,
        environment: process.env,
        ...roles(),
      });
      expect(report.results.filter((entry) => entry.status === "fail")).toEqual([]);
      names = report.results.map((entry) => entry.name);
    } finally {
      await replicaSet.stop();
    }
    expect(names).toEqual(
      expect.arrayContaining([
        "isolation guards",
        "runtime role allowed actions",
        "runtime role expected denials",
        "transaction commit and abort",
        "production indexes via Mongoose createIndexes",
        "dormant messaging indexes via Mongoose createIndexes",
        "review indexes via createReviewModels",
        "pool burst fails fast",
      ])
    );
    expect(existsSync(dataDirectory)).toBe(false);
    expect(pid && alive(pid)).toBeFalsy();
    expect(mongoose.connection.readyState).toBe(0);
  });

  it("refuses a loopback tunnel to a server that is not the harness, before any write", async () => {
    process.env[PROBE_OPT_IN_ENV] = "1";
    const replicaSet = await startLocalAuthReplicaSet();
    try {
      const refused = await runLocalQualificationProbe({
        adminUri: replicaSet.adminUri,
        runtimeUriFor: replicaSet.runtimeUriFor,
        expectedDataDirectory: "/tmp/not-the-harness-directory",
        databaseName: `${PROBE_DATABASE_PREFIX}refuse`,
        environment: process.env,
        ...roles(),
      });
      expect(refused.ok).toBe(false);
      expect(refused.results.map((entry) => entry.name)).toEqual(["isolated local server guard"]);
      expect(JSON.stringify(refused)).not.toMatch(/mongodb:\/\//);
    } finally {
      await replicaSet.stop();
    }
  });

  it("refuses a production-shaped target without touching it", async () => {
    const refused = await runLocalQualificationProbe({
      adminUri: "mongodb://u:p@cluster0.abc.mongodb.net/?replicaSet=rs0",
      runtimeUriFor: () => "mongodb://u:p@cluster0.abc.mongodb.net/?replicaSet=rs0",
      expectedDataDirectory: "/tmp/x",
      databaseName: "commonplate_production",
      environment: process.env,
      ...roles(),
    });
    expect(refused.ok).toBe(false);
    expect(refused.results).toHaveLength(1);
    expect(JSON.stringify(refused)).not.toMatch(/mongodb\.net/);
  });

  it("removes mongod and its directory when the CLI is interrupted", async () => {
    const child = spawn(path.join(process.cwd(), "node_modules/.bin/tsx"), ["scripts/atlas-qualification-probe-local.ts"], {
      env: { ...process.env, PROBE_HOLD_FOR_INTERRUPT_TEST: "1" },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    const exited = new Promise((resolve) => child.once("exit", resolve));
    try {
      expect(await until(() => stderr.includes(HELD_MARKER), 120_000)).toBe(true);
      const held = /dir=(\S+) pid=(\d+)/.exec(stderr);
      expect(held).not.toBeNull();
      const [directory, pid] = [held![1]!, Number(held![2])];
      expect(existsSync(directory)).toBe(true);
      expect(alive(pid)).toBe(true);
      child.kill("SIGINT");
      await exited;
      expect(await until(() => !existsSync(directory) && !alive(pid), 15_000)).toBe(true);
    } finally {
      if (child.exitCode === null) child.kill("SIGKILL");
    }
  });
});
