import express, { type Express, type RequestHandler } from "express";
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
import type { Request, Response } from "express";
import { SendLog, Subscriber } from "../models/db.js";
import { confirmSubscription } from "./confirmSubscription.js";
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
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";

// Retain dormant lifecycle regression coverage; production shutdown has its own tests.
vi.mock("./requestAlertEmailDelivery.js", () => ({
  isRequestAlertEmailDeliveryActive: () => true,
  assertRequestAlertEmailDeliveryActive: () => {},
  REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE: "Email Request Alerts are unavailable.",
}));

// The signup route is imported for the re-signup regression below, and
// `emailHelpers.js` builds a Resend client at module scope that refuses to
// construct without an API key. Every case injects its own send function, so
// nothing here depends on the replacement beyond the module loading.
vi.mock("./emailHelpers.js", () => ({
  sendSubscriptionConfirmationEmail: vi.fn(),
}));

import { createSubscribeHandler } from "./subscribeRoute.js";
import {
  SUBSCRIPTION_TOKEN_BYTES,
  digestSubscriptionToken,
} from "./subscriptionTokens.js";
import {
  MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES,
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
  UNSUBSCRIBE_SIGNING_SECRET_ENV,
  buildUnsubscribeUrl,
  signUnsubscribeCredential,
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
 * The registered browser routes against real MongoDB, through the production
 * handlers and their real signing secret. What is proved here is the part only
 * a database can answer: that the GET writes nothing, that the POST is one
 * conditional atomic transition from any prior status, that a pending row's
 * confirmation link dies with it, that counters and history survive, and that
 * a version rotation landing between validation and update loses.
 */
const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

const SIGNING_SECRET = "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES);
const SECRET = Buffer.from(SIGNING_SECRET, "utf8");

function rawToken(byte: number): string {
  return Buffer.alloc(SUBSCRIPTION_TOKEN_BYTES, byte).toString("base64url");
}

function credentialFor(
  subscriberId: mongoose.Types.ObjectId,
  version = 1
): string {
  return signUnsubscribeCredential(String(subscriberId), version, SECRET);
}

/**
 * A tampered copy of an authentic credential, guaranteed to differ from it.
 * Overwriting the final signature character with one fixed letter is a no-op
 * whenever the authentic signature already ends in that letter, which would
 * quietly turn a tampering case into a valid-credential case. Both letters
 * below are canonical trailing base64url characters, so the result stays well
 * formed and fails the signature comparison rather than the parser.
 * `unsubscribeCredential.test.ts` owns this helper's own regression coverage.
 */
function tamperCredentialSignature(value: string): string {
  const last = value.slice(-1);
  return `${value.slice(0, -1)}${last === "A" ? "E" : "A"}`;
}

/**
 * The first subscriber id, counting deterministically from a fixed prefix,
 * whose authentic credential ends in the requested character. No randomness and
 * no sampling: this suite's secret is fixed, so the walk always yields the same
 * id. Both shapes of authentic signature — one ending in `A`, one not — must be
 * covered, because they are the two cases the old fixture handled differently.
 */
function subscriberIdWithFinalCharacter(
  matches: (finalCharacter: string) => boolean
): mongoose.Types.ObjectId {
  for (let counter = 1; counter <= 4096; counter++) {
    const id = new mongoose.Types.ObjectId(
      `64b00000000000000000${counter.toString(16).padStart(4, "0")}`
    );
    if (matches(credentialFor(id).slice(-1))) return id;
  }

  throw new Error("no credential with the requested final character was found");
}

/** Mirrors the production chain, including registration ahead of the parsers. */
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

/**
 * The confirmation chain, mirrored from `confirmSubscriptionRoute.mongo.test.ts`
 * so the lifecycle cases below can reopen a real confirmation link through the
 * production handlers rather than the primitive alone.
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
  app.get(
    CONFIRMATION_ROUTE_PATH,
    confirmationSecurityHeaders,
    pauseConfirmationPage,
    showConfirmationPage
  );
  return app;
}

async function withServer(
  app: Express,
  run: (baseUrl: string) => Promise<{ status: number; html: string }>
): Promise<{ status: number; html: string }> {
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

async function withRequest(
  run: (baseUrl: string) => Promise<{ status: number; html: string }>,
  limiter: RequestHandler = createUnsubscribeRateLimiter()
): Promise<{ status: number; html: string }> {
  return withServer(buildUnsubscribeApp(limiter), run);
}

/**
 * The safe confirmation GET. It answers from token shape alone — no hashing, no
 * lookup — so what a case can prove here is which page a reader lands on and
 * whether submitting the form on it still does anything.
 */
async function getConfirmation(token: string) {
  return withServer(
    buildConfirmationApp(createConfirmationRateLimiter()),
    async (baseUrl) => {
      const response = await fetch(
        `${baseUrl}${CONFIRMATION_ROUTE_PATH}?token=${encodeURIComponent(token)}`
      );
      return { status: response.status, html: await response.text() };
    }
  );
}

async function postConfirmation(token: string) {
  return withServer(
    buildConfirmationApp(createConfirmationRateLimiter()),
    async (baseUrl) => {
      const response = await fetch(`${baseUrl}${CONFIRMATION_ROUTE_PATH}`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token }).toString(),
      });
      return { status: response.status, html: await response.text() };
    }
  );
}

async function getUnsubscribe(credential: string) {
  return withRequest(async (baseUrl) => {
    const response = await fetch(
      `${baseUrl}${UNSUBSCRIBE_ROUTE_PATH}?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${encodeURIComponent(credential)}`
    );
    return { status: response.status, html: await response.text() };
  });
}

async function getUnsubscribeUrl(url: string) {
  return withRequest(async (baseUrl) => {
    const { pathname, search } = new URL(url);
    const response = await fetch(`${baseUrl}${pathname}${search}`);
    return { status: response.status, html: await response.text() };
  });
}

async function postUnsubscribe(
  credential: string,
  limiter: RequestHandler = createUnsubscribeRateLimiter()
) {
  return withRequest(
    async (baseUrl) => {
      const response = await fetch(`${baseUrl}${UNSUBSCRIBE_ROUTE_PATH}`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          [UNSUBSCRIBE_CREDENTIAL_PARAMETER]: credential,
        }).toString(),
      });
      return { status: response.status, html: await response.text() };
    },
    limiter
  );
}

async function readSubscriber(id: mongoose.Types.ObjectId) {
  return Subscriber.collection.findOne({ _id: id });
}

/**
 * Re-signup through the production signup handler, with the confirmation token
 * and its email pinned so a case can name the credential it expects.
 *
 * The handler is called directly, exactly as `subscribeRoute.mongo.test.ts`
 * does. Signup's pause guard is separate middleware registered in `app.ts`;
 * nothing here removes it, and signup stays paused.
 */
async function resignup(email: string, rawConfirmationToken: string) {
  const subscribe = createSubscribeHandler({
    generateRawToken: () => rawConfirmationToken,
    sendConfirmationEmail: vi.fn().mockResolvedValue(undefined),
  });

  let statusCode = 0;
  const res = {} as Response;
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as never;
  res.json = vi.fn(() => res) as never;

  await subscribe({ body: { email } } as unknown as Request, res);
  return statusCode;
}

interface SubscriberFixture {
  status?: "pending" | "confirmed" | "unsubscribed";
  confirmationToken?: string;
  confirmationExpiresInMs?: number;
  /**
   * The bounded receipt a real confirmation leaves behind: the digest of the
   * token that was spent and the expiry it stays recognisable until. A
   * `confirmed` row written by the production primitive always holds one until
   * that expiry passes.
   */
  confirmedToken?: string;
  confirmedTokenExpiresInMs?: number;
  confirmationSendAttemptId?: string;
  /**
   * `null` is deliberately allowed: it is malformed persisted state that the
   * schema, its default, and its validators can never produce, so only a direct
   * driver write can describe it.
   */
  unsubscribeCredentialVersion?: number | null;
  omitCredentialVersion?: boolean;
  /** A chosen `_id`, for the cases that need a signature of a known shape. */
  id?: mongoose.Types.ObjectId;
  dailyCount?: number;
  lastSentAt?: Date;
  bounced?: boolean;
  unsubscribedAt?: Date;
  email?: string;
}

async function insertSubscriber(fixture: SubscriberFixture = {}) {
  const {
    status = "confirmed",
    confirmationToken,
    confirmationExpiresInMs = 3_600_000,
    confirmedToken,
    confirmedTokenExpiresInMs = 3_600_000,
    confirmationSendAttemptId,
    unsubscribeCredentialVersion = 1,
    omitCredentialVersion = false,
    dailyCount = 3,
    lastSentAt = new Date("2026-08-02T09:00:00.000Z"),
    bounced = false,
    unsubscribedAt,
    email = "helper@example.edu",
    id = new mongoose.Types.ObjectId(),
  } = fixture;

  const document: Record<string, unknown> = {
    _id: id,
    email,
    status,
    dailyCount,
    lastSentAt,
    bounced,
  };
  // Written through the driver so a fixture can describe a legacy row that
  // physically lacks the credential-version field; the schema default would
  // otherwise supply one.
  if (!omitCredentialVersion) {
    document.unsubscribeCredentialVersion = unsubscribeCredentialVersion;
  }
  if (confirmationToken) {
    document.confirmationTokenDigest = digestSubscriptionToken(confirmationToken);
    document.confirmationExpiresAt = new Date(
      Date.now() + confirmationExpiresInMs
    );
  }
  if (confirmedToken) {
    document.lastConfirmedTokenDigest = digestSubscriptionToken(confirmedToken);
    document.lastConfirmedTokenExpiresAt = new Date(
      Date.now() + confirmedTokenExpiresInMs
    );
  }
  if (confirmationSendAttemptId) {
    document.confirmationSendAttemptId = confirmationSendAttemptId;
    document.confirmationSendAttemptAt = new Date();
  }
  if (unsubscribedAt) document.unsubscribedAt = unsubscribedAt;

  await Subscriber.collection.insertOne(document);
  return id;
}

describeMongo("browser unsubscribe routes against real MongoDB", () => {
  beforeAll(async () => {
    // Its own database: Mongo files run concurrently and the subscription
    // suites clear the whole Subscriber collection between cases, so a shared
    // database would let one suite delete another's fixtures mid-test.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_unsubscribe_test",
    });
  });

  beforeEach(() => {
    // The production handlers read both of these, so every case states them.
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, SIGNING_SECRET);
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    await Subscriber.deleteMany({});
    await SendLog.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  describe("safe GET", () => {
    it.each(["pending", "confirmed", "unsubscribed"] as const)(
      "renders the same form page for a %s subscriber and mutates nothing",
      async (status) => {
        const id = await insertSubscriber({
          status,
          confirmationToken: status === "pending" ? rawToken(41) : undefined,
        });
        const before = await readSubscriber(id);

        const { status: httpStatus, html } = await getUnsubscribe(
          credentialFor(id)
        );

        expect(httpStatus).toBe(200);
        expect(html).toContain("<h1>Unsubscribe from CommonPlate alerts?</h1>");
        expect(html).toContain(
          "<p>You’ll stop receiving CommonPlate alert and digest emails.</p>"
        );
        expect(html).toMatch(/<form[^>]*method="post"/i);
        expect(html).toContain(
          `<input type="hidden" name="credential" value="${credentialFor(id)}" />`
        );
        // Nothing about the subscriber reaches the page.
        expect(html).not.toContain("helper@example.edu");
        expect(html).not.toContain(status);
        expect(await readSubscriber(id)).toEqual(before);
      }
    );

    it("mutates nothing however many times the link is opened", async () => {
      const id = await insertSubscriber({ status: "confirmed" });
      const before = await readSubscriber(id);

      for (let attempt = 0; attempt < 3; attempt++) {
        expect((await getUnsubscribe(credentialFor(id))).status).toBe(200);
      }

      expect(await readSubscriber(id)).toEqual(before);
    });

    it("accepts the real URL Slice 4A builds for an alert or digest", async () => {
      vi.stubEnv("BASE_URL", "https://commonplate.test");
      const id = await insertSubscriber({ status: "confirmed" });
      const emailed = buildUnsubscribeUrl(
        { _id: id, unsubscribeCredentialVersion: 1 },
        SECRET
      );

      const { status, html } = await getUnsubscribeUrl(emailed);

      expect(status).toBe(200);
      expect(html).toContain("<h1>Unsubscribe from CommonPlate alerts?</h1>");
      expect(html).toContain(
        `<input type="hidden" name="credential" value="${credentialFor(id)}" />`
      );
    });

    it.each([
      ["a malformed credential", async () => "not-a-credential"],
      [
        "a tampered signature",
        async () => {
          const id = await insertSubscriber({ status: "confirmed" });
          const tampered = tamperCredentialSignature(credentialFor(id));
          expect(tampered).not.toBe(credentialFor(id));
          expect(verifyUnsubscribeCredential(tampered, SECRET)).toBeNull();
          return tampered;
        },
      ],
      [
        "an unknown subscriber",
        async () => credentialFor(new mongoose.Types.ObjectId()),
      ],
      [
        "a stored-version mismatch",
        async () => {
          const id = await insertSubscriber({
            status: "confirmed",
            unsubscribeCredentialVersion: 2,
          });
          return credentialFor(id, 1);
        },
      ],
    ])("answers %s with the generic invalid page", async (_label, build) => {
      const credential = await build();
      const before = await Subscriber.collection.find({}).toArray();

      const { status, html } = await getUnsubscribe(credential);

      expect(status).toBe(400);
      expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
      expect(html).not.toContain("<form");
      expect(await Subscriber.collection.find({}).toArray()).toEqual(before);
    });

    it("refuses while paused before any lookup, and renders no form", async () => {
      vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
      const id = await insertSubscriber({ status: "confirmed" });
      const before = await readSubscriber(id);
      const lookup = vi.spyOn(Subscriber, "findById");

      const { status, html } = await getUnsubscribe(credentialFor(id));

      expect(status).toBe(503);
      expect(html).toContain(
        "<h1>Unsubscribing is temporarily unavailable.</h1>"
      );
      expect(html).not.toContain("<form");
      expect(lookup).not.toHaveBeenCalled();
      expect(await readSubscriber(id)).toEqual(before);
    });
  });

  describe("explicit POST", () => {
    it("moves a confirmed subscriber to unsubscribed", async () => {
      const id = await insertSubscriber({ status: "confirmed" });

      const { status, html } = await postUnsubscribe(credentialFor(id));

      expect(status).toBe(200);
      expect(html).toContain("<h1>You’re unsubscribed</h1>");
      expect(html).toContain(
        "<p>You won’t receive CommonPlate alert or digest emails unless you sign up and confirm again.</p>"
      );

      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("unsubscribed");
      expect(persisted?.unsubscribedAt).toBeInstanceOf(Date);
    });

    it("moves a confirmed subscriber holding a live confirmation receipt to unsubscribed and clears it", async () => {
      const spentToken = rawToken(51);
      const id = await insertSubscriber({
        status: "confirmed",
        confirmedToken: spentToken,
      });
      // The receipt is live, so before the unsubscribe the spent link is still
      // recognised — this is exactly the state the correction targets.
      expect(await confirmSubscription(spentToken, new Date())).toEqual({
        outcome: "alreadyConfirmed",
        subscriberId: String(id),
      });

      const { status, html } = await postUnsubscribe(credentialFor(id));

      expect(status).toBe(200);
      expect(html).toContain("<h1>You’re unsubscribed</h1>");
      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("unsubscribed");
      expect(persisted?.unsubscribedAt).toBeInstanceOf(Date);
      for (const cleared of [
        "lastConfirmedTokenDigest",
        "lastConfirmedTokenExpiresAt",
      ]) {
        expect(persisted).not.toHaveProperty(cleared);
      }
    });

    it("moves a pending subscriber to unsubscribed and clears its confirmation state", async () => {
      const token = rawToken(42);
      const id = await insertSubscriber({
        status: "pending",
        confirmationToken: token,
        confirmationSendAttemptId: "attempt-1",
      });

      const { status } = await postUnsubscribe(credentialFor(id));

      expect(status).toBe(200);
      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("unsubscribed");
      for (const cleared of [
        "confirmationTokenDigest",
        "confirmationExpiresAt",
        "confirmationSendAttemptId",
        "confirmationSendAttemptAt",
      ]) {
        expect(persisted).not.toHaveProperty(cleared);
      }
    });

    it("leaves the old pending confirmation link unable to activate the address", async () => {
      const token = rawToken(43);
      const id = await insertSubscriber({
        status: "pending",
        confirmationToken: token,
      });

      await postUnsubscribe(credentialFor(id));
      const result = await confirmSubscription(token, new Date());

      expect(result).toEqual({ outcome: "invalid" });
      expect((await readSubscriber(id))?.status).toBe("unsubscribed");
    });

    it("answers an already-unsubscribed subscriber with the same success page", async () => {
      const unsubscribedAt = new Date("2026-08-01T12:00:00.000Z");
      const id = await insertSubscriber({
        status: "unsubscribed",
        unsubscribedAt,
      });

      const { status, html } = await postUnsubscribe(credentialFor(id));

      expect(status).toBe(200);
      expect(html).toContain("<h1>You’re unsubscribed</h1>");
      // Existing unsubscribe history stands rather than being restamped.
      expect((await readSubscriber(id))?.unsubscribedAt).toEqual(unsubscribedAt);
    });

    it("is idempotent: a repeated submission changes the document no further", async () => {
      const limiter = createUnsubscribeRateLimiter();
      // Carries a live receipt, so the whole-document comparison below covers
      // the receipt clearing as well as the status transition.
      const id = await insertSubscriber({
        status: "confirmed",
        confirmedToken: rawToken(52),
      });

      const first = await postUnsubscribe(credentialFor(id), limiter);
      const afterFirst = await readSubscriber(id);
      const second = await postUnsubscribe(credentialFor(id), limiter);

      expect(second.status).toBe(first.status);
      expect(second.html).toBe(first.html);
      // The whole document is compared, so any second mutation fails this.
      expect(await readSubscriber(id)).toEqual(afterFirst);
    });

    it("preserves the identity, credential version, counters, and send history", async () => {
      const lastSentAt = new Date("2026-08-02T09:00:00.000Z");
      const id = await insertSubscriber({
        status: "confirmed",
        confirmedToken: rawToken(53),
        dailyCount: 3,
        lastSentAt,
        bounced: true,
      });
      await SendLog.create({
        subscriberId: id,
        requestId: new mongoose.Types.ObjectId(),
        sentAt: lastSentAt,
        status: "sent",
      });

      await postUnsubscribe(credentialFor(id));

      const persisted = await readSubscriber(id);
      expect(persisted?._id).toEqual(id);
      expect(persisted?.email).toBe("helper@example.edu");
      // Rotating the version here would kill every unsubscribe link already
      // delivered to this address, including the one just used.
      expect(persisted?.unsubscribeCredentialVersion).toBe(1);
      expect(persisted?.dailyCount).toBe(3);
      expect(persisted?.lastSentAt).toEqual(lastSentAt);
      expect(persisted?.bounced).toBe(true);
      expect(await SendLog.countDocuments({ subscriberId: id })).toBe(1);
      // The row itself survives: unsubscribing is a status, not a deletion.
      expect(await Subscriber.countDocuments({ _id: id })).toBe(1);
      // Only the confirmation credentials go.
      expect(persisted).not.toHaveProperty("lastConfirmedTokenDigest");
      expect(persisted).not.toHaveProperty("lastConfirmedTokenExpiresAt");
    });

    it("accepts a version-1 credential for a legacy row with no stored version", async () => {
      const id = await insertSubscriber({
        status: "confirmed",
        omitCredentialVersion: true,
      });
      const before = await readSubscriber(id);
      expect(before).not.toHaveProperty("unsubscribeCredentialVersion");
      // The real update still runs; the spy only records the filter it was
      // given, because the physical-absence condition is the whole point.
      const realUpdateOne = Subscriber.updateOne.bind(Subscriber);
      const update = vi
        .spyOn(Subscriber, "updateOne")
        .mockImplementation(realUpdateOne as never);

      const { status } = await postUnsubscribe(credentialFor(id, 1));

      expect(status).toBe(200);
      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("unsubscribed");
      // No version is invented for a legacy row by unsubscribing it.
      expect(persisted).not.toHaveProperty("unsubscribeCredentialVersion");
      // Absence is conditioned on as absence. An equality match on 1 would also
      // accept a row that had meanwhile been written with a version, and
      // `{...: null}` would match both a physical null and no field at all.
      expect(update.mock.calls[0]?.[0]).toEqual({
        _id: String(id),
        unsubscribeCredentialVersion: { $exists: false },
      });
    });

    it("refuses a row whose stored version is physically null, and mutates nothing", async () => {
      // Malformed persisted state, not a legacy row: the schema default and
      // validators cannot produce it, so it is written through the driver.
      // Resolving it to version 1 would redeem a link against a document whose
      // real revocation state nothing recorded.
      const id = await insertSubscriber({
        status: "confirmed",
        unsubscribeCredentialVersion: null,
        confirmedToken: rawToken(71),
      });
      const before = await readSubscriber(id);
      expect(before?.unsubscribeCredentialVersion).toBeNull();

      const opened = await getUnsubscribe(credentialFor(id, 1));
      const posted = await postUnsubscribe(credentialFor(id, 1));

      expect(opened.status).toBe(400);
      expect(opened.html).toContain("<h1>This unsubscribe link is invalid.</h1>");
      expect(opened.html).not.toContain("<form");
      expect(posted.status).toBe(400);
      expect(posted.html).toContain("<h1>This unsubscribe link is invalid.</h1>");

      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("confirmed");
      // The physical null is left exactly as it was found: this route reports
      // an unusable link, it does not repair or normalize stored state.
      expect(persisted?.unsubscribeCredentialVersion).toBeNull();
      expect(persisted).toEqual(before);
    });

    it("refuses a physically null row at every other credential version too", async () => {
      const id = await insertSubscriber({
        status: "confirmed",
        unsubscribeCredentialVersion: null,
      });
      const before = await readSubscriber(id);

      for (const version of [1, 2, 3]) {
        expect((await postUnsubscribe(credentialFor(id, version))).status).toBe(
          400
        );
      }

      expect(await readSubscriber(id)).toEqual(before);
    });

    it("rejects a version-1 credential once the stored version is 2", async () => {
      const id = await insertSubscriber({
        status: "confirmed",
        unsubscribeCredentialVersion: 2,
      });
      const before = await readSubscriber(id);

      const { status, html } = await postUnsubscribe(credentialFor(id, 1));

      expect(status).toBe(400);
      expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
      expect(await readSubscriber(id)).toEqual(before);
    });

    it("accepts a version-2 credential against stored version 2", async () => {
      const id = await insertSubscriber({
        status: "confirmed",
        unsubscribeCredentialVersion: 2,
      });

      const { status } = await postUnsubscribe(credentialFor(id, 2));

      expect(status).toBe(200);
      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("unsubscribed");
      expect(persisted?.unsubscribeCredentialVersion).toBe(2);
    });

    it("loses to a version rotation that lands between validation and update", async () => {
      const id = await insertSubscriber({ status: "confirmed" });
      const before = await readSubscriber(id);
      const realUpdateOne = Subscriber.updateOne.bind(Subscriber);
      // Rotates the stored version after the check read it and before the
      // conditional update runs — the exact window the version condition in
      // the update filter exists to close.
      vi.spyOn(Subscriber, "updateOne").mockImplementation(
        ((filter: unknown, update: unknown, options: unknown) => {
          return {
            exec: async () => {
              await Subscriber.collection.updateOne(
                { _id: id },
                { $set: { unsubscribeCredentialVersion: 2 } }
              );
              return realUpdateOne(
                filter as never,
                update as never,
                options as never
              ).exec();
            },
          };
        }) as never
      );

      const { status, html } = await postUnsubscribe(credentialFor(id, 1));

      expect(status).toBe(400);
      expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("confirmed");
      expect(persisted?.unsubscribeCredentialVersion).toBe(2);
      expect({ ...persisted, unsubscribeCredentialVersion: 1 }).toEqual(before);
    });

    it.each([
      ["a malformed credential", async () => "not-a-credential"],
      [
        "a tampered signature",
        async () => {
          const id = await insertSubscriber({ status: "confirmed" });
          const tampered = tamperCredentialSignature(credentialFor(id));
          expect(tampered).not.toBe(credentialFor(id));
          expect(verifyUnsubscribeCredential(tampered, SECRET)).toBeNull();
          return tampered;
        },
      ],
      [
        "an unknown subscriber",
        async () => credentialFor(new mongoose.Types.ObjectId()),
      ],
    ])("answers %s with the generic invalid page and no mutation", async (
      _label,
      build
    ) => {
      const credential = await build();
      const before = await Subscriber.collection.find({}).toArray();

      const { status, html } = await postUnsubscribe(credential);

      expect(status).toBe(400);
      expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
      expect(await Subscriber.collection.find({}).toArray()).toEqual(before);
    });

    it("refuses while paused before verification, lookup, or mutation", async () => {
      vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
      const id = await insertSubscriber({ status: "confirmed" });
      const before = await readSubscriber(id);
      const lookup = vi.spyOn(Subscriber, "findById");
      const update = vi.spyOn(Subscriber, "updateOne");

      const { status, html } = await postUnsubscribe(credentialFor(id));

      expect(status).toBe(503);
      expect(html).toContain(
        "<h1>Unsubscribing is temporarily unavailable.</h1>"
      );
      expect(lookup).not.toHaveBeenCalled();
      expect(update).not.toHaveBeenCalled();
      expect(await readSubscriber(id)).toEqual(before);
    });
  });

  describe("tampered signatures of both shapes", () => {
    // Deterministic, not sampled: a fixed walk over a fixed id prefix under this
    // suite's fixed secret. The last character of a 43-character base64url
    // signature carries only four significant bits, so an authentic signature
    // ending in `A` is an ordinary case rather than a rare one — and it is
    // exactly the case the old `slice(0, -1) + "A"` fixture failed to tamper.
    const shapes: Array<[string, mongoose.Types.ObjectId]> = [
      [
        "an authentic signature ending in A",
        subscriberIdWithFinalCharacter((character) => character === "A"),
      ],
      [
        "an authentic signature not ending in A",
        subscriberIdWithFinalCharacter((character) => character !== "A"),
      ],
    ];

    it.each(shapes)(
      "refuses a tampered copy of %s on both verbs without mutating",
      async (_label, chosenId) => {
        const id = await insertSubscriber({ status: "confirmed", id: chosenId });
        const authentic = credentialFor(id);
        const tampered = tamperCredentialSignature(authentic);
        const before = await readSubscriber(id);

        // The fixture is a real tampering before it is sent anywhere.
        expect(tampered).not.toBe(authentic);
        expect(verifyUnsubscribeCredential(authentic, SECRET)).not.toBeNull();
        expect(verifyUnsubscribeCredential(tampered, SECRET)).toBeNull();

        const opened = await getUnsubscribe(tampered);
        const posted = await postUnsubscribe(tampered);

        expect(opened.status).toBe(400);
        expect(opened.html).toContain(
          "<h1>This unsubscribe link is invalid.</h1>"
        );
        expect(opened.html).not.toContain("<form");
        expect(posted.status).toBe(400);
        expect(posted.html).toContain(
          "<h1>This unsubscribe link is invalid.</h1>"
        );
        expect(await readSubscriber(id)).toEqual(before);
        expect((await readSubscriber(id))?.status).toBe("confirmed");
      }
    );

    it.each(shapes)(
      "still accepts the authentic %s the tampered copy was built from",
      async (_label, chosenId) => {
        // The counterpart proof: the tampering is what is refused above, not
        // the chosen fixture id or the shape of its signature.
        const id = await insertSubscriber({ status: "confirmed", id: chosenId });

        const { status } = await postUnsubscribe(credentialFor(id));

        expect(status).toBe(200);
        expect((await readSubscriber(id))?.status).toBe("unsubscribed");
      }
    );
  });

  describe("the confirmation lifecycle after unsubscribe", () => {
    it("stops a reopened confirmation link claiming the address is confirmed", async () => {
      const spentToken = rawToken(61);
      const id = await insertSubscriber({
        status: "confirmed",
        confirmedToken: spentToken,
      });

      await postUnsubscribe(credentialFor(id));

      // The confirmation GET is inert by contract: it answers from token shape
      // alone — no hashing, no lookup — so it renders the same form for any
      // well-formed token and can state nothing about a Subscriber. What must
      // not survive is the claim, and the form this page carries is now dead:
      // the POST below is the only thing that could have acted on it.
      const opened = await getConfirmation(spentToken);
      expect(opened.status).toBe(200);
      expect(opened.html).not.toContain("already confirmed");
      expect(opened.html).not.toContain("Email alerts confirmed");

      const submitted = await postConfirmation(spentToken);
      expect(submitted.status).toBe(400);
      expect(submitted.html).toContain(
        "<h1>This confirmation link is invalid.</h1>"
      );
      expect(submitted.html).not.toContain("<form");
      expect(submitted.html).not.toContain("already confirmed");
    });

    it("cannot be posted back to confirmed by the old confirmation credential", async () => {
      const spentToken = rawToken(62);
      const id = await insertSubscriber({
        status: "confirmed",
        confirmedToken: spentToken,
      });

      await postUnsubscribe(credentialFor(id));
      const afterUnsubscribe = await readSubscriber(id);

      // The existing invalid result, not a new outcome: the receipt is gone, so
      // nothing recognises the token at all.
      expect(await confirmSubscription(spentToken, new Date())).toEqual({
        outcome: "invalid",
      });
      await postConfirmation(spentToken);

      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("unsubscribed");
      // The whole document is compared, so any write by the refused
      // confirmation fails this.
      expect(persisted).toEqual(afterUnsubscribe);
    });

    it("lets a re-signup create a fresh pending confirmation credential", async () => {
      const email = "resignup@nyu.edu";
      const spentToken = rawToken(63);
      const id = await insertSubscriber({
        status: "confirmed",
        confirmedToken: spentToken,
        email,
      });
      await postUnsubscribe(credentialFor(id));

      const freshToken = rawToken(64);
      expect(await resignup(email, freshToken)).toBe(202);

      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("pending");
      expect(persisted?.confirmationTokenDigest).toBe(
        digestSubscriptionToken(freshToken)
      );
      expect(persisted?.confirmationExpiresAt.getTime()).toBeGreaterThan(
        Date.now()
      );
      // The same row and the same credential version: signing up again is not
      // a new subscriber and does not revoke the emailed unsubscribe link.
      expect(persisted?._id).toEqual(id);
      expect(persisted?.unsubscribeCredentialVersion).toBe(1);
      // The spent token stays spent; a re-signup issues its own credential.
      expect(persisted).not.toHaveProperty("lastConfirmedTokenDigest");
      expect(await confirmSubscription(spentToken, new Date())).toEqual({
        outcome: "invalid",
      });
    });

    it("keeps the original unsubscribe link working after re-signup and reconfirmation", async () => {
      const email = "durable@nyu.edu";
      const id = await insertSubscriber({
        status: "confirmed",
        confirmedToken: rawToken(65),
        email,
      });
      // Signed once, as an alert or digest would have emailed it, and used
      // unchanged through every step below.
      const emailedCredential = credentialFor(id);

      expect((await postUnsubscribe(emailedCredential)).status).toBe(200);

      const freshToken = rawToken(66);
      expect(await resignup(email, freshToken)).toBe(202);
      const reconfirmed = await postConfirmation(freshToken);
      expect(reconfirmed.status).toBe(200);
      expect(reconfirmed.html).toContain("<h1>Email alerts confirmed.</h1>");
      expect((await readSubscriber(id))?.status).toBe("confirmed");

      const reopened = await getUnsubscribe(emailedCredential);
      expect(reopened.status).toBe(200);
      expect(reopened.html).toContain(
        "<h1>Unsubscribe from CommonPlate alerts?</h1>"
      );

      const { status, html } = await postUnsubscribe(emailedCredential);

      expect(status).toBe(200);
      expect(html).toContain("<h1>You’re unsubscribed</h1>");
      const persisted = await readSubscriber(id);
      expect(persisted?.status).toBe("unsubscribed");
      expect(persisted?._id).toEqual(id);
      expect(persisted?.email).toBe(email);
      expect(persisted?.unsubscribeCredentialVersion).toBe(1);
      // The second lifecycle's receipt is cleared by the second unsubscribe
      // exactly as the first one's was.
      expect(persisted).not.toHaveProperty("lastConfirmedTokenDigest");
      expect(persisted).not.toHaveProperty("lastConfirmedTokenExpiresAt");
      expect(await confirmSubscription(freshToken, new Date())).toEqual({
        outcome: "invalid",
      });
    });
  });

  describe("delivery eligibility", () => {
    it("takes an unsubscribed subscriber out of the confirmed alert and digest pool", async () => {
      const id = await insertSubscriber({
        status: "confirmed",
        dailyCount: 0,
        bounced: false,
      });
      const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);

      // The selection both send paths run, before and after. `status:
      // "confirmed"` is pinned in the real-time query by
      // `notifySubscribers.test.ts` and in the digest query by
      // `publicActionsRoutes.test.ts`, so leaving that pool is what makes an
      // unsubscribed row ineligible.
      const eligible = () =>
        Subscriber.countDocuments({
          status: "confirmed",
          bounced: false,
          dailyCount: { $lt: 4 },
          $or: [{ lastSentAt: { $lt: oneHourAgo } }, { lastSentAt: null }],
        });

      expect(await eligible()).toBe(1);

      await postUnsubscribe(credentialFor(id));

      expect(await eligible()).toBe(0);
      expect(await Subscriber.countDocuments({ status: "confirmed" })).toBe(0);
    });
  });
});
