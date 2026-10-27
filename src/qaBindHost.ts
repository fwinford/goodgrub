import { existsSync } from "node:fs";
import { basename, isAbsolute } from "node:path";

export const QA_BIND_HOST_ENV = "QA_BIND_HOST";
const QA_LOOPBACK_HOST = "127.0.0.1";

function isDisposableQaMongoUri(value: string | undefined): boolean {
  if (!value) return false;

  try {
    const uri = new URL(value);
    return (
      uri.protocol === "mongodb:" &&
      uri.hostname === QA_LOOPBACK_HOST &&
      Number(uri.port) > 0 &&
      uri.username === "" &&
      uri.password === "" &&
      /^\/commonplate_qa_[a-z0-9_]+$/.test(uri.pathname) &&
      uri.searchParams.size === 1 &&
      uri.searchParams.get("replicaSet") === "qa1cp4" &&
      uri.hash === ""
    );
  } catch {
    return false;
  }
}

function isLoopbackMailSink(value: string | undefined): boolean {
  if (!value) return false;

  try {
    const url = new URL(value);
    return (
      url.protocol === "http:" &&
      url.hostname === QA_LOOPBACK_HOST &&
      Number(url.port) > 0 &&
      url.username === "" &&
      url.password === "" &&
      url.pathname === "/" &&
      url.search === "" &&
      url.hash === ""
    );
  } catch {
    return false;
  }
}

function isDisposableQaRuntime(environment: NodeJS.ProcessEnv): boolean {
  const dotenvPath = environment.DOTENV_CONFIG_PATH;
  return (
    environment.NODE_ENV === "development" &&
    environment.ALLOW_LOCAL_SEED === "true" &&
    environment.CRON_ENABLED === "false" &&
    environment.TRUST_PROXY === "false" &&
    environment.PUBLIC_ACTIONS_PAUSED === "false" &&
    environment.RESEND_API_KEY === "re_local_qa_fake" &&
    isDisposableQaMongoUri(environment.MONGO_URI) &&
    isLoopbackMailSink(environment.RESEND_BASE_URL) &&
    typeof dotenvPath === "string" &&
    isAbsolute(dotenvPath) &&
    basename(dotenvPath) === "intentionally-absent.env" &&
    !existsSync(dotenvPath)
  );
}

export function assertQaBindHostConfiguration(
  environment: NodeJS.ProcessEnv = process.env
): void {
  const bindHost = environment[QA_BIND_HOST_ENV];
  if (bindHost === undefined) return;

  if (bindHost !== QA_LOOPBACK_HOST) {
    throw new Error("QA_BIND_HOST must be exactly 127.0.0.1.");
  }
  if (!isDisposableQaRuntime(environment)) {
    throw new Error(
      "QA_BIND_HOST is restricted to the disposable local QA runtime."
    );
  }
}
