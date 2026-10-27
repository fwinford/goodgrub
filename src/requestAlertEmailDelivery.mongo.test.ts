import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
const { send } = vi.hoisted(() => ({ send: vi.fn() }));
vi.mock("resend", () => ({ Resend: class { emails = { send }; } }));
import { Request as MealRequest, Subscriber, SendLog } from "../models/db.js";
import { runEligibilityNotificationSweep } from "./eligibilityNotificationSweep.js";
import { notifySubscriberAboutRecentRequests } from "./notifySubscribers.js";
import { confirmSubscription } from "./confirmSubscription.js";
import { digestSubscriptionToken } from "./subscriptionTokens.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

describeMongo("production-inactive Request Alert Email persistence", () => {
  beforeAll(async () => {
    await mongoose.connect(mongoUri!, { dbName: "commonplate_n1_email_shutdown_test" });
    await Promise.all([MealRequest.syncIndexes(), Subscriber.syncIndexes(), SendLog.syncIndexes()]);
  });
  afterEach(async () => {
    await Promise.all([MealRequest.deleteMany({}), Subscriber.deleteMany({}), SendLog.deleteMany({})]);
    send.mockClear();
  });
  afterAll(async () => { await mongoose.disconnect(); });

  it("marks the sweep initiated without provider, bounce, counter or SendLog changes", async () => {
    const now = new Date();
    const subscriber = await Subscriber.create({
      email: "helper@nyu.edu", status: "confirmed", dailyCount: 3,
      lastSentAt: new Date(now.getTime() - 60_000), bounced: false,
    });
    const before = await Subscriber.collection.findOne({ _id: subscriber._id });
    const request = await MealRequest.create({
      email: "requester@nyu.edu", vendor: "Campus Market", pickupName: "Private",
      food: "Private order", pickupWindowText: "ASAP", mealSwipes: 1, status: "open",
      visibleFrom: new Date(now.getTime() - 60_000),
      expiresAt: new Date(now.getTime() + 3_600_000),
      helperNotification: "awaiting-eligibility",
    });
    const result = await runEligibilityNotificationSweep({
      now: () => now, isPaused: () => false,
      dispatchPush: async () => "processed",
    });
    expect(result).toMatchObject({ initiated: 1, deferred: 0 });
    expect((await MealRequest.findById(request._id).lean())?.helperNotification).toBe("initiated");
    await notifySubscriberAboutRecentRequests(subscriber);
    expect(await Subscriber.collection.findOne({ _id: subscriber._id })).toEqual(before);
    expect(await SendLog.countDocuments({})).toBe(0);
    expect(send).not.toHaveBeenCalled();
    expect(await runEligibilityNotificationSweep({
      now: () => now, isPaused: () => false, dispatchPush: async () => "processed",
    })).toMatchObject({ candidates: 0, initiated: 0, deferred: 0 });
  });

  it("leaves an old pending confirmation pending rather than activating it", async () => {
    const token = Buffer.alloc(32, 5).toString("base64url");
    const subscriber = await Subscriber.create({
      email: "pending@nyu.edu", status: "pending",
      confirmationTokenDigest: digestSubscriptionToken(token),
      confirmationExpiresAt: new Date(Date.now() + 60_000),
    });
    const before = await Subscriber.collection.findOne({ _id: subscriber._id });
    expect(await confirmSubscription(token, new Date())).toEqual({ outcome: "unavailable" });
    expect(await Subscriber.collection.findOne({ _id: subscriber._id })).toEqual(before);
    expect(send).not.toHaveBeenCalled();
  });
});
