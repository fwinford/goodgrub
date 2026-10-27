import express, { type NextFunction, type Request, type Response } from "express";
import rateLimit from "express-rate-limit";
import { escapeHtml } from "./htmlEscape.js";
import { isPublicActionsPaused } from "./publicActionsPause.js";
import {
  publicPageSecurityHeaders,
  renderPublicPage,
  sendPublicPage,
} from "./publicPage.js";
import {
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
} from "./unsubscribeCredential.js";
import {
  checkUnsubscribeCredential as checkCredential,
  unsubscribeSubscriber as redeemUnsubscribeCredential,
  type UnsubscribeCredentialCheck,
  type UnsubscribeResult,
} from "./unsubscribeSubscriber.js";

/**
 * Browser surface for the emailed unsubscribe link:
 *
 *   emailed link → safe GET page → explicit POST → unsubscribeSubscriber
 *
 * Opening the link never unsubscribes anyone. Mail scanners, previewers, and
 * prefetchers fetch inbox links with nobody acting, so a GET that mutated would
 * unsubscribe people who merely received an alert. The mutation belongs to the
 * button press.
 *
 * Unlike the confirmation GET, this one does read a Subscriber: an unsubscribe
 * credential is unforgeable, so refusing an unknown or revoked link before
 * rendering a form costs nothing an attacker could learn. What the page must
 * never disclose is the *state* it found — pending, confirmed, and already
 * unsubscribed all get the same page, and both valid outcomes read the same way
 * for all three.
 */
export { UNSUBSCRIBE_CREDENTIAL_PARAMETER, UNSUBSCRIBE_ROUTE_PATH };

/**
 * Same window and threshold as the confirmation POST and the shared public
 * mutation limiter in `app.ts`. Unsubscribing is a lifecycle mutation reached
 * from an emailed link, exactly like confirming, so it is throttled like it and
 * keeps its own bucket: pressing this button must not spend a signup or
 * confirmation allowance.
 */
export const UNSUBSCRIBE_RATE_LIMIT_WINDOW_MS = 60_000;
export const UNSUBSCRIBE_RATE_LIMIT_MAX = 5;

/**
 * One fixed page for every unusable link — malformed, tampered, unknown, or
 * signed at a revoked version — so nothing here can be read as evidence about a
 * subscriber. It carries no form: there is nothing to submit.
 */
const INVALID_PAGE = renderPublicPage("This unsubscribe link is invalid.");

/**
 * The pause and the unexpected error read identically on purpose: both are
 * temporary service conditions, the reader can do nothing different about
 * either, and the visible text must not disclose which one occurred. The
 * distinction survives in the status code — 503 versus 500.
 */
const TEMPORARILY_UNAVAILABLE_PAGE = renderPublicPage(
  "Unsubscribing is temporarily unavailable.",
  "      <p>Please open this link again later.</p>"
);

const PAUSED_PAGE = TEMPORARILY_UNAVAILABLE_PAGE;

const UNEXPECTED_ERROR_PAGE = TEMPORARILY_UNAVAILABLE_PAGE;

const RATE_LIMITED_PAGE = renderPublicPage(
  "Please wait a moment",
  "      <p>Wait about a minute, then open your unsubscribe link again.</p>"
);

/**
 * The one success page. A pending, a confirmed, and an already-unsubscribed
 * subscriber all reach it, so the wording states the resulting condition and
 * never what changed.
 */
const UNSUBSCRIBED_PAGE = renderPublicPage(
  "You’re unsubscribed",
  "      <p>You won’t receive CommonPlate alert or digest emails unless you sign up and confirm again.</p>"
);

/**
 * The credential is the only dynamic value on any page here, and it lives in
 * exactly one place: the hidden field that carries it back to the POST. It is
 * escaped even though the parser that accepted it is strict, because the page
 * must not depend on a validator elsewhere staying strict.
 */
function renderUnsubscribeFormPage(credential: string): string {
  return renderPublicPage(
    "Unsubscribe from CommonPlate alerts?",
    `      <p>You’ll stop receiving CommonPlate alert and digest emails.</p>
      <form method="post" action="${UNSUBSCRIBE_ROUTE_PATH}">
        <input type="hidden" name="${UNSUBSCRIBE_CREDENTIAL_PARAMETER}" value="${escapeHtml(credential)}" />
        <button type="submit">Unsubscribe</button>
      </form>`
  );
}

export const unsubscribeSecurityHeaders = publicPageSecurityHeaders;

/**
 * Mounted ahead of the limiter, credential verification, the signing-secret
 * read, the Subscriber lookup, and the mutation, so a paused request performs
 * no lifecycle work, touches no configuration secret, and consumes no throttle
 * capacity.
 */
export function pauseUnsubscribePage(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (!isPublicActionsPaused()) {
    next();
    return;
  }

  sendPublicPage(res, 503, PAUSED_PAGE);
}

export function createUnsubscribeRateLimiter() {
  return rateLimit({
    windowMs: UNSUBSCRIBE_RATE_LIMIT_WINDOW_MS,
    max: UNSUBSCRIBE_RATE_LIMIT_MAX,
    standardHeaders: true,
    legacyHeaders: false,
    handler: (_req, res) => sendPublicPage(res, 429, RATE_LIMITED_PAGE),
  });
}

/**
 * Its own bucket. Production registers this one persistent instance; tests
 * build their own through the factory so one suite's requests cannot fill
 * another's window.
 */
export const unsubscribeRateLimiter = createUnsubscribeRateLimiter();

/**
 * Route-local body parsing, mounted after the pause guard and the limiter and
 * registered ahead of the global parsers in `app.ts`, for the same reason the
 * confirmation route parses its own body: a global parser runs first, so a body
 * it rejected would be answered by the global JSON error handler — outside this
 * route's security headers, outside its HTML contract, and with a parser error
 * that can quote the body, and therefore the credential, logged.
 *
 * Only `application/x-www-form-urlencoded` is accepted, because that is the
 * only thing the accepted form submits.
 */
export const unsubscribeBodyParser = express.urlencoded({
  extended: true,
  limit: "100kb",
});

/**
 * Final error boundary: a rejected body is an unusable unsubscribe submission,
 * so it gets the existing invalid-link page rather than a new status or
 * message. Nothing is logged, because a parser error can carry the body.
 */
export function unsubscribeParserError(
  error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (res.headersSent) {
    next(error);
    return;
  }

  sendPublicPage(res, 400, INVALID_PAGE);
}

export interface UnsubscribePageDependencies {
  checkUnsubscribeCredential: (
    rawCredential: unknown
  ) => Promise<{ outcome: UnsubscribeCredentialCheck }>;
  unsubscribeSubscriber: (
    rawCredential: unknown,
    now: Date
  ) => Promise<UnsubscribeResult>;
}

const defaultDependencies: UnsubscribePageDependencies = {
  checkUnsubscribeCredential: (rawCredential) => checkCredential(rawCredential),
  unsubscribeSubscriber: (rawCredential, now) =>
    redeemUnsubscribeCredential(rawCredential, now),
};

/**
 * Renders the unsubscribe form for a usable link and nothing else. It performs
 * no mutation on any path, including a repeated open.
 */
export function createShowUnsubscribePageHandler(
  overrides: Partial<UnsubscribePageDependencies> = {}
) {
  const dependencies = { ...defaultDependencies, ...overrides };

  return async function showUnsubscribePage(
    req: Request,
    res: Response
  ): Promise<Response> {
    const credential = req.query?.[UNSUBSCRIBE_CREDENTIAL_PARAMETER];
    // A repeated or structured query parameter is not a credential. Answering
    // from shape here keeps a hostile query string away from the database and
    // guarantees the value echoed into the form is the string that verified.
    if (typeof credential !== "string") {
      return sendPublicPage(res, 400, INVALID_PAGE);
    }

    let result: { outcome: UnsubscribeCredentialCheck };
    try {
      result = await dependencies.checkUnsubscribeCredential(credential);
    } catch {
      // Fixed text only: the credential, the URL that carries it, and the
      // error itself are all credential-bearing.
      console.error("[unsubscribe] Unsubscribe link check failed");
      return sendPublicPage(res, 500, UNEXPECTED_ERROR_PAGE);
    }

    if (result.outcome !== "match") {
      return sendPublicPage(res, 400, INVALID_PAGE);
    }

    return sendPublicPage(res, 200, renderUnsubscribeFormPage(credential));
  };
}

export const showUnsubscribePage = createShowUnsubscribePageHandler();

export function createUnsubscribePageHandler(
  overrides: Partial<UnsubscribePageDependencies> = {}
) {
  const dependencies = { ...defaultDependencies, ...overrides };

  return async function unsubscribePage(
    req: Request,
    res: Response
  ): Promise<Response> {
    let result: UnsubscribeResult;
    try {
      // The primitive owns shape validation, so a missing body, a non-string
      // value, or an unparsed body is an invalid credential rather than a throw.
      result = await dependencies.unsubscribeSubscriber(
        req.body?.[UNSUBSCRIBE_CREDENTIAL_PARAMETER],
        new Date()
      );
    } catch {
      console.error("[unsubscribe] Unsubscribe redemption failed");
      return sendPublicPage(res, 500, UNEXPECTED_ERROR_PAGE);
    }

    switch (result.outcome) {
      case "unsubscribed":
        // One page for every prior status, so a valid link cannot be used to
        // learn whether the address was pending, confirmed, or already gone.
        return sendPublicPage(res, 200, UNSUBSCRIBED_PAGE);
      case "invalid":
        return sendPublicPage(res, 400, INVALID_PAGE);
      default:
        console.error("[unsubscribe] Unsubscribe redemption failed");
        return sendPublicPage(res, 500, UNEXPECTED_ERROR_PAGE);
    }
  };
}

export const unsubscribePage = createUnsubscribePageHandler();
