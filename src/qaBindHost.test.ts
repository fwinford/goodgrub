import { createConnection, createServer } from "node:net";
import { networkInterfaces } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { assertQaBindHostConfiguration } from "./qaBindHost.js";

function nonLoopbackIpv4Addresses(): string[] {
  return Object.values(networkInterfaces())
    .flatMap((interfaces) => interfaces ?? [])
    .filter((address) => address.family === "IPv4" && !address.internal)
    .map((address) => address.address);
}

function canConnect(host: string, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host, port });
    const finish = (connected: boolean) => {
      socket.destroy();
      resolve(connected);
    };
    socket.setTimeout(1_000, () => finish(false));
    socket.once("connect", () => finish(true));
    socket.once("error", () => finish(false));
  });
}

describe("QA-only backend bind configuration", () => {
  const server = createServer();
  const nonLoopbackAddresses = nonLoopbackIpv4Addresses();
  afterEach(async () => {
    if (server.listening) {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      );
    }
  });

  it("leaves the existing default path unchanged when QA_BIND_HOST is absent", () => {
    expect(() => assertQaBindHostConfiguration({})).not.toThrow();
  });

  it("accepts only the explicitly authorized disposable QA runtime", () => {
    const environment: NodeJS.ProcessEnv = {
      QA_BIND_HOST: "127.0.0.1",
      NODE_ENV: "development",
      ALLOW_LOCAL_SEED: "true",
      CRON_ENABLED: "false",
      TRUST_PROXY: "false",
      PUBLIC_ACTIONS_PAUSED: "false",
      RESEND_API_KEY: "re_local_qa_fake",
      MONGO_URI:
        "mongodb://127.0.0.1:27041/commonplate_qa_report_test?replicaSet=qa1cp4",
      RESEND_BASE_URL: "http://127.0.0.1:8031",
      DOTENV_CONFIG_PATH:
        "/tmp/commonplate-qa-bind-test/intentionally-absent.env",
    };

    expect(() => assertQaBindHostConfiguration(environment)).not.toThrow();

    for (const invalid of [
      { ...environment, QA_BIND_HOST: "0.0.0.0" },
      { ...environment, QA_BIND_HOST: "::1" },
      { ...environment, QA_BIND_HOST: "localhost" },
      { ...environment, QA_BIND_HOST: "127.0.0.2" },
      { ...environment, NODE_ENV: "production" },
      { ...environment, ALLOW_LOCAL_SEED: undefined },
      { ...environment, MONGO_URI: "mongodb://db.example.com/commonplate_prod" },
      {
        ...environment,
        MONGO_URI:
          "mongodb://127.0.0.1:27041/commonplate_prod?replicaSet=qa1cp4",
      },
      { ...environment, RESEND_API_KEY: "real-provider-key" },
      { ...environment, RESEND_BASE_URL: "https://api.resend.com" },
      { ...environment, DOTENV_CONFIG_PATH: "/tmp/.env" },
    ]) {
      expect(() => assertQaBindHostConfiguration(invalid)).toThrow();
    }
  });

  it.skipIf(nonLoopbackAddresses.length === 0)(
    "binds the QA listener only to loopback, not the Mac interfaces",
    async () => {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("The QA loopback listener did not expose a TCP address.");
    }

    expect(address.address).toBe("127.0.0.1");
    expect(await canConnect("127.0.0.1", address.port)).toBe(true);
    for (const host of nonLoopbackAddresses) {
      expect(await canConnect(host, address.port)).toBe(false);
    }
  });
});
