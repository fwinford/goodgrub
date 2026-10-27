import { describe, expect, it } from "vitest";
import { validateProductionRuntime } from "./productionRuntimeConfig.js";

const validProductionEnvironment: NodeJS.ProcessEnv = {
  NODE_ENV: "production",
  MONGO_URI:
    "mongodb+srv://runtime:password@example.test/commonplate_production",
  HOST: "127.0.0.1",
  SCHEDULER_ENABLED: "true",
  BASE_URL: "https://example.test",
  FROM_EMAIL: "GoodGrub <noreply@goodgrubapp.com>",
};

describe("production runtime configuration", () => {
  it("leaves non-production configuration unchanged", () => {
    expect(
      validateProductionRuntime({
        NODE_ENV: "development",
        HOST: "0.0.0.0",
      })
    ).toBeNull();
  });

  it("accepts an explicit HTTPS origin and the single scheduler process", () => {
    expect(validateProductionRuntime(validProductionEnvironment)).toBeNull();
  });

  it("accepts MongoDB replica-set seeds with explicit ports without connecting", () => {
    expect(validateProductionRuntime({
      ...validProductionEnvironment,
      MONGO_URI: "mongodb://node0.example.test:27017,node1.example.test:27017,node2.example.test:27017/commonplate_production?replicaSet=atlas-example&tls=true&authSource=admin",
    })).toBeNull();
  });

  it.each([
    [{ ...validProductionEnvironment, HOST: "0.0.0.0" }, "HOST"],
    [{ ...validProductionEnvironment, PORT: "0" }, "PORT"],
    [{ ...validProductionEnvironment, PORT: "3000/tcp" }, "PORT"],
    [
      {
        ...validProductionEnvironment,
        MONGO_URI: "mongodb+srv://runtime:password@example.test/commonplate_review",
      },
      "production database",
    ],
    [
      {
        ...validProductionEnvironment,
        MONGO_URI: "https://example.test/commonplate_production",
      },
      "production database",
    ],
    [
      { ...validProductionEnvironment, SCHEDULER_ENABLED: "false" },
      "SCHEDULER_ENABLED",
    ],
    [{ ...validProductionEnvironment, BASE_URL: "" }, "BASE_URL"],
    [
      { ...validProductionEnvironment, FROM_EMAIL: "CommonPlate <onboarding@resend.dev>" },
      "approved GoodGrub sender",
    ],
    [
      { ...validProductionEnvironment, FROM_EMAIL: "" },
      "approved GoodGrub sender",
    ],
    [
      { ...validProductionEnvironment, BASE_URL: "http://example.test" },
      "HTTPS",
    ],
    [
      { ...validProductionEnvironment, BASE_URL: "https://user:pass@example.test" },
      "HTTPS",
    ],
    [
      { ...validProductionEnvironment, BASE_URL: "https://example.test/path" },
      "HTTPS",
    ],
    [
      { ...validProductionEnvironment, BASE_URL: "https://example.test/?token=x" },
      "HTTPS",
    ],
  ])("rejects invalid production configuration", (environment, message) => {
    expect(validateProductionRuntime(environment)).toContain(message);
  });

  it("requires the reviewer service to remain paused, scheduler-free, and database-isolated", () => {
    const validReviewEnvironment: NodeJS.ProcessEnv = {
      NODE_ENV: "review",
      MONGO_URI: "mongodb://review:secret@localhost/commonplate_review",
      HOST: "127.0.0.1",
      PORT: "3001",
      SCHEDULER_ENABLED: "false",
      PUBLIC_ACTIONS_PAUSED: "true",
      CRON_ENABLED: "false",
      EXTERNAL_PROVIDERS: "disabled",
      BASE_URL: "https://review.example.test",
      PRODUCTION_BASE_URL: "https://example.test",
    };

    expect(validateProductionRuntime(validReviewEnvironment)).toBeNull();
    for (const name of [
      "PARTICIPATION_HMAC_KEYRING",
      "BLOCK_SAFETY_HMAC_KEYRING",
      "PARTICIPANT_DELETION_SIGNING_SECRET",
    ]) {
      expect(
        validateProductionRuntime({
          ...validReviewEnvironment,
          [name]: "must-not-be-inherited",
        })
      ).toContain("production participant credentials must be absent");
    }
    const reviewSeedUri = "mongodb://node0.example.test:27017,node1.example.test:27017,node2.example.test:27017/commonplate_review?replicaSet=atlas-example&tls=true&authSource=admin";
    expect(validateProductionRuntime({
      ...validReviewEnvironment, MONGO_URI: reviewSeedUri,
    })).toBeNull();
    expect(validateProductionRuntime({
      ...validReviewEnvironment,
      MONGO_URI: reviewSeedUri.replace("/commonplate_review?", "/commonplate_production?"),
    })).toContain("isolated review database");
    expect(
      validateProductionRuntime({
        ...validReviewEnvironment,
        MONGO_URI:
          "mongodb://review:secret@localhost/commonplate_production",
      })
    ).toContain("isolated review database");
    expect(
      validateProductionRuntime({
        ...validReviewEnvironment,
        PUBLIC_ACTIONS_PAUSED: "false",
      })
    ).toContain("PUBLIC_ACTIONS_PAUSED");
    expect(
      validateProductionRuntime({
        ...validReviewEnvironment,
        SCHEDULER_ENABLED: "true",
      })
    ).toContain("SCHEDULER_ENABLED");
  });
});
