import express, { type NextFunction, type Request, type Response } from "express";
import rateLimit from "express-rate-limit";
import {
  confirmSubscription as redeemConfirmationToken,
  type ConfirmationResult,
} from "./confirmSubscription.js";
import { escapeHtml } from "./htmlEscape.js";
import { isPublicActionsPaused } from "./publicActionsPause.js";
import {
  PUBLIC_PAGE_CONTENT_SECURITY_POLICY,
  publicPageSecurityHeaders,
  renderPublicPage,
  sendPublicPage,
} from "./publicPage.js";
import { isValidRawSubscriptionToken } from "./subscriptionTokens.js";
import {
  isRequestAlertEmailDeliveryActive,
  REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE,
} from "./requestAlertEmailDelivery.js";

/**
 * Browser surface for the accepted confirmation primitive:
 *
 *   emailed link → safe GET page → explicit POST → confirmSubscription
 *
 * The GET is deliberately inert. A link in an inbox is fetched by scanners,
 * previewers, and prefetchers, so rendering it must never mutate a Subscriber
 * — the mutation belongs to the explicit button press. The GET also answers
 * from token shape alone, so the page cannot be used to probe which tokens
 * match a real subscriber.
 *
 * Every response here is HTML, including refusals: a person reading email is
 * the only caller, and the JSON error envelope would render as noise in a
 * browser window.
 */
export const CONFIRMATION_ROUTE_PATH = "/api/subscribe/confirm";

/**
 * Same window and threshold as the shared public-mutation limiter in `app.ts`
 * that covers `POST /api/subscribe`. Confirmation is the second half of that
 * one signup flow, so it is throttled like it rather than like the Day 4 claim
 * mutations.
 */
export const CONFIRMATION_RATE_LIMIT_WINDOW_MS = 60_000;
export const CONFIRMATION_RATE_LIMIT_MAX = 5;

export const CONFIRMATION_CONTENT_SECURITY_POLICY =
  PUBLIC_PAGE_CONTENT_SECURITY_POLICY;

/**
 * The only dynamic value any page carries is the escaped hidden token; every
 * heading and paragraph below is a fixed string, so interpolating them is not
 * an injection surface.
 */
const renderPage = renderPublicPage;

/**
 * One fixed recovery line for every unusable link — malformed, unknown,
 * rotated, or rejected by the parser — so the page can never be read as
 * evidence about a Subscriber. Signup lives on the home page, so recovery is a
 * same-origin link rather than an instruction the reader has to act out.
 */
const RECOVERY_PARAGRAPH =
  '      <p><a href="/">Return to CommonPlate</a> to sign up again and receive a new link.</p>';

const INVALID_PAGE = renderPage(
  "This confirmation link is invalid.",
  RECOVERY_PARAGRAPH
);

const EXPIRED_PAGE = renderPage(
  "This confirmation link has expired.",
  RECOVERY_PARAGRAPH
);

/**
 * The pause and the unexpected error read identically on purpose: both are
 * temporary service conditions, the reader can do nothing different about
 * either, and the visible text must not disclose which one occurred. The
 * distinction survives in the status code — 503 versus 500.
 */
const TEMPORARILY_UNAVAILABLE_PAGE = renderPage(
  "Email confirmation is temporarily unavailable.",
  "      <p>Please open this link again later.</p>"
);

const PAUSED_PAGE = TEMPORARILY_UNAVAILABLE_PAGE;

const UNEXPECTED_ERROR_PAGE = TEMPORARILY_UNAVAILABLE_PAGE;

/**
 * The window is 60 seconds, so the wait is stated as about a minute. A reader
 * who lands here has usually refreshed or resubmitted, or shares an address
 * with other readers, so the page names the wait rather than the attempts.
 */
const RATE_LIMITED_PAGE = renderPage(
  "Please wait a moment",
  "      <p>Wait about a minute, then open your confirmation link again.</p>"
);

const CONFIRMED_PAGE = renderPage(
  "Email alerts confirmed.",
  "      <p>You can now receive CommonPlate alerts about new food requests. No further action is needed.</p>"
);

const ALREADY_CONFIRMED_PAGE = renderPage(
  "Your email is already confirmed.",
  "      <p>You can receive CommonPlate alerts about new food requests. No further action is needed.</p>"
);

/**
 * The lead sentence states what opening the link did not do. It describes the
 * page, never the Subscriber: this page is rendered from token shape alone, so
 * it cannot claim a current subscription state and must read correctly for an
 * already-confirmed token too.
 */
function renderConfirmationFormPage(rawToken: string): string {
  return renderPage(
    "Confirm email alerts",
    `      <p>Opening this link does not confirm alerts. Select “Confirm alerts” to receive CommonPlate alerts about new food requests.</p>
      <form method="post" action="${CONFIRMATION_ROUTE_PATH}">
        <input type="hidden" name="token" value="${escapeHtml(rawToken)}" />
        <button type="submit">Confirm alerts</button>
      </form>`
  );
}

const sendConfirmationPage = sendPublicPage;
const UNAVAILABLE_PAGE = renderPage(REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE);

/**
 * Route-owned headers for every confirmation response, including the pause,
 * invalid, expired, rate-limit, and error pages. Mounted first so a refusal
 * produced by a later middleware still carries them.
 */
export const confirmationSecurityHeaders = publicPageSecurityHeaders;

/**
 * HTML sibling of `pausePublicAction`, which answers in JSON and is left
 * unchanged for the API mutations. Mounted ahead of shape validation, hashing,
 * the Subscriber lookup, the mutation, and the rate limiter, so a paused
 * confirmation performs no lifecycle work and consumes no throttle capacity.
 */
export function pauseConfirmationPage(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (!isPublicActionsPaused()) {
    next();
    return;
  }

  sendConfirmationPage(res, 503, PAUSED_PAGE);
}

export function createConfirmationRateLimiter() {
  return rateLimit({
    windowMs: CONFIRMATION_RATE_LIMIT_WINDOW_MS,
    max: CONFIRMATION_RATE_LIMIT_MAX,
    standardHeaders: true,
    legacyHeaders: false,
    handler: (_req, res) =>
      sendConfirmationPage(res, 429, RATE_LIMITED_PAGE),
  });
}

/**
 * Its own bucket: confirming must not spend the signup allowance. Production
 * registers this one persistent instance; tests build their own through the
 * factory so one suite's requests cannot fill another's window.
 */
export const confirmationRateLimiter = createConfirmationRateLimiter();

/**
 * Route-local body parsing, mounted after the pause guard and the limiter and
 * registered ahead of the global parsers in `app.ts`.
 *
 * A global parser runs before any route middleware, so a body it rejects would
 * be answered by the global JSON error handler — outside this route's security
 * headers, outside its HTML contract, and with the parser error (which can
 * quote the body) logged. Parsing here instead keeps every malformed-body
 * outcome inside the confirmation route.
 *
 * Only `application/x-www-form-urlencoded` is accepted, because that is the
 * only thing the accepted form submits. A JSON body is simply left unparsed
 * and reaches the handler with no usable token.
 */
export const confirmationBodyParser = express.urlencoded({
  extended: true,
  limit: "100kb",
});

/**
 * Final error boundary for this route: a rejected body — malformed, oversized,
 * wrongly encoded — is an unusable confirmation link, so it gets the existing
 * invalid-link page rather than a new status or message. Nothing is logged,
 * because a parser error can carry the body and therefore the raw token.
 */
export function confirmationParserError(
  error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (res.headersSent) {
    next(error);
    return;
  }

  sendConfirmationPage(res, 400, INVALID_PAGE);
}

/**
 * Renders the confirmation form. Answers from token shape only: no hashing, no
 * Subscriber lookup, and therefore no way to learn from this page whether a
 * token matches a real subscriber.
 */
export function showConfirmationPage(req: Request, res: Response): Response {
  if (!isRequestAlertEmailDeliveryActive()) {
    return sendConfirmationPage(res, 410, UNAVAILABLE_PAGE);
  }
  const token = req.query?.token;
  if (!isValidRawSubscriptionToken(token)) {
    return sendConfirmationPage(res, 400, INVALID_PAGE);
  }

  return sendConfirmationPage(res, 200, renderConfirmationFormPage(token));
}

export interface ConfirmSubscriptionPageDependencies {
  confirmSubscription: (
    rawToken: unknown,
    now: Date
  ) => Promise<ConfirmationResult>;
}

const defaultDependencies: ConfirmSubscriptionPageDependencies = {
  confirmSubscription: redeemConfirmationToken,
};

export function createConfirmSubscriptionPageHandler(
  overrides: Partial<ConfirmSubscriptionPageDependencies> = {}
) {
  const dependencies = { ...defaultDependencies, ...overrides };

  return async function confirmSubscriptionPage(
    req: Request,
    res: Response
  ): Promise<Response> {
    if (!isRequestAlertEmailDeliveryActive()) {
      return sendConfirmationPage(res, 410, UNAVAILABLE_PAGE);
    }
    let result: ConfirmationResult;
    try {
      // The primitive owns shape validation, so a missing body, a non-string
      // value, or an unparsed body is an invalid token rather than a throw.
      result = await dependencies.confirmSubscription(
        req.body?.token,
        new Date()
      );
    } catch {
      // Fixed text only. The token, its digest, the URL, the body, and the
      // error are all either credentials or credential-bearing.
      console.error("[confirm] Confirmation redemption failed");
      return sendConfirmationPage(res, 500, UNEXPECTED_ERROR_PAGE);
    }

    switch (result.outcome) {
      case "unavailable":
        return sendConfirmationPage(res, 410, UNAVAILABLE_PAGE);
      case "confirmed":
        // The primitive returns no credential to render or log: an unsubscribe
        // link is signed on demand when an alert or digest is built, never
        // issued or stored by confirmation.
        return sendConfirmationPage(res, 200, CONFIRMED_PAGE);
      case "alreadyConfirmed":
        return sendConfirmationPage(res, 200, ALREADY_CONFIRMED_PAGE);
      case "expired":
        return sendConfirmationPage(res, 410, EXPIRED_PAGE);
      case "invalid":
        return sendConfirmationPage(res, 400, INVALID_PAGE);
      default:
        console.error("[confirm] Confirmation redemption failed");
        return sendConfirmationPage(res, 500, UNEXPECTED_ERROR_PAGE);
    }
  };
}

export const confirmSubscriptionPage = createConfirmSubscriptionPageHandler();
