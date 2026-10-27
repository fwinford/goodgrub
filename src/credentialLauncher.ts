import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isReviewRuntime } from "./externalProviders.js";

export const RUNTIME_CREDENTIAL_NAMES = [
  "MONGO_URI",
  "RESEND_API_KEY",
  "CLAIM_TOKEN_HMAC_SECRET",
  "UNSUBSCRIBE_SIGNING_SECRET",
  "PARTICIPANT_SIGNING_SECRET",
  "PARTICIPATION_HMAC_KEYRING",
  "BLOCK_SAFETY_HMAC_KEYRING",
  "PARTICIPANT_DELETION_SIGNING_SECRET",
  "APNS_TEAM_ID",
  "APNS_KEY_ID",
  "APNS_BUNDLE_ID",
  "APNS_AUTH_KEY_P8",
  "OPENAI_API_KEY",
] as const;

const REQUIRED_RUNTIME_CREDENTIAL_NAMES = new Set([
  "MONGO_URI",
  "RESEND_API_KEY",
  "CLAIM_TOKEN_HMAC_SECRET",
]);

export async function readRuntimeCredentials(
  credentialsDirectory: string | undefined,
  environment: NodeJS.ProcessEnv = process.env
): Promise<Record<string, string>> {
  if (!credentialsDirectory) {
    throw new Error("systemd credential directory unavailable");
  }

  const credentials: Record<string, string> = {};
  for (const name of RUNTIME_CREDENTIAL_NAMES) {
    if (isReviewRuntime(environment) && name !== "MONGO_URI" && name !== "CLAIM_TOKEN_HMAC_SECRET") {
      credentials[name] = "";
      continue;
    }
    let value: string;
    try {
      value = await readFile(resolve(credentialsDirectory, name), "utf8");
    } catch (error) {
      if (
        !REQUIRED_RUNTIME_CREDENTIAL_NAMES.has(name) &&
        error instanceof Error &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        credentials[name] = "";
        continue;
      }
      throw new Error("runtime credential unavailable");
    }
    if (value.includes("\0")) {
      throw new Error("runtime credential invalid");
    }
    credentials[name] = value;
  }

  for (const name of REQUIRED_RUNTIME_CREDENTIAL_NAMES) {
    if (isReviewRuntime(environment) && name === "RESEND_API_KEY") continue;
    if (!credentials[name].trim()) {
      throw new Error("required runtime credential unavailable");
    }
  }
  return credentials;
}

export function startApplication(
  credentials: Record<string, string>,
  spawnProcess: typeof spawn = spawn
): void {
  const appPath = fileURLToPath(new URL("../app.js", import.meta.url));
  const child = spawnProcess(process.execPath, [appPath], {
    cwd: process.cwd(),
    env: { ...process.env, ...credentials },
    stdio: "inherit",
  });

  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.once(signal, () => {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill(signal);
      }
    });
  }
  child.once("error", () => {
    console.error("[launcher] application process could not start");
    process.exitCode = 1;
  });
  child.once("exit", (code) => {
    process.exitCode = code ?? 1;
  });
}

export async function runCredentialLauncher(): Promise<void> {
  try {
    const credentials = await readRuntimeCredentials(
      process.env.CREDENTIALS_DIRECTORY
    );
    startApplication(credentials);
  } catch {
    console.error("[launcher] runtime credentials unavailable; service not started");
    process.exitCode = 1;
  }
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  void runCredentialLauncher();
}
