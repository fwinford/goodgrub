import type { Request, Response } from "express";
import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";
const { send } = vi.hoisted(() => ({ send: vi.fn(async () => ({ data: { id: "test" } })) }));
vi.mock("resend", () => ({ Resend: class { emails = { send }; } }));
import { Subscriber, SendLog, Request as MealRequest } from "../models/db.js";
import { isRequestAlertEmailDeliveryActive } from "./requestAlertEmailDelivery.js";
import { createSubscribeHandler } from "./subscribeRoute.js";
import { confirmSubscription } from "./confirmSubscription.js";
import { createConfirmSubscriptionPageHandler, showConfirmationPage } from "./confirmSubscriptionRoute.js";
import { notifySubscribersForRequest, notifySubscriberAboutRecentRequests } from "./notifySubscribers.js";
import {
  sendNewRequestAlert, sendSubscriptionConfirmationEmail,
  sendFulfillmentEmail, sendParticipantVerificationEmail,
} from "./emailHelpers.js";
import { sendDigestEmail } from "./sendDigestEmail.js";

function context() {
  const req = { body: { email: "student@nyu.edu", token: "x".repeat(43) }, query: { token: "x".repeat(43) } } as unknown as Request;
  let status = 200;
  let body: unknown;
  const res = {
    status(code: number) { status = code; return this; },
    json(value: unknown) { body = value; return this; },
    type() { return this; },
    set() { return this; },
    send(value: unknown) { body = value; return this; },
  } as unknown as Response;
  return { req, res, get status() { return status; }, get body() { return body; } };
}

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); send.mockClear(); });

describe("V1 Request Alert Email shutdown (production defaults)", () => {
  it("cannot be reactivated by release environment configuration", () => {
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    vi.stubEnv("REQUEST_ALERT_EMAIL_DELIVERY_ACTIVE", "true");
    expect(isRequestAlertEmailDeliveryActive()).toBe(false);
  });

  it("refuses enrollment, activation and both old-link routes without lifecycle work", async () => {
    const read = vi.spyOn(Subscriber, "findOne");
    const update = vi.spyOn(Subscriber, "findOneAndUpdate");
    const create = vi.spyOn(Subscriber, "create");
    const c = context();
    await createSubscribeHandler()(c.req, c.res);
    expect(c.status).toBe(410);
    expect(await confirmSubscription(c.req.body.token, new Date())).toEqual({ outcome: "unavailable" });
    for (const handler of [showConfirmationPage, createConfirmSubscriptionPageHandler()]) {
      await handler(c.req, c.res);
      expect(c.status).toBe(410);
      expect(String(c.body)).toContain("Email Request Alerts are not available.");
      expect(String(c.body)).not.toContain("<form");
    }
    for (const spy of [read, update, create, send]) expect(spy).not.toHaveBeenCalled();
  });

  it("terminally processes fan-out and catch-up before any SendLog or Subscriber work", async () => {
    const claim = vi.spyOn(SendLog, "create");
    const recipients = vi.spyOn(Subscriber, "find");
    const update = vi.spyOn(Subscriber, "updateOne");
    const requests = vi.spyOn(MealRequest, "find");
    expect(await notifySubscribersForRequest(new MealRequest())).toBe("processed");
    await notifySubscriberAboutRecentRequests(new Subscriber({ status: "confirmed" }));
    for (const spy of [claim, recipients, update, requests, send]) expect(spy).not.toHaveBeenCalled();
  });

  it("refuses direct alert, digest and confirmation provider calls", async () => {
    vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
    const subscriber = new Subscriber({ email: "helper@nyu.edu" });
    const request = new MealRequest({ email: "requester@nyu.edu" });
    for (const attempt of [
      () => sendNewRequestAlert(subscriber, request),
      () => sendDigestEmail(subscriber, [request]),
      () => sendSubscriptionConfirmationEmail("helper@nyu.edu", "x".repeat(43)),
    ]) await expect(attempt()).rejects.toThrow("Email Request Alerts are not available.");
    expect(send).not.toHaveBeenCalled();
  });

  it("preserves verification and placement email", async () => {
    await sendParticipantVerificationEmail("student@nyu.edu", "123456", 5);
    await sendFulfillmentEmail(new MealRequest({
      email: "student@nyu.edu", vendor: "Test", pickupWindowText: "ASAP",
    }), "123");
    expect(send).toHaveBeenCalledTimes(2);
  });

  it("guards the digest before any query or ledger work and the direct script through fan-out", () => {
    const app = readFileSync(new URL("../app.ts", import.meta.url), "utf8");
    const digest = app.slice(app.indexOf('scheduleAppJob("5 * * * *"'), app.indexOf("// Daily cron job"));
    expect(digest.indexOf("if (!isRequestAlertEmailDeliveryActive()) return;")).toBeLessThan(digest.indexOf("MealRequest.find"));
    expect(digest).toContain("if (!isRequestAlertEmailDeliveryActive()) return;");
    const script = readFileSync(new URL("../scripts/trigger-notify.ts", import.meta.url), "utf8");
    expect(script).toContain("notifySubscribersForRequest");
  });
});
