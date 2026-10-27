import type { Express, Request, RequestHandler } from "express";
import { sendDay4Error } from "./day4Errors.js";
import { isReviewRuntime } from "./externalProviders.js";
import { validateProductionRuntime } from "./productionRuntimeConfig.js";
import { isPublicActionsPaused, pausePublicAction } from "./publicActionsPause.js";

// Only server-side adapter completion can mark a request; never wire state.
const authorizedRequests = new WeakSet<Request>();
const REVIEW_ROUTES = [
  /^GET \/api\/(?:requests|stats|request-operation\/authority)$/,
  /^POST \/api\/(?:request|request-operation\/terminal)$/,
  /^GET \/api\/request\/[a-fA-F0-9]{24}(?:\/eligibility)?$/,
  /^POST \/api\/request\/[a-fA-F0-9]{24}\/(?:claim(?:\/extend|\/release)?|fulfill|edit|withdraw|block)$/,
  /^GET \/api\/participant\/(?:requests|active-reservation|request-eligibility|blocks)$/,
  /^GET \/api\/participant\/request\/[a-fA-F0-9]{24}$/,
  /^DELETE \/api\/participant\/blocks\/[a-fA-F0-9]{24}$/,
];

export interface ReviewAuthorizationAdapter {
  isReady(): boolean;
  authorize(req: Request): Promise<boolean>;
}

export function registerReviewBoundary(
  app: Express,
  adapter?: ReviewAuthorizationAdapter
): { isReady(): boolean } {
  const isReady = () => {
    if (!isReviewRuntime()) return true;
    try {
      return validateProductionRuntime() === null && adapter?.isReady() === true;
    } catch {
      console.error("[review] readiness adapter failed");
      return false;
    }
  };

  app.use(async (req, res, next) => {
    if (!isReviewRuntime()) return next();
    res.set("Cache-Control", "no-store");
    if (req.method === "GET" && /^\/health(?:\/live|\/ready)?$/.test(req.path)) {
      return next();
    }
    if (!isReady() || !adapter) {
      return sendDay4Error(res, 503, "REVIEW_UNAVAILABLE", "Review access is unavailable.");
    }
    // No student verification, subscription, push registration, AI or web UI.
    if (
      !REVIEW_ROUTES.some((route) => route.test(`${req.method} ${req.path}`))
    ) {
      return sendDay4Error(res, 403, "REVIEW_ROUTE_DISABLED", "This route is unavailable in review.");
    }
    try {
      if (!(await adapter.authorize(req))) {
        return sendDay4Error(res, 401, "REVIEW_UNAUTHORIZED", "Review sign-in is required.");
      }
    } catch {
      console.error("[review] authorization adapter failed");
      return sendDay4Error(res, 503, "REVIEW_UNAVAILABLE", "Review access is unavailable.");
    }
    authorizedRequests.add(req);
    next();
  });
  return { isReady };
}

export function isRequestActionPaused(req: Request): boolean {
  if (!isReviewRuntime()) return isPublicActionsPaused();
  return validateProductionRuntime() !== null || !authorizedRequests.has(req);
}

export function pauseRequestAction(message: string, errorCode?: string): RequestHandler {
  const productionPause = pausePublicAction(message, errorCode);
  return (req, res, next) => {
    if (!isReviewRuntime()) return productionPause(req, res, next);
    if (!isRequestActionPaused(req)) return next();
    sendDay4Error(res, 503, "REVIEW_UNAVAILABLE", "Review access is unavailable.");
  };
}
