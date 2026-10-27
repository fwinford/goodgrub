import { mkdtemp, readFile, rm } from "node:fs/promises";
import { spawn, type ChildProcess } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import cron from "node-cron";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  isSchedulerEnabled,
  registerScheduledJob,
} from "./scheduledJobs.js";

describe("single-process scheduler registration", () => {
  afterEach(() => vi.restoreAllMocks());

  it.each([undefined, "", "True", "1", "false"])(
    "keeps the scheduler disabled for SCHEDULER_ENABLED=%s",
    (value) => {
      expect(
        isSchedulerEnabled({ SCHEDULER_ENABLED: value } as NodeJS.ProcessEnv)
      ).toBe(false);
    }
  );

  it("requires the exact true value", () => {
    expect(
      isSchedulerEnabled({
        SCHEDULER_ENABLED: "true",
      } as NodeJS.ProcessEnv)
    ).toBe(true);
  });

  it("does not register any schedule when disabled", () => {
    const schedule = vi.spyOn(cron, "schedule");
    const job = vi.fn();

    expect(registerScheduledJob("* * * * *", job, { enabled: false })).toBe(
      undefined
    );
    expect(schedule).not.toHaveBeenCalled();
    expect(job).not.toHaveBeenCalled();
  });

  it("enforces readiness and asks node-cron not to overlap a running job", async () => {
    const schedule = vi
      .spyOn(cron, "schedule")
      .mockImplementation(() => undefined as never);
    const job = vi.fn();
    let ready = false;

    registerScheduledJob("* * * * *", job, {
      enabled: true,
      isReady: () => ready,
    });
    const callback = schedule.mock.calls[0][1] as () => Promise<void>;

    await callback();
    expect(job).not.toHaveBeenCalled();
    expect(schedule).toHaveBeenCalledWith(
      "* * * * *",
      expect.any(Function),
      { noOverlap: true }
    );

    ready = true;
    await callback();
    expect(job).toHaveBeenCalledOnce();
  });
});

const schedulerWorker = `
import { appendFile } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { registerScheduledJob } from "./src/scheduledJobs.ts";
const task = registerScheduledJob("* * * * * *", async () => {
  await appendFile(process.env.SCHEDULER_TRACE, "start:" + process.pid + "\\n");
  await delay(800);
  await appendFile(process.env.SCHEDULER_TRACE, "end:" + process.pid + "\\n");
}, { enabled: process.env.SCHEDULER_ENABLED === "true" });
process.on("SIGTERM", () => {
  task?.stop();
  process.exit(0);
});
setInterval(() => {}, 1000);
`;

function startWorker(tracePath: string, enabled: boolean): ChildProcess {
  const child = spawn(
    process.execPath,
    ["--import", "tsx", "--input-type=module", "--eval", schedulerWorker],
    {
      cwd: process.cwd(),
      env: {
        ...process.env,
        SCHEDULER_ENABLED: String(enabled),
        SCHEDULER_TRACE: tracePath,
      },
      stdio: ["ignore", "ignore", "pipe"],
    }
  );
  const diagnostics: string[] = [];
  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", (chunk: string) => diagnostics.push(chunk));
  child.on("error", (error) => diagnostics.push(`spawn error: ${error.message}`));
  child.on("exit", (code, signal) =>
    diagnostics.push(`exit: code=${code} signal=${signal}`)
  );
  workerDiagnostics.set(child, diagnostics);
  return child;
}

const workerDiagnostics = new WeakMap<ChildProcess, string[]>();

async function waitForLine(
  tracePath: string,
  expectedPrefix: string,
  timeoutMs = 4000,
  workers: ChildProcess[] = []
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    let content = "";
    try {
      content = await readFile(tracePath, "utf8");
    } catch {
      // The first scheduled callback has not written its marker yet.
    }
    const line = content.split("\n").find((entry) => entry.startsWith(expectedPrefix));
    if (line) return line;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const workerState = workers
    .map((worker) => {
      const output = workerDiagnostics.get(worker)?.join("").trim() || "no stderr";
      return `pid=${worker.pid} exitCode=${worker.exitCode} signal=${worker.signalCode}: ${output}`;
    })
    .join("; ");
  throw new Error(
    `scheduler did not write ${expectedPrefix}${workerState ? `; workers: ${workerState}` : ""}`
  );
}

function waitForExit(child: ChildProcess): Promise<void> {
  return new Promise((resolve, reject) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    child.once("error", reject);
    child.once("exit", () => resolve());
  });
}

describe("two-process scheduler ownership and restart", () => {
  it(
    "runs one scheduled owner and recovers only after the old process exits",
    async () => {
      const directory = await mkdtemp(path.join(tmpdir(), "commonplate-scheduler-"));
      const tracePath = path.join(directory, "runs.log");
      const standby = startWorker(tracePath, false);
      const firstOwner = startWorker(tracePath, true);
      let replacement: ChildProcess | undefined;

      try {
        const firstStart = await waitForLine(tracePath, "start:", 4000, [
          standby,
          firstOwner,
        ]);
        const firstPid = Number(firstStart.split(":")[1]);
        expect(firstPid).toBe(firstOwner.pid);

        firstOwner.kill("SIGTERM");
        await waitForExit(firstOwner);

        replacement = startWorker(tracePath, true);
        const replacementStart = await waitForLine(
          tracePath,
          `start:${replacement.pid}`,
          4000,
          [standby, firstOwner, replacement]
        );
        const events = (await readFile(tracePath, "utf8"))
          .trim()
          .split("\n");
        expect(Number(replacementStart.split(":")[1])).toBe(replacement.pid);
        expect(events.some((line) => line.endsWith(String(standby.pid)))).toBe(
          false
        );
        expect(events.some((line) => line.endsWith(String(firstOwner.pid)))).toBe(
          true
        );
      } finally {
        firstOwner.kill("SIGTERM");
        standby.kill("SIGTERM");
        replacement?.kill("SIGTERM");
        await Promise.all([
          waitForExit(firstOwner),
          waitForExit(standby),
          ...(replacement ? [waitForExit(replacement)] : []),
        ]);
        await rm(directory, { recursive: true, force: true });
      }
    },
    15_000
  );
});
