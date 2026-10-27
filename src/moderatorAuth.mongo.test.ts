import express, { type Request, type Response } from "express";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { createHmac, scryptSync } from "node:crypto";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Participant,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
import {
  ConversationMessage,
  MessageConversation,
  MessageReceipt,
  initializeMessagingIndexes,
} from "../models/messaging.js";
import {
  ModerationAuditEvent,
  MODERATION_MODELS,
  ModerationReport,
  ModeratorSession,
  ModeratorThrottle,
  ReportEvidence,
  RetentionHold,
  establishModerationIndexes,
} from "../models/moderation.js";
import { registerModerationRoutes } from "./moderationRoutes.js";
import { requireModerator } from "./moderatorAuth.js";
import { buildReportRequestSnapshot } from "./reportRequestSnapshot.js";
import { recordReportCase } from "./moderationRecords.js";
import { runModerationTransaction } from "./safetyIdentity.js";
import { readSafetyIdentityKeyring } from "./safetyIdentityKeyring.js";
import { closeMessagingRelationship, createMessagingService } from "./messaging.js";
import { createMessagingPolicy } from "./messagingPolicy.js";
import {
  installMessagingLifecycle,
} from "./messagingSafety.js";
import {
  installMessagingLifecycleHooks,
  uninstallMessagingLifecycleHooks,
} from "./messagingLifecycle.js";
import { isEitherParticipantSuspended } from "./moderationEnforcement.js";
import { signParticipantAuthority } from "./participantCredentials.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_moderator_auth`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;
const passphrase = "CP3 test passphrase, deliberately long";
const salt = Buffer.alloc(16, 0x31);
const passphraseDigest = scryptSync(passphrase, salt, 32, { N: 16_384, r: 8, p: 1 });
const totpBytes = Buffer.from("12345678901234567890");
const totpBase32 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
const participantSigningSecret = "moderator-messaging-integration-signing-secret";
const participantCredential = (id: mongoose.Types.ObjectId) =>
  signParticipantAuthority(id, 1, Buffer.from(participantSigningSecret));
const keyring = JSON.stringify({
  current: "k1",
  keys: { k1: Buffer.alloc(32, 0x61).toString("base64url") },
});
const encodedPassphrase = (hash: Buffer) =>
  [
    "scrypt-v1",
    16_384,
    8,
    1,
    salt.toString("base64url"),
    hash.toString("base64url"),
  ].join("$");

function setConfig(hash = passphraseDigest): void {
  vi.stubEnv("MODERATOR_ORIGIN", "https://moderator.example");
  vi.stubEnv("MODERATOR_PASSPHRASE_HASH", encodedPassphrase(hash));
  vi.stubEnv("MODERATOR_TOTP_SECRET", totpBase32);
  vi.stubEnv("REPORT_ALERT_RECIPIENT", "moderator@example.org");
  vi.stubEnv("SUPPORT_EMAIL", "support@example.org");
  vi.stubEnv("SAFETY_IDENTITY_KEYRING", keyring);
  vi.stubEnv("PARTICIPANT_SIGNING_SECRET", participantSigningSecret);
  vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "claim-token-test-secret-material-32b");
  vi.stubEnv("PUBLIC_ACTIONS_PAUSED", "false");
}

function codeAt(now: Date): string {
  const step = Math.floor(now.getTime() / 30_000);
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const digest = createHmac("sha1", totpBytes).update(counter).digest();
  const offset = digest[digest.length - 1]! & 0x0f;
  const value =
    ((digest[offset]! & 0x7f) << 24) |
    ((digest[offset + 1]! & 0xff) << 16) |
    ((digest[offset + 2]! & 0xff) << 8) |
    (digest[offset + 3]! & 0xff);
  return String(value % 1_000_000).padStart(6, "0");
}

let baseUrl = "";
let closeServer: () => Promise<void>;
let server: ReturnType<typeof createServer>;
let rateLimitIp = "198.51.100.1";
let nextTestIp = 1;

async function login(code = codeAt(new Date()), pass = passphrase) {
  return fetch(`${baseUrl}/moderation/login`, {
    method: "POST",
    headers: {
      Origin: "https://moderator.example",
      "Content-Type": "application/x-www-form-urlencoded",
      "X-Forwarded-For": rateLimitIp,
    },
    body: new URLSearchParams({ passphrase: pass, totp: code }),
    redirect: "manual",
  });
}

function loginCookies(response: globalThis.Response): { cookie: string; csrf: string } {
  const value = response.headers.get("set-cookie") ?? "";
  const session = /__Host-commonplate-moderator=([A-Za-z0-9_-]+)/.exec(value)?.[1];
  const csrf = /__Host-commonplate-moderator-csrf=([A-Za-z0-9_-]+)/.exec(value)?.[1];
  if (!session || !csrf) throw new Error("Moderator login did not set both cookies.");
  return { cookie: `__Host-commonplate-moderator=${session}; __Host-commonplate-moderator-csrf=${csrf}`, csrf };
}

async function getInbox(cookie: string) {
  return fetch(`${baseUrl}/moderation`, { headers: { Cookie: cookie } });
}

async function postForm(
  path: string,
  cookie: string,
  csrf: string,
  values: Record<string, string>
) {
  return fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers: {
      Cookie: cookie,
      Origin: "https://moderator.example",
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ ...values, _csrf: csrf }),
    redirect: "manual",
  });
}

describeMongo(
  "real MongoDB moderator authentication and session controls",
  { timeout: 60_000 },
  () => {
    beforeAll(async () => {
      setConfig();
      await mongoose.connect(mongoUri!);
      await Participant.createIndexes();
      await MealRequest.syncIndexes();
      await RequestParticipation.createIndexes();
      await initializeMessagingIndexes();
      await establishModerationIndexes();
      const app = express();
      app.set("trust proxy", 1);
      expect(registerModerationRoutes(app)).toBe(true);
      server = createServer(app);
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
      closeServer = () =>
        new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve()))
        );
    });

    beforeEach(async () => {
      setConfig();
      nextTestIp += 1;
      rateLimitIp = `198.51.100.${nextTestIp}`;
      await MealRequest.deleteMany({});
      await Participant.deleteMany({});
      await RequestParticipation.deleteMany({});
      await ConversationMessage.deleteMany({});
      await MessageReceipt.deleteMany({});
      await MessageConversation.deleteMany({});
      for (const model of MODERATION_MODELS) await model.deleteMany({});
    });

    afterEach(() => {
      uninstallMessagingLifecycleHooks();
      vi.restoreAllMocks();
    });

    afterAll(async () => {
      await closeServer();
      await mongoose.disconnect();
      vi.unstubAllEnvs();
    });

    it("creates one digest-only session, applies secure cookies and serves script-free HTML", async () => {
      const response = await login();
      expect(response.status).toBe(303);
      const setCookie = response.headers.get("set-cookie") ?? "";
      expect(setCookie).toContain("Secure");
      expect(setCookie).toContain("HttpOnly");
      expect(setCookie).toContain("SameSite=Strict");
      expect(setCookie).toContain("Path=/");
      expect(setCookie).not.toContain("Domain=");
      const { cookie } = loginCookies(response);
      const page = await getInbox(cookie);
      expect(page.status).toBe(200);
      expect(page.headers.get("cache-control")).toBe("no-store");
      expect(page.headers.get("x-robots-tag")).toContain("noindex");
      expect(page.headers.get("content-security-policy")).toContain("default-src 'none'");
      expect(await page.text()).toContain("Reports");
      expect(page.headers.get("content-security-policy")).toContain("style-src 'self'");
      expect(page.headers.get("content-security-policy")).not.toContain("unsafe-inline");
      expect(page.headers.get("referrer-policy")).toBe("same-origin");
      expect(await ModeratorSession.countDocuments({})).toBe(1);
      const stored = await ModeratorSession.findOne().lean();
      expect(stored?.sessionDigest).toMatch(/^[0-9a-f]{64}$/);
      expect(stored?.csrfDigest).toMatch(/^[0-9a-f]{64}$/);
      expect(JSON.stringify(stored)).not.toContain(cookie);
    });

    it("refuses TOTP replay and makes concurrent same-step logins one-winner", async () => {
      const code = codeAt(new Date());
      const [first, concurrent] = await Promise.all([login(code), login(code)]);
      const accepted = [first, concurrent].filter((response) => response.status === 303);
      const refused = [first, concurrent].filter((response) => response.status === 200);
      expect(accepted).toHaveLength(1);
      expect(refused).toHaveLength(1);
      expect(await ModeratorSession.countDocuments({})).toBe(1);

      const replay = await login(code);
      expect(replay.status).toBe(200);
      expect(await replay.text()).toContain("Sign-in was not confirmed.");
      expect(await ModeratorSession.countDocuments({})).toBe(1);
    });

    it("uses one failure response, persists the global throttle, and rejects a bad Origin", async () => {
      const invalidOrigin = await fetch(`${baseUrl}/moderation/login`, {
        method: "POST",
        headers: {
          Origin: "https://attacker.example",
          "Content-Type": "application/x-www-form-urlencoded",
          "X-Forwarded-For": rateLimitIp,
        },
        body: new URLSearchParams({ passphrase, totp: codeAt(new Date()) }),
        redirect: "manual",
      });
      expect(invalidOrigin.status).toBe(200);

      const first = await login("000000");
      const firstBody = await first.text();
      expect(first.status).toBe(200);
      expect(firstBody).toContain("Sign-in was not confirmed.");
      for (let attempt = 1; attempt < 5; attempt += 1) await login("000000");
      const throttle = await ModeratorThrottle.findOne({ scope: "global" }).lean();
      expect(throttle?.failures).toBe(5);
      expect(throttle?.delayMs).toBe(30_000);
      expect(throttle?.blockedUntil?.getTime()).toBeGreaterThan(Date.now());
      const throttled = await login();
      expect(throttled.status).toBe(200);
      expect(await throttled.text()).toBe(firstBody);
      expect(await ModerationAuditEvent.countDocuments({ kind: "moderator-authentication" })).toBe(6);
      expect(await ModeratorSession.countDocuments({})).toBe(0);
    });

    it("accepts a same-origin login and still rejects null, missing and cross-origin requests", async () => {
      const attempt = (origin?: string) =>
        fetch(`${baseUrl}/moderation/login`, {
          method: "POST",
          headers: {
            ...(origin === undefined ? {} : { Origin: origin }),
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Forwarded-For": rateLimitIp,
          },
          body: new URLSearchParams({ passphrase, totp: codeAt(new Date()) }),
          redirect: "manual",
        });
      for (const origin of ["null", undefined, "https://attacker.example"]) {
        const refused = await attempt(origin);
        expect(refused.status).toBe(200);
        expect(await refused.text()).toContain("Sign-in was not confirmed.");
        expect(refused.headers.get("set-cookie")).toBeNull();
      }
      expect(await ModeratorSession.countDocuments({})).toBe(0);

      const accepted = await attempt("https://moderator.example");
      expect(accepted.status).toBe(303);
      expect(accepted.headers.get("location")).toBe("/moderation");
      const { cookie, csrf } = loginCookies(accepted);
      expect(await ModeratorSession.countDocuments({})).toBe(1);

      const report = await seedOpenReport("origin-check@nyu.edu", "Origin check explanation");
      for (const origin of ["null", "https://attacker.example", undefined]) {
        const refusedClose = await fetch(`${baseUrl}/moderation/reports/${report.ref}/close`, {
          method: "POST",
          headers: {
            Cookie: cookie,
            ...(origin === undefined ? {} : { Origin: origin }),
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: new URLSearchParams({ _csrf: csrf, confirm: "close", outcome: "no-action" }),
          redirect: "manual",
        });
        expect(refusedClose.status).toBe(403);
      }
      expect((await ModerationReport.findById(report.reportId).lean())?.state).toBe("open");
    });

    it("scopes Referrer-Policy same-origin to moderator pages only", async () => {
      const { cookie } = loginCookies(await login());
      for (const path of ["/moderation/login", "/moderation", "/moderation/closed", "/moderation/suspensions"]) {
        const response = await fetch(`${baseUrl}${path}`, { headers: { Cookie: cookie } });
        expect(response.headers.get("referrer-policy")).toBe("same-origin");
      }
      const other = await fetch(`${baseUrl}/not-a-moderator-route`);
      expect(other.headers.get("referrer-policy")).not.toBe("same-origin");
    });

    it("requires Origin and the per-session CSRF token, then audits and revokes logout", async () => {
      const response = await login();
      const { cookie, csrf } = loginCookies(response);
      const absentOrigin = await fetch(`${baseUrl}/moderation/logout`, {
        method: "POST",
        headers: { Cookie: cookie, "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ _csrf: csrf }),
        redirect: "manual",
      });
      expect(absentOrigin.status).toBe(403);
      const badToken = await fetch(`${baseUrl}/moderation/logout`, {
        method: "POST",
        headers: {
          Cookie: cookie,
          Origin: "https://moderator.example",
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({ _csrf: `${csrf}x` }),
        redirect: "manual",
      });
      expect(badToken.status).toBe(403);
      const logout = await fetch(`${baseUrl}/moderation/logout`, {
        method: "POST",
        headers: {
          Cookie: cookie,
          Origin: "https://moderator.example",
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({ _csrf: csrf }),
        redirect: "manual",
      });
      expect(logout.status).toBe(303);
      expect(await ModeratorSession.countDocuments({})).toBe(0);
      expect(await (await getInbox(cookie)).text()).toContain("Moderator sign in");
    });

    it("rejects idle and absolute expiry and invalidates sessions on config rotation", async () => {
      const response = await login();
      const { cookie } = loginCookies(response);
      const session = await ModeratorSession.findOne().exec();
      expect(session).not.toBeNull();

      await ModeratorSession.updateOne(
        { _id: session!._id },
        { $set: { idleExpiresAt: new Date(Date.now() - 1) } }
      ).exec();
      expect((await getInbox(cookie)).status).toBe(200);
      expect(await (await getInbox(cookie)).text()).toContain("Moderator sign in");

      await ModeratorSession.updateOne(
        { _id: session!._id },
        {
          $set: {
            idleExpiresAt: new Date(Date.now() + 60_000),
            absoluteExpiresAt: new Date(Date.now() - 1),
          },
        }
      ).exec();
      expect(await (await getInbox(cookie)).text()).toContain("Moderator sign in");

      await ModeratorSession.updateOne(
        { _id: session!._id },
        { $set: { absoluteExpiresAt: new Date(Date.now() + 60_000) } }
      ).exec();
      expect((await getInbox(cookie)).status).toBe(200);

      setConfig(scryptSync("rotated moderator passphrase", salt, 32, { N: 16_384, r: 8, p: 1 }));
      expect(await (await getInbox(cookie)).text()).toContain("Moderator sign in");
    });

    it("fails closed when the session database dependency is unavailable", async () => {
      const findOneAndUpdate = vi
        .spyOn(ModeratorSession, "findOneAndUpdate")
        .mockImplementation(() => {
          throw new Error("private test failure");
        });
      const request = {
        headers: {
          cookie:
            "__Host-commonplate-moderator=" +
            "a".repeat(43) +
            "; __Host-commonplate-moderator-csrf=" +
            "b".repeat(43),
        },
        body: {},
      } as unknown as Request;
      const response = {
        status: vi.fn().mockReturnThis(),
        type: vi.fn().mockReturnThis(),
        send: vi.fn().mockReturnThis(),
      } as unknown as Response;
      const next = vi.fn();
      await requireModerator(request, response, next);
      expect(response.status).toHaveBeenCalledWith(503);
      expect(response.send).toHaveBeenCalledWith("Moderator service unavailable.");
      expect(next).not.toHaveBeenCalled();
      findOneAndUpdate.mockRestore();
    });

    it("keeps hold review and release available to the backend without dashboard controls", async () => {
      const now = new Date();
      const report = await ModerationReport.create({
        state: "closed",
        outcome: "no-action",
        closedAt: now,
      });
      const hold = await RetentionHold.create({
        targetKind: "case",
        targetId: report._id,
        holdClass: "legal-preservation",
        reasonCode: "legal-preservation",
        note: "<script>private hold note</script>",
        endingCondition: "Counsel confirms preservation has ended.",
        reviewAt: new Date(now.getTime() - 60_000),
        reviewPromptRaisedAt: now,
      });
      const authenticated = loginCookies(await login());

      const detail = await fetch(`${baseUrl}/moderation/reports/${report.ref}`, {
        headers: { Cookie: authenticated.cookie },
      });
      const html = await detail.text();
      expect(html).not.toContain(hold.ref);
      expect(html).not.toContain("private hold note");
      expect(html).not.toMatch(/retention hold/i);

      const reviewAt = new Date(Date.now() + 24 * 60 * 60_000).toISOString();
      const reviewed = await postForm(
        `/moderation/holds/${hold.ref}/review`,
        authenticated.cookie,
        authenticated.csrf,
        { reviewAt }
      );
      expect(reviewed.status).toBe(303);
      expect(reviewed.headers.get("location")).toBe("/moderation/health?hold=reviewed");
      expect(await RetentionHold.findById(hold._id).lean()).toMatchObject({ state: "active" });
      expect((await RetentionHold.findById(hold._id).lean())?.reviewPromptRaisedAt).toBeUndefined();
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-reviewed" })).toBe(1);

      const released = await postForm(
        `/moderation/holds/${hold.ref}/release`,
        authenticated.cookie,
        authenticated.csrf,
        { confirm: "release", endingConditionMet: "yes" }
      );
      expect(released.status).toBe(303);
      expect(released.headers.get("location")).toBe("/moderation/health?hold=released");
      expect((await RetentionHold.findById(hold._id).lean())?.state).toBe("released");
      expect(await ModerationAuditEvent.countDocuments({ kind: "hold-released" })).toBe(1);
    });

    describe("retention holds on the health page", () => {
      async function seedHold(overrides: Record<string, unknown> = {}) {
        const now = new Date();
        const report = await ModerationReport.create({ state: "closed", outcome: "no-action", closedAt: now });
        const hold = await RetentionHold.create({
          targetKind: "case",
          targetId: report._id,
          holdClass: "legal-preservation",
          reasonCode: "legal-preservation",
          note: "<b>fictional note</b>",
          endingCondition: "Counsel confirms preservation has ended.",
          reviewAt: new Date(now.getTime() + 10 * 86_400_000),
          ...overrides,
        });
        return { report, hold };
      }

      it("shows an empty state and a recorded sweep state", async () => {
        const finished = new Date(Date.now() - 3_600_000);
        await ModerationAuditEvent.create({
          kind: "retention-run",
          run: {
            status: "succeeded",
            startedAt: new Date(finished.getTime() - 5000),
            finishedAt: finished,
            keyringState: "ok",
          },
          deleteAt: new Date(Date.now() + 86_400_000),
        });
        const { cookie } = loginCookies(await login());
        const html = await (await fetch(`${baseUrl}/moderation/health`, { headers: { Cookie: cookie } })).text();
        expect(html).toMatch(/<dt>Last successful retention run<\/dt><dd><time datetime="/);
        expect(html).toContain("succeeded");
        expect(html).toContain("<h2>Retention holds</h2>");
        expect(html).toContain("No retention holds are active.");
        expect(html).not.toContain("Create retention hold");
      });

      it("lists existing holds with escaped data, dates and both actions, and no creation form", async () => {
        const { report, hold } = await seedHold({
          reviewAt: new Date(Date.now() - 60_000),
          lastReviewedAt: new Date(Date.now() - 86_400_000),
        });
        const { cookie } = loginCookies(await login());
        const html = await (await fetch(`${baseUrl}/moderation/health`, { headers: { Cookie: cookie } })).text();
        expect(html).toContain("Review due");
        expect(html).toContain(report.ref);
        expect(html).toContain("&lt;b&gt;fictional note&lt;/b&gt;");
        expect(html).not.toContain("<b>fictional note");
        expect(html).toContain("Counsel confirms preservation has ended.");
        expect(html).toMatch(/<dt>Placed<\/dt><dd><time datetime=/);
        expect(html).toMatch(/<dt>Last review<\/dt><dd><time datetime=/);
        expect(html).toContain(`action="/moderation/holds/${hold.ref}/review"`);
        expect(html).toContain(`action="/moderation/holds/${hold.ref}/release"`);
        expect(html).toContain("Record review");
        expect(html).toContain("Release hold");
        expect(html).not.toContain('action="/moderation/holds"');
        expect(html).not.toContain("<script");
      });

      it("keeps hold controls out of reports and suspensions pages and out of navigation", async () => {
        const { report } = await seedHold();
        const { cookie } = loginCookies(await login());
        for (const path of ["/moderation/closed", "/moderation/suspensions", `/moderation/reports/${report.ref}`]) {
          const html = await (await fetch(`${baseUrl}${path}`, { headers: { Cookie: cookie } })).text();
          expect(html).not.toContain("/moderation/holds");
          expect(html).not.toContain("Release hold");
          expect(html).not.toContain("Record review");
        }
        const inbox = await (await fetch(`${baseUrl}/moderation`, { headers: { Cookie: cookie } })).text();
        expect(inbox).not.toContain("/moderation/holds");
        expect(inbox).not.toContain("Release hold");
        expect(inbox).not.toContain("Record review");
      });

      it("records a review from the form, shows the notice and audits it", async () => {
        const { hold } = await seedHold({ reviewAt: new Date(Date.now() - 60_000), reviewPromptRaisedAt: new Date() });
        const authenticated = loginCookies(await login());
        const response = await postForm(`/moderation/holds/${hold.ref}/review`, authenticated.cookie, authenticated.csrf, {
          reviewInDays: "30",
        });
        expect(response.status).toBe(303);
        const stored = await RetentionHold.findById(hold._id).lean();
        expect(stored?.state).toBe("active");
        expect(stored?.lastReviewedAt).toBeInstanceOf(Date);
        expect(stored?.reviewPromptRaisedAt).toBeUndefined();
        expect(stored!.reviewAt.getTime()).toBeGreaterThan(Date.now() + 29 * 86_400_000);
        expect(await ModerationAuditEvent.countDocuments({ kind: "hold-reviewed" })).toBe(1);
        const html = await (await fetch(`${baseUrl}${response.headers.get("location")}`, { headers: { Cookie: authenticated.cookie } })).text();
        expect(html).toContain("Review recorded.");
        expect(html).not.toContain("Review due");
      });

      it("refuses invalid review input readably without changing the hold", async () => {
        const { hold } = await seedHold();
        const authenticated = loginCookies(await login());
        const before = await RetentionHold.findById(hold._id).lean();
        for (const values of [
          { reviewInDays: "365" },
          { reviewAt: new Date(Date.now() - 86_400_000).toISOString() },
          { reviewAt: new Date(Date.now() + 200 * 86_400_000).toISOString() },
          { reviewAt: "not-a-date" },
          { reviewInDays: "30", reviewAt: new Date(Date.now() + 86_400_000).toISOString() },
          {},
        ] as Record<string, string>[]) {
          const response = await postForm(`/moderation/holds/${hold.ref}/review`, authenticated.cookie, authenticated.csrf, values);
          expect([400, 409]).toContain(response.status);
          expect(await response.text()).toContain("The review could not be recorded.");
        }
        const unknown = await postForm(`/moderation/holds/${"x".repeat(24)}/review`, authenticated.cookie, authenticated.csrf, { reviewInDays: "30" });
        expect(unknown.status).toBe(409);
        expect(await RetentionHold.findById(hold._id).lean()).toMatchObject({ reviewAt: before!.reviewAt });
        expect(await ModerationAuditEvent.countDocuments({ kind: "hold-reviewed" })).toBe(0);
      });

      it("releases only with confirmation, applies normal retention, and refuses a second release", async () => {
        const { report, hold } = await seedHold();
        const authenticated = loginCookies(await login());
        for (const values of [{}, { confirm: "release" }, { confirm: "release", endingConditionMet: "no" }] as Record<
          string,
          string
        >[]) {
          const refused = await postForm(`/moderation/holds/${hold.ref}/release`, authenticated.cookie, authenticated.csrf, values);
          expect(refused.status).toBe(400);
          expect(await refused.text()).toContain("The hold could not be released.");
        }
        expect((await RetentionHold.findById(hold._id).lean())?.state).toBe("active");
        const released = await postForm(`/moderation/holds/${hold.ref}/release`, authenticated.cookie, authenticated.csrf, {
          confirm: "release",
          endingConditionMet: "yes",
        });
        expect(released.status).toBe(303);
        const stored = await RetentionHold.findById(hold._id).lean();
        expect(stored?.state).toBe("released");
        expect(stored?.releaseBasis).toBe("ending-condition-met");
        const closed = await ModerationReport.findById(report._id).lean();
        expect(closed?.deleteAt).toBeInstanceOf(Date);
        expect(closed!.deleteAt!.getTime()).toBeGreaterThan(Date.now());
        expect(await ModerationAuditEvent.countDocuments({ kind: "hold-released" })).toBe(1);
        const html = await (await fetch(`${baseUrl}${released.headers.get("location")}`, { headers: { Cookie: authenticated.cookie } })).text();
        expect(html).toContain("Hold released.");
        expect(html).toContain("No retention holds are active.");
        const again = await postForm(`/moderation/holds/${hold.ref}/release`, authenticated.cookie, authenticated.csrf, {
          confirm: "release",
          endingConditionMet: "yes",
        });
        expect(again.status).toBe(409);
        expect(await ModerationAuditEvent.countDocuments({ kind: "hold-released" })).toBe(1);
      });

      it("ignores unknown or inherited notice keys", async () => {
        const { cookie } = loginCookies(await login());
        for (const key of ["constructor", "__proto__", "bogus"]) {
          const html = await (await fetch(`${baseUrl}/moderation/health?hold=${key}`, { headers: { Cookie: cookie } })).text();
          expect(html).not.toContain('role="status"');
          expect(html).not.toContain("native code");
        }
      });

      it("rejects unauthenticated, bad-Origin, bad-CSRF and expired-session mutations", async () => {
        const { hold } = await seedHold();
        const authenticated = loginCookies(await login());
        const url = `${baseUrl}/moderation/holds/${hold.ref}/release`;
        const body = (csrf: string) => new URLSearchParams({ confirm: "release", endingConditionMet: "yes", _csrf: csrf });
        const send = (headers: Record<string, string>, csrf = authenticated.csrf) =>
          fetch(url, {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded", ...headers },
            body: body(csrf),
            redirect: "manual",
          });
        const noSession = await send({ Origin: "https://moderator.example" });
        expect(noSession.status).not.toBe(303);
        expect(await noSession.text()).toContain("Moderator sign in");
        for (const origin of ["null", "https://attacker.example"]) {
          expect((await send({ Cookie: authenticated.cookie, Origin: origin })).status).toBe(403);
        }
        expect((await send({ Cookie: authenticated.cookie })).status).toBe(403);
        expect((await send({ Cookie: authenticated.cookie, Origin: "https://moderator.example" }, "wrong")).status).toBe(403);
        const reviewNoAuth = await fetch(`${baseUrl}/moderation/holds/${hold.ref}/review`, {
          method: "POST",
          headers: { Origin: "https://moderator.example", "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ reviewInDays: "30", _csrf: authenticated.csrf }),
          redirect: "manual",
        });
        expect(reviewNoAuth.status).not.toBe(303);
        expect((await RetentionHold.findById(hold._id).lean())?.state).toBe("active");
        await ModeratorSession.updateOne({}, { $set: { absoluteExpiresAt: new Date(Date.now() - 1) } }).exec();
        const expired = await send({ Cookie: authenticated.cookie, Origin: "https://moderator.example" });
        expect(expired.status).not.toBe(303);
        expect((await RetentionHold.findById(hold._id).lean())?.state).toBe("active");
      });
    });

    it("marks a placed request permanently unavailable without changing order or pickup data", async () => {
      const participant = await Participant.create({
        email: "placed-report-subject@nyu.edu",
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      const helper = await Participant.create({
        email: "placed-report-helper@nyu.edu",
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      const previousHelper = await Participant.create({
        email: "previous-report-helper@nyu.edu",
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      const unrelatedHelper = await Participant.create({
        email: "unrelated-report-helper@nyu.edu",
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      const placedAt = new Date(Date.now() - 60_000);
      const deleteAt = new Date(Date.now() + 90 * 24 * 60 * 60_000);
      const request = await MealRequest.create({
        vendor: "Jasper Kane Cafe",
        food: "Rice bowl",
        pickupWindowText: "ASAP",
        email: participant.email,
        status: "placed",
        placedAt,
        orderNumber: "private-order-number",
        etaText: "15 minutes",
        deleteAt,
        requesterParticipantId: participant._id,
        helperParticipantId: helper._id,
      });
      const unrelatedRequest = await MealRequest.create({
        vendor: "Unrelated Cafe",
        food: "Soup",
        pickupWindowText: "Later",
        email: participant.email,
        status: "placed",
        placedAt,
        deleteAt,
        requesterParticipantId: participant._id,
        helperParticipantId: unrelatedHelper._id,
      });
      await RequestParticipation.create([
        { requestId: request._id, participantId: helper._id },
        { requestId: request._id, participantId: previousHelper._id },
        { requestId: unrelatedRequest._id, participantId: unrelatedHelper._id },
      ]);
      const firstConversationId = new mongoose.Types.ObjectId();
      const previousConversationId = new mongoose.Types.ObjectId();
      const unrelatedConversationId = new mongoose.Types.ObjectId();
      await MessageConversation.create([
        {
          _id: firstConversationId,
          requestId: request._id,
          helperParticipantId: helper._id,
          requesterParticipantId: participant._id,
          sequence: 1,
          lastAuthorizedAt: placedAt,
          checkedAt: placedAt,
        },
        {
          _id: previousConversationId,
          requestId: request._id,
          helperParticipantId: previousHelper._id,
          requesterParticipantId: participant._id,
          sequence: 1,
          lastAuthorizedAt: placedAt,
          checkedAt: placedAt,
        },
        {
          _id: unrelatedConversationId,
          requestId: unrelatedRequest._id,
          helperParticipantId: unrelatedHelper._id,
          requesterParticipantId: participant._id,
          sequence: 1,
          lastAuthorizedAt: placedAt,
          checkedAt: placedAt,
        },
      ]);
      await ConversationMessage.create({
        conversationId: firstConversationId,
        clientMessageId: "removal-message",
        senderParticipantId: helper._id,
        sequence: 1,
        text: "private conversation content",
        createdAt: placedAt,
      });
      const { reportId, ref, identityId } = await runModerationTransaction((session) =>
        recordReportCase(session, {
          keyring: readSafetyIdentityKeyring(),
          reportedEmail: participant.email,
          snapshot: buildReportRequestSnapshot(
            {
              _id: new mongoose.Types.ObjectId(String(request._id)),
              status: "placed",
              vendor: request.vendor,
              food: request.food,
              pickupWindowText: request.pickupWindowText,
            },
            "requester"
          ),
          reason: "Other concern",
        })
      );
      await Participant.updateOne(
        { _id: participant._id },
        { $set: { safetyIdentityRef: identityId } }
      );
      installMessagingLifecycle(
        createMessagingPolicy(async () => "none", isEitherParticipantSuspended)
      );
      const authenticated = loginCookies(await login());

      const response = await postForm(
        `/moderation/reports/${ref}/close`,
        authenticated.cookie,
        authenticated.csrf,
        { confirm: "close", outcome: "request-removed" }
      );
      expect(response.status).toBe(303);
      const after = await MealRequest.findById(request._id)
        .select("+moderationUnavailable +requesterParticipantId +helperParticipantId")
        .lean()
        .exec();
      expect(after).toMatchObject({
        status: "placed",
        placedAt,
        orderNumber: "private-order-number",
        etaText: "15 minutes",
        deleteAt,
        requesterParticipantId: participant._id,
        helperParticipantId: request.helperParticipantId,
        moderationUnavailable: true,
      });
      expect(await ModerationReport.findById(reportId).lean()).toMatchObject({
        state: "closed",
        outcome: "request-removed",
      });
      expect(await ModerationAuditEvent.countDocuments({
        kind: "request-removed",
        subjectId: reportId,
      })).toBe(1);
      const removedConversations = await MessageConversation.find({
        requestId: request._id,
      }).lean<Array<{
        helperParticipantId: mongoose.Types.ObjectId;
        closedAt?: Date;
      }>>();
      expect(removedConversations).toHaveLength(2);
      expect(removedConversations.every((conversation) => conversation.closedAt)).toBe(true);
      expect((await MessageConversation.findById(unrelatedConversationId).lean())?.closedAt).toBeFalsy();
      expect(await ConversationMessage.countDocuments({ conversationId: firstConversationId })).toBe(1);
      const firstClosedAt = removedConversations.find((row) =>
        String(row.helperParticipantId) === String(helper._id)
      )!.closedAt;

      const retryCase = await runModerationTransaction((session) =>
        recordReportCase(session, {
          keyring: readSafetyIdentityKeyring(),
          reportedEmail: participant.email,
          snapshot: buildReportRequestSnapshot(
            {
              _id: new mongoose.Types.ObjectId(String(request._id)),
              status: "placed",
            },
            "requester"
          ),
          reason: "Other concern",
        })
      );
      await Participant.updateOne(
        { _id: participant._id },
        { $set: { safetyIdentityRef: retryCase.identityId } }
      );
      const retryResponse = await postForm(
        `/moderation/reports/${retryCase.ref}/close`,
        authenticated.cookie,
        authenticated.csrf,
        { confirm: "close", outcome: "request-removed" }
      );
      expect(retryResponse.status).toBe(303);
      expect((await MessageConversation.findById(firstConversationId).lean())?.closedAt)
        .toEqual(firstClosedAt);

      const messaging = createMessagingService(
        createMessagingPolicy(async () => "none", isEitherParticipantSuspended)
      );
      await expect(messaging.open(
        participantCredential(new mongoose.Types.ObjectId(String(helper._id))),
        String(request._id)
      )).rejects.toThrow("unavailable");

      // Simulate a later authority change and helper replacement. The old
      // request/helper tombstones remain closed, while the new helper gets a
      // fresh, empty conversation for its distinct relationship.
      const freshHelper = await Participant.create({
        email: "fresh-report-helper@nyu.edu",
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      await RequestParticipation.create({ requestId: request._id, participantId: freshHelper._id });
      await MealRequest.collection.updateOne(
        { _id: new mongoose.Types.ObjectId(String(request._id)) },
        {
          $set: { helperParticipantId: freshHelper._id },
          $unset: { moderationUnavailable: "" },
        }
      );
      const fresh = await messaging.open(
        participantCredential(new mongoose.Types.ObjectId(String(freshHelper._id))),
        String(request._id)
      );
      expect(fresh.conversationId).not.toBe(String(firstConversationId));
      await expect(messaging.read(
        participantCredential(new mongoose.Types.ObjectId(String(helper._id))),
        String(request._id),
        String(helper._id)
      )).rejects.toThrow("unavailable");
      await expect(messaging.read(
        participantCredential(new mongoose.Types.ObjectId(String(previousHelper._id))),
        String(request._id),
        String(previousHelper._id)
      )).rejects.toThrow("unavailable");
    });

    it("rolls request removal back when the request-bound closure hook fails", async () => {
      const participant = await Participant.create({
        email: "closure-failure-owner@nyu.edu",
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      const helper = await Participant.create({
        email: "closure-failure-helper@nyu.edu",
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      const request = await MealRequest.create({
        vendor: "Fictional Cafe",
        food: "Fictional bowl",
        pickupWindowText: "Later",
        email: participant.email,
        status: "placed",
        placedAt: new Date(),
        deleteAt: new Date(Date.now() + 90 * 24 * 60 * 60_000),
        requesterParticipantId: participant._id,
        helperParticipantId: helper._id,
      });
      await RequestParticipation.create({ requestId: request._id, participantId: helper._id });
      const { reportId, ref, identityId } = await runModerationTransaction((session) =>
        recordReportCase(session, {
          keyring: readSafetyIdentityKeyring(),
          reportedEmail: participant.email,
          snapshot: buildReportRequestSnapshot(
            {
              _id: new mongoose.Types.ObjectId(String(request._id)),
              status: "placed",
            },
            "requester"
          ),
          reason: "Other concern",
        })
      );
      await Participant.updateOne(
        { _id: participant._id },
        { $set: { safetyIdentityRef: identityId } }
      );
      installMessagingLifecycleHooks({
        closeForRelationship: async (requestId, helperId, session) => {
          await closeMessagingRelationship(requestId, helperId, session);
          throw new Error("injected closure failure after tombstone write");
        },
        closeForRequest: async (requestId, helperId, session) => {
          if (helperId) await closeMessagingRelationship(requestId, helperId, session);
          throw new Error("injected closure failure after tombstone write");
        },
        closeForPair: async () => {},
        closeForParticipant: async () => {},
        grantReportLease: async () => false,
        captureReportContext: async () => ({
          captureStatus: "complete",
          messages: [],
        }),
      });
      const authenticated = loginCookies(await login());
      const response = await postForm(
        `/moderation/reports/${ref}/close`,
        authenticated.cookie,
        authenticated.csrf,
        { confirm: "close", outcome: "request-removed" }
      );
      expect(response.status).not.toBe(303);
      expect((await MealRequest.findById(request._id)
        .select("+moderationUnavailable").lean())?.moderationUnavailable).not.toBe(true);
      expect(await MessageConversation.countDocuments({ requestId: request._id })).toBe(0);
      expect((await ModerationReport.findById(reportId).lean())?.state).toBe("open");
      expect(await ModerationAuditEvent.countDocuments({
        kind: "request-removed",
        subjectId: reportId,
      })).toBe(0);
    });

    it("shows an incomplete message-capture limitation in reviewer-visible report detail", async () => {
      const participant = await Participant.create({
        email: "incomplete-capture-subject@nyu.edu",
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      const { ref, identityId } = await runModerationTransaction((session) =>
        recordReportCase(session, {
          keyring: readSafetyIdentityKeyring(),
          reportedEmail: participant.email,
          snapshot: buildReportRequestSnapshot(
            { _id: new mongoose.Types.ObjectId(), status: "claimed" },
            "helper"
          ),
          reason: "Other concern",
          messageContext: {
            captureStatus: "incomplete",
            captureReason: "message-history-incomplete",
            messages: [],
          },
        })
      );
      await Participant.updateOne(
        { _id: participant._id },
        { $set: { safetyIdentityRef: identityId } }
      );
      const { cookie } = loginCookies(await login());
      const response = await fetch(`${baseUrl}/moderation/reports/${ref}`, {
        headers: { Cookie: cookie },
      });
      const html = await response.text();
      expect(response.status).toBe(200);
      expect(html).toContain("Capture incomplete:");
      expect(html).toContain("Some committed conversation messages were unavailable.");
      expect(html).toContain("No conversation messages were attached.");
    });

    async function seedOpenReport(
      email: string,
      explanation: string
    ): Promise<{ reportId: mongoose.Types.ObjectId; ref: string }> {
      const participant = await Participant.create({
        email,
        verifiedAt: new Date(),
        authorityVersion: 1,
      });
      const { reportId, ref, identityId } = await runModerationTransaction((session) =>
        recordReportCase(session, {
          keyring: readSafetyIdentityKeyring(),
          reportedEmail: participant.email,
          snapshot: buildReportRequestSnapshot(
            {
              _id: new mongoose.Types.ObjectId(),
              status: "claimed",
              vendor: "Fictional Hall",
              food: "Fictional bowl",
              pickupWindowText: "6:00 PM",
            },
            "helper"
          ),
          reason: "Other concern",
          explanation,
        })
      );
      await Participant.updateOne({ _id: participant._id }, { $set: { safetyIdentityRef: identityId } });
      return { reportId, ref };
    }

    it("styles every page from the same-origin stylesheet without inline styles or scripts", async () => {
      const loginPage = await (await fetch(`${baseUrl}/moderation/login`)).text();
      expect(loginPage).toContain('href="/moderation/assets/dashboard.css"');
      expect(loginPage).toContain("Moderation");
      expect(loginPage).toContain("The moderator password.");
      expect(loginPage).toContain("authenticator app");
      const css = await fetch(`${baseUrl}/moderation/assets/dashboard.css`);
      expect(css.status).toBe(200);
      expect(css.headers.get("content-type")).toContain("text/css");
      expect(css.headers.get("x-content-type-options")).toBe("nosniff");
      expect(await css.text()).not.toMatch(/@import|url\(|content:/);

      const { cookie } = loginCookies(await login());
      for (const path of ["/moderation", "/moderation/closed", "/moderation/suspensions"]) {
        const response = await fetch(`${baseUrl}${path}`, { headers: { Cookie: cookie } });
        const html = await response.text();
        expect(response.status).toBe(200);
        expect(response.headers.get("content-security-policy")).toContain("style-src 'self'");
        expect(html).not.toMatch(/<script|<style|style="|\son[a-z]+=/i);
        expect(html).toContain('href="/moderation"');
        expect(html).toContain('href="/moderation/suspensions"');
        expect(html).not.toMatch(/<nav[^>]*>[\s\S]*System health[\s\S]*<\/nav>/);
        expect(html.includes('href="/moderation/health"')).toBe(path !== "/moderation/suspensions");
        expect(html).toContain('action="/moderation/logout"');
        expect(html).toContain('aria-current="page"');
      }
      const inboxHtml = await (await fetch(`${baseUrl}/moderation`, { headers: { Cookie: cookie } })).text();
      expect(inboxHtml).toContain('<p class="footer-link"><a href="/moderation/health">System health &amp; retention</a></p>');
      expect(await (await fetch(`${baseUrl}/moderation/health`, { redirect: "manual" })).text()).toContain("Moderator sign in");
      const health = await fetch(`${baseUrl}/moderation/health`, { headers: { Cookie: cookie } });
      const healthHtml = await health.text();
      expect(health.status).toBe(200);
      expect(healthHtml).toContain("<title>System health &amp; retention</title>");
      expect(healthHtml).toContain("<h2>Retention sweep</h2>");
      expect(healthHtml).toContain("<h2>Alerts &amp; notifications</h2>");
      expect(healthHtml).toContain("<dt>Overdue records</dt>");
      expect(healthHtml).not.toContain('aria-current="page"');
      expect(healthHtml).not.toContain("<form method=\"post\" action=\"/moderation/holds");
      expect(await (await fetch(`${baseUrl}/moderation/health`)).text()).toContain("Moderator sign in");
    });

    it("explains retention alert conditions in plain language on the unlisted health page", async () => {
      const now = new Date();
      const report = await ModerationReport.create({ state: "closed", outcome: "no-action", closedAt: now });
      await RetentionHold.create({
        targetKind: "case",
        targetId: report._id,
        holdClass: "legal-preservation",
        reasonCode: "legal-preservation",
        endingCondition: "Counsel confirms.",
        reviewAt: new Date(now.getTime() - 60_000),
      });
      const { cookie } = loginCookies(await login());
      const html = await (await fetch(`${baseUrl}/moderation/health`, { headers: { Cookie: cookie } })).text();
      expect(html).toContain("A retention hold is past its review date");
      expect(html).not.toContain("hold-review-due");
    });

    it("requires a moderator session for every dashboard route", async () => {
      for (const path of ["/moderation", "/moderation/closed", "/moderation/suspensions", "/moderation/health"]) {
        const response = await fetch(`${baseUrl}${path}`);
        expect(await response.text()).toContain("Moderator sign in");
      }
      const detail = await fetch(`${baseUrl}/moderation/reports/${"a".repeat(20)}`);
      expect(await detail.text()).toContain("Moderator sign in");
    });

    it("lists open and closed reports separately with Eastern-time labels", async () => {
      const open = await seedOpenReport("open-subject@nyu.edu", "Open explanation text");
      const closed = await seedOpenReport("closed-subject@nyu.edu", "Closed explanation text");
      const authenticated = loginCookies(await login());
      const closeResponse = await postForm(
        `/moderation/reports/${closed.ref}/close`,
        authenticated.cookie,
        authenticated.csrf,
        { confirm: "close", outcome: "no-action" }
      );
      expect(closeResponse.status).toBe(303);

      const get = async (path: string) =>
        (await fetch(`${baseUrl}${path}`, { headers: { Cookie: authenticated.cookie } })).text();
      const openHtml = await get("/moderation");
      expect(openHtml).toContain(open.ref);
      expect(openHtml).not.toContain(closed.ref);
      expect(openHtml).toContain("Review case");
      expect(openHtml).toMatch(/<time datetime="[^"]+">[A-Z][a-z]{2} \d{1,2}, \d{4} · \d{1,2}:\d{2} [AP]M E[SD]T<\/time>/);

      const closedHtml = await get("/moderation/closed");
      expect(closedHtml).toContain(closed.ref);
      expect(closedHtml).not.toContain(open.ref);
      expect(closedHtml).toContain("Closed");
      expect(closedHtml).toContain("No action · Closed");
      expect(closedHtml).toContain("Other concern");
      expect(closedHtml).toContain(`/moderation/reports/${closed.ref}`);
    });

    it("shows closed reports read-only without identity or mutation controls", async () => {
      const closed = await seedOpenReport("closed-detail@nyu.edu", "Closed detail explanation");
      const authenticated = loginCookies(await login());
      await postForm(`/moderation/reports/${closed.ref}/close`, authenticated.cookie, authenticated.csrf, {
        confirm: "close",
        outcome: "no-action",
      });
      const auditBefore = await ModerationAuditEvent.countDocuments({});

      const response = await fetch(`${baseUrl}/moderation/reports/${closed.ref}`, {
        headers: { Cookie: authenticated.cookie },
      });
      const html = await response.text();
      expect(response.status).toBe(200);
      expect(html).toContain("Closed detail explanation");
      expect(html).not.toContain("closed and read-only");
      expect(html).not.toContain("not retained after closure");
      expect(html).not.toContain("closed-detail@nyu.edu");
      expect(html).not.toContain("Reported participant");
      expect(html).not.toContain("Safety identifier");
      expect(html).not.toContain("Apply and close report");
      expect(html).not.toContain("Create retention hold");
      expect((html.match(/<form/g) ?? []).length).toBe(1);
      expect(html).toContain('action="/moderation/logout"');
      expect(await ModerationAuditEvent.countDocuments({})).toBe(auditBefore + 1);
      expect(await ModerationAuditEvent.countDocuments({ kind: "report-viewed", subjectId: closed.reportId })).toBe(1);

      const reclose = await postForm(
        `/moderation/reports/${closed.ref}/close`,
        authenticated.cookie,
        authenticated.csrf,
        { confirm: "close", outcome: "participant-suspended", rationale: "No." }
      );
      expect(reclose.status).toBe(404);
      expect(await ModerationReport.findById(closed.reportId).lean()).toMatchObject({
        state: "closed",
        outcome: "no-action",
      });
    });

    it("shows a missing-notes error inside the dashboard and leaves the report open", async () => {
      const open = await seedOpenReport("missing-notes@nyu.edu", "Needs notes");
      const authenticated = loginCookies(await login());
      const refused = await postForm(
        `/moderation/reports/${open.ref}/close`,
        authenticated.cookie,
        authenticated.csrf,
        { confirm: "close", outcome: "request-removed-and-participant-suspended", rationale: "" }
      );
      const html = await refused.text();
      expect(refused.status).toBe(400);
      expect(html).toContain('role="alert"');
      expect(html).toContain("Notes are required");
      expect(html).toContain(`href="/moderation/reports/${open.ref}"`);
      expect(html).toContain('action="/moderation/logout"');
      expect(await ModerationReport.findById(open.reportId).lean()).toMatchObject({ state: "open" });
    });

    it("never restores expired closed-report evidence or history", async () => {
      const closed = await seedOpenReport("expired-evidence@nyu.edu", "Expiring explanation");
      const authenticated = loginCookies(await login());
      await postForm(`/moderation/reports/${closed.ref}/close`, authenticated.cookie, authenticated.csrf, {
        confirm: "close",
        outcome: "no-action",
      });
      const before = await ModerationReport.findById(closed.reportId).lean();
      const past = new Date(Date.now() - 60_000);
      await ReportEvidence.updateMany({ reportId: closed.reportId }, { $set: { deleteAt: past } });

      const get = async (path: string) =>
        (await fetch(`${baseUrl}${path}`, { headers: { Cookie: authenticated.cookie } })).text();
      const detail = await get(`/moderation/reports/${closed.ref}`);
      expect(detail).not.toContain("Expiring explanation");
      expect(detail).not.toContain("Request snapshot");
      expect(detail).toContain("no longer retained");
      const list = await get("/moderation/closed");
      expect(list).toContain(closed.ref);
      expect(list).toContain("Reason no longer retained");

      await ModerationReport.updateOne({ _id: closed.reportId }, { $set: { deleteAt: past } });
      expect((await fetch(`${baseUrl}/moderation/reports/${closed.ref}`, {
        headers: { Cookie: authenticated.cookie },
      })).status).toBe(404);
      expect(await get("/moderation/closed")).not.toContain(closed.ref);
      expect((await ReportEvidence.countDocuments({ reportId: closed.reportId }))).toBe(2);
      expect((await ModerationReport.findById(closed.reportId).lean())?.closedAt).toEqual(before?.closedAt);
    });

    it("refuses every mutation of a closed report on the server, not just in the UI", async () => {
      const closed = await seedOpenReport("immutable-closed@nyu.edu", "Immutable explanation");
      const authenticated = loginCookies(await login());
      await postForm(`/moderation/reports/${closed.ref}/close`, authenticated.cookie, authenticated.csrf, {
        confirm: "close",
        outcome: "no-action",
      });
      const snapshot = async () => ({
        report: await ModerationReport.findById(closed.reportId).lean(),
        evidence: await ReportEvidence.find({ reportId: closed.reportId }).sort({ kind: 1 }).lean(),
        audit: await ModerationAuditEvent.countDocuments({ kind: { $ne: "report-viewed" } }),
      });
      const before = await snapshot();
      for (const outcome of [
        "no-action",
        "request-removed",
        "participant-suspended",
        "request-removed-and-participant-suspended",
      ]) {
        const response = await postForm(
          `/moderation/reports/${closed.ref}/close`,
          authenticated.cookie,
          authenticated.csrf,
          { confirm: "close", outcome, rationale: "Attempt to reopen." }
        );
        expect(response.status).toBe(404);
      }
      expect(await snapshot()).toEqual(before);
      for (const method of ["PUT", "PATCH", "DELETE", "POST"]) {
        const response = await fetch(`${baseUrl}/moderation/reports/${closed.ref}`, {
          method,
          headers: { Cookie: authenticated.cookie, Origin: "https://moderator.example" },
        });
        expect(response.status).toBe(404);
      }
      expect(await snapshot()).toEqual(before);
    });

    it("refuses a retention hold on a closed case whose history has expired", async () => {
      const closed = await seedOpenReport("expired-hold@nyu.edu", "Expired hold explanation");
      const authenticated = loginCookies(await login());
      await postForm(`/moderation/reports/${closed.ref}/close`, authenticated.cookie, authenticated.csrf, {
        confirm: "close",
        outcome: "no-action",
      });
      const past = new Date(Date.now() - 60_000);
      await ModerationReport.updateOne({ _id: closed.reportId }, { $set: { deleteAt: past } });
      const response = await postForm("/moderation/holds", authenticated.cookie, authenticated.csrf, {
        targetKind: "case",
        targetRef: closed.ref,
        holdClass: "legal-preservation",
        reasonCode: "legal-preservation",
        endingCondition: "Counsel confirms.",
        reviewAt: new Date(Date.now() + 86_400_000).toISOString(),
      });
      expect(response.status).toBe(409);
      expect(await RetentionHold.countDocuments({})).toBe(0);
      expect((await ModerationReport.findById(closed.reportId).lean())?.deleteAt).toEqual(past);
    });

    it("keeps open report detail controls without retention hold controls", async () => {
      const open = await seedOpenReport("open-detail@nyu.edu", "Open detail explanation");
      const { cookie } = loginCookies(await login());
      const html = await (
        await fetch(`${baseUrl}/moderation/reports/${open.ref}`, { headers: { Cookie: cookie } })
      ).text();
      expect(html).toContain("open-detail@nyu.edu");
      expect(html).toContain("Apply and close report");
      expect(html).toContain(`action="/moderation/reports/${open.ref}/close"`);
      expect(html).not.toMatch(/retention hold/i);
      expect(html).not.toContain('action="/moderation/holds"');
      for (const [value, label] of [
        ["no-action", "No action"],
        ["request-removed", "Remove the request"],
        ["participant-suspended", "Suspend the participant"],
        ["request-removed-and-participant-suspended", "Remove the request and suspend the participant"],
      ]) {
        expect(html).toContain(`<option value="${value}">${label}</option>`);
      }
      expect(html).not.toMatch(/<option[^>]*>[a-z]+-[a-z-]+<\/option>/);
    });
  }
);
