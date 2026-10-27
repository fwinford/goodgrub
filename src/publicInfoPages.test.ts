import express, { type Request, type Response } from "express";
import helmet from "helmet";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { PUBLIC_PAGE_CONTENT_SECURITY_POLICY } from "./publicPage.js";
import {
  GUIDELINES_PAGE_TITLE,
  SUPPORT_PAGE_TITLE,
  registerPublicInfoRoutes,
} from "./publicInfoPages.js";

/**
 * Faith-approved copy, pinned verbatim as ordered block texts (inline markup
 * removed). Do not edit without a new approval.
 */
const GUIDELINES_BLOCKS = [
  "H1:GoodGrub Community Guidelines",
  "P:GoodGrub helps NYU students share meals voluntarily. We're here to make helping each other easier, and we ask everyone to follow a few simple rules.",
  "H2:Keep meal sharing free",
  "P:GoodGrub is not a marketplace. Never buy, sell, trade, or request payment, tips, or other compensation for meal swipes, Dining Dollars, or helping with a request.",
  "H2:Be respectful",
  "P:Treat other students with kindness and respect. Harassment, discrimination, threats, bullying, and unwanted sexual content are not allowed. Respect others' boundaries.",
  "H2:Be honest",
  "P:Make genuine requests, provide accurate order details, and never fake an order or proof of fulfillment. If your plans change, use the available withdrawal or stop-helping controls. Don't deliberately disrupt other students' requests.",
  "H2:Protect each other's privacy",
  "P:Only use information obtained through GoodGrub to coordinate the relevant meal request. Don't misuse or share another student's personal information, messages, or contact details without permission. Never ask for someone else's NYU ID, password, or account access.",
  "H2:Use GoodGrub responsibly",
  "P:No scams, spam, impersonation, or fraudulent activity. Follow applicable NYU Dining and Grubhub rules.",
  "H2:Need help?",
  "P:Contact goodgrubsupport@gmail.com with questions, safety concerns, or suspected violations. GoodGrub may review concerns and restrict access when appropriate. A complaint alone does not establish wrongdoing.",
  "P:These rules apply to participation in GoodGrub, not unrelated personal interactions.",
  "P:GoodGrub is an independent student-developed service and is not affiliated with or endorsed by NYU.",
];

const SUPPORT_BLOCKS = [
  "H1:GoodGrub Support",
  "P:Need help with GoodGrub? We're here to help.",
  "P:Email us at goodgrubsupport@gmail.com for:",
  "LI:Requests and orders: Problems requesting, helping, or coordinating a meal.",
  "LI:Account help: NYU email verification, account access, or deletion.",
  "LI:Safety concerns: Harassment, inappropriate behavior, or suspected misuse.",
  "LI:Privacy questions: Questions or concerns about your personal information.",
  "LI:Technical issues: Bugs or features that aren't working as expected.",
  "P:When contacting us, describe what happened and include any details that could help us understand the issue. Please don't send passwords or verification codes.",
  "P:Contact: goodgrubsupport@gmail.com",
  "P:GoodGrub is an independent student-developed service and is not affiliated with or endorsed by NYU.",
];

function mainBlocks(html: string): string[] {
  const main = /<main[^>]*>([\s\S]*)<\/main>/.exec(html)![1];
  const blocks: string[] = [];
  const re = /<(h1|h2|p|li)>([\s\S]*?)<\/\1>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(main))) {
    const tag = m[1] === "li" ? "LI" : m[1] === "p" ? "P" : m[1].toUpperCase();
    blocks.push(`${tag}:${m[2].replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim()}`);
  }
  return blocks;
}

let baseUrl = "";
let server: ReturnType<typeof createServer>;

beforeAll(async () => {
  const app = express();
  app.use(helmet());
  registerPublicInfoRoutes(app);
  server = createServer(app);
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

afterAll(async () => {
  await new Promise<void>((r) => server.close(() => r()));
});

async function get(path: string, method = "GET") {
  const res = await fetch(`${baseUrl}${path}`, { method });
  return { res, html: await res.text() };
}

describe.each([
  ["/guidelines", GUIDELINES_PAGE_TITLE, GUIDELINES_BLOCKS],
  ["/support", SUPPORT_PAGE_TITLE, SUPPORT_BLOCKS],
])("GET %s", (path, title, blocks) => {
  it("serves HTML with the GoodGrub title and document structure", async () => {
    const { res, html } = await get(path);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(html).toContain(`<title>${title}</title>`);
    expect(html).toContain('<html lang="en">');
    expect(html).toContain(
      '<meta name="viewport" content="width=device-width, initial-scale=1" />'
    );
    expect(html.match(/<h1>/g)).toHaveLength(1);
    expect(html.match(/<main[ >]/g)).toHaveLength(1);
    expect(html).toContain('<a class="skip-link" href="#main">');
    expect(html).toContain('<main id="main">');
    expect(html).toContain("a:focus-visible");
    expect(html).toContain("#ad563d");
    expect(html).toContain("prefers-color-scheme: dark");
  });

  it("preserves the approved wording and order exactly", async () => {
    const { html } = await get(path);
    expect(mainBlocks(html)).toEqual(blocks);
  });

  it("sends strict route-owned security headers and the approved cache policy", async () => {
    const { res } = await get(path);
    expect(res.headers.get("content-security-policy")).toBe(
      PUBLIC_PAGE_CONTENT_SECURITY_POLICY
    );
    expect(res.headers.get("content-security-policy")).toContain(
      "script-src 'none'"
    );
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("x-frame-options")).toBe("DENY");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
    expect(res.headers.get("cache-control")).toBe("public, max-age=300");
    expect(res.headers.get("set-cookie")).toBeNull();
  });

  it("has no script, handler, form, external resource, or privacy link", async () => {
    const { html } = await get(path);
    expect(html).not.toMatch(/<script|<form|<iframe|<img|<link\b/i);
    expect(html).not.toMatch(/\son[a-z]+=/i);
    expect(html).not.toMatch(/https?:\/\//i);
    expect(html).not.toMatch(/href="[^"]*privacy/i);
    const hrefs = [...html.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
    for (const href of hrefs) {
      expect([
        "#main",
        "/guidelines",
        "/support",
        "mailto:goodgrubsupport@gmail.com",
      ]).toContain(href);
    }
  });

  it("links to the sibling page and marks the current one", async () => {
    const { html } = await get(path);
    expect(html).toContain('href="/guidelines"');
    expect(html).toContain('href="/support"');
    expect(html.match(/aria-current="page"/g)).toHaveLength(1);
  });

  it("opens mail via the exact mailto address", async () => {
    const { html } = await get(path);
    expect(html).toContain(
      '<a href="mailto:goodgrubsupport@gmail.com">goodgrubsupport@gmail.com</a>'
    );
  });

  it("makes no unapproved response-time or enforcement promise", async () => {
    const { html } = await get(path);
    expect(html).not.toMatch(/within \d|hours|business days|24|48|banned|permanently|automatic/i);
  });

  it("is read-only", async () => {
    const { res } = await get(path, "POST");
    expect(res.status).toBe(404);
  });
});

describe("shared shell and wiring", () => {
  it("keeps no-store in the shared helper used by emailed-link pages", async () => {
    const { publicPageSecurityHeaders } = await import("./publicPage.js");
    const headers: Record<string, string> = {};
    publicPageSecurityHeaders(
      {} as Request,
      { setHeader: (k: string, v: string) => (headers[k] = v) } as unknown as Response,
      () => undefined
    );
    expect(headers["Cache-Control"]).toBe("no-store");
  });

  it("leaves the emailed-link shell titled CommonPlate", () => {
    const src = readFileSync("src/publicPage.ts", "utf8");
    expect(src).toContain('const PAGE_TITLE_SUFFIX = " — CommonPlate";');
  });

  it("registers the routes in app.ts with one import and one call", () => {
    const src = readFileSync("app.ts", "utf8");
    expect(src.match(/registerPublicInfoRoutes/g)).toHaveLength(2);
    expect(src).not.toMatch(/["']\/privacy["']/);
  });
});
