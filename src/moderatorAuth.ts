import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { Express, NextFunction, Request, Response } from "express";
import rateLimit from "express-rate-limit";
import {
  ModeratorSession,
  ModeratorThrottle,
  type IModeratorSession,
} from "../models/moderation.js";
import { appendClockedAudit } from "./moderationAudit.js";
import { runModerationTransaction } from "./safetyIdentity.js";
import { MODERATOR_STYLESHEET, MODERATOR_STYLESHEET_PATH } from "./moderatorDashboardStyles.js";
import {
  matchTotpStep,
  readModeratorConfig,
  verifyModeratorPassphrase,
  type ModeratorConfig,
} from "./moderatorSecurity.js";

export const MODERATOR_COOKIE = "__Host-commonplate-moderator";
export const MODERATOR_CSRF_COOKIE = "__Host-commonplate-moderator-csrf";
export const MODERATOR_IDLE_MS = 15 * 60 * 1000;
export const MODERATOR_ABSOLUTE_MS = 8 * 60 * 60 * 1000;
const THROTTLE_START_MS = 30_000;
const THROTTLE_MAX_MS = 15 * 60_000;

export interface ModeratorContext {
  config: ModeratorConfig;
  session: IModeratorSession;
  actor: string;
  csrfToken: string;
}

declare module "express-serve-static-core" {
  interface Request {
    moderator?: ModeratorContext;
  }
}

function digest(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function equalDigest(left: string, right: string): boolean {
  const a = Buffer.from(left, "hex");
  const b = Buffer.from(right, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

export function setModeratorSecurityHeaders(_req: Request, res: Response, next: NextFunction): void {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("X-Robots-Tag", "noindex, nofollow, noarchive");
  res.setHeader("Content-Security-Policy", "default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("X-Content-Type-Options", "nosniff");
  // `no-referrer` makes Chromium send `Origin: null` on same-origin form posts,
  // which the strict Origin check correctly refuses; `same-origin` still sends
  // no referrer to any other site.
  res.setHeader("Referrer-Policy", "same-origin");
  res.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  next();
}

function setModeratorCookie(res: Response, raw: string, csrf: string): void {
  res.setHeader("Set-Cookie", [
    `${MODERATOR_COOKIE}=${raw}; Path=/; Secure; HttpOnly; SameSite=Strict`,
    `${MODERATOR_CSRF_COOKIE}=${csrf}; Path=/; Secure; SameSite=Strict`,
  ]);
}

function clearModeratorCookie(res: Response): void {
  res.setHeader("Set-Cookie", [
    `${MODERATOR_COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0`,
    `${MODERATOR_CSRF_COOKIE}=; Path=/; Secure; SameSite=Strict; Max-Age=0`,
  ]);
}

function cookieValues(req: Request): { session: string | null; csrf: string | null } {
  const header = req.headers.cookie;
  if (typeof header !== "string") return { session: null, csrf: null };
  const parts = header
    .split(";")
    .map((part) => part.trim());
  const sessionValues = parts.filter((part) => part.startsWith(`${MODERATOR_COOKIE}=`));
  const csrfValues = parts.filter((part) => part.startsWith(`${MODERATOR_CSRF_COOKIE}=`));
  const session = sessionValues.length === 1 ? sessionValues[0]!.slice(MODERATOR_COOKIE.length + 1) : "";
  const csrf =
    csrfValues.length === 1 ? csrfValues[0]!.slice(MODERATOR_CSRF_COOKIE.length + 1) : "";
  return {
    session: /^[A-Za-z0-9_-]{40,64}$/.test(session) ? session : null,
    csrf: /^[A-Za-z0-9_-]{40,64}$/.test(csrf) ? csrf : null,
  };
}

function hasOrigin(req: Request, origin: string): boolean {
  return typeof req.headers.origin === "string" && req.headers.origin === origin;
}

function loginForm(message = ""): string {
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Moderator sign in</title><link rel="stylesheet" href="${MODERATOR_STYLESHEET_PATH}"><body class="page-login"><main class="login-card"><p class="brand-line">Moderation</p><h1>Moderator sign in</h1>${message ? `<p role="alert">${message}</p>` : ""}<form method="post" action="/moderation/login"><label>Passphrase <input name="passphrase" type="password" autocomplete="current-password" required maxlength="1024" aria-describedby="passphrase-help"><small id="passphrase-help">The moderator password.</small></label><label>Authenticator code <input name="totp" inputmode="numeric" autocomplete="one-time-code" required pattern="[0-9]{6}" maxlength="6" aria-describedby="totp-help"><small id="totp-help">The 6-digit code from your authenticator app.</small></label><button type="submit">Sign in</button></form></main></body></html>`;
}

export const moderatorLoginRateLimiter = rateLimit({
  windowMs: 60_000,
  limit: 10,
  standardHeaders: true,
  legacyHeaders: false,
  handler: (_req, res) => res.status(200).type("html").send(loginForm("Sign-in was not confirmed.")),
});

function progressiveDelay(current: number, failures: number): number {
  if (failures < 5) return 0;
  return current < THROTTLE_START_MS
    ? THROTTLE_START_MS
    : Math.min(THROTTLE_MAX_MS, current * 2);
}

export async function showModeratorLogin(_req: Request, res: Response): Promise<Response | void> {
  return res.type("html").send(loginForm());
}

export function createModeratorLoginHandler(
  readConfig: () => ModeratorConfig | null = readModeratorConfig,
  now: () => Date = () => new Date()
) {
  return async function moderatorLogin(req: Request, res: Response): Promise<Response | void> {
    const config = readConfig();
    if (!config || !hasOrigin(req, config.origin)) {
      return res.status(200).type("html").send(loginForm("Sign-in was not confirmed."));
    }

    const timestamp = now();
    const passphrase = typeof req.body?.passphrase === "string" ? req.body.passphrase : "";
    const totp = typeof req.body?.totp === "string" ? req.body.totp : "";
    let passwordMatches = false;
    let totpStep: number | null = null;
    try {
      [passwordMatches, totpStep] = await Promise.all([
        verifyModeratorPassphrase(passphrase, config.passphraseHash),
        Promise.resolve(matchTotpStep(totp, config.totpSecret, timestamp)),
      ]);
    } catch {
      return res.status(200).type("html").send(loginForm("Sign-in was not confirmed."));
    }

    const rawSession = randomBytes(32).toString("base64url");
    const rawCsrf = randomBytes(32).toString("base64url");
    const validFactors = passwordMatches && totpStep !== null;
    let accepted = false;

    try {
      accepted = await runModerationTransaction(async (session) => {
        const throttle = await ModeratorThrottle.findOneAndUpdate(
          { scope: "global" },
          { $setOnInsert: { failures: 0, delayMs: 0, serial: 0 } },
          { upsert: true, new: true, session }
        )
          .lean()
          .exec();
        if (!throttle) throw new Error("Moderator throttle unavailable.");
        if (throttle.blockedUntil && throttle.blockedUntil.getTime() > timestamp.getTime()) {
          await appendClockedAudit(
            "moderator-authentication",
            timestamp,
            undefined,
            session,
            digest(rawSession)
          );
          return false;
        }

        if (validFactors) {
          const totpConsumed = await ModeratorThrottle.updateOne(
            {
              _id: throttle._id,
              $or: [
                { lastAcceptedTotpStep: { $exists: false } },
                { lastAcceptedTotpStep: { $lt: totpStep! } },
              ],
            },
            {
              $set: {
                failures: 0,
                delayMs: 0,
                lastAcceptedTotpStep: totpStep,
              },
              $unset: { blockedUntil: 1 },
              $inc: { serial: 1 },
            },
            { session }
          );
          if (totpConsumed.modifiedCount !== 1) {
            await appendClockedAudit(
              "moderator-authentication",
              timestamp,
              undefined,
              session,
              digest(rawSession)
            );
            return false;
          }
          await ModeratorSession.findOneAndUpdate(
            { scope: "faith" },
            {
              $set: {
                sessionDigest: digest(rawSession),
                csrfDigest: digest(rawCsrf),
                configFingerprint: config.fingerprint,
                createdAt: timestamp,
                lastSeenAt: timestamp,
                idleExpiresAt: new Date(timestamp.getTime() + MODERATOR_IDLE_MS),
                absoluteExpiresAt: new Date(timestamp.getTime() + MODERATOR_ABSOLUTE_MS),
              },
            },
            { upsert: true, new: true, runValidators: true, session }
          ).exec();
          await appendClockedAudit(
            "moderator-authentication",
            timestamp,
            undefined,
            session,
            digest(rawSession)
          );
          return true;
        }

        const failures = throttle.failures + 1;
        const delayMs = progressiveDelay(throttle.delayMs, failures);
        await ModeratorThrottle.updateOne(
          { _id: throttle._id },
          {
            $set: {
              failures,
              delayMs,
              ...(delayMs ? { blockedUntil: new Date(timestamp.getTime() + delayMs) } : {}),
            },
            $inc: { serial: 1 },
          },
          { session }
        );
        await appendClockedAudit(
          "moderator-authentication",
          timestamp,
          undefined,
          session,
          digest(rawSession)
        );
        return false;
      });
    } catch {
      accepted = false;
    }

    if (!accepted) {
      return res.status(200).type("html").send(loginForm("Sign-in was not confirmed."));
    }
    setModeratorCookie(res, rawSession, rawCsrf);
    return res.redirect(303, "/moderation");
  };
}

export async function requireModerator(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  const config = readModeratorConfig();
  const cookies = cookieValues(req);
  if (!config || !cookies.session || !cookies.csrf) {
    res.status(200).type("html").send(loginForm());
    return;
  }

  const now = new Date();
  try {
    const row = await ModeratorSession.findOneAndUpdate(
      {
        scope: "faith",
        sessionDigest: digest(cookies.session),
        configFingerprint: config.fingerprint,
        csrfDigest: digest(cookies.csrf),
        idleExpiresAt: { $gt: now },
        absoluteExpiresAt: { $gt: now },
      },
      {
        $set: {
          lastSeenAt: now,
          idleExpiresAt: new Date(now.getTime() + MODERATOR_IDLE_MS),
        },
      },
      { new: true }
    )
      .lean<IModeratorSession>()
      .exec();
    if (!row) {
      res.status(200).type("html").send(loginForm());
      return;
    }

    req.moderator = {
      config,
      session: row,
      actor: row.sessionDigest.slice(0, 32),
      csrfToken: cookies.csrf,
    };
    next();
  } catch {
    res.status(503).type("html").send("Moderator service unavailable.");
  }
}

export function requireModeratorOriginAndCsrf(
  req: Request,
  res: Response,
  next: NextFunction
): void {
  const context = req.moderator;
  const csrf = typeof req.body?._csrf === "string" ? req.body._csrf : "";
  if (
    !context ||
    !hasOrigin(req, context.config.origin) ||
    !csrf ||
    csrf !== context.csrfToken ||
    !equalDigest(digest(csrf), context.session.csrfDigest)
  ) {
    res.status(403).type("html").send("Request could not be confirmed.");
    return;
  }
  next();
}

export type ModeratorNavSection = "reports" | "suspensions";

const NAV_ITEMS: Array<{ key: ModeratorNavSection; href: string; label: string }> = [
  { key: "reports", href: "/moderation", label: "Reports" },
  { key: "suspensions", href: "/moderation/suspensions", label: "Active suspensions" },
];

export function moderatorHtml(
  title: string,
  content: string,
  csrfToken?: string,
  active?: ModeratorNavSection
): string {
  const logout = csrfToken
    ? `<form method="post" action="/moderation/logout"><input type="hidden" name="_csrf" value="${csrfToken}"><button type="submit" class="btn-secondary">Sign out</button></form>`
    : "";
  const nav = NAV_ITEMS.map(
    (item) =>
      `<a href="${item.href}"${item.key === active ? ' aria-current="page"' : ""}>${item.label}</a>`
  ).join("");
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title><link rel="stylesheet" href="${MODERATOR_STYLESHEET_PATH}"><body><header class="site-header"><span class="brand">Moderation</span><nav class="primary-nav" aria-label="Moderator">${nav}</nav>${logout}</header><main class="page-${active ?? "other"}"><h1>${title}</h1>${content}</main></body></html>`;
}

function serveModeratorStylesheet(_req: Request, res: Response): void {
  res.setHeader("Content-Type", "text/css; charset=utf-8");
  res.setHeader("Cache-Control", "public, max-age=300");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.send(MODERATOR_STYLESHEET);
}

export async function moderatorLogout(req: Request, res: Response): Promise<Response | void> {
  if (req.moderator) {
    await runModerationTransaction(async (session) => {
      const removed = await ModeratorSession.deleteOne({
        _id: req.moderator!.session._id,
        sessionDigest: req.moderator!.session.sessionDigest,
      })
        .session(session)
        .exec();
      if (removed.deletedCount === 1) {
        await appendClockedAudit(
          "moderator-authentication",
          new Date(),
          undefined,
          session,
          req.moderator!.session.sessionDigest
        );
      }
    });
  }
  clearModeratorCookie(res);
  return res.redirect(303, "/moderation/login");
}

export function registerModeratorAuthRoutes(
  app: Express,
  bodyParser: (req: Request, res: Response, next: NextFunction) => void
): void {
  app.get(MODERATOR_STYLESHEET_PATH, serveModeratorStylesheet);
  app.get("/moderation/login", setModeratorSecurityHeaders, showModeratorLogin);
  app.post(
    "/moderation/login",
    setModeratorSecurityHeaders,
    moderatorLoginRateLimiter,
    bodyParser,
    createModeratorLoginHandler(() => readModeratorConfig()),
    (error: unknown, _req: Request, res: Response, _next: NextFunction) => {
      if (error) res.status(400).type("html").send(loginForm("Sign-in was not confirmed."));
    }
  );
  app.post(
    "/moderation/logout",
    setModeratorSecurityHeaders,
    bodyParser,
    requireModerator,
    requireModeratorOriginAndCsrf,
    moderatorLogout
  );
}
