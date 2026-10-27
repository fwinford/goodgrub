import express, { type Express, type RequestHandler } from "express";
import helmet from "helmet";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
vi.mock("./requestAlertEmailDelivery.js", () => ({
  isRequestAlertEmailDeliveryActive: () => true,
  REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE: "Email Request Alerts are not available.",
}));

/**
 * Spies wrap the real shape check, the real digest, and the real escape helper
 * rather than replacing them, so the assertions below prove *whether* the route
 * reached each step without changing what any step does.
 *
 * `models/db.js` is replaced outright: every Subscriber method is a bare spy,
 * so a route path that reaches Mongo fails loudly instead of silently querying.
 */
const { validateSpy, digestSpy, escapeSpy, subscriberSpies } = vi.hoisted(
  () => ({
    validateSpy: vi.fn(),
    digestSpy: vi.fn(),
    escapeSpy: vi.fn(),
    subscriberSpies: {
      findOneAndUpdate: vi.fn(),
      findOne: vi.fn(),
      exists: vi.fn(),
      create: vi.fn(),
      updateOne: vi.fn(),
      deleteOne: vi.fn(),
      countDocuments: vi.fn(),
    },
  })
);

vi.mock("./subscriptionTokens.js", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./subscriptionTokens.js")>();
  return {
    ...actual,
    isValidRawSubscriptionToken: (value: unknown) => {
      validateSpy(value);
      return actual.isValidRawSubscriptionToken(value);
    },
    digestSubscriptionToken: (rawToken: string) => {
      digestSpy(rawToken);
      return actual.digestSubscriptionToken(rawToken);
    },
  };
});

vi.mock("./htmlEscape.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./htmlEscape.js")>();
  return {
    ...actual,
    escapeHtml: (value: unknown) => {
      escapeSpy(value);
      return actual.escapeHtml(value);
    },
  };
});

vi.mock("../models/db.js", () => ({ Subscriber: subscriberSpies }));

import type { NextFunction, Request, Response } from "express";
import { confirmSubscription } from "./confirmSubscription.js";
import type { ConfirmationResult } from "./confirmSubscription.js";
import {
  CONFIRMATION_CONTENT_SECURITY_POLICY,
  CONFIRMATION_RATE_LIMIT_MAX,
  CONFIRMATION_RATE_LIMIT_WINDOW_MS,
  CONFIRMATION_ROUTE_PATH,
  confirmationBodyParser,
  confirmationParserError,
  confirmationRateLimiter,
  confirmationSecurityHeaders,
  createConfirmSubscriptionPageHandler,
  createConfirmationRateLimiter,
  pauseConfirmationPage,
  showConfirmationPage,
} from "./confirmSubscriptionRoute.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { SUBSCRIPTION_TOKEN_BYTES } from "./subscriptionTokens.js";

type ConfirmFn = (
  rawToken: unknown,
  now: Date
) => Promise<ConfirmationResult>;

const VALID_TOKEN = Buffer.alloc(SUBSCRIPTION_TOKEN_BYTES, 7).toString(
  "base64url"
);
const OTHER_VALID_TOKEN = Buffer.alloc(SUBSCRIPTION_TOKEN_BYTES, 9).toString(
  "base64url"
);
/**
 * Internal detail the primitive hands back on a win. The route may act on the
 * outcome and nothing else, so this identifier must never reach a page, a
 * header, or a log line.
 */
const PRIVATE_SUBSCRIBER_ID = "64b000000000000000000abc";

const globalErrorHandler = vi.fn();

function resumePublicActions(): void {
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
}

function pausePublicActions(): void {
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
}

interface TestAppOptions {
  confirmSubscription?: ConfirmFn;
  limiter?: RequestHandler;
  withHelmet?: boolean;
}

/**
 * The same global middleware `app.ts` installs, in the same order and with the
 * confirmation POST registered ahead of the global parsers, so these
 * assertions exercise the production body-parsing and header behavior rather
 * than a simplified stand-in. The global JSON error handler is mounted too: if
 * the route ever called `next(error)`, or a global parser ever answered for it,
 * the JSON envelope would surface here.
 *
 * Every app gets its own limiter unless one is supplied, so requests made by
 * one test cannot fill another test's window.
 */
function buildTestApp(options: TestAppOptions = {}): Express {
  const app = express();
  if (options.withHelmet) app.use(helmet());

  app.post(
    CONFIRMATION_ROUTE_PATH,
    confirmationSecurityHeaders,
    pauseConfirmationPage,
    options.limiter ?? createConfirmationRateLimiter(),
    confirmationBodyParser,
    createConfirmSubscriptionPageHandler(
      options.confirmSubscription
        ? { confirmSubscription: options.confirmSubscription }
        : {}
    ),
    confirmationParserError
  );

  app.use(express.json({ limit: "100kb" }));
  app.use(express.urlencoded({ extended: true, limit: "100kb" }));

  app.get(
    CONFIRMATION_ROUTE_PATH,
    confirmationSecurityHeaders,
    pauseConfirmationPage,
    showConfirmationPage
  );

  // Stands in for the JSON API routes that keep using the global parsers.
  app.post("/api/echo", (req: Request, res: Response) => {
    res.json({ body: req.body ?? null });
  });

  app.use((err: Error, _req: Request, res: Response, _next: () => void) => {
    globalErrorHandler(err);
    res.status(500).json({ error: "Internal server error" });
  });

  return app;
}

async function postRaw(
  baseUrl: string,
  init: RequestInit,
  path: string = CONFIRMATION_ROUTE_PATH
): Promise<{ status: number; html: string; response: globalThis.Response }> {
  const response = await fetch(`${baseUrl}${path}`, {
    method: "POST",
    ...init,
  });
  return { status: response.status, html: await response.text(), response };
}

async function withServer(
  app: Express,
  run: (baseUrl: string) => Promise<void>
): Promise<void> {
  const server = createServer(app);
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });

  try {
    const { port } = server.address() as AddressInfo;
    await run(`http://127.0.0.1:${port}`);
  } finally {
    if (server.listening) {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    }
  }
}

async function getConfirmationPage(
  baseUrl: string,
  query = ""
): Promise<{ status: number; html: string; response: globalThis.Response }> {
  const response = await fetch(
    `${baseUrl}${CONFIRMATION_ROUTE_PATH}${query}`
  );
  return { status: response.status, html: await response.text(), response };
}

async function postConfirmation(
  baseUrl: string,
  token?: string
): Promise<{ status: number; html: string; response: globalThis.Response }> {
  const response = await fetch(`${baseUrl}${CONFIRMATION_ROUTE_PATH}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(token === undefined ? {} : { token }).toString(),
  });
  return { status: response.status, html: await response.text(), response };
}

function expectConfirmationHeaders(response: globalThis.Response): void {
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(response.headers.get("referrer-policy")).toBe("no-referrer");
  expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  expect(response.headers.get("x-frame-options")).toBe("DENY");
  expect(response.headers.get("content-type")).toBe(
    "text/html; charset=utf-8"
  );

  const csp = response.headers.get("content-security-policy") ?? "";
  expect(csp).toContain("default-src 'none'");
  expect(csp).toContain("script-src 'none'");
  expect(csp).toContain("style-src 'self' 'unsafe-inline'");
  expect(csp).toContain("form-action 'self'");
  expect(csp).toContain("base-uri 'none'");
  expect(csp).toContain("frame-ancestors 'none'");
}

function expectNoMongoWork(): void {
  for (const spy of Object.values(subscriberSpies)) {
    expect(spy).not.toHaveBeenCalled();
  }
}

function responseDouble() {
  const headers: Record<string, string> = {};
  const state: { status: number; body: string } = { status: 200, body: "" };
  const res = {
    status: vi.fn((value: number) => {
      state.status = value;
      return res;
    }),
    set: vi.fn((key: string, value: string) => {
      headers[key] = value;
      return res;
    }),
    setHeader: vi.fn((key: string, value: string) => {
      headers[key] = value;
    }),
    send: vi.fn((body: string) => {
      state.body = body;
      return res;
    }),
  } as unknown as Response;

  return { res, headers, state };
}

beforeEach(() => {
  vi.clearAllMocks();
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("GET /api/subscribe/confirm", () => {
  it("returns an HTML 503 page while public actions are paused", async () => {
    pausePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { status, html, response } = await getConfirmationPage(
        baseUrl,
        `?token=${VALID_TOKEN}`
      );

      expect(status).toBe(503);
      expect(html).toContain(
        "<h1>Email confirmation is temporarily unavailable.</h1>"
      );
      expect(html).toContain("Please open this link again later.");
      expectConfirmationHeaders(response);
    });
  });

  it("renders no confirmation form while paused", async () => {
    pausePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { html } = await getConfirmationPage(
        baseUrl,
        `?token=${VALID_TOKEN}`
      );

      expect(html).not.toContain("<form");
      expect(html).not.toContain("Confirm alerts");
      expect(html).not.toContain(VALID_TOKEN);
    });
  });

  it("performs no shape validation, hashing, or Subscriber work while paused", async () => {
    pausePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      await getConfirmationPage(baseUrl, `?token=${VALID_TOKEN}`);

      expect(validateSpy).not.toHaveBeenCalled();
      expect(digestSpy).not.toHaveBeenCalled();
      expectNoMongoWork();
    });
  });

  it("returns 400 for a missing token", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { status, html, response } = await getConfirmationPage(baseUrl);

      expect(status).toBe(400);
      expect(html).toContain("This confirmation link is invalid.");
      expect(html).not.toContain("<form");
      expectConfirmationHeaders(response);
    });
  });

  it("returns 400 for malformed token strings", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      for (const malformed of [
        "short",
        "a".repeat(42),
        "a".repeat(44),
        `${"a".repeat(42)}*`,
        `${"a".repeat(42)}=`,
      ]) {
        const { status, html } = await getConfirmationPage(
          baseUrl,
          `?token=${encodeURIComponent(malformed)}`
        );

        expect(status).toBe(400);
        expect(html).toContain("This confirmation link is invalid.");
      }

      expect(digestSpy).not.toHaveBeenCalled();
      expectNoMongoWork();
    });
  });

  it("returns 400 for repeated token parameters", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { status, html } = await getConfirmationPage(
        baseUrl,
        `?token=${VALID_TOKEN}&token=${OTHER_VALID_TOKEN}`
      );

      expect(status).toBe(400);
      expect(html).toContain("This confirmation link is invalid.");
      expect(html).not.toContain(VALID_TOKEN);
    });
  });

  it("returns 400 for array and object token values", () => {
    for (const token of [
      [VALID_TOKEN],
      [VALID_TOKEN, OTHER_VALID_TOKEN],
      { token: VALID_TOKEN },
      { toString: () => VALID_TOKEN },
    ]) {
      const { res, state } = responseDouble();
      showConfirmationPage({ query: { token } } as unknown as Request, res);

      expect(state.status).toBe(400);
      expect(state.body).toContain("This confirmation link is invalid.");
      expect(state.body).not.toContain("<form");
    }

    expect(digestSpy).not.toHaveBeenCalled();
    expectNoMongoWork();
  });

  it("renders the confirmation form for a well-formed token", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { status, html, response } = await getConfirmationPage(
        baseUrl,
        `?token=${VALID_TOKEN}`
      );

      expect(status).toBe(200);
      expect(html).toContain("<!doctype html>");
      expect(html).toContain('<html lang="en">');
      expect(html).toContain('<meta charset="utf-8" />');
      expect(html).toContain('name="viewport"');
      expect(html).toContain("<h1>Confirm email alerts</h1>");
      expect(html).toContain(
        "Opening this link does not confirm alerts. Select “Confirm alerts” to receive CommonPlate alerts about new food requests."
      );
      expect(html).toContain("Confirm alerts</button>");
      expectConfirmationHeaders(response);
    });
  });

  it("uses a no-JavaScript POST form carrying one hidden token input", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { html } = await getConfirmationPage(
        baseUrl,
        `?token=${VALID_TOKEN}`
      );

      expect(html).toMatch(/<form[^>]*method="post"/i);
      expect(html).toMatch(
        /<form[^>]*action="\/api\/subscribe\/confirm"/i
      );
      expect(html).toContain(
        `<input type="hidden" name="token" value="${VALID_TOKEN}" />`
      );
      expect(html.match(/<input/g)).toHaveLength(1);
      expect(html).not.toContain("<script");
      expect(html).not.toContain("onclick");
    });
  });

  it("escapes the hidden token value with the shared escape utility", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { html } = await getConfirmationPage(
        baseUrl,
        `?token=${VALID_TOKEN}`
      );

      expect(escapeSpy).toHaveBeenCalledWith(VALID_TOKEN);
      expect(html).toContain(`value="${VALID_TOKEN}"`);
    });
  });

  it("never hashes the token or reads a Subscriber", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      await getConfirmationPage(baseUrl, `?token=${VALID_TOKEN}`);

      expect(validateSpy).toHaveBeenCalledWith(VALID_TOKEN);
      expect(digestSpy).not.toHaveBeenCalled();
      expectNoMongoWork();
    });
  });
});

describe("POST /api/subscribe/confirm outcome mapping", () => {
  const cases: Array<{
    outcome: ConfirmationResult;
    status: number;
    heading: string;
    copy?: string;
  }> = [
    {
      outcome: {
        outcome: "confirmed",
        subscriberId: PRIVATE_SUBSCRIBER_ID,
      },
      status: 200,
      heading: "Email alerts confirmed.",
      copy: "You can now receive CommonPlate alerts about new food requests. No further action is needed.",
    },
    {
      outcome: { outcome: "alreadyConfirmed", subscriberId: "abc" },
      status: 200,
      heading: "Your email is already confirmed.",
      copy: "You can receive CommonPlate alerts about new food requests. No further action is needed.",
    },
    {
      outcome: { outcome: "expired" },
      status: 410,
      heading: "This confirmation link has expired.",
      copy: '<a href="/">Return to CommonPlate</a> to sign up again and receive a new link.',
    },
    {
      outcome: { outcome: "invalid" },
      status: 400,
      heading: "This confirmation link is invalid.",
      copy: '<a href="/">Return to CommonPlate</a> to sign up again and receive a new link.',
    },
  ];

  for (const testCase of cases) {
    it(`maps ${testCase.outcome.outcome} to ${testCase.status}`, async () => {
      resumePublicActions();
      const primitive = vi.fn<ConfirmFn>(async () => testCase.outcome);

      await withServer(
        buildTestApp({ confirmSubscription: primitive }),
        async (baseUrl) => {
          const { status, html, response } = await postConfirmation(
            baseUrl,
            VALID_TOKEN
          );

          expect(status).toBe(testCase.status);
          expect(html).toContain(`<h1>${testCase.heading}</h1>`);
          if (testCase.copy) expect(html).toContain(testCase.copy);
          expectConfirmationHeaders(response);
          expect(primitive).toHaveBeenCalledOnce();
          expect(primitive.mock.calls[0][0]).toBe(VALID_TOKEN);
          expect(primitive.mock.calls[0][1]).toBeInstanceOf(Date);
          expect(globalErrorHandler).not.toHaveBeenCalled();
        }
      );
    });
  }

  it("never renders internal subscriber detail from a winning confirmation", async () => {
    resumePublicActions();
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
    const primitive = vi.fn<ConfirmFn>(async () => ({
      outcome: "confirmed",
      subscriberId: PRIVATE_SUBSCRIBER_ID,
    }));

    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        const { html, response } = await postConfirmation(
          baseUrl,
          VALID_TOKEN
        );

        expect(html).not.toContain(PRIVATE_SUBSCRIBER_ID);
        expect(response.headers.get("set-cookie")).toBeNull();
        expect(response.headers.get("location")).toBeNull();
        for (const call of [
          ...consoleError.mock.calls,
          ...consoleLog.mock.calls,
        ]) {
          expect(JSON.stringify(call)).not.toContain(PRIVATE_SUBSCRIBER_ID);
        }
      }
    );
  });

  it("answers a rejecting primitive with a generic 500 page and no delegation", async () => {
    resumePublicActions();
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const primitive = vi.fn<ConfirmFn>(async () => {
      throw new Error(`boom ${VALID_TOKEN}`);
    });

    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        const { status, html, response } = await postConfirmation(
          baseUrl,
          VALID_TOKEN
        );

        expect(status).toBe(500);
        expect(html).toContain(
          "<h1>Email confirmation is temporarily unavailable.</h1>"
        );
        expect(html).toContain("Please open this link again later.");
        expect(html).not.toContain("boom");
        expectConfirmationHeaders(response);
        expect(globalErrorHandler).not.toHaveBeenCalled();
        expect(consoleError.mock.calls).toEqual([
          ["[confirm] Confirmation redemption failed"],
        ]);
      }
    );
  });

  it("treats an unparsed body as an invalid token instead of throwing", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const response = await fetch(`${baseUrl}${CONFIRMATION_ROUTE_PATH}`, {
        method: "POST",
      });
      const html = await response.text();

      expect(response.status).toBe(400);
      expect(html).toContain("This confirmation link is invalid.");
      expect(globalErrorHandler).not.toHaveBeenCalled();
      expect(digestSpy).not.toHaveBeenCalled();
      expectNoMongoWork();
    });
  });

  it("treats non-string body tokens as invalid without reaching Mongo", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      for (const body of [
        JSON.stringify({ token: { nested: VALID_TOKEN } }),
        JSON.stringify({ token: [VALID_TOKEN] }),
        JSON.stringify({ token: 42 }),
        JSON.stringify({}),
      ]) {
        const response = await fetch(`${baseUrl}${CONFIRMATION_ROUTE_PATH}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body,
        });
        const html = await response.text();

        expect(response.status).toBe(400);
        expect(html).toContain("This confirmation link is invalid.");
      }

      expect(globalErrorHandler).not.toHaveBeenCalled();
      expect(digestSpy).not.toHaveBeenCalled();
      expectNoMongoWork();
    });
  });

  it("forwards the exact raw token to the primitive", async () => {
    resumePublicActions();
    const primitive = vi.fn<ConfirmFn>(async () => ({ outcome: "confirmed" }));

    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        await postConfirmation(baseUrl, VALID_TOKEN);

        expect(primitive).toHaveBeenCalledOnce();
        expect(primitive.mock.calls[0][0]).toBe(VALID_TOKEN);
      }
    );
  });
});

describe("confirmation body parsing stays inside the route", () => {
  const MALFORMED_JSON = `{"token": "${VALID_TOKEN}"`;
  const jsonInit = (body: string): RequestInit => ({
    headers: { "Content-Type": "application/json" },
    body,
  });
  const formInit = (body: string, charset = ""): RequestInit => ({
    headers: {
      "Content-Type": `application/x-www-form-urlencoded${charset}`,
    },
    body,
  });

  function spyConsole() {
    return {
      error: vi.spyOn(console, "error").mockImplementation(() => {}),
      log: vi.spyOn(console, "log").mockImplementation(() => {}),
      warn: vi.spyOn(console, "warn").mockImplementation(() => {}),
    };
  }

  function loggedText(spies: ReturnType<typeof spyConsole>): string {
    return JSON.stringify([
      ...spies.error.mock.calls,
      ...spies.log.mock.calls,
      ...spies.warn.mock.calls,
    ]);
  }

  it("refuses a paused malformed-JSON POST in HTML before the limiter or any parsing", async () => {
    pausePublicActions();
    const spies = spyConsole();
    const limiter = vi.fn<RequestHandler>((_req, _res, next) => next());
    const primitive = vi.fn<ConfirmFn>(async () => ({ outcome: "confirmed" }));

    await withServer(
      buildTestApp({ limiter, confirmSubscription: primitive }),
      async (baseUrl) => {
        const { status, html, response } = await postRaw(
          baseUrl,
          jsonInit(MALFORMED_JSON)
        );

        expect(status).toBe(503);
        expect(html).toContain(
          "<h1>Email confirmation is temporarily unavailable.</h1>"
        );
        expect(html).toContain("Please open this link again later.");
        expectConfirmationHeaders(response);
        expect(limiter).not.toHaveBeenCalled();
        expect(primitive).not.toHaveBeenCalled();
        expect(globalErrorHandler).not.toHaveBeenCalled();

        const logged = loggedText(spies);
        expect(logged).not.toContain(VALID_TOKEN);
        expect(logged).not.toContain(CONFIRMATION_ROUTE_PATH);
        expect(logged).not.toContain("JSON");
        expect(logged).not.toContain("token");
      }
    );
  });

  it("answers an unpaused malformed-JSON POST with the invalid-link page", async () => {
    resumePublicActions();
    const spies = spyConsole();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { status, html, response } = await postRaw(
        baseUrl,
        jsonInit(MALFORMED_JSON)
      );

      expect(status).toBe(400);
      expect(html).toContain("<h1>This confirmation link is invalid.</h1>");
      expectConfirmationHeaders(response);
      expect(globalErrorHandler).not.toHaveBeenCalled();
      expect(html).not.toContain("JSON");
      expect(html).not.toContain("Unexpected");

      const logged = loggedText(spies);
      expect(logged).not.toContain(VALID_TOKEN);
      expect(logged).not.toContain("JSON");
    });
  });

  it("leaves a well-formed JSON body unparsed, so no usable token reaches the primitive", async () => {
    resumePublicActions();
    const primitive = vi.fn<ConfirmFn>(async () => ({ outcome: "invalid" }));

    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        const { status, html } = await postRaw(
          baseUrl,
          jsonInit(JSON.stringify({ token: VALID_TOKEN }))
        );

        expect(status).toBe(400);
        expect(html).toContain("<h1>This confirmation link is invalid.</h1>");
        expect(primitive).toHaveBeenCalledOnce();
        expect(primitive.mock.calls[0][0]).toBeUndefined();
        expect(globalErrorHandler).not.toHaveBeenCalled();
      }
    );
  });

  it("answers rejected URL-encoded bodies with the invalid-link page and no parser detail", async () => {
    resumePublicActions();
    const spies = spyConsole();
    const primitive = vi.fn<ConfirmFn>(async () => ({ outcome: "confirmed" }));

    const rejected: RequestInit[] = [
      // Over the 100kb route-local limit.
      formInit(`token=${"a".repeat(200_000)}`),
      // Charset the parser cannot decode.
      formInit(`token=${VALID_TOKEN}`, "; charset=utf-7"),
      // Declares an encoding the body does not use.
      {
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Content-Encoding": "gzip",
        },
        body: `token=${VALID_TOKEN}`,
      },
    ];

    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        for (const init of rejected) {
          const { status, html, response } = await postRaw(baseUrl, init);

          expect(status).toBe(400);
          expect(html).toContain("<h1>This confirmation link is invalid.</h1>");
          expectConfirmationHeaders(response);
          // The static page legitimately declares `charset=utf-8`, so this
          // looks for parser vocabulary rather than the word alone.
          expect(html).not.toMatch(
            /entity\.|too large|unsupported charset|unsupported content encoding/i
          );
        }

        expect(primitive).not.toHaveBeenCalled();
        expect(globalErrorHandler).not.toHaveBeenCalled();

        const logged = loggedText(spies);
        expect(logged).not.toContain(VALID_TOKEN);
        expect(logged).not.toMatch(
          /entity\.|too large|unsupported charset|unsupported content encoding/i
        );
      }
    );
  });

  it("still delivers a valid form submission to the primitive", async () => {
    resumePublicActions();
    const primitive = vi.fn<ConfirmFn>(async () => ({
      outcome: "confirmed",
      subscriberId: PRIVATE_SUBSCRIBER_ID,
    }));

    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        const { status, html } = await postConfirmation(baseUrl, VALID_TOKEN);

        expect(status).toBe(200);
        expect(html).toContain("<h1>Email alerts confirmed.</h1>");
        expect(primitive).toHaveBeenCalledOnce();
        expect(primitive.mock.calls[0][0]).toBe(VALID_TOKEN);
      }
    );
  });

  it("leaves the global parsers owning every other route", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const parsed = await postRaw(
        baseUrl,
        jsonInit(JSON.stringify({ hello: "world" })),
        "/api/echo"
      );

      expect(parsed.status).toBe(200);
      expect(JSON.parse(parsed.html)).toEqual({ body: { hello: "world" } });
      expect(globalErrorHandler).not.toHaveBeenCalled();

      // Unchanged global behavior elsewhere: a malformed JSON body is still the
      // global handler's to answer, in JSON.
      const rejected = await postRaw(
        baseUrl,
        jsonInit(MALFORMED_JSON),
        "/api/echo"
      );

      expect(rejected.status).toBe(500);
      expect(JSON.parse(rejected.html)).toEqual({
        error: "Internal server error",
      });
      expect(globalErrorHandler).toHaveBeenCalledOnce();
    });
  });

  it("delegates only when a response has already been sent", () => {
    const next = vi.fn();
    const { res, state } = responseDouble();

    confirmationParserError(
      new Error("boom"),
      {} as Request,
      res,
      next as unknown as NextFunction
    );
    expect(state.status).toBe(400);
    expect(state.body).toContain("This confirmation link is invalid.");
    expect(next).not.toHaveBeenCalled();

    const sent = responseDouble();
    (sent.res as unknown as { headersSent: boolean }).headersSent = true;
    const error = new Error("boom");
    confirmationParserError(
      error,
      {} as Request,
      sent.res,
      next as unknown as NextFunction
    );
    expect(next).toHaveBeenCalledWith(error);
  });

  it("exposes a URL-encoded-only route-local parser", () => {
    expect(typeof confirmationBodyParser).toBe("function");
  });
});

describe("confirmation rate limiting", () => {
  it("matches the window and threshold of the existing public mutation limiter", () => {
    expect(CONFIRMATION_RATE_LIMIT_WINDOW_MS).toBe(60_000);
    expect(CONFIRMATION_RATE_LIMIT_MAX).toBe(5);

    const appSource = readFileSync(
      new URL("../app.ts", import.meta.url),
      "utf8"
    );
    expect(appSource).toContain(
      "const limiter = rateLimit({ windowMs: 60_000, max: 5 })"
    );
  });

  it("leaves the existing mutation limiters untouched", () => {
    const claimSource = readFileSync(
      new URL("./claimRoute.ts", import.meta.url),
      "utf8"
    );
    const createSource = readFileSync(
      new URL("./createRequestRoute.ts", import.meta.url),
      "utf8"
    );
    const fulfillmentSource = readFileSync(
      new URL("./fulfillmentRoute.ts", import.meta.url),
      "utf8"
    );

    expect(claimSource).toContain("windowMs: 60_000");
    expect(claimSource).toContain(
      "export const claimRateLimiter = createDay4MutationRateLimiter(10)"
    );
    expect(claimSource).toContain(
      "export const claimExtensionRateLimiter = createDay4MutationRateLimiter(10)"
    );
    expect(createSource).toContain(
      "export const createRequestRateLimiter = createDay4MutationRateLimiter(5)"
    );
    expect(fulfillmentSource).toContain(
      "export const fulfillmentRateLimiter = createDay4MutationRateLimiter(10)"
    );
    // The confirmation bucket is confirmation-owned, not a reused Day 4 bucket.
    expect(claimSource).not.toContain("confirmation");
  });

  it("exposes one persistent limiter for the registered route", () => {
    expect(typeof confirmationRateLimiter).toBe("function");
    // Production keeps a single instance; a factory call must not be what
    // `app.ts` registers, or every worker restart of the module would reset it.
    const appSource = readFileSync(
      new URL("../app.ts", import.meta.url),
      "utf8"
    );
    expect(appSource).toContain("confirmationRateLimiter");
    expect(appSource).not.toContain("createConfirmationRateLimiter");
  });

  it("gives each factory instance an independent bucket", async () => {
    resumePublicActions();
    const primitive = vi.fn<ConfirmFn>(async () => ({ outcome: "confirmed" }));

    // One app exhausts its window.
    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        for (let attempt = 0; attempt < CONFIRMATION_RATE_LIMIT_MAX; attempt++) {
          expect((await postConfirmation(baseUrl, VALID_TOKEN)).status).toBe(
            200
          );
        }
        expect((await postConfirmation(baseUrl, VALID_TOKEN)).status).toBe(429);
      }
    );

    // A separately built app starts empty, from the same client IP.
    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        expect((await postConfirmation(baseUrl, VALID_TOKEN)).status).toBe(200);
      }
    );
  });

  it("shares one supplied limiter across the apps that are given it", async () => {
    resumePublicActions();
    const limiter = createConfirmationRateLimiter();
    const primitive = vi.fn<ConfirmFn>(async () => ({ outcome: "confirmed" }));

    for (let attempt = 0; attempt < CONFIRMATION_RATE_LIMIT_MAX; attempt++) {
      await withServer(
        buildTestApp({ limiter, confirmSubscription: primitive }),
        async (baseUrl) => {
          expect((await postConfirmation(baseUrl, VALID_TOKEN)).status).toBe(
            200
          );
        }
      );
    }

    await withServer(
      buildTestApp({ limiter, confirmSubscription: primitive }),
      async (baseUrl) => {
        const limited = await postConfirmation(baseUrl, VALID_TOKEN);
        expect(limited.status).toBe(429);
        expect(limited.html).toContain("<h1>Please wait a moment</h1>");
      }
    );
  });

  it("does not rate limit GET", async () => {
    resumePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      for (let attempt = 0; attempt < CONFIRMATION_RATE_LIMIT_MAX + 3; attempt++) {
        const { status } = await getConfirmationPage(
          baseUrl,
          `?token=${VALID_TOKEN}`
        );
        expect(status).toBe(200);
      }
    });
  });

  it("answers the request past the threshold with an HTML 429 and no redemption", async () => {
    resumePublicActions();
    const primitive = vi.fn<ConfirmFn>(async () => ({ outcome: "confirmed" }));

    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        for (let attempt = 0; attempt < CONFIRMATION_RATE_LIMIT_MAX; attempt++) {
          const { status } = await postConfirmation(baseUrl, VALID_TOKEN);
          expect(status).toBe(200);
        }

        const limited = await postConfirmation(baseUrl, VALID_TOKEN);

        expect(limited.status).toBe(429);
        expect(limited.html).toContain("<h1>Please wait a moment</h1>");
        expect(limited.html).toContain(
          "Wait about a minute, then open your confirmation link again."
        );
        expect(limited.html).not.toContain('"error"');
        expectConfirmationHeaders(limited.response);
        expect(primitive).toHaveBeenCalledTimes(CONFIRMATION_RATE_LIMIT_MAX);
      }
    );
  });

  it("does not let paused requests consume confirmation capacity", async () => {
    pausePublicActions();
    const primitive = vi.fn<ConfirmFn>(async () => ({ outcome: "confirmed" }));

    await withServer(
      buildTestApp({ confirmSubscription: primitive }),
      async (baseUrl) => {
        for (
          let attempt = 0;
          attempt < CONFIRMATION_RATE_LIMIT_MAX + 2;
          attempt++
        ) {
          const { status } = await postConfirmation(baseUrl, VALID_TOKEN);
          expect(status).toBe(503);
        }
        expect(primitive).not.toHaveBeenCalled();

        resumePublicActions();
        for (let attempt = 0; attempt < CONFIRMATION_RATE_LIMIT_MAX; attempt++) {
          const { status } = await postConfirmation(baseUrl, VALID_TOKEN);
          expect(status).toBe(200);
        }
        expect(primitive).toHaveBeenCalledTimes(CONFIRMATION_RATE_LIMIT_MAX);
      }
    );
  });
});

describe("confirmation security headers", () => {
  it("sets them before any later middleware can answer", () => {
    const { res, headers } = responseDouble();
    const next = vi.fn();

    confirmationSecurityHeaders({} as Request, res, next);

    expect(headers).toEqual({
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Content-Security-Policy": CONFIRMATION_CONTENT_SECURITY_POLICY,
    });
    expect(next).toHaveBeenCalledOnce();
  });

  it("accompanies every confirmation outcome", async () => {
    const outcomes: ConfirmationResult[] = [
      { outcome: "confirmed", subscriberId: PRIVATE_SUBSCRIBER_ID },
      { outcome: "alreadyConfirmed" },
      { outcome: "expired" },
      { outcome: "invalid" },
    ];

    for (const outcome of outcomes) {
      resumePublicActions();
      await withServer(
        buildTestApp({ confirmSubscription: async () => outcome }),
        async (baseUrl) => {
          const { response } = await postConfirmation(baseUrl, VALID_TOKEN);
          expectConfirmationHeaders(response);
        }
      );
    }

    // Error, pause, invalid-GET, form, and rate-limit pages.
    resumePublicActions();
    await withServer(
      buildTestApp({
        confirmSubscription: async () => {
          throw new Error("boom");
        },
        limiter: createConfirmationRateLimiter(),
      }),
      async (baseUrl) => {
        vi.spyOn(console, "error").mockImplementation(() => {});
        expectConfirmationHeaders((await postConfirmation(baseUrl, VALID_TOKEN)).response);
        expectConfirmationHeaders(
          (await getConfirmationPage(baseUrl, "?token=bad")).response
        );
        expectConfirmationHeaders(
          (await getConfirmationPage(baseUrl, `?token=${VALID_TOKEN}`)).response
        );
      }
    );

    resumePublicActions();
    await withServer(
      buildTestApp({ confirmSubscription: async () => ({ outcome: "invalid" }) }),
      async (baseUrl) => {
        for (let attempt = 0; attempt < CONFIRMATION_RATE_LIMIT_MAX; attempt++) {
          await postConfirmation(baseUrl, VALID_TOKEN);
        }
        const limited = await postConfirmation(baseUrl, VALID_TOKEN);
        expect(limited.status).toBe(429);
        expectConfirmationHeaders(limited.response);
      }
    );

    pausePublicActions();
    await withServer(buildTestApp(), async (baseUrl) => {
      expectConfirmationHeaders(
        (await getConfirmationPage(baseUrl, `?token=${VALID_TOKEN}`)).response
      );
      expectConfirmationHeaders(
        (await postConfirmation(baseUrl, VALID_TOKEN)).response
      );
    });
  });

  it("overrides the global helmet defaults for this route", async () => {
    resumePublicActions();

    await withServer(
      buildTestApp({
        withHelmet: true,
        confirmSubscription: async () => ({ outcome: "confirmed" }),
      }),
      async (baseUrl) => {
        expectConfirmationHeaders(
          (await getConfirmationPage(baseUrl, `?token=${VALID_TOKEN}`)).response
        );
        expectConfirmationHeaders(
          (await postConfirmation(baseUrl, VALID_TOKEN)).response
        );
      }
    );
  });
});

describe("confirmation logging", () => {
  it("logs no token, URL, body, digest, or error detail on either verb", async () => {
    resumePublicActions();
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
    const consoleWarn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const consoleInfo = vi.spyOn(console, "info").mockImplementation(() => {});

    const digest = (await import("./subscriptionTokens.js")).digestSubscriptionToken(
      VALID_TOKEN
    );
    digestSpy.mockClear();

    await withServer(
      buildTestApp({
        confirmSubscription: vi.fn<ConfirmFn>(async () => {
          throw new Error(
            `provider failure for ${VALID_TOKEN} digest ${digest}`
          );
        }),
      }),
      async (baseUrl) => {
        await getConfirmationPage(baseUrl, `?token=${VALID_TOKEN}`);
        await postConfirmation(baseUrl, VALID_TOKEN);
      }
    );

    const logged = JSON.stringify([
      ...consoleError.mock.calls,
      ...consoleLog.mock.calls,
      ...consoleWarn.mock.calls,
      ...consoleInfo.mock.calls,
    ]);

    expect(logged).not.toContain(VALID_TOKEN);
    expect(logged).not.toContain(digest);
    expect(logged).not.toContain(PRIVATE_SUBSCRIBER_ID);
    expect(logged).not.toContain(CONFIRMATION_ROUTE_PATH);
    expect(logged).not.toContain("provider failure");
    expect(logged).not.toContain("token=");
    // Only the fixed sanitized event is permitted.
    expect(consoleError.mock.calls).toEqual([
      ["[confirm] Confirmation redemption failed"],
    ]);
  });
});

/**
 * Copy and page-structure guards for the accepted Slice 3B product review.
 * Every page a reader can reach is collected once, then asserted as a set, so a
 * later copy edit cannot fix one page and leave the others inconsistent.
 */
describe("confirmation page copy and structure", () => {
  const RECOVERY_LINK =
    '<a href="/">Return to CommonPlate</a> to sign up again and receive a new link.';

  let pages: Record<string, string>;

  function mainOf(html: string): string {
    return html.match(/<main>([\s\S]*?)<\/main>/)?.[1] ?? "";
  }

  function titleOf(html: string): string {
    return html.match(/<title>([\s\S]*?)<\/title>/)?.[1] ?? "";
  }

  beforeAll(async () => {
    const collected: Record<string, string> = {};
    resumePublicActions();

    await withServer(
      buildTestApp({
        confirmSubscription: async () => ({
          outcome: "confirmed",
          subscriberId: PRIVATE_SUBSCRIBER_ID,
        }),
      }),
      async (baseUrl) => {
        collected.form = (
          await getConfirmationPage(baseUrl, `?token=${VALID_TOKEN}`)
        ).html;
        collected.invalidGet = (
          await getConfirmationPage(baseUrl, "?token=not-a-token")
        ).html;
        collected.confirmed = (await postConfirmation(baseUrl, VALID_TOKEN))
          .html;
      }
    );

    for (const [key, outcome] of [
      ["alreadyConfirmed", "alreadyConfirmed"],
      ["expired", "expired"],
      ["invalidPost", "invalid"],
    ] as const) {
      await withServer(
        buildTestApp({
          confirmSubscription: async () =>
            ({ outcome }) as unknown as ConfirmationResult,
        }),
        async (baseUrl) => {
          collected[key] = (await postConfirmation(baseUrl, VALID_TOKEN)).html;
        }
      );
    }

    await withServer(
      buildTestApp({
        confirmSubscription: async () => ({ outcome: "confirmed" }),
      }),
      async (baseUrl) => {
        for (let attempt = 0; attempt < CONFIRMATION_RATE_LIMIT_MAX; attempt++) {
          await postConfirmation(baseUrl, VALID_TOKEN);
        }
        collected.rateLimited = (await postConfirmation(baseUrl, VALID_TOKEN))
          .html;
      }
    );

    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    await withServer(
      buildTestApp({
        confirmSubscription: async () => {
          throw new Error("boom");
        },
      }),
      async (baseUrl) => {
        collected.unexpectedError = (
          await postConfirmation(baseUrl, VALID_TOKEN)
        ).html;
        // A body the route-local parser rejects outright, so this page comes
        // from the parser error boundary rather than the outcome switch.
        collected.invalidParser = (
          await postRaw(baseUrl, {
            headers: {
              "Content-Type": "application/x-www-form-urlencoded; charset=utf-7",
            },
            body: `token=${VALID_TOKEN}`,
          })
        ).html;
      }
    );
    consoleError.mockRestore();

    pausePublicActions();
    await withServer(buildTestApp(), async (baseUrl) => {
      collected.paused = (
        await getConfirmationPage(baseUrl, `?token=${VALID_TOKEN}`)
      ).html;
    });
    vi.unstubAllEnvs();

    pages = collected;
  });

  it("tells the reader on the form page that opening the link confirmed nothing", () => {
    expect(pages.form).toContain(
      "<p>Opening this link does not confirm alerts. Select “Confirm alerts” to receive CommonPlate alerts about new food requests.</p>"
    );
    expect(pages.form).toContain("<h1>Confirm email alerts</h1>");
    expect(pages.form).toContain("<button type=\"submit\">Confirm alerts</button>");
  });

  it("never claims a subscription state the shape-only GET cannot know", () => {
    // The same page is rendered for an already-confirmed token, so no wording
    // may assert that the reader is currently unsubscribed.
    expect(pages.form).not.toContain("You are not subscribed yet");
    expect(pages.form).not.toContain("not subscribed");
    expect(pages.form).not.toContain("pending");
  });

  it("closes the confirmed and already-confirmed pages with no further action", () => {
    expect(pages.confirmed).toContain(
      "<p>You can now receive CommonPlate alerts about new food requests. No further action is needed.</p>"
    );
    expect(pages.alreadyConfirmed).toContain(
      "<p>You can receive CommonPlate alerts about new food requests. No further action is needed.</p>"
    );
  });

  it("keeps the success claim at eligibility rather than guaranteed delivery", () => {
    for (const html of [pages.confirmed, pages.alreadyConfirmed]) {
      expect(html).toContain("You can");
      expect(html).not.toContain("You will receive");
      expect(html).not.toContain("every");
    }
  });

  it("gives the expired and invalid pages the same same-origin recovery link", () => {
    for (const html of [
      pages.expired,
      pages.invalidGet,
      pages.invalidPost,
      pages.invalidParser,
    ]) {
      expect(html).toContain(RECOVERY_LINK);
      // A plain anchor: keyboard reachable and activatable with no script.
      expect(html).not.toContain("<script");
      expect(html).not.toContain("onclick");
    }
  });

  it("renders one identical invalid page for malformed, unknown, and rejected tokens", () => {
    const invalidPages = [
      pages.invalidGet,
      pages.invalidPost,
      pages.invalidParser,
    ];

    for (const html of invalidPages) {
      expect(mainOf(html)).toBe(mainOf(invalidPages[0]));
      expect(mainOf(html)).toContain(
        "<h1>This confirmation link is invalid.</h1>"
      );
    }
  });

  it("states the real one-minute wait on the rate-limit page without blaming the reader", () => {
    expect(pages.rateLimited).toContain("<h1>Please wait a moment</h1>");
    expect(pages.rateLimited).toContain(
      "<p>Wait about a minute, then open your confirmation link again.</p>"
    );
    expect(pages.rateLimited).not.toContain("Too many");
    expect(pages.rateLimited).not.toContain("a few minutes");
    expect(pages.rateLimited).not.toContain("attempts");
  });

  it("tells the paused and unexpected-error readers to reopen the link later", () => {
    for (const html of [pages.paused, pages.unexpectedError]) {
      expect(html).toContain(
        "<h1>Email confirmation is temporarily unavailable.</h1>"
      );
      expect(html).toContain("<p>Please open this link again later.</p>");
      expect(html).not.toContain("Please try again later.");
    }

    // Identical to a reader; only the status distinguishes them, so neither
    // page discloses which condition occurred.
    expect(mainOf(pages.paused)).toBe(mainOf(pages.unexpectedError));
    expect(pages.paused).not.toContain("paused");
    expect(pages.paused).not.toContain("PUBLIC_ACTIONS");
  });

  it("brands every document title without branding the visible heading", () => {
    for (const [name, html] of Object.entries(pages)) {
      expect(`${name}: ${titleOf(html)}`).toMatch(/ — CommonPlate$/);
    }

    // The heading itself stays unbranded.
    expect(pages.form).toContain("<h1>Confirm email alerts</h1>");
    expect(pages.confirmed).toContain("<h1>Email alerts confirmed.</h1>");
  });

  it("says 'new food requests' on every page that names them", () => {
    for (const html of Object.values(pages)) {
      expect(html).not.toContain("alerts about new requests");
    }

    for (const html of [pages.form, pages.confirmed, pages.alreadyConfirmed]) {
      expect(html).toContain("alerts about new food requests");
    }
  });

  it("keeps one heading, the main landmark, and the page contract on every page", () => {
    for (const html of Object.values(pages)) {
      expect(html.match(/<h1[\s>]/g)).toHaveLength(1);
      expect(html).toContain('<html lang="en">');
      expect(html).toContain("<main>");
      expect(html).toContain('name="viewport"');
      expect(html).not.toContain("<script");
    }

    // Only the form page is interactive, and it still carries exactly one
    // hidden input and no user-facing label for it.
    expect(pages.form.match(/<input/g)).toHaveLength(1);
    expect(pages.form).toContain('<input type="hidden" name="token"');
    expect(pages.form).not.toContain("<label");
    for (const [name, html] of Object.entries(pages)) {
      if (name === "form") continue;
      expect(html).not.toContain("<form");
      expect(html).not.toContain("<input");
    }
  });

  it("shows no address, token, or internal vocabulary on any page", () => {
    for (const [name, html] of Object.entries(pages)) {
      if (name !== "form") expect(html).not.toContain(VALID_TOKEN);
      expect(html).not.toContain(PRIVATE_SUBSCRIBER_ID);
      expect(html).not.toContain("@");
      expect(html).not.toMatch(/digest|hash|Subscriber|database|status:/i);
    }
  });
});

describe("confirmation route with the real primitive", () => {
  it("rejects malformed tokens from shape alone, before any Mongo work", async () => {
    resumePublicActions();

    await withServer(
      buildTestApp({ confirmSubscription: confirmSubscription }),
      async (baseUrl) => {
        const { status, html } = await postConfirmation(baseUrl, "not-a-token");

        expect(status).toBe(400);
        expect(html).toContain("This confirmation link is invalid.");
        expect(validateSpy).toHaveBeenCalledWith("not-a-token");
        expect(digestSpy).not.toHaveBeenCalled();
        expectNoMongoWork();
        expect(globalErrorHandler).not.toHaveBeenCalled();
      }
    );
  });
});
