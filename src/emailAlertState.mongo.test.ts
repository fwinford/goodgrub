import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { Subscriber } from "../models/db.js";
import { readEmailAlertState } from "./emailAlertState.js";

/**
 * Real-Mongo acceptance for the W4-N0 Email Request Alert state read: that
 * absent, pending, confirmed, and unsubscribed Subscriber rows map exactly
 * to the accepted binary result, and that the lookup is scoped to the exact
 * principal only. Route-level authority-gate and privacy-projection behavior
 * are proved against stubbed persistence in `emailAlertStateRoute.test.ts`.
 */
const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

describeMongo("W4-N0 email alert state read against real MongoDB", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_email_alert_state_test",
    });
  });

  afterEach(async () => {
    await Subscriber.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("reports inactive for a principal with no Subscriber row, and creates none", async () => {
    const result = await readEmailAlertState("absent@nyu.edu");

    expect(result).toEqual({ active: false });
    expect(await Subscriber.countDocuments({})).toBe(0);
  });

  it("reports inactive for a pending Subscriber", async () => {
    await Subscriber.create({
      email: "pending@nyu.edu",
      status: "pending",
      confirmationTokenDigest: "digest",
      confirmationExpiresAt: new Date(Date.now() + 60_000),
    });

    expect(await readEmailAlertState("pending@nyu.edu")).toEqual({
      active: false,
    });
  });

  it("reports active for a confirmed Subscriber", async () => {
    await Subscriber.create({
      email: "confirmed@nyu.edu",
      status: "confirmed",
    });

    expect(await readEmailAlertState("confirmed@nyu.edu")).toEqual({
      active: true,
    });
  });

  it("reports inactive for an unsubscribed Subscriber", async () => {
    await Subscriber.create({
      email: "unsubscribed@nyu.edu",
      status: "unsubscribed",
      unsubscribedAt: new Date(),
    });

    expect(await readEmailAlertState("unsubscribed@nyu.edu")).toEqual({
      active: false,
    });
  });

  it("scopes strictly to the exact principal: another confirmed Subscriber cannot affect the result", async () => {
    await Subscriber.create({
      email: "someone-else@nyu.edu",
      status: "confirmed",
    });

    expect(await readEmailAlertState("caller@nyu.edu")).toEqual({
      active: false,
    });
  });

  it("performs no mutation on any lifecycle state", async () => {
    const created = await Subscriber.create({
      email: "readonly@nyu.edu",
      status: "confirmed",
      dailyCount: 2,
    });

    await readEmailAlertState("readonly@nyu.edu");

    const stored = await Subscriber.findById(created._id)
      .lean<Record<string, unknown>>()
      .exec();
    expect(stored?.status).toBe("confirmed");
    expect(stored?.dailyCount).toBe(2);
  });
});
