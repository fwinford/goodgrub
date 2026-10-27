import type { Express, NextFunction, Request, Response } from "express";
import {
  publicPageSecurityHeaders,
  sendPublicPage,
} from "./publicPage.js";

export const GUIDELINES_ROUTE_PATH = "/guidelines";
export const SUPPORT_ROUTE_PATH = "/support";

export const GUIDELINES_PAGE_TITLE = "Community Guidelines — GoodGrub";
export const SUPPORT_PAGE_TITLE = "Support — GoodGrub";

const SUPPORT_EMAIL = "goodgrubsupport@gmail.com";
const SUPPORT_MAILTO = `<a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>`;

const INDEPENDENCE_NOTICE =
  "GoodGrub is an independent student-developed service and is not affiliated with or endorsed by NYU.";

/**
 * Static GoodGrub information pages. Separate from the emailed-link shell in
 * `publicPage.ts`, whose " — CommonPlate" title suffix and styles stay
 * untouched. Everything rendered here is fixed text: no request data reaches
 * the page, so there is nothing to escape.
 */
const PAGE_STYLES = `
      :root {
        color-scheme: light dark;
        --bg: #ffffff;
        --text: #2a2320;
        --muted: #6b5f58;
        --rule: #e6ddd7;
        --accent: #ad563d;
        --link: #ad563d;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #1b1715;
          --text: #ede6e1;
          --muted: #b8aba3;
          --rule: #3a312d;
          --link: #e8957c;
        }
      }
      * { box-sizing: border-box; }
      html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
      body {
        margin: 0;
        background: var(--bg);
        color: var(--text);
        font-family: system-ui, -apple-system, "Segoe UI", Helvetica, sans-serif;
        line-height: 1.6;
        overflow-wrap: anywhere;
      }
      .skip-link {
        position: absolute;
        left: 0.75rem;
        top: -4rem;
        padding: 0.6rem 1rem;
        background: var(--bg);
        color: var(--link);
        border: 2px solid var(--link);
        border-radius: 0.4rem;
        z-index: 1;
      }
      .skip-link:focus { top: 0.75rem; }
      header, main, footer {
        max-width: 40rem;
        margin: 0 auto;
        padding-left: 1.25rem;
        padding-right: 1.25rem;
      }
      header {
        padding-top: 1.5rem;
        padding-bottom: 1rem;
        border-bottom: 4px solid var(--accent);
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem 1.5rem;
        align-items: baseline;
        justify-content: space-between;
      }
      .brand { font-weight: 700; font-size: 1.25rem; letter-spacing: 0.01em; }
      nav ul { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 0.25rem 1.25rem; }
      main { padding-top: 1.75rem; padding-bottom: 1.5rem; }
      h1 { font-size: 1.75rem; line-height: 1.25; margin: 0 0 1rem; }
      h2 { font-size: 1.2rem; line-height: 1.3; margin: 2rem 0 0.5rem; }
      p { margin: 0 0 1rem; }
      ul { margin: 0 0 1rem; padding-left: 1.25rem; }
      li { margin-bottom: 0.6rem; }
      a { color: var(--link); text-underline-offset: 0.15em; }
      a:focus-visible {
        outline: 3px solid var(--link);
        outline-offset: 3px;
        border-radius: 2px;
      }
      footer { padding-top: 1rem; padding-bottom: 2.5rem; color: var(--muted); border-top: 1px solid var(--rule); }
      footer p { margin: 0; }
`;

function renderGoodGrubPage(
  title: string,
  current: "guidelines" | "support",
  mainHtml: string
): string {
  const link = (href: string, label: string, key: string): string =>
    key === current
      ? `<li><a href="${href}" aria-current="page">${label}</a></li>`
      : `<li><a href="${href}">${label}</a></li>`;

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${title}</title>
    <style>${PAGE_STYLES}    </style>
  </head>
  <body>
    <a class="skip-link" href="#main">Skip to main content</a>
    <header>
      <span class="brand">GoodGrub</span>
      <nav aria-label="GoodGrub information">
        <ul>
          ${link(GUIDELINES_ROUTE_PATH, "Community Guidelines", "guidelines")}
          ${link(SUPPORT_ROUTE_PATH, "Support", "support")}
        </ul>
      </nav>
    </header>
    <main id="main">
${mainHtml}
    </main>
  </body>
</html>
`;
}

export function renderGuidelinesPage(): string {
  return renderGoodGrubPage(
    GUIDELINES_PAGE_TITLE,
    "guidelines",
    `      <h1>GoodGrub Community Guidelines</h1>
      <p>GoodGrub helps NYU students share meals voluntarily. We're here to make helping each other easier, and we ask everyone to follow a few simple rules.</p>

      <h2>Keep meal sharing free</h2>
      <p>GoodGrub is not a marketplace. Never buy, sell, trade, or request payment, tips, or other compensation for meal swipes, Dining Dollars, or helping with a request.</p>

      <h2>Be respectful</h2>
      <p>Treat other students with kindness and respect. Harassment, discrimination, threats, bullying, and unwanted sexual content are not allowed. Respect others' boundaries.</p>

      <h2>Be honest</h2>
      <p>Make genuine requests, provide accurate order details, and never fake an order or proof of fulfillment. If your plans change, use the available withdrawal or stop-helping controls. Don't deliberately disrupt other students' requests.</p>

      <h2>Protect each other's privacy</h2>
      <p>Only use information obtained through GoodGrub to coordinate the relevant meal request. Don't misuse or share another student's personal information, messages, or contact details without permission. Never ask for someone else's NYU ID, password, or account access.</p>

      <h2>Use GoodGrub responsibly</h2>
      <p>No scams, spam, impersonation, or fraudulent activity. Follow applicable NYU Dining and Grubhub rules.</p>

      <h2>Need help?</h2>
      <p>Contact <strong>${SUPPORT_MAILTO}</strong> with questions, safety concerns, or suspected violations. GoodGrub may review concerns and restrict access when appropriate. A complaint alone does not establish wrongdoing.</p>

      <p>These rules apply to participation in GoodGrub, not unrelated personal interactions.</p>

      <p><em>${INDEPENDENCE_NOTICE}</em></p>`
  );
}

export function renderSupportPage(): string {
  return renderGoodGrubPage(
    SUPPORT_PAGE_TITLE,
    "support",
    `      <h1>GoodGrub Support</h1>
      <p>Need help with GoodGrub? We're here to help.</p>

      <p>Email us at <strong>${SUPPORT_MAILTO}</strong> for:</p>

      <ul>
        <li><strong>Requests and orders:</strong> Problems requesting, helping, or coordinating a meal.</li>
        <li><strong>Account help:</strong> NYU email verification, account access, or deletion.</li>
        <li><strong>Safety concerns:</strong> Harassment, inappropriate behavior, or suspected misuse.</li>
        <li><strong>Privacy questions:</strong> Questions or concerns about your personal information.</li>
        <li><strong>Technical issues:</strong> Bugs or features that aren't working as expected.</li>
      </ul>

      <p>When contacting us, describe what happened and include any details that could help us understand the issue. Please don't send passwords or verification codes.</p>

      <p><strong>Contact:</strong> ${SUPPORT_MAILTO}</p>

      <p>${INDEPENDENCE_NOTICE}</p>`
  );
}

export const PUBLIC_INFO_CACHE_CONTROL = "public, max-age=300";

/**
 * Runs after `publicPageSecurityHeaders` and replaces only its `no-store`;
 * the shared helper keeps `no-store` for the emailed-link pages.
 */
function publicInfoCacheControl(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  res.setHeader("Cache-Control", PUBLIC_INFO_CACHE_CONTROL);
  next();
}

const guidelinesHtml = renderGuidelinesPage();
const supportHtml = renderSupportPage();

function showGuidelines(_req: Request, res: Response): void {
  sendPublicPage(res, 200, guidelinesHtml);
}

function showSupport(_req: Request, res: Response): void {
  sendPublicPage(res, 200, supportHtml);
}

/**
 * Static, read-only pages: no database, no cookies, no pause or rate-limit
 * coupling. Headers are route-owned so they hold regardless of what is mounted
 * before or after this registration.
 */
export function registerPublicInfoRoutes(app: Express): void {
  app.get(
    GUIDELINES_ROUTE_PATH,
    publicPageSecurityHeaders,
    publicInfoCacheControl,
    showGuidelines
  );
  app.get(
    SUPPORT_ROUTE_PATH,
    publicPageSecurityHeaders,
    publicInfoCacheControl,
    showSupport
  );
}
