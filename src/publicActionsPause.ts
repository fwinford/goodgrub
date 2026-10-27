import type { NextFunction, Request, Response } from "express";
import { isReviewRuntime } from "./externalProviders.js";

/**
 * Fail-closed deployment control for request creation, claims, subscriptions,
 * and notifications. Fulfillment remains independently authorized by a valid
 * active claim token.
 */
export const PUBLIC_ACTIONS_PAUSED_ENV = "PUBLIC_ACTIONS_PAUSED";

export const CREATE_UNAVAILABLE_MESSAGE =
  "Posting meal requests is temporarily unavailable";
export const SUBSCRIBE_UNAVAILABLE_MESSAGE =
  "Meal request alerts are temporarily unavailable";

/**
 * Only an explicit, recognized "off" value resumes public actions. A missing,
 * empty, or unrecognized value stays paused so a forgotten or mistyped
 * deployment variable cannot silently re-open posting on the live site.
 */
const EXPLICITLY_RESUMED = new Set(["false", "0"]);

export function isPublicActionsPaused(
  environment: NodeJS.ProcessEnv = process.env
): boolean {
  const configured = environment[PUBLIC_ACTIONS_PAUSED_ENV];
  if (configured === undefined) {
    return true;
  }
  return !EXPLICITLY_RESUMED.has(configured.trim().toLowerCase());
}

/**
 * Refuses a public mutation while paused. Mount this as the first handler on
 * the route — ahead of the rate limiter and the route handler — so no
 * validation, email, database write, or subscriber notification can run, and
 * so the response cannot reveal whether the payload would otherwise be valid.
 */
export function pausePublicAction(message: string, errorCode?: string) {
  return function refusePausedPublicAction(
    _req: Request,
    res: Response,
    next: NextFunction
  ): void {
    if (!isPublicActionsPaused()) {
      next();
      return;
    }

    res.status(503).json(
      errorCode
        ? { error: { code: errorCode, message } }
        : { error: message }
    );
  };
}

/**
 * Shared logging for background notification paths that are skipped while
 * paused. Callers must return before writing any delivery record, so a
 * suppressed notification is never recorded as sent.
 */
export function logPausedSkip(pathDescription: string): void {
  if (isReviewRuntime()) {
    console.log(`[review] skipped ${pathDescription}; providers and schedulers disabled`);
    return;
  }
  console.log(
    `[pause] skipped ${pathDescription} while ${PUBLIC_ACTIONS_PAUSED_ENV} is on`
  );
}
