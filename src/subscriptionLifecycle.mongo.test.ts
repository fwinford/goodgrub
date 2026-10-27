import express, { type Express, type RequestHandler } from "express";
import rateLimit from "express-rate-limit";
import mongoose from "mongoose";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
vi.mock("./requestAlertEmailDelivery.js", () => ({
  isRequestAlertEmailDeliveryActive: () => true,
  assertRequestAlertEmailDeliveryActive: () => {},
  REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE: "Email Request Alerts are not available.",
}));

/**
 * The email provider, replaced at the boundary the production code already
 * owns. Everything above it is real: the same `emailHelpers.ts` that composes a
 * confirmation, an alert, and a digest, including the links they carry.
 */
const { resendSend } = vi.hoisted(() => ({ resendSend: vi.fn() }));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

import { Request as MealRequest, SendLog, Subscriber, System } from "../models/db.js";
import {
  CONFIRMATION_ROUTE_PATH,
  confirmSubscriptionPage,
  confirmationBodyParser,
  confirmationParserError,
  confirmationSecurityHeaders,
  createConfirmationRateLimiter,
  pauseConfirmationPage,
  showConfirmationPage,
} from "./confirmSubscriptionRoute.js";
import { sendDigestEmail } from "./sendDigestEmail.js";
import { notifySubscribersForRequest } from "./notifySubscribers.js";
import {
  PUBLIC_ACTIONS_PAUSED_ENV,
  SUBSCRIBE_UNAVAILABLE_MESSAGE,
  pausePublicAction,
} from "./publicActionsPause.js";
import { subscribe } from "./subscribeRoute.js";
import { digestSubscriptionToken } from "./subscriptionTokens.js";
import {
  MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES,
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
  UNSUBSCRIBE_SIGNING_SECRET_ENV,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";
import {
  createUnsubscribeRateLimiter,
  pauseUnsubscribePage,
  showUnsubscribePage,
  unsubscribeBodyParser,
  unsubscribePage,
  unsubscribeParserError,
  unsubscribeSecurityHeaders,
} from "./unsubscribeRoute.js";

/**
 * Backend acceptance for the complete email lifecycle, end to end against real
 * MongoDB through the production handlers, helpers, and emails:
 *
 *   signup → pending → confirmation email → safe GET → explicit POST
 *   → confirmed and alert-eligible → alert/digest email carrying an unsubscribe
 *   link → safe GET → explicit POST → unsubscribed and ineligible
 *   → re-signup on the same row → reconfirmation → the original link still works
 *
 * The individual units are already covered by their own focused suites. What is
 * proved here is that they compose: that the link a real confirmation email
 * carries redeems, that the credential a real alert or digest carries reaches
 * the real unsubscribe route, and that identity, counters, history, and the
 * credential version survive a full round trip.
 *
 * Nothing is unpaused in the repository or in any deployed configuration. Each
 * case states the pause it needs for itself, exactly as the Slice 4B suite does.
 */
const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

const SIGNING_SECRET = "l".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES);
const SECRET = Buffer.from(SIGNING_SECRET, "utf8");
const BASE_URL = "https://commonplate.test";
const EMAIL = "lifecycle-helper@nyu.edu";

const ONE_HOUR_MS = 60 * 60 * 1000;

interface SentEmail {
  to: string;
  subject: string;
  html: string;
  text: string;
}

function sentEmails(): SentEmail[] {
  return resendSend.mock.calls.map((call) => call[0] as SentEmail);
}

function onlyEmail(): SentEmail {
  const emails = sentEmails();
  expect(emails).toHaveLength(1);
  return emails[0];
}

/** Both bodies must carry the same link, so both are searched and compared. */
function linkIn(email: SentEmail, pattern: RegExp): string {
  const fromHtml = email.html.match(pattern);
  const fromText = email.text.match(pattern);
  expect(fromHtml, `no link matching ${pattern} in the HTML body`).not.toBeNull();
  expect(fromText, `no link matching ${pattern} in the text body`).not.toBeNull();
  expect(fromText![0]).toBe(fromHtml![0]);
  return fromText![0];
}

const CONFIRMATION_LINK_PATTERN = new RegExp(
  `https?://[^\\s"'<>]*${CONFIRMATION_ROUTE_PATH}\\?token=[^\\s"'<>]+`
);
const UNSUBSCRIBE_LINK_PATTERN = new RegExp(
  `https?://[^\\s"'<>]*${UNSUBSCRIBE_ROUTE_PATH}\\?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=[^\\s"'<>]+`
);

function confirmationTokenIn(email: SentEmail): string {
  const token = new URL(linkIn(email, CONFIRMATION_LINK_PATTERN)).searchParams.get(
    "token"
  );
  expect(token).toBeTruthy();
  return token!;
}

function unsubscribeCredentialIn(email: SentEmail): string {
  const credential = new URL(
    linkIn(email, UNSUBSCRIBE_LINK_PATTERN)
  ).searchParams.get(UNSUBSCRIBE_CREDENTIAL_PARAMETER);
  expect(credential).toBeTruthy();
  return credential!;
}

/**
 * The production registration for signup, mirrored: the pause guard ahead of
 * the limiter and the handler. A fresh limiter per app, because these cases
 * make more signup attempts than one 5-per-minute window allows and a shared
 * bucket would make one case depend on another.
 */
function buildSubscribeApp(): Express {
  const app = express();
  app.use(express.json({ limit: "100kb" }));
  app.use(express.urlencoded({ extended: true, limit: "100kb" }));
  app.post(
    "/api/subscribe",
    pausePublicAction(SUBSCRIBE_UNAVAILABLE_MESSAGE),
    rateLimit({ windowMs: 60_000, max: 5 }),
    subscribe
  );
  return app;
}

/** Registered ahead of the global parsers, exactly as `app.ts` does. */
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
  app.get(
    CONFIRMATION_ROUTE_PATH,
    confirmationSecurityHeaders,
    pauseConfirmationPage,
    showConfirmationPage
  );
  return app;
}

function buildUnsubscribeApp(limiter: RequestHandler): Express {
  const app = express();
  app.post(
    UNSUBSCRIBE_ROUTE_PATH,
    unsubscribeSecurityHeaders,
    pauseUnsubscribePage,
    limiter,
    unsubscribeBodyParser,
    unsubscribePage,
    unsubscribeParserError
  );
  app.use(express.json({ limit: "100kb" }));
  app.use(express.urlencoded({ extended: true, limit: "100kb" }));
  app.get(
    UNSUBSCRIBE_ROUTE_PATH,
    unsubscribeSecurityHeaders,
    pauseUnsubscribePage,
    showUnsubscribePage
  );
  return app;
}

interface HttpResult {
  status: number;
  body: string;
}

async function withServer(
  app: Express,
  run: (baseUrl: string) => Promise<HttpResult>
): Promise<HttpResult> {
  const server = createServer(app);
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });

  try {
    const { port } = server.address() as AddressInfo;
    return await run(`http://127.0.0.1:${port}`);
  } finally {
    if (server.listening) {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    }
  }
}

/** Signup through the registered route, pause guard included. */
async function postSignup(email: string): Promise<HttpResult> {
  return withServer(buildSubscribeApp(), async (baseUrl) => {
    const response = await fetch(`${baseUrl}/api/subscribe`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email }),
    });
    return { status: response.status, body: await response.text() };
  });
}

/**
 * An emailed link is opened by its own URL, so the origin the email carries is
 * exercised rather than a path rebuilt by the test.
 */
async function openEmailedLink(
  app: Express,
  url: string
): Promise<HttpResult> {
  return withServer(app, async (baseUrl) => {
    const { pathname, search } = new URL(url);
    const response = await fetch(`${baseUrl}${pathname}${search}`);
    return { status: response.status, body: await response.text() };
  });
}

async function getConfirmationLink(url: string): Promise<HttpResult> {
  return openEmailedLink(buildConfirmationApp(createConfirmationRateLimiter()), url);
}

async function postConfirmation(token: string): Promise<HttpResult> {
  return withServer(
    buildConfirmationApp(createConfirmationRateLimiter()),
    async (baseUrl) => {
      const response = await fetch(`${baseUrl}${CONFIRMATION_ROUTE_PATH}`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token }).toString(),
      });
      return { status: response.status, body: await response.text() };
    }
  );
}

async function getUnsubscribeLink(url: string): Promise<HttpResult> {
  return openEmailedLink(buildUnsubscribeApp(createUnsubscribeRateLimiter()), url);
}

async function postUnsubscribe(credential: string): Promise<HttpResult> {
  return withServer(
    buildUnsubscribeApp(createUnsubscribeRateLimiter()),
    async (baseUrl) => {
      const response = await fetch(`${baseUrl}${UNSUBSCRIBE_ROUTE_PATH}`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          [UNSUBSCRIBE_CREDENTIAL_PARAMETER]: credential,
        }).toString(),
      });
      return { status: response.status, body: await response.text() };
    }
  );
}

/** The stored document as the driver sees it: field presence is evidence here. */
async function readSubscriber(
  id: mongoose.Types.ObjectId
): Promise<Record<string, unknown> | null> {
  return Subscriber.collection.findOne({ _id: id });
}

async function readOnlySubscriber(): Promise<Record<string, unknown>> {
  const documents = await Subscriber.collection.find({}).toArray();
  expect(documents).toHaveLength(1);
  return documents[0];
}

/** An effectively available request, so the alert path can truthfully send it. */
async function createAvailableRequest(vendor: string) {
  return MealRequest.create({
    vendor,
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    pickupWindowText: "1:00 PM – 2:00 PM",
    email: "requester-private@example.edu",
    status: "open",
    expiresAt: new Date(Date.now() + 4 * ONE_HOUR_MS),
  });
}

/**
 * The real-time alert path, with the real selection query and the real email.
 * Returns every email the run submitted, so a case can assert on delivery
 * rather than on the query it believes the path runs.
 */
async function runRealTimeAlert(vendor: string): Promise<SentEmail[]> {
  resendSend.mockClear();
  const request = await createAvailableRequest(vendor);
  await notifySubscribersForRequest(request);
  return sentEmails();
}

/**
 * The hourly digest selection, as `app.ts` runs it. That cron cannot be
 * imported — `app.ts` connects and listens at module scope — and
 * `publicActionsRoutes.test.ts` pins the query's `status: "confirmed"` against
 * the real source, so this counts what that selection would return.
 */
function digestEligibleCount(): Promise<number> {
  const oneHourAgo = new Date(Date.now() - ONE_HOUR_MS);
  return Subscriber.countDocuments({
    status: "confirmed",
    bounced: false,
    dailyCount: { $lt: 4 },
    $or: [{ lastSentAt: { $lt: oneHourAgo } }, { lastSentAt: null }],
  });
}

interface PendingSubscriber {
  id: mongoose.Types.ObjectId;
  confirmationToken: string;
  confirmationUrl: string;
}

/**
 * Signup through the real route, asserting the accepted response, the pending
 * row it wrote, and that the emailed link carries the token whose digest that
 * row now holds. Every later stage starts from this, so its assertions are the
 * fixture-validity proof for everything downstream.
 */
async function signupAndReadConfirmationLink(
  email = EMAIL
): Promise<PendingSubscriber> {
  resendSend.mockClear();

  const response = await postSignup(email);
  expect(response.status).toBe(202);

  const confirmationEmail = onlyEmail();
  expect(confirmationEmail.to).toBe(email);

  const stored = await Subscriber.collection.findOne({ email });
  expect(stored).not.toBeNull();
  expect(stored!.status).toBe("pending");

  const confirmationUrl = linkIn(confirmationEmail, CONFIRMATION_LINK_PATTERN);
  const confirmationToken = confirmationTokenIn(confirmationEmail);
  // The link is usable because it carries the token this row was written with,
  // not because it looks like a URL.
  expect(stored!.confirmationTokenDigest).toBe(
    digestSubscriptionToken(confirmationToken)
  );

  return {
    id: stored!._id as mongoose.Types.ObjectId,
    confirmationToken,
    confirmationUrl,
  };
}

/** The explicit confirmation POST, asserted to have transitioned the row. */
async function confirmThroughBrowser(
  pending: PendingSubscriber
): Promise<void> {
  const posted = await postConfirmation(pending.confirmationToken);
  expect(posted.status).toBe(200);
  expect(posted.body).toContain("<h1>Email alerts confirmed.</h1>");
  expect((await readSubscriber(pending.id))?.status).toBe("confirmed");
}

describeMongo("subscription email lifecycle against real MongoDB", () => {
  beforeAll(async () => {
    // Its own database. Mongo files run concurrently and every subscription
    // suite clears the whole Subscriber collection between cases, so a shared
    // database would let one suite delete another's fixtures mid-test.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_lifecycle_test",
    });
  });

  beforeEach(() => {
    resendSend.mockReset();
    resendSend.mockResolvedValue({});
    // Stated per case rather than globally: the production handlers read all
    // three, and a case that needs the pause on says so for itself.
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, SIGNING_SECRET);
    vi.stubEnv("BASE_URL", BASE_URL);
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    await Subscriber.deleteMany({});
    await SendLog.deleteMany({});
    await MealRequest.deleteMany({});
    await System.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  describe("signup and the confirmation email", () => {
    it("creates one pending Subscriber for a new address", async () => {
      const response = await postSignup(EMAIL);

      expect(response.status).toBe(202);
      const stored = await readOnlySubscriber();
      expect(stored.email).toBe(EMAIL);
      expect(stored.status).toBe("pending");
      expect(stored.confirmationTokenDigest).toEqual(expect.any(String));
      expect(
        (stored.confirmationExpiresAt as Date).getTime()
      ).toBeGreaterThan(Date.now());
      // The schema default, untouched by signup: the revocation counter behind
      // every unsubscribe link this address will ever be sent.
      expect(stored.unsubscribeCredentialVersion).toBe(1);
      expect(stored.dailyCount).toBe(0);
    });

    it("rotates the same Subscriber rather than creating a second one", async () => {
      const first = await signupAndReadConfirmationLink();

      const second = await signupAndReadConfirmationLink();

      expect(second.id).toEqual(first.id);
      expect(await Subscriber.countDocuments({})).toBe(1);
      // A rotation, not a reissue of the same link: the fresh credential must
      // differ, and the previous one must be dead.
      expect(second.confirmationToken).not.toBe(first.confirmationToken);
      const stored = await readOnlySubscriber();
      expect(stored.confirmationTokenDigest).toBe(
        digestSubscriptionToken(second.confirmationToken)
      );
      expect(stored.confirmationTokenDigest).not.toBe(
        digestSubscriptionToken(first.confirmationToken)
      );
    });

    it("emails a confirmation link built from the configured base URL", async () => {
      const pending = await signupAndReadConfirmationLink();

      expect(pending.confirmationUrl.startsWith(`${BASE_URL}${CONFIRMATION_ROUTE_PATH}`)).toBe(
        true
      );
      // The raw token exists only in the emailed link; the row holds a digest.
      const stored = await readSubscriber(pending.id);
      expect(JSON.stringify(stored)).not.toContain(pending.confirmationToken);
    });
  });

  describe("confirmation", () => {
    it("mutates nothing when the emailed link is merely opened", async () => {
      const pending = await signupAndReadConfirmationLink();
      const before = await readSubscriber(pending.id);

      // Three opens, because a scanner, a previewer, and a person all fetch it.
      for (let attempt = 0; attempt < 3; attempt++) {
        const opened = await getConfirmationLink(pending.confirmationUrl);
        expect(opened.status).toBe(200);
        expect(opened.body).toContain("<h1>Confirm email alerts</h1>");
      }

      expect(await readSubscriber(pending.id)).toEqual(before);
      expect((await readSubscriber(pending.id))?.status).toBe("pending");
    });

    it("transitions pending to confirmed on the explicit POST", async () => {
      const pending = await signupAndReadConfirmationLink();
      expect((await readSubscriber(pending.id))?.status).toBe("pending");

      const posted = await postConfirmation(pending.confirmationToken);

      expect(posted.status).toBe(200);
      expect(posted.body).toContain("<h1>Email alerts confirmed.</h1>");
      const stored = await readSubscriber(pending.id);
      expect(stored?.status).toBe("confirmed");
      expect(stored?._id).toEqual(pending.id);
      // Confirmation must never move the revocation counter: it would kill
      // every unsubscribe link already delivered to this address.
      expect(stored?.unsubscribeCredentialVersion).toBe(1);
    });

    it("makes the address alert-eligible only after that POST", async () => {
      const pending = await signupAndReadConfirmationLink();

      // Pending is the ineligible half of the fixture, proved through the real
      // send path rather than a query the test wrote.
      expect(await runRealTimeAlert("Pending Vendor")).toHaveLength(0);
      expect(await digestEligibleCount()).toBe(0);

      await confirmThroughBrowser(pending);

      // Digest eligibility is read before the alert runs: that send starts the
      // hourly cooldown both selections share, so checking afterwards would
      // measure the cooldown rather than the status.
      expect(await digestEligibleCount()).toBe(1);
      const alerts = await runRealTimeAlert("Confirmed Vendor");
      expect(alerts).toHaveLength(1);
      expect(alerts[0].to).toBe(EMAIL);
    });
  });

  describe("the unsubscribe link an alert or digest carries", () => {
    it("reaches the real unsubscribe route from a real-time alert", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);

      const alerts = await runRealTimeAlert("Alert Vendor");
      expect(alerts).toHaveLength(1);
      const credential = unsubscribeCredentialIn(alerts[0]);
      // Authentic for exactly this subscriber, before it is sent anywhere.
      expect(verifyUnsubscribeCredential(credential, SECRET)).toEqual({
        subscriberId: String(pending.id),
        credentialVersion: 1,
      });

      const opened = await getUnsubscribeLink(
        linkIn(alerts[0], UNSUBSCRIBE_LINK_PATTERN)
      );

      expect(opened.status).toBe(200);
      expect(opened.body).toContain(
        "<h1>Unsubscribe from CommonPlate alerts?</h1>"
      );
      expect(opened.body).toContain(
        `<input type="hidden" name="credential" value="${credential}" />`
      );
    });

    it("reaches the real unsubscribe route from a digest", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);
      const subscriber = await Subscriber.findById(pending.id);
      const request = await createAvailableRequest("Digest Vendor");

      resendSend.mockClear();
      await sendDigestEmail(subscriber!, [request]);
      const digest = onlyEmail();
      const credential = unsubscribeCredentialIn(digest);

      expect(verifyUnsubscribeCredential(credential, SECRET)).toEqual({
        subscriberId: String(pending.id),
        credentialVersion: 1,
      });
      const opened = await getUnsubscribeLink(
        linkIn(digest, UNSUBSCRIBE_LINK_PATTERN)
      );
      expect(opened.status).toBe(200);
      expect(opened.body).toContain(
        "<h1>Unsubscribe from CommonPlate alerts?</h1>"
      );
    });

    it("mutates nothing when that link is merely opened", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);
      const alerts = await runRealTimeAlert("Preview Vendor");
      const url = linkIn(alerts[0], UNSUBSCRIBE_LINK_PATTERN);
      const before = await readSubscriber(pending.id);

      for (let attempt = 0; attempt < 3; attempt++) {
        expect((await getUnsubscribeLink(url)).status).toBe(200);
      }

      expect(await readSubscriber(pending.id)).toEqual(before);
      expect((await readSubscriber(pending.id))?.status).toBe("confirmed");
    });
  });

  describe("unsubscribe", () => {
    it("transitions the Subscriber and clears its confirmation credentials", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);
      const alerts = await runRealTimeAlert("Unsubscribe Vendor");
      const credential = unsubscribeCredentialIn(alerts[0]);
      // The receipt a real confirmation left behind is physically present
      // before the mutation, so its removal below is a real change.
      const before = await readSubscriber(pending.id);
      expect(before).toHaveProperty("lastConfirmedTokenDigest");
      expect(before).toHaveProperty("lastConfirmedTokenExpiresAt");

      const posted = await postUnsubscribe(credential);

      expect(posted.status).toBe(200);
      expect(posted.body).toContain("<h1>You’re unsubscribed</h1>");
      const stored = await readSubscriber(pending.id);
      expect(stored?.status).toBe("unsubscribed");
      expect(stored?.unsubscribedAt).toBeInstanceOf(Date);
      for (const cleared of [
        "confirmationTokenDigest",
        "confirmationExpiresAt",
        "confirmationSendAttemptId",
        "confirmationSendAttemptAt",
        "lastConfirmedTokenDigest",
        "lastConfirmedTokenExpiresAt",
      ]) {
        expect(stored).not.toHaveProperty(cleared);
      }
    });

    it("is idempotent when the same link is submitted again", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);
      const credential = unsubscribeCredentialIn(
        (await runRealTimeAlert("Repeat Vendor"))[0]
      );

      const first = await postUnsubscribe(credential);
      const afterFirst = await readSubscriber(pending.id);
      const second = await postUnsubscribe(credential);

      expect(second.status).toBe(first.status);
      expect(second.body).toBe(first.body);
      // The whole document, so any second write fails this.
      expect(await readSubscriber(pending.id)).toEqual(afterFirst);
    });

    it("takes the address out of later alert and digest selection", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);

      // Eligible, proved by a real send rather than by a query.
      const alerts = await runRealTimeAlert("Before Vendor");
      expect(alerts).toHaveLength(1);
      const credential = unsubscribeCredentialIn(alerts[0]);

      // That send started an hourly cooldown, which would be a second reason
      // for the next run to skip this address. Clearing it is what makes the
      // status the only remaining explanation below.
      await Subscriber.collection.updateOne(
        { _id: pending.id },
        { $set: { lastSentAt: null, dailyCount: 0 } }
      );
      const rested = await readSubscriber(pending.id);
      expect(rested?.lastSentAt).toBeNull();
      expect(rested?.dailyCount).toBe(0);
      expect(await digestEligibleCount()).toBe(1);

      expect((await postUnsubscribe(credential)).status).toBe(200);

      expect(await runRealTimeAlert("After Vendor")).toHaveLength(0);
      expect(await digestEligibleCount()).toBe(0);
      expect(await Subscriber.countDocuments({ status: "confirmed" })).toBe(0);
    });
  });

  describe("re-signup, reconfirmation, and the durable link", () => {
    it("preserves identity, credential version, counters, and history", async () => {
      const first = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(first);
      const alerts = await runRealTimeAlert("History Vendor");
      const credential = unsubscribeCredentialIn(alerts[0]);
      expect((await postUnsubscribe(credential)).status).toBe(200);

      const afterUnsubscribe = await readSubscriber(first.id);
      const sendLogCount = await SendLog.countDocuments({
        subscriberId: first.id,
      });
      expect(sendLogCount).toBe(1);
      expect(afterUnsubscribe?.dailyCount).toBe(1);
      expect(afterUnsubscribe?.lastSentAt).toBeInstanceOf(Date);
      expect(afterUnsubscribe?.unsubscribedAt).toBeInstanceOf(Date);

      const again = await signupAndReadConfirmationLink();

      expect(again.id).toEqual(first.id);
      const stored = await readSubscriber(first.id);
      expect(stored?.status).toBe("pending");
      expect(stored?.unsubscribeCredentialVersion).toBe(
        afterUnsubscribe?.unsubscribeCredentialVersion
      );
      expect(stored?.unsubscribeCredentialVersion).toBe(1);
      expect(stored?.dailyCount).toBe(afterUnsubscribe?.dailyCount);
      expect(stored?.lastSentAt).toEqual(afterUnsubscribe?.lastSentAt);
      expect(stored?.bounced).toBe(afterUnsubscribe?.bounced);
      // Unsubscribe history is not rewritten by signing up again.
      expect(stored?.unsubscribedAt).toEqual(afterUnsubscribe?.unsubscribedAt);
      expect(
        await SendLog.countDocuments({ subscriberId: first.id })
      ).toBe(sendLogCount);
      expect(await Subscriber.countDocuments({})).toBe(1);
    });

    it("issues a fresh confirmation credential and retires the previous one", async () => {
      const first = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(first);
      const credential = unsubscribeCredentialIn(
        (await runRealTimeAlert("Fresh Vendor"))[0]
      );
      await postUnsubscribe(credential);

      const again = await signupAndReadConfirmationLink();

      expect(again.confirmationToken).not.toBe(first.confirmationToken);
      const stored = await readSubscriber(first.id);
      expect(stored?.confirmationTokenDigest).toBe(
        digestSubscriptionToken(again.confirmationToken)
      );
      // The retired link cannot activate the address that asked to stop.
      const retired = await postConfirmation(first.confirmationToken);
      expect(retired.status).toBe(400);
      expect(retired.body).toContain(
        "<h1>This confirmation link is invalid.</h1>"
      );
      expect((await readSubscriber(first.id))?.status).toBe("pending");
    });

    it("restores eligibility on reconfirmation and keeps the original link working", async () => {
      const first = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(first);
      // Signed once, as the alert emailed it, and reused unchanged from here on.
      const emailedCredential = unsubscribeCredentialIn(
        (await runRealTimeAlert("Durable Vendor"))[0]
      );
      expect((await postUnsubscribe(emailedCredential)).status).toBe(200);

      const again = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(again);

      // Eligible again, through the real send path.
      const alerts = await runRealTimeAlert("Rejoined Vendor");
      expect(alerts).toHaveLength(1);
      expect(alerts[0].to).toBe(EMAIL);
      // And the credential emailed before all of that still opens the page and
      // still unsubscribes: it is derived from identity, not from a lifecycle.
      expect(unsubscribeCredentialIn(alerts[0])).toBe(emailedCredential);

      const reopened = await getUnsubscribeLink(
        `${BASE_URL}${UNSUBSCRIBE_ROUTE_PATH}?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${encodeURIComponent(emailedCredential)}`
      );
      expect(reopened.status).toBe(200);
      expect(reopened.body).toContain(
        "<h1>Unsubscribe from CommonPlate alerts?</h1>"
      );

      const posted = await postUnsubscribe(emailedCredential);

      expect(posted.status).toBe(200);
      expect(posted.body).toContain("<h1>You’re unsubscribed</h1>");
      const stored = await readSubscriber(first.id);
      expect(stored?.status).toBe("unsubscribed");
      expect(stored?._id).toEqual(first.id);
      expect(stored?.unsubscribeCredentialVersion).toBe(1);
    });
  });

  describe("what the lifecycle never stores", () => {
    it("persists no raw unsubscribe credential anywhere it passes through", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);
      const alerts = await runRealTimeAlert("Storage Vendor");
      const credential = unsubscribeCredentialIn(alerts[0]);
      const [, , signature] = credential.split(".");
      await postUnsubscribe(credential);

      for (const collection of [Subscriber, SendLog, System]) {
        const documents = await collection.collection.find({}).toArray();
        const serialized = JSON.stringify(documents);
        expect(serialized).not.toContain(credential);
        expect(serialized).not.toContain(signature);
      }
      // The legacy raw field is not revived either.
      expect(await readSubscriber(pending.id)).not.toHaveProperty("unsubToken");
    });
  });

  describe("while public actions are paused", () => {
    it("refuses signup without writing a Subscriber or sending mail", async () => {
      vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");

      const response = await postSignup(EMAIL);

      expect(response.status).toBe(503);
      expect(response.body).toContain(SUBSCRIBE_UNAVAILABLE_MESSAGE);
      expect(await Subscriber.countDocuments({})).toBe(0);
      expect(resendSend).not.toHaveBeenCalled();
    });

    it("refuses both confirmation verbs before any lifecycle work", async () => {
      const pending = await signupAndReadConfirmationLink();
      const before = await readSubscriber(pending.id);
      vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");

      const opened = await getConfirmationLink(pending.confirmationUrl);
      const posted = await postConfirmation(pending.confirmationToken);

      expect(opened.status).toBe(503);
      expect(posted.status).toBe(503);
      for (const result of [opened, posted]) {
        expect(result.body).toContain(
          "<h1>Email confirmation is temporarily unavailable.</h1>"
        );
        expect(result.body).not.toContain("<form");
      }
      expect(await readSubscriber(pending.id)).toEqual(before);
      expect((await readSubscriber(pending.id))?.status).toBe("pending");
    });

    it("refuses both unsubscribe verbs before the lookup or the mutation", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);
      const alerts = await runRealTimeAlert("Paused Vendor");
      const credential = unsubscribeCredentialIn(alerts[0]);
      const before = await readSubscriber(pending.id);
      vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
      const lookup = vi.spyOn(Subscriber, "findById");
      const update = vi.spyOn(Subscriber, "updateOne");

      const opened = await getUnsubscribeLink(
        linkIn(alerts[0], UNSUBSCRIBE_LINK_PATTERN)
      );
      const posted = await postUnsubscribe(credential);

      expect(opened.status).toBe(503);
      expect(posted.status).toBe(503);
      for (const result of [opened, posted]) {
        expect(result.body).toContain(
          "<h1>Unsubscribing is temporarily unavailable.</h1>"
        );
        expect(result.body).not.toContain("<form");
      }
      expect(lookup).not.toHaveBeenCalled();
      expect(update).not.toHaveBeenCalled();
      expect(await readSubscriber(pending.id)).toEqual(before);
    });

    it("delivers neither a real-time alert nor a digest", async () => {
      const pending = await signupAndReadConfirmationLink();
      await confirmThroughBrowser(pending);
      const subscriber = await Subscriber.findById(pending.id);
      vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
      const request = await createAvailableRequest("Silent Vendor");
      resendSend.mockClear();

      await notifySubscribersForRequest(request);
      // The digest helper throws rather than returning quietly, so no caller
      // can record a digest that was never submitted.
      await expect(sendDigestEmail(subscriber!, [request])).rejects.toThrow(
        /PUBLIC_ACTIONS_PAUSED/
      );

      expect(resendSend).not.toHaveBeenCalled();
      // A suppressed alert leaves no delivery record behind.
      expect(await SendLog.countDocuments({})).toBe(0);
    });
  });
});
