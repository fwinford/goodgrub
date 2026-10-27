import express, { type Express, type RequestHandler } from "express";
import mongoose from "mongoose";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { Subscriber } from "../models/db.js";
vi.mock("./requestAlertEmailDelivery.js", () => ({
  isRequestAlertEmailDeliveryActive: () => true,
  REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE: "Email Request Alerts are not available.",
}));
import {
  CONFIRMATION_ROUTE_PATH,
  confirmSubscriptionPage,
  confirmationBodyParser,
  confirmationParserError,
  confirmationSecurityHeaders,
  createConfirmationRateLimiter,
  pauseConfirmationPage,
} from "./confirmSubscriptionRoute.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  SUBSCRIPTION_TOKEN_BYTES,
  digestSubscriptionToken,
} from "./subscriptionTokens.js";

/**
 * Two route-level proofs only: that the registered browser POST reaches the
 * accepted primitive against real MongoDB, and that reopening the same link is
 * idempotent. Slice 3A already owns atomicity, concurrency, lease interaction,
 * rollback, and field-rewrite coverage in `confirmSubscription.mongo.test.ts`.
 */
const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

function rawToken(byte: number): string {
  return Buffer.alloc(SUBSCRIPTION_TOKEN_BYTES, byte).toString("base64url");
}

/**
 * Mirrors the production chain, including the confirmation POST being
 * registered ahead of the global parsers. The limiter is supplied per test
 * rather than taken from the module: sharing the production instance would let
 * one case's requests fill the next case's window.
 */
function buildConfirmationApp(limiter: RequestHandler): Express {
  const app = express();
  app.post(
    CONFIRMATION_ROUTE_PATH,
    confirmationSecurityHeaders,
    pauseConfirmationPage,
    limiter,
    confirmationBodyParser,
    confirmSubscriptionPage,
    confirmationParserError
  );
  app.use(express.json({ limit: "100kb" }));
  app.use(express.urlencoded({ extended: true, limit: "100kb" }));
  return app;
}

async function postConfirmation(
  token: string,
  limiter: RequestHandler
): Promise<{ status: number; html: string }> {
  const server = createServer(buildConfirmationApp(limiter));
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });

  try {
    const { port } = server.address() as AddressInfo;
    const response = await fetch(
      `http://127.0.0.1:${port}${CONFIRMATION_ROUTE_PATH}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token }).toString(),
      }
    );
    return { status: response.status, html: await response.text() };
  } finally {
    if (server.listening) {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    }
  }
}

async function readSubscriberDocument(id: mongoose.Types.ObjectId) {
  return Subscriber.collection.findOne({ _id: id });
}

describeMongo("browser confirmation route against real MongoDB", () => {
  beforeAll(async () => {
    // Its own database: Mongo test files run concurrently and the subscription
    // suites clear the whole Subscriber collection between cases, so a shared
    // database would let one suite delete another's fixtures mid-test.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_confirmation_route_test",
    });
    await Subscriber.syncIndexes();
  });

  afterEach(async () => {
    vi.unstubAllEnvs();
    await Subscriber.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  async function insertPending(token: string, expiresInMs = 3_600_000) {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "helper@example.edu",
      status: "pending",
      confirmationTokenDigest: digestSubscriptionToken(token),
      confirmationExpiresAt: new Date(Date.now() + expiresInMs),
      bounced: false,
      dailyCount: 0,
    });
    return id;
  }

  it("confirms an eligible pending subscriber through the posted form", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    const limiter = createConfirmationRateLimiter();
    const token = rawToken(21);
    const id = await insertPending(token);

    const { status, html } = await postConfirmation(token, limiter);

    expect(status).toBe(200);
    expect(html).toContain("<h1>Email alerts confirmed.</h1>");
    expect(html).toContain(
      "You can now receive CommonPlate alerts about new food requests. No further action is needed."
    );

    const persisted = await readSubscriberDocument(id);
    expect(persisted?.status).toBe("confirmed");
    // Confirmation issues no unsubscribe credential in any form: the emailed
    // link is signed on demand from `_id` and the credential version.
    expect(persisted?.unsubscribeTokenDigest).toBeUndefined();
    expect(persisted?.unsubToken).toBeUndefined();
    expect(persisted?.confirmationTokenDigest).toBeUndefined();
  });

  it("treats a reopened link as already confirmed and mutates nothing further", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    // A fresh bucket per test: the previous case's requests must not count
    // toward this one, and neither may reach the production instance.
    const limiter = createConfirmationRateLimiter();
    const token = rawToken(22);
    const id = await insertPending(token);

    const first = await postConfirmation(token, limiter);
    expect(first.status).toBe(200);
    const afterFirst = await readSubscriberDocument(id);
    expect(afterFirst?.status).toBe("confirmed");

    const second = await postConfirmation(token, limiter);

    expect(second.status).toBe(200);
    expect(second.html).toContain("<h1>Your email is already confirmed.</h1>");
    expect(second.html).toContain(
      "You can receive CommonPlate alerts about new food requests. No further action is needed."
    );

    const afterSecond = await readSubscriberDocument(id);
    // The whole document is compared, so a second lifecycle mutation of any
    // field — including the unsubscribe credential version an emailed link
    // depends on — fails this.
    expect(afterSecond).toEqual(afterFirst);
  });
});
