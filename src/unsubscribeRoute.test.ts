import express, { type Express, type RequestHandler } from "express";
import helmet from "helmet";
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

/**
 * The escape helper is wrapped rather than replaced, so the assertions prove
 * *whether* the route escaped the credential without changing what escaping
 * does. `models/db.js` is replaced outright: every Subscriber method is a bare
 * spy, so a route path that reaches Mongo fails loudly instead of querying.
 */
const { escapeSpy, subscriberSpies } = vi.hoisted(() => ({
  escapeSpy: vi.fn(),
  subscriberSpies: {
    findById: vi.fn(),
    findOne: vi.fn(),
    findOneAndUpdate: vi.fn(),
    updateOne: vi.fn(),
    updateMany: vi.fn(),
    deleteOne: vi.fn(),
    exists: vi.fn(),
    create: vi.fn(),
    countDocuments: vi.fn(),
  },
}));

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
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { PUBLIC_PAGE_CONTENT_SECURITY_POLICY } from "./publicPage.js";
import {
  MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES,
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
  buildUnsubscribeUrl,
  signUnsubscribeCredential,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";
import {
  UNSUBSCRIBE_RATE_LIMIT_MAX,
  UNSUBSCRIBE_RATE_LIMIT_WINDOW_MS,
  createShowUnsubscribePageHandler,
  createUnsubscribePageHandler,
  createUnsubscribeRateLimiter,
  pauseUnsubscribePage,
  unsubscribeBodyParser,
  unsubscribeParserError,
  unsubscribeRateLimiter,
  unsubscribeSecurityHeaders,
} from "./unsubscribeRoute.js";
import type {
  UnsubscribeCredentialCheck,
  UnsubscribeResult,
} from "./unsubscribeSubscriber.js";

type CheckFn = (
  rawCredential: unknown
) => Promise<{ outcome: UnsubscribeCredentialCheck }>;
type UnsubscribeFn = (
  rawCredential: unknown,
  now: Date
) => Promise<UnsubscribeResult>;

const SECRET = Buffer.alloc(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES, 1);
const SUBSCRIBER_ID = "64b000000000000000000abc";
const VALID_CREDENTIAL = signUnsubscribeCredential(SUBSCRIBER_ID, 1, SECRET);

/**
 * A tampered copy of an authentic credential, guaranteed to differ from it.
 * Overwriting the final signature character with one fixed letter is a no-op
 * whenever the authentic signature already ends in that letter, which would
 * quietly turn a tampering case into a valid-credential case. Both letters
 * below are canonical trailing base64url characters, so the result stays well
 * formed and fails the signature comparison rather than the parser.
 * `unsubscribeCredential.test.ts` owns this helper's own regression coverage.
 */
function tamperCredentialSignature(value: string): string {
  const last = value.slice(-1);
  return `${value.slice(0, -1)}${last === "A" ? "E" : "A"}`;
}

const TAMPERED_CREDENTIAL = tamperCredentialSignature(VALID_CREDENTIAL);
const SUBSCRIBER_EMAIL = "helper@example.edu";

const globalErrorHandler = vi.fn();

function resumePublicActions(): void {
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
}

function pausePublicActions(): void {
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
}

interface TestAppOptions {
  check?: CheckFn;
  unsubscribe?: UnsubscribeFn;
  limiter?: RequestHandler;
  withHelmet?: boolean;
}

/**
 * The same global middleware `app.ts` installs, in the same order and with the
 * unsubscribe POST registered ahead of the global parsers, so these assertions
 * exercise the production body-parsing and header behaviour. The global JSON
 * error handler is mounted too: if the route ever delegated, its envelope
 * would surface here.
 */
function buildTestApp(options: TestAppOptions = {}): Express {
  const app = express();
  if (options.withHelmet) app.use(helmet());

  app.post(
    UNSUBSCRIBE_ROUTE_PATH,
    unsubscribeSecurityHeaders,
    pauseUnsubscribePage,
    options.limiter ?? createUnsubscribeRateLimiter(),
    unsubscribeBodyParser,
    createUnsubscribePageHandler(
      options.unsubscribe ? { unsubscribeSubscriber: options.unsubscribe } : {}
    ),
    unsubscribeParserError
  );

  app.use(express.json({ limit: "100kb" }));
  app.use(express.urlencoded({ extended: true, limit: "100kb" }));

  app.get(
    UNSUBSCRIBE_ROUTE_PATH,
    unsubscribeSecurityHeaders,
    pauseUnsubscribePage,
    createShowUnsubscribePageHandler(
      options.check ? { checkUnsubscribeCredential: options.check } : {}
    )
  );

  app.use((err: Error, _req: Request, res: Response, _next: () => void) => {
    globalErrorHandler(err);
    res.status(500).json({ error: "Internal server error" });
  });

  return app;
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

interface PageResponse {
  status: number;
  html: string;
  response: globalThis.Response;
}

async function getUnsubscribePage(
  baseUrl: string,
  query = ""
): Promise<PageResponse> {
  const response = await fetch(`${baseUrl}${UNSUBSCRIBE_ROUTE_PATH}${query}`);
  return { status: response.status, html: await response.text(), response };
}

async function getUrl(url: string): Promise<PageResponse> {
  const response = await fetch(url);
  return { status: response.status, html: await response.text(), response };
}

async function postUnsubscribe(
  baseUrl: string,
  credential?: string
): Promise<PageResponse> {
  const response = await fetch(`${baseUrl}${UNSUBSCRIBE_ROUTE_PATH}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(
      credential === undefined
        ? {}
        : { [UNSUBSCRIBE_CREDENTIAL_PARAMETER]: credential }
    ).toString(),
  });
  return { status: response.status, html: await response.text(), response };
}

async function postRaw(
  baseUrl: string,
  init: RequestInit
): Promise<PageResponse> {
  const response = await fetch(`${baseUrl}${UNSUBSCRIBE_ROUTE_PATH}`, {
    method: "POST",
    ...init,
  });
  return { status: response.status, html: await response.text(), response };
}

function expectUnsubscribeHeaders(response: globalThis.Response): void {
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(response.headers.get("referrer-policy")).toBe("no-referrer");
  expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  expect(response.headers.get("x-frame-options")).toBe("DENY");
  expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
  expect(response.headers.get("content-security-policy")).toBe(
    PUBLIC_PAGE_CONTENT_SECURITY_POLICY
  );
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

const matching: CheckFn = async () => ({ outcome: "match" });
const notMatching: CheckFn = async () => ({ outcome: "invalid" });
const unsubscribing: UnsubscribeFn = async () => ({ outcome: "unsubscribed" });

beforeEach(() => {
  vi.clearAllMocks();
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("GET /unsubscribe while paused", () => {
  it("returns an HTML 503 before verification, lookup, or mutation", async () => {
    pausePublicActions();
    const check = vi.fn<CheckFn>(matching);

    await withServer(buildTestApp({ check }), async (baseUrl) => {
      const { status, html, response } = await getUnsubscribePage(
        baseUrl,
        `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
      );

      expect(status).toBe(503);
      expect(html).toContain(
        "<h1>Unsubscribing is temporarily unavailable.</h1>"
      );
      expect(html).toContain("Please open this link again later.");
      expect(check).not.toHaveBeenCalled();
      expectNoMongoWork();
      expectUnsubscribeHeaders(response);
    });
  });

  it("renders no unsubscribe form and echoes no credential while paused", async () => {
    pausePublicActions();

    await withServer(buildTestApp(), async (baseUrl) => {
      const { html } = await getUnsubscribePage(
        baseUrl,
        `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
      );

      expect(html).not.toContain("<form");
      expect(html).not.toContain("<input");
      expect(html).not.toContain("Unsubscribe</button>");
      expect(html).not.toContain(VALID_CREDENTIAL);
    });
  });
});

describe("GET /unsubscribe with a usable link", () => {
  it("renders the confirmation page and an explicit POST form", async () => {
    resumePublicActions();

    await withServer(buildTestApp({ check: matching }), async (baseUrl) => {
      const { status, html, response } = await getUnsubscribePage(
        baseUrl,
        `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
      );

      expect(status).toBe(200);
      expect(html).toContain("<!doctype html>");
      expect(html).toContain('<html lang="en">');
      expect(html).toContain("<h1>Unsubscribe from CommonPlate alerts?</h1>");
      expect(html).toContain(
        "<p>You’ll stop receiving CommonPlate alert and digest emails.</p>"
      );
      expect(html).toMatch(/<form[^>]*method="post"/i);
      expect(html).toMatch(/<form[^>]*action="\/unsubscribe"/i);
      expect(html).toContain(
        `<input type="hidden" name="credential" value="${VALID_CREDENTIAL}" />`
      );
      expect(html).toContain("<button type=\"submit\">Unsubscribe</button>");
      expect(html.match(/<input/g)).toHaveLength(1);
      expect(html).not.toContain("<script");
      expect(html).not.toContain("onclick");
      expectUnsubscribeHeaders(response);
    });
  });

  it("renders one identical page whatever status the subscriber holds", async () => {
    resumePublicActions();
    // The route is told only that the link is usable, so a pending, a
    // confirmed, and an already-unsubscribed subscriber cannot be told apart
    // by construction. This pins that the check returns nothing else.
    const pages: string[] = [];

    for (const _status of ["pending", "confirmed", "unsubscribed"]) {
      await withServer(buildTestApp({ check: matching }), async (baseUrl) => {
        pages.push(
          (
            await getUnsubscribePage(
              baseUrl,
              `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
            )
          ).html
        );
      });
    }

    expect(pages[1]).toBe(pages[0]);
    expect(pages[2]).toBe(pages[0]);
  });

  it("escapes the hidden credential with the shared escape utility", async () => {
    resumePublicActions();

    await withServer(buildTestApp({ check: matching }), async (baseUrl) => {
      await getUnsubscribePage(
        baseUrl,
        `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
      );

      expect(escapeSpy).toHaveBeenCalledWith(VALID_CREDENTIAL);
    });
  });

  it("never mutates, however many times the link is opened", async () => {
    resumePublicActions();
    const unsubscribe = vi.fn<UnsubscribeFn>(unsubscribing);

    await withServer(
      buildTestApp({ check: matching, unsubscribe }),
      async (baseUrl) => {
        for (let attempt = 0; attempt < 4; attempt++) {
          const { status } = await getUnsubscribePage(
            baseUrl,
            `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
          );
          expect(status).toBe(200);
        }

        expect(unsubscribe).not.toHaveBeenCalled();
        expectNoMongoWork();
      }
    );
  });

  it("accepts the real URL an alert or digest email would carry", async () => {
    resumePublicActions();
    vi.stubEnv("BASE_URL", "https://commonplate.test/");
    // Built exactly as Slice 4A builds it, then opened as a reader would, so
    // the emitted link and this route cannot drift apart on path, parameter
    // name, or encoding.
    const emailed = buildUnsubscribeUrl(
      { _id: SUBSCRIBER_ID, unsubscribeCredentialVersion: 1 },
      SECRET
    );
    const check: CheckFn = async (raw) => ({
      outcome: verifyUnsubscribeCredential(raw, SECRET) ? "match" : "invalid",
    });

    await withServer(buildTestApp({ check }), async (baseUrl) => {
      const { pathname, search } = new URL(emailed);
      expect(pathname).toBe(UNSUBSCRIBE_ROUTE_PATH);

      const { status, html } = await getUrl(`${baseUrl}${pathname}${search}`);

      expect(status).toBe(200);
      expect(html).toContain("<h1>Unsubscribe from CommonPlate alerts?</h1>");
      expect(html).toContain(
        `<input type="hidden" name="credential" value="${VALID_CREDENTIAL}" />`
      );
    });
  });
});

describe("GET /unsubscribe with an unusable link", () => {
  it("tampers its fixture into a credential that genuinely differs and genuinely fails", () => {
    // Guarded here because every tampering case below submits this string: if
    // the fixture were still the authentic credential, those cases would be
    // asserting the invalid page for a valid link.
    expect(TAMPERED_CREDENTIAL).not.toBe(VALID_CREDENTIAL);
    expect(verifyUnsubscribeCredential(VALID_CREDENTIAL, SECRET)).not.toBeNull();
    expect(verifyUnsubscribeCredential(TAMPERED_CREDENTIAL, SECRET)).toBeNull();
  });

  it("answers malformed, tampered, unknown, and rotated links identically", async () => {
    resumePublicActions();
    expect(TAMPERED_CREDENTIAL).not.toBe(VALID_CREDENTIAL);
    expect(verifyUnsubscribeCredential(TAMPERED_CREDENTIAL, SECRET)).toBeNull();
    // Malformed and tampered fail verification; unknown and version-mismatched
    // fail against the stored row. All four are one answer.
    const check = vi.fn<CheckFn>(notMatching);

    await withServer(buildTestApp({ check }), async (baseUrl) => {
      const pages: string[] = [];
      for (const credential of [
        "not-a-credential",
        TAMPERED_CREDENTIAL,
        VALID_CREDENTIAL,
        signUnsubscribeCredential(SUBSCRIBER_ID, 2, SECRET),
      ]) {
        const { status, html, response } = await getUnsubscribePage(
          baseUrl,
          `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${encodeURIComponent(credential)}`
        );

        expect(status).toBe(400);
        expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
        expect(html).not.toContain("<form");
        expect(html).not.toContain("<input");
        expectUnsubscribeHeaders(response);
        pages.push(html);
      }

      for (const html of pages) expect(html).toBe(pages[0]);
    });
  });

  it("returns 400 for a missing credential without asking the primitive", async () => {
    resumePublicActions();
    const check = vi.fn<CheckFn>(matching);

    await withServer(buildTestApp({ check }), async (baseUrl) => {
      const { status, html } = await getUnsubscribePage(baseUrl);

      expect(status).toBe(400);
      expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
      expect(check).not.toHaveBeenCalled();
      expectNoMongoWork();
    });
  });

  it("returns 400 for repeated credential parameters", async () => {
    resumePublicActions();
    const check = vi.fn<CheckFn>(matching);

    await withServer(buildTestApp({ check }), async (baseUrl) => {
      const { status, html } = await getUnsubscribePage(
        baseUrl,
        `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}&${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${TAMPERED_CREDENTIAL}`
      );

      expect(status).toBe(400);
      expect(html).not.toContain(VALID_CREDENTIAL);
      expect(check).not.toHaveBeenCalled();
    });
  });

  it("returns 400 for array and object credential values", async () => {
    const check = vi.fn<CheckFn>(matching);
    const handler = createShowUnsubscribePageHandler({
      checkUnsubscribeCredential: check,
    });

    for (const credential of [
      [VALID_CREDENTIAL],
      { credential: VALID_CREDENTIAL },
      { toString: () => VALID_CREDENTIAL },
    ]) {
      const { res, state } = responseDouble();
      await handler(
        { query: { credential } } as unknown as Request,
        res
      );

      expect(state.status).toBe(400);
      expect(state.body).toContain("<h1>This unsubscribe link is invalid.</h1>");
      expect(state.body).not.toContain("<form");
    }

    expect(check).not.toHaveBeenCalled();
    expectNoMongoWork();
  });

  it("answers a failing check with a generic 500 and one fixed log line", async () => {
    resumePublicActions();
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const check = vi.fn<CheckFn>(async () => {
      throw new Error(`boom ${VALID_CREDENTIAL}`);
    });

    await withServer(buildTestApp({ check }), async (baseUrl) => {
      const { status, html, response } = await getUnsubscribePage(
        baseUrl,
        `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
      );

      expect(status).toBe(500);
      expect(html).toContain(
        "<h1>Unsubscribing is temporarily unavailable.</h1>"
      );
      expect(html).not.toContain("boom");
      expect(html).not.toContain("<form");
      expectUnsubscribeHeaders(response);
      expect(globalErrorHandler).not.toHaveBeenCalled();
      expect(consoleError.mock.calls).toEqual([
        ["[unsubscribe] Unsubscribe link check failed"],
      ]);
    });
  });
});

describe("POST /unsubscribe", () => {
  it("refuses while paused before verification, lookup, or mutation", async () => {
    pausePublicActions();
    const unsubscribe = vi.fn<UnsubscribeFn>(unsubscribing);
    const limiter = vi.fn<RequestHandler>((_req, _res, next) => next());

    await withServer(
      buildTestApp({ unsubscribe, limiter }),
      async (baseUrl) => {
        const { status, html, response } = await postUnsubscribe(
          baseUrl,
          VALID_CREDENTIAL
        );

        expect(status).toBe(503);
        expect(html).toContain(
          "<h1>Unsubscribing is temporarily unavailable.</h1>"
        );
        expect(html).not.toContain("<form");
        expect(unsubscribe).not.toHaveBeenCalled();
        // Ahead of the limiter too, so a paused submission spends no capacity.
        expect(limiter).not.toHaveBeenCalled();
        expectNoMongoWork();
        expectUnsubscribeHeaders(response);
      }
    );
  });

  it("returns the generic success page for a redeemed credential", async () => {
    resumePublicActions();
    const unsubscribe = vi.fn<UnsubscribeFn>(unsubscribing);

    await withServer(buildTestApp({ unsubscribe }), async (baseUrl) => {
      const { status, html, response } = await postUnsubscribe(
        baseUrl,
        VALID_CREDENTIAL
      );

      expect(status).toBe(200);
      expect(html).toContain("<h1>You’re unsubscribed</h1>");
      expect(html).toContain(
        "<p>You won’t receive CommonPlate alert or digest emails unless you sign up and confirm again.</p>"
      );
      expect(html).not.toContain("<form");
      expectUnsubscribeHeaders(response);
      expect(unsubscribe).toHaveBeenCalledOnce();
      expect(unsubscribe.mock.calls[0][0]).toBe(VALID_CREDENTIAL);
      expect(unsubscribe.mock.calls[0][1]).toBeInstanceOf(Date);
      expect(globalErrorHandler).not.toHaveBeenCalled();
    });
  });

  it("returns the identical success page however often it is submitted", async () => {
    resumePublicActions();

    await withServer(
      buildTestApp({ unsubscribe: unsubscribing }),
      async (baseUrl) => {
        const first = await postUnsubscribe(baseUrl, VALID_CREDENTIAL);
        const second = await postUnsubscribe(baseUrl, VALID_CREDENTIAL);

        expect(second.status).toBe(first.status);
        expect(second.html).toBe(first.html);
      }
    );
  });

  it("answers an invalid outcome with the same 400 page as the GET", async () => {
    resumePublicActions();
    expect(TAMPERED_CREDENTIAL).not.toBe(VALID_CREDENTIAL);
    expect(verifyUnsubscribeCredential(TAMPERED_CREDENTIAL, SECRET)).toBeNull();

    await withServer(
      buildTestApp({ unsubscribe: async () => ({ outcome: "invalid" }) }),
      async (baseUrl) => {
        const posted = await postUnsubscribe(baseUrl, TAMPERED_CREDENTIAL);

        expect(posted.status).toBe(400);
        expect(posted.html).toContain(
          "<h1>This unsubscribe link is invalid.</h1>"
        );
        expect(posted.html).not.toContain("<form");
        expectUnsubscribeHeaders(posted.response);
      }
    );
  });

  it("treats an unparsed or non-string body as an invalid credential", async () => {
    resumePublicActions();
    const unsubscribe = vi.fn<UnsubscribeFn>(async () => ({
      outcome: "invalid",
    }));

    await withServer(buildTestApp({ unsubscribe }), async (baseUrl) => {
      const bodies: RequestInit[] = [
        {},
        {
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ credential: VALID_CREDENTIAL }),
        },
      ];

      for (const init of bodies) {
        const { status, html } = await postRaw(baseUrl, init);
        expect(status).toBe(400);
        expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
      }

      // A JSON body is left unparsed rather than rejected, so nothing usable
      // reaches the primitive and no parser error is logged.
      for (const call of unsubscribe.mock.calls) {
        expect(call[0]).toBeUndefined();
      }
      expect(globalErrorHandler).not.toHaveBeenCalled();
    });
  });

  it("answers rejected bodies with the invalid page and no parser detail", async () => {
    resumePublicActions();
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
    const unsubscribe = vi.fn<UnsubscribeFn>(unsubscribing);

    const rejected: RequestInit[] = [
      {
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: `${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${"a".repeat(200_000)}`,
      },
      {
        headers: {
          "Content-Type": "application/x-www-form-urlencoded; charset=utf-7",
        },
        body: `${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`,
      },
    ];

    await withServer(buildTestApp({ unsubscribe }), async (baseUrl) => {
      for (const init of rejected) {
        const { status, html, response } = await postRaw(baseUrl, init);

        expect(status).toBe(400);
        expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
        expect(html).not.toMatch(
          /entity\.|too large|unsupported charset|unsupported content encoding/i
        );
        expectUnsubscribeHeaders(response);
      }

      expect(unsubscribe).not.toHaveBeenCalled();
      expect(globalErrorHandler).not.toHaveBeenCalled();

      const logged = JSON.stringify([
        ...consoleError.mock.calls,
        ...consoleLog.mock.calls,
      ]);
      expect(logged).not.toContain(VALID_CREDENTIAL);
      expect(logged).not.toMatch(/entity\.|unsupported charset/i);
    });
  });

  it("answers a rejecting primitive with a generic 500 and no delegation", async () => {
    resumePublicActions();
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});

    await withServer(
      buildTestApp({
        unsubscribe: async () => {
          throw new Error(`boom ${VALID_CREDENTIAL}`);
        },
      }),
      async (baseUrl) => {
        const { status, html, response } = await postUnsubscribe(
          baseUrl,
          VALID_CREDENTIAL
        );

        expect(status).toBe(500);
        expect(html).toContain(
          "<h1>Unsubscribing is temporarily unavailable.</h1>"
        );
        expect(html).not.toContain("boom");
        expectUnsubscribeHeaders(response);
        expect(globalErrorHandler).not.toHaveBeenCalled();
        expect(consoleError.mock.calls).toEqual([
          ["[unsubscribe] Unsubscribe redemption failed"],
        ]);
      }
    );
  });

  it("delegates a parser error only when a response has already been sent", () => {
    const next = vi.fn();
    const { res, state } = responseDouble();

    unsubscribeParserError(
      new Error("boom"),
      {} as Request,
      res,
      next as unknown as NextFunction
    );
    expect(state.status).toBe(400);
    expect(state.body).toContain("<h1>This unsubscribe link is invalid.</h1>");
    expect(next).not.toHaveBeenCalled();

    const sent = responseDouble();
    (sent.res as unknown as { headersSent: boolean }).headersSent = true;
    const error = new Error("boom");
    unsubscribeParserError(
      error,
      {} as Request,
      sent.res,
      next as unknown as NextFunction
    );
    expect(next).toHaveBeenCalledWith(error);
  });
});

describe("unsubscribe rate limiting", () => {
  it("matches the confirmation window and threshold", () => {
    expect(UNSUBSCRIBE_RATE_LIMIT_WINDOW_MS).toBe(60_000);
    expect(UNSUBSCRIBE_RATE_LIMIT_MAX).toBe(5);
    expect(typeof unsubscribeRateLimiter).toBe("function");
  });

  it("answers the request past the threshold with an HTML 429 and no mutation", async () => {
    resumePublicActions();
    const unsubscribe = vi.fn<UnsubscribeFn>(unsubscribing);

    await withServer(buildTestApp({ unsubscribe }), async (baseUrl) => {
      for (let attempt = 0; attempt < UNSUBSCRIBE_RATE_LIMIT_MAX; attempt++) {
        expect((await postUnsubscribe(baseUrl, VALID_CREDENTIAL)).status).toBe(
          200
        );
      }

      const limited = await postUnsubscribe(baseUrl, VALID_CREDENTIAL);

      expect(limited.status).toBe(429);
      expect(limited.html).toContain("<h1>Please wait a moment</h1>");
      expect(limited.html).toContain(
        "Wait about a minute, then open your unsubscribe link again."
      );
      expect(limited.html).not.toContain('"error"');
      expectUnsubscribeHeaders(limited.response);
      expect(unsubscribe).toHaveBeenCalledTimes(UNSUBSCRIBE_RATE_LIMIT_MAX);
    });
  });

  it("does not rate limit the GET", async () => {
    resumePublicActions();

    await withServer(buildTestApp({ check: matching }), async (baseUrl) => {
      for (
        let attempt = 0;
        attempt < UNSUBSCRIBE_RATE_LIMIT_MAX + 3;
        attempt++
      ) {
        const { status } = await getUnsubscribePage(
          baseUrl,
          `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
        );
        expect(status).toBe(200);
      }
    });
  });

  it("does not let paused requests consume capacity", async () => {
    pausePublicActions();
    const unsubscribe = vi.fn<UnsubscribeFn>(unsubscribing);
    const limiter = createUnsubscribeRateLimiter();

    await withServer(
      buildTestApp({ unsubscribe, limiter }),
      async (baseUrl) => {
        for (
          let attempt = 0;
          attempt < UNSUBSCRIBE_RATE_LIMIT_MAX + 2;
          attempt++
        ) {
          expect(
            (await postUnsubscribe(baseUrl, VALID_CREDENTIAL)).status
          ).toBe(503);
        }
        expect(unsubscribe).not.toHaveBeenCalled();

        resumePublicActions();
        for (let attempt = 0; attempt < UNSUBSCRIBE_RATE_LIMIT_MAX; attempt++) {
          expect(
            (await postUnsubscribe(baseUrl, VALID_CREDENTIAL)).status
          ).toBe(200);
        }
      }
    );
  });

  it("gives each factory instance an independent bucket", async () => {
    resumePublicActions();

    await withServer(
      buildTestApp({ unsubscribe: unsubscribing }),
      async (baseUrl) => {
        for (let attempt = 0; attempt < UNSUBSCRIBE_RATE_LIMIT_MAX; attempt++) {
          await postUnsubscribe(baseUrl, VALID_CREDENTIAL);
        }
        expect((await postUnsubscribe(baseUrl, VALID_CREDENTIAL)).status).toBe(
          429
        );
      }
    );

    await withServer(
      buildTestApp({ unsubscribe: unsubscribing }),
      async (baseUrl) => {
        expect((await postUnsubscribe(baseUrl, VALID_CREDENTIAL)).status).toBe(
          200
        );
      }
    );
  });
});

describe("unsubscribe security headers", () => {
  it("sets them before any later middleware can answer", () => {
    const { res, headers } = responseDouble();
    const next = vi.fn();

    unsubscribeSecurityHeaders({} as Request, res, next);

    expect(headers).toEqual({
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Content-Security-Policy": PUBLIC_PAGE_CONTENT_SECURITY_POLICY,
    });
    expect(next).toHaveBeenCalledOnce();
  });

  it("overrides the global helmet defaults for this route", async () => {
    resumePublicActions();

    await withServer(
      buildTestApp({
        withHelmet: true,
        check: matching,
        unsubscribe: unsubscribing,
      }),
      async (baseUrl) => {
        expectUnsubscribeHeaders(
          (
            await getUnsubscribePage(
              baseUrl,
              `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
            )
          ).response
        );
        expectUnsubscribeHeaders(
          (await postUnsubscribe(baseUrl, VALID_CREDENTIAL)).response
        );
      }
    );
  });

  it("refuses while paused with the JSON guard nowhere in the chain", async () => {
    pausePublicActions();
    const { res, state } = responseDouble();
    const next = vi.fn();

    pauseUnsubscribePage({} as Request, res, next as unknown as NextFunction);

    expect(state.status).toBe(503);
    expect(state.body).toContain("<!doctype html>");
    expect(state.body).not.toContain('"error"');
    expect(next).not.toHaveBeenCalled();
  });
});

describe("unsubscribe logging", () => {
  it("logs no credential, URL, address, or error detail on either verb", async () => {
    resumePublicActions();
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
    const consoleWarn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const consoleInfo = vi.spyOn(console, "info").mockImplementation(() => {});

    await withServer(
      buildTestApp({
        check: async () => {
          throw new Error(`check failure for ${VALID_CREDENTIAL}`);
        },
        unsubscribe: async () => {
          throw new Error(
            `redemption failure for ${VALID_CREDENTIAL} <${SUBSCRIBER_EMAIL}>`
          );
        },
      }),
      async (baseUrl) => {
        await getUnsubscribePage(
          baseUrl,
          `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
        );
        await postUnsubscribe(baseUrl, VALID_CREDENTIAL);
      }
    );

    const logged = JSON.stringify([
      ...consoleError.mock.calls,
      ...consoleLog.mock.calls,
      ...consoleWarn.mock.calls,
      ...consoleInfo.mock.calls,
    ]);

    expect(logged).not.toContain(VALID_CREDENTIAL);
    expect(logged).not.toContain(SUBSCRIBER_ID);
    expect(logged).not.toContain(SUBSCRIBER_EMAIL);
    expect(logged).not.toContain("credential=");
    expect(logged).not.toContain("failure for");
    expect(consoleError.mock.calls).toEqual([
      ["[unsubscribe] Unsubscribe link check failed"],
      ["[unsubscribe] Unsubscribe redemption failed"],
    ]);
  });
});

/**
 * Copy and structure guards for the accepted Slice 4B contract. Every page a
 * reader can reach is collected once and asserted as a set, so a later edit
 * cannot fix one page and leave the others inconsistent.
 */
describe("unsubscribe page copy and structure", () => {
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
      buildTestApp({ check: matching, unsubscribe: unsubscribing }),
      async (baseUrl) => {
        collected.form = (
          await getUnsubscribePage(
            baseUrl,
            `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
          )
        ).html;
        collected.unsubscribed = (
          await postUnsubscribe(baseUrl, VALID_CREDENTIAL)
        ).html;
      }
    );

    await withServer(
      buildTestApp({
        check: notMatching,
        unsubscribe: async () => ({ outcome: "invalid" }),
      }),
      async (baseUrl) => {
        collected.invalidGet = (
          await getUnsubscribePage(
            baseUrl,
            `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${TAMPERED_CREDENTIAL}`
          )
        ).html;
        collected.invalidPost = (
          await postUnsubscribe(baseUrl, TAMPERED_CREDENTIAL)
        ).html;
      }
    );

    await withServer(
      buildTestApp({ unsubscribe: unsubscribing }),
      async (baseUrl) => {
        for (let attempt = 0; attempt < UNSUBSCRIBE_RATE_LIMIT_MAX; attempt++) {
          await postUnsubscribe(baseUrl, VALID_CREDENTIAL);
        }
        collected.rateLimited = (
          await postUnsubscribe(baseUrl, VALID_CREDENTIAL)
        ).html;
      }
    );

    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    await withServer(
      buildTestApp({
        unsubscribe: async () => {
          throw new Error("boom");
        },
      }),
      async (baseUrl) => {
        collected.unexpectedError = (
          await postUnsubscribe(baseUrl, VALID_CREDENTIAL)
        ).html;
      }
    );
    consoleError.mockRestore();

    pausePublicActions();
    await withServer(buildTestApp(), async (baseUrl) => {
      collected.paused = (
        await getUnsubscribePage(
          baseUrl,
          `?${UNSUBSCRIBE_CREDENTIAL_PARAMETER}=${VALID_CREDENTIAL}`
        )
      ).html;
    });
    vi.unstubAllEnvs();

    pages = collected;
  });

  it("asks before acting and states what unsubscribing does", () => {
    expect(pages.form).toContain("<h1>Unsubscribe from CommonPlate alerts?</h1>");
    expect(pages.form).toContain(
      "<p>You’ll stop receiving CommonPlate alert and digest emails.</p>"
    );
    expect(pages.form).toContain('<button type="submit">Unsubscribe</button>');
  });

  it("never claims a subscription state the page cannot know", () => {
    // The same page is rendered for pending, confirmed, and already
    // unsubscribed readers, so no wording may assert a current state.
    for (const html of [pages.form, pages.unsubscribed]) {
      expect(html).not.toContain("currently");
      expect(html).not.toContain("pending");
      expect(html).not.toContain("confirmed subscriber");
    }
  });

  it("tells the unsubscribed reader how to come back", () => {
    expect(pages.unsubscribed).toContain("<h1>You’re unsubscribed</h1>");
    expect(pages.unsubscribed).toContain(
      "<p>You won’t receive CommonPlate alert or digest emails unless you sign up and confirm again.</p>"
    );
  });

  it("renders one identical invalid page for every unusable link", () => {
    for (const html of [pages.invalidGet, pages.invalidPost]) {
      expect(mainOf(html)).toBe(mainOf(pages.invalidGet));
      expect(html).toContain("<h1>This unsubscribe link is invalid.</h1>");
    }
  });

  it("tells the paused and unexpected-error readers to reopen the link later", () => {
    for (const html of [pages.paused, pages.unexpectedError]) {
      expect(html).toContain(
        "<h1>Unsubscribing is temporarily unavailable.</h1>"
      );
      expect(html).toContain("<p>Please open this link again later.</p>");
    }

    // Identical to a reader; only the status distinguishes them, so neither
    // page discloses which condition occurred.
    expect(mainOf(pages.paused)).toBe(mainOf(pages.unexpectedError));
    expect(pages.paused).not.toContain("paused");
    expect(pages.paused).not.toContain("PUBLIC_ACTIONS");
  });

  it("states the real one-minute wait without blaming the reader", () => {
    expect(pages.rateLimited).toContain("<h1>Please wait a moment</h1>");
    expect(pages.rateLimited).toContain(
      "<p>Wait about a minute, then open your unsubscribe link again.</p>"
    );
    expect(pages.rateLimited).not.toContain("Too many");
    expect(pages.rateLimited).not.toContain("attempts");
  });

  it("brands every document title without branding the visible heading", () => {
    for (const [name, html] of Object.entries(pages)) {
      expect(`${name}: ${titleOf(html)}`).toMatch(/ — CommonPlate$/);
    }
  });

  it("keeps one heading, the main landmark, and no script on every page", () => {
    for (const html of Object.values(pages)) {
      expect(html.match(/<h1[\s>]/g)).toHaveLength(1);
      expect(html).toContain('<html lang="en">');
      expect(html).toContain("<main>");
      expect(html).toContain('name="viewport"');
      expect(html).not.toContain("<script");
      // No external resource of any kind: no stylesheet, image, font, or
      // tracking pixel may be fetched by a page opened from an inbox.
      expect(html).not.toMatch(/<(img|iframe|link|object|embed)\b/i);
      expect(html).not.toContain("http://");
      expect(html).not.toContain("https://");
    }

    // Only the form page is interactive, and it carries exactly one hidden
    // input. Every other page — invalid, paused, error, rate-limited, and the
    // success page — has no active form at all.
    expect(pages.form.match(/<input/g)).toHaveLength(1);
    expect(pages.form).toContain('<input type="hidden" name="credential"');
    for (const [name, html] of Object.entries(pages)) {
      if (name === "form") continue;
      expect(html).not.toContain("<form");
      expect(html).not.toContain("<input");
    }
  });

  it("shows no address, credential, or internal vocabulary on any page", () => {
    for (const [name, html] of Object.entries(pages)) {
      if (name !== "form") {
        // The credential carries the subscriber id, so only the hidden field
        // on the form page may contain either.
        expect(html).not.toContain(VALID_CREDENTIAL);
        expect(html).not.toContain(SUBSCRIBER_ID);
      }
      expect(html).not.toContain(SUBSCRIBER_EMAIL);
      expect(html).not.toContain("@");
      expect(html).not.toMatch(/digest count|hash|Subscriber|database|status:/i);
    }
  });
});
