import type { NextFunction, Request, Response } from "express";

/**
 * The one page shell behind every emailed-link surface: the confirmation flow
 * and the unsubscribe flow.
 *
 * These pages are read by a person who opened a link in an inbox, so they are
 * HTML — including refusals, where the JSON error envelope would render as
 * noise in a browser window. They carry no script, no external resource, and no
 * subscriber detail, so one shell can serve every one of them and a copy or
 * header change cannot land on one flow and miss the other.
 */
export const PUBLIC_PAGE_CONTENT_SECURITY_POLICY = [
  "default-src 'none'",
  "script-src 'none'",
  "style-src 'self' 'unsafe-inline'",
  "form-action 'self'",
  "base-uri 'none'",
  "frame-ancestors 'none'",
].join("; ");

const PAGE_STYLES = `
      :root { color-scheme: light dark; }
      body {
        margin: 0;
        padding: 2.5rem 1.25rem;
        font-family: system-ui, -apple-system, "Segoe UI", Helvetica, sans-serif;
        line-height: 1.55;
      }
      main { max-width: 34rem; margin: 0 auto; }
      h1 { font-size: 1.5rem; line-height: 1.25; margin: 0 0 0.75rem; }
      p { margin: 0 0 1.5rem; }
      button {
        font: inherit;
        padding: 0.7rem 1.4rem;
        border: 1px solid currentColor;
        border-radius: 0.4rem;
        background: transparent;
        color: inherit;
        cursor: pointer;
      }
      button:focus-visible,
      a:focus-visible {
        outline: 3px solid currentColor;
        outline-offset: 3px;
      }
`;

/**
 * Titles carry the product name so a page opened from an inbox is identifiable
 * in a tab, in history, and in a screen reader's window list; the visible
 * heading stays unbranded.
 */
const PAGE_TITLE_SUFFIX = " — CommonPlate";

/**
 * Callers pass fixed strings and values they have already escaped. Nothing here
 * escapes on a caller's behalf, because a page that needs escaping needs it at
 * the point the dynamic value is known.
 */
export function renderPublicPage(heading: string, bodyHtml = ""): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${heading}${PAGE_TITLE_SUFFIX}</title>
    <style>${PAGE_STYLES}    </style>
  </head>
  <body>
    <main>
      <h1>${heading}</h1>
${bodyHtml}
    </main>
  </body>
</html>
`;
}

export function sendPublicPage(
  res: Response,
  status: number,
  html: string
): Response {
  return res
    .status(status)
    .set("Content-Type", "text/html; charset=utf-8")
    .send(html);
}

/**
 * Route-owned headers for every emailed-link response, including the pause,
 * invalid, rate-limit, and error pages. Mount this first on a route so a
 * refusal produced by a later middleware still carries them.
 */
export function publicPageSecurityHeaders(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Content-Security-Policy", PUBLIC_PAGE_CONTENT_SECURITY_POLICY);
  next();
}
