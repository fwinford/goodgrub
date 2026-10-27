import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_WAIT_QUEUE_TIMEOUT_MS,
  MAX_POOL_SIZE_CEILING,
  PRODUCTION_MAX_POOL_SIZE,
  REVIEW_MAX_POOL_SIZE,
  mongoConnectionOptions,
} from "./mongoConnectionOptions.js";

const appSource = readFileSync(
  fileURLToPath(new URL("../app.ts", import.meta.url)),
  "utf8"
);

describe("bounded MongoDB connection options (Atlas Flex 500-connection budget)", () => {
  it("uses a bounded production default and a smaller review default", () => {
    expect(mongoConnectionOptions({ NODE_ENV: "production" })).toEqual({
      ok: true,
      options: {
        maxPoolSize: PRODUCTION_MAX_POOL_SIZE,
        minPoolSize: 0,
        waitQueueTimeoutMS: DEFAULT_WAIT_QUEUE_TIMEOUT_MS,
      },
    });
    const review = mongoConnectionOptions({ NODE_ENV: "review" });
    expect(review.ok && review.options.maxPoolSize).toBe(REVIEW_MAX_POOL_SIZE);
    expect(PRODUCTION_MAX_POOL_SIZE + REVIEW_MAX_POOL_SIZE).toBeLessThan(100);
  });

  it("applies the same bounded default outside production and review", () => {
    const result = mongoConnectionOptions({});
    expect(result.ok && result.options.maxPoolSize).toBe(PRODUCTION_MAX_POOL_SIZE);
  });

  it("accepts explicit bounded overrides", () => {
    const result = mongoConnectionOptions({
      MONGO_MAX_POOL_SIZE: "35",
      MONGO_WAIT_QUEUE_TIMEOUT_MS: "2500",
    });
    expect(result).toEqual({
      ok: true,
      options: { maxPoolSize: 35, minPoolSize: 0, waitQueueTimeoutMS: 2500 },
    });
  });

  it.each(["0", "-1", "51", "abc", "1.5", "1e2", "0x10", "20 20"])(
    "refuses pool size %s",
    (value) => {
      const result = mongoConnectionOptions({ MONGO_MAX_POOL_SIZE: value });
      expect(result.ok).toBe(false);
      expect(!result.ok && result.error).toContain(
        `1 to ${MAX_POOL_SIZE_CEILING}`
      );
    }
  );

  it.each(["0", "99", "30001", "soon", "-5"])(
    "refuses wait-queue timeout %s",
    (value) => {
      expect(
        mongoConnectionOptions({ MONGO_WAIT_QUEUE_TIMEOUT_MS: value }).ok
      ).toBe(false);
    }
  );

  it("treats an empty override as unset, never as unbounded", () => {
    const result = mongoConnectionOptions({
      MONGO_MAX_POOL_SIZE: " ",
      MONGO_WAIT_QUEUE_TIMEOUT_MS: "",
    });
    expect(result.ok && result.options.maxPoolSize).toBe(PRODUCTION_MAX_POOL_SIZE);
  });

  it("sets no socket timeout that could abort an ambiguous write", () => {
    const result = mongoConnectionOptions({});
    expect(result.ok && "socketTimeoutMS" in result.options).toBe(false);
  });

  it("is the only option source for the application connection", () => {
    expect(appSource).toContain(
      "await mongoose.connect(MONGO_URI, mongoOptions.options);"
    );
    expect(appSource).not.toMatch(/mongoose\.connect\(MONGO_URI\)/);
    expect(appSource.indexOf("mongoConnectionOptions(process.env)")).toBeLessThan(
      appSource.indexOf("mongoose.connect(MONGO_URI")
    );
  });
});
