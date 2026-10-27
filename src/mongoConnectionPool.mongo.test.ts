import mongoose from "mongoose";
import { afterAll, describe, expect, it } from "vitest";
import { mongoConnectionOptions } from "./mongoConnectionOptions.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const suite = mongoUri ? describe : describe.skip;

suite("bounded MongoDB pool against a real replica set", () => {
  const connections: mongoose.Connection[] = [];
  afterAll(async () => {
    await Promise.all(connections.map((connection) => connection.close()));
  });

  it("the driver honors the configured pool bound and wait timeout", async () => {
    const result = mongoConnectionOptions({
      NODE_ENV: "production",
      MONGO_MAX_POOL_SIZE: "3",
      MONGO_WAIT_QUEUE_TIMEOUT_MS: "300",
    });
    if (!result.ok) throw new Error(result.error);
    const connection = await mongoose
      .createConnection(mongoUri!, {
        ...result.options,
        dbName: "commonplate_pool_bounds_test",
      })
      .asPromise();
    connections.push(connection);
    const driverOptions = connection.getClient().options;
    expect(driverOptions.maxPoolSize).toBe(3);
    expect(driverOptions.minPoolSize).toBe(0);
    expect(driverOptions.waitQueueTimeoutMS).toBe(300);
  });

  it("fails fast instead of queueing forever when the pool is exhausted", async () => {
    const connection = await mongoose
      .createConnection(mongoUri!, {
        maxPoolSize: 1,
        waitQueueTimeoutMS: 300,
        dbName: "commonplate_pool_bounds_test",
      })
      .asPromise();
    connections.push(connection);
    const collection = connection.collection("held");
    await collection.insertOne({ seed: true });
    // A slow server-side scan occupies the single pooled connection.
    const holder = collection
      .find({ $where: "sleep(1500) || true" })
      .toArray();
    await new Promise((resolve) => setTimeout(resolve, 150));
    const started = Date.now();
    await expect(collection.findOne({})).rejects.toMatchObject({
      name: "MongoWaitQueueTimeoutError",
    });
    expect(Date.now() - started).toBeLessThan(1_200);
    await holder;
  });
});
