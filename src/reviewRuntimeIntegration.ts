import type { Express } from "express";
import type { Connection } from "mongoose";
import { assertReviewDatabase } from "../models/reviewDb.js";
import { assertMongoTransactionsSupported } from "./mongoTransactions.js";
import { ReviewAuthority } from "./reviewAuthority.js";
import {
  createReviewAuthorizationAdapter, type ReviewLifecycleBinding,
} from "./reviewAuthorizationAdapter.js";
import { registerReviewAuthRoutes } from "./reviewAuthRoutes.js";

export interface ReviewRuntimeDependencies {
  connection: Connection;
  validateProductionRuntime(): string | null;
  isRuntimeReady(): boolean;
  registerReviewBoundary(
    app: Express,
    adapter?: ReturnType<typeof createReviewAuthorizationAdapter>
  ): { isReady(): boolean };
}

// INF1 supplies its actual perimeter/configuration functions after serialized
// incorporation. No infrastructure module is copied or substituted here.
export function registerReviewRuntimeIntegration(
  app: Express,
  dependencies: ReviewRuntimeDependencies,
  binding?: ReviewLifecycleBinding
) {
  const reviewRuntime = process.env.NODE_ENV === "review";
  let authority: ReviewAuthority | undefined;
  let initialization: Promise<void> | undefined;

  const configurationReady = () => reviewRuntime &&
    process.env.NODE_ENV === "review" &&
    dependencies.validateProductionRuntime() === null;
  const authorityReady = () => configurationReady() &&
    dependencies.isRuntimeReady() && authority?.isReady() === true;
  const requireAuthority = () => {
    if (!authorityReady() || !authority) throw new Error("Review authority is unavailable");
    return authority;
  };
  const adapter = createReviewAuthorizationAdapter({
    isReady: authorityReady,
    authenticate: (token) => requireAuthority().authenticate(token),
  }, binding);

  // The closure is not evaluated until requests arrive, after the perimeter
  // is installed. Auth must precede INF1's lifecycle-only route allowlist.
  if (reviewRuntime) {
    registerReviewAuthRoutes(app, {
      isReady: authorityReady,
      login: (role, password) => requireAuthority().login(role, password),
      authenticate: (token) => requireAuthority().authenticate(token),
      logout: (token) => requireAuthority().logout(token),
    }, () => boundary.isReady());
  }
  const boundary = dependencies.registerReviewBoundary(app, reviewRuntime ? adapter : undefined);

  return {
    async initialize(): Promise<void> {
      if (!reviewRuntime) return;
      if (!initialization) {
        initialization = (async () => {
          if (!configurationReady()) throw new Error("Review runtime configuration is unsafe");
          assertReviewDatabase(dependencies.connection);
          await assertMongoTransactionsSupported(dependencies.connection);
          const candidate = new ReviewAuthority(dependencies.connection);
          await candidate.initialize();
          if (!configurationReady()) throw new Error("Review runtime configuration changed");
          authority = candidate;
        })();
      }
      await initialization;
    },
    isReady(): boolean {
      try {
        return dependencies.isRuntimeReady() &&
          (!reviewRuntime || adapter.isReady()) && boundary.isReady();
      } catch {
        console.error("[review] runtime integration readiness failed");
        return false;
      }
    },
    actorForRequest: adapter.actorForRequest,
  };
}
