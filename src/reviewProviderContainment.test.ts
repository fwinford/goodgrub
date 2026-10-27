import http2 from "node:http2";
import cron from "node-cron";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
const { send } = vi.hoisted(() => ({ send: vi.fn() }));
vi.mock("resend", () => ({ Resend: class { emails = { send }; } }));
import {
  Request as MealRequest, Subscriber, SendLog, PushDelivery, Installation,
} from "../models/db.js";
import {
  sendEmailSafe, sendFulfillmentEmail, sendParticipantVerificationEmail,
  sendSubscriptionConfirmationEmail,
} from "./emailHelpers.js";
import { openApnsConnection } from "./apnsClient.js";
import { callScreenshotProvider } from "./screenshotProposalProvider.js";
import { dispatchHelperNewRequestPush } from "./helperNewRequestPush.js";
import { dispatchRequesterFulfillmentPush } from "./requesterFulfillmentPush.js";
import { runEligibilityNotificationSweep } from "./eligibilityNotificationSweep.js";
import { notifySubscribersForRequest, notifySubscriberAboutRecentRequests } from "./notifySubscribers.js";
import { sendDigestEmail } from "./sendDigestEmail.js";
import { isSchedulerEnabled, registerScheduledJob } from "./scheduledJobs.js";

beforeEach(() => {
  vi.stubEnv("NODE_ENV", "review");
  // Deliberately contradictory: transports and jobs must still refuse.
  vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
  vi.stubEnv("SCHEDULER_ENABLED", "true");
  send.mockClear();
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); });

describe("unconditional review provider and scheduler containment", () => {
  it("refuses direct email, fulfillment, verification, confirmation and digest sends", async () => {
    const request = new MealRequest({
      vendor: "Fictional venue", email: "requester@example.invalid",
      food: "Fictional meal", pickupWindowText: "ASAP",
    });
    const subscriber = new Subscriber({ email: "helper@example.invalid" });
    for (const attempt of [
      () => sendEmailSafe({ from: "sender@example.invalid", to: "recipient@example.invalid", subject: "test", text: "test" }),
      () => sendFulfillmentEmail(request, "123"),
      () => sendParticipantVerificationEmail("requester@example.invalid", "123456", 5),
      () => sendSubscriptionConfirmationEmail("requester@example.invalid", "fictional"),
      () => sendDigestEmail(subscriber, [request]),
    ]) {
      await expect(attempt()).rejects.toThrow("External providers are disabled");
    }
    expect(send).not.toHaveBeenCalled();
  });

  it("refuses APNs before opening even an injected connection", () => {
    const connect = vi.spyOn(http2, "connect");
    expect(() => openApnsConnection("https://api.push.apple.com")).toThrow("External providers are disabled");
    expect(connect).not.toHaveBeenCalled();
  });

  it("refuses OpenAI before invoking even an injected fetch", async () => {
    const fetchImpl = vi.fn();
    await expect(callScreenshotProvider({
      images: [], apiKey: "not-a-real-key", timeoutMs: 100, fetchImpl,
    })).rejects.toThrow("External providers are disabled");
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("skips direct dispatches and sweeps before database/provider bookkeeping", async () => {
    const query = vi.spyOn(MealRequest, "find");
    const subscribers = vi.spyOn(Subscriber, "find");
    const sendLog = vi.spyOn(SendLog, "create");
    const pushLog = vi.spyOn(PushDelivery, "create");
    const installations = vi.spyOn(Installation, "find");
    const request = new MealRequest();
    const isPaused = vi.fn(() => false);
    expect((await dispatchHelperNewRequestPush(request, { isPaused })).stop).toBe("paused");
    expect((await dispatchRequesterFulfillmentPush(request, { isPaused })).stop).toBe("paused");
    expect((await runEligibilityNotificationSweep({ isPaused })).stop).toBe("paused");
    await notifySubscribersForRequest(request);
    await notifySubscriberAboutRecentRequests(new Subscriber());
    for (const spy of [query, subscribers, sendLog, pushLog, installations, isPaused, send]) {
      expect(spy).not.toHaveBeenCalled();
    }
  });

  it("cannot enable cron with an explicit option or environment value in review", () => {
    const schedule = vi.spyOn(cron, "schedule");
    const job = vi.fn();
    expect(isSchedulerEnabled()).toBe(false);
    expect(registerScheduledJob("* * * * *", job, { enabled: true })).toBeUndefined();
    expect(schedule).not.toHaveBeenCalled();
    expect(job).not.toHaveBeenCalled();
  });
});
