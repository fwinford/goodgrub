import { posix as path } from "node:path";
import type { RequestHandler } from "express";

const LEGACY_WEB_PAGES = new Set([
  "/",
  "/home.html",
  "/request/new",
  "/new-request.html",
  "/fulfill.html",
]);

function isLegacyWebPage(pathname: string): boolean {
  if (/^\/request\/[^/]+\/fulfill\/?$/i.test(pathname)) return true;

  const rawNormalizedPath =
    path.normalize(pathname).toLowerCase().replace(/\/+$/, "") || "/";
  if (/^\/request\/[^/]+\/fulfill$/.test(rawNormalizedPath)) return true;

  let decodedPath: string;
  try {
    decodedPath = decodeURIComponent(pathname);
  } catch {
    return false;
  }
  const normalizedPath =
    path.normalize(decodedPath).toLowerCase().replace(/\/+$/, "") || "/";
  return (
    LEGACY_WEB_PAGES.has(normalizedPath) ||
    /^\/request\/[^/]+\/fulfill\/?$/.test(normalizedPath)
  );
}

export function createProductionLegacyWebPageGuard(
  environment: NodeJS.ProcessEnv = process.env
): RequestHandler {
  return (request, response, next) => {
    if (
      environment.NODE_ENV === "production" &&
      isLegacyWebPage(request.path)
    ) {
      response.sendStatus(404);
      return;
    }
    next();
  };
}
