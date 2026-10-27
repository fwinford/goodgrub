import express, {
  type Express, type NextFunction, type Request, type Response,
} from "express";
import rateLimit from "express-rate-limit";
import { sendDay4Error } from "./day4Errors.js";
import type { ReviewAuthority } from "./reviewAuthority.js";
import { readReviewSession } from "./reviewAuthorizationAdapter.js";

export function registerReviewAuthRoutes(
  app: Express,
  authority: Pick<ReviewAuthority, "isReady" | "login" | "authenticate" | "logout">,
  runtimeReady: () => boolean
): void {
  const router = express.Router();
  router.use((_req, res, next) => {
    res.set("Cache-Control", "no-store");
    if (process.env.NODE_ENV !== "review") {
      sendDay4Error(res, 404, "NOT_FOUND", "This route could not be found.");
      return;
    }
    try {
      if (!authority.isReady() || !runtimeReady()) {
        sendDay4Error(res, 503, "REVIEW_UNAVAILABLE", "Review access is unavailable.");
        return;
      }
    } catch {
      console.error("[review] authentication readiness failed");
      sendDay4Error(res, 503, "REVIEW_UNAVAILABLE", "Review access is unavailable.");
      return;
    }
    next();
  });
  router.post("/login", rateLimit({
    windowMs: 60_000, limit: 5, standardHeaders: true, legacyHeaders: false,
    handler: (_req, res) => {
      sendDay4Error(res, 429, "RATE_LIMITED", "Try review sign-in again later.");
    },
  }), express.json({ limit: "2kb" }), async (req, res) => {
    const body: unknown = req.body;
    if (!body || typeof body !== "object" || Array.isArray(body) ||
        Object.keys(body).sort().join(",") !== "password,role") {
      sendDay4Error(res, 401, "REVIEW_UNAUTHORIZED", "Review credentials are not valid.");
      return;
    }
    const { role, password } = body as Record<string, unknown>;
    try {
      const result = await authority.login(role, password);
      if (result.outcome === "limited") {
        sendDay4Error(res, 429, "RATE_LIMITED", "Try review sign-in again later.");
      } else if (result.outcome === "invalid") {
        sendDay4Error(res, 401, "REVIEW_UNAUTHORIZED", "Review credentials are not valid.");
      } else {
        res.json({ token: result.token, expiresAt: result.expiresAt.toISOString(),
          role: result.actor.role, generation: result.actor.generation });
      }
    } catch {
      console.error("[review] sign-in failed");
      sendDay4Error(res, 503, "REVIEW_UNAVAILABLE", "Review access is unavailable.");
    }
  });
  router.get("/session", async (req, res) => {
    try {
      const actor = await authority.authenticate(readReviewSession(req));
      if (!actor) {
        sendDay4Error(res, 401, "REVIEW_UNAUTHORIZED", "Review sign-in is required.");
        return;
      }
      res.json({ role: actor.role, generation: actor.generation });
    } catch {
      console.error("[review] session check failed");
      sendDay4Error(res, 503, "REVIEW_UNAVAILABLE", "Review access is unavailable.");
    }
  });
  router.post("/logout", async (req, res) => {
    try {
      await authority.logout(readReviewSession(req));
      res.json({ signedOut: true });
    } catch {
      console.error("[review] sign-out failed");
      sendDay4Error(res, 503, "REVIEW_UNAVAILABLE", "Review access is unavailable.");
    }
  });
  router.use((error: unknown, _req: Request, res: Response, next: NextFunction) => {
    if (error && typeof error === "object" && "type" in error &&
        (error.type === "entity.parse.failed" || error.type === "entity.too.large")) {
      sendDay4Error(res, 400, "INVALID_REVIEW_LOGIN", "Review sign-in could not be read.");
      return;
    }
    next(error);
  });
  app.use("/api/review", router);
}
