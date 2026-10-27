import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

/**
 * `app.ts` connects to MongoDB and listens at module scope, so it cannot be
 * imported into a test. These assertions check the wiring instead: that the
 * pause guard is mounted ahead of the limiter and handler on exactly the two
 * public mutations, that browsing routes are left alone, and that the digest
 * cron consults the pause before it can write a delivery record.
 *
 * `publicActionsPause.test.ts` covers what the guard itself does.
 */
const appSource = readFileSync(new URL("../app.ts", import.meta.url), "utf8");

function registrationLine(pattern: RegExp): string {
  const match = appSource.match(pattern);
  expect(match, `no registration matched ${pattern}`).not.toBeNull();
  return match![0];
}

describe("public action routes are mounted behind the pause", () => {
  it("guards POST /api/request before the limiter and handler", () => {
    const line = registrationLine(/app\.post\("\/api\/request",[^\n]*/);

    expect(line).toContain(
      "pauseRequestAction(CREATE_UNAVAILABLE_MESSAGE, \"PUBLIC_ACTIONS_PAUSED\")"
    );
    expect(line).toContain("createRequestRateLimiter");
    expect(line.indexOf("pauseRequestAction")).toBeLessThan(
      line.indexOf("createRequestRateLimiter")
    );
  });

  it("gives request creation its own envelope-emitting limiter", () => {
    const line = registrationLine(/app\.post\("\/api\/request",[^\n]*/);

    // The shared `limiter` answers with the rate-limit library's plain-string
    // body, which iOS cannot decode as an error envelope. On a non-idempotent
    // create POST an undecodable failure is treated as ambiguous, so a
    // throttled attempt would be reported as "your request may already exist".
    // The create bucket must be the one built from `day4Error`.
    expect(line).not.toMatch(/[^a-zA-Z]limiter[^a-zA-Z]/);

    const routeSource = readFileSync(
      new URL("./createRequestRoute.ts", import.meta.url),
      "utf8"
    );
    expect(routeSource).toContain(
      "export const createRequestRateLimiter = createDay4MutationRateLimiter(5)"
    );
  });

  it("guards POST /api/subscribe before the limiter and handler", () => {
    const line = registrationLine(/app\.post\('\/api\/subscribe',[^\n]*/);

    expect(line).toContain("pausePublicAction(SUBSCRIBE_UNAVAILABLE_MESSAGE)");
    expect(line.indexOf("pausePublicAction")).toBeLessThan(
      line.indexOf("limiter")
    );
    expect(line.indexOf("limiter")).toBeLessThan(line.lastIndexOf("subscribe"));
    expect(line).toContain("limiter, subscribe");
  });

  it("renders the confirmation GET behind headers and the HTML pause guard", () => {
    const registration = appSource.match(
      /app\.get\(\s*CONFIRMATION_ROUTE_PATH,[\s\S]*?\);/
    );

    expect(registration).not.toBeNull();
    const line = registration![0];
    expect(line).toContain("confirmationSecurityHeaders");
    expect(line).toContain("pauseConfirmationPage");
    expect(line).toContain("showConfirmationPage");
    expect(line.indexOf("confirmationSecurityHeaders")).toBeLessThan(
      line.indexOf("pauseConfirmationPage")
    );
    expect(line.indexOf("pauseConfirmationPage")).toBeLessThan(
      line.indexOf("showConfirmationPage")
    );
    // The GET only renders a form. Throttling it would refuse people whose
    // mail client prefetched the link, and it mutates nothing to protect.
    expect(line).not.toContain("confirmationRateLimiter");
    expect(line).not.toContain("pausePublicAction");
  });

  it("guards the confirmation POST before its own limiter, parser, and redemption", () => {
    const registration = appSource.match(
      /app\.post\(\s*CONFIRMATION_ROUTE_PATH,[\s\S]*?\);/
    );

    expect(registration).not.toBeNull();
    const line = registration![0];
    const order = [
      "confirmationSecurityHeaders",
      "pauseConfirmationPage",
      "confirmationRateLimiter",
      "confirmationBodyParser",
      "confirmSubscriptionPage",
      "confirmationParserError",
    ];
    const positions = order.map((name) => line.indexOf(name));
    expect(positions.every((index) => index > -1)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);

    // The confirmation POST answers in HTML, so it must not reuse the JSON
    // guard or spend the shared signup allowance.
    expect(line).not.toContain("pausePublicAction");
    expect(line).not.toMatch(/[^a-zA-Z]limiter[^a-zA-Z]/);
    // Route-local parsing is URL-encoded only: the accepted form submits
    // nothing else, and JSON must stay unparsed rather than error.
    expect(line).not.toContain("express.json");
  });

  it("registers the confirmation POST ahead of the global body parsers", () => {
    const confirmationPost = appSource.indexOf(
      "app.post(\n  CONFIRMATION_ROUTE_PATH"
    );
    const globalJson = appSource.indexOf("app.use(express.json(");
    const globalUrlencoded = appSource.indexOf("app.use(express.urlencoded(");

    expect(confirmationPost).toBeGreaterThan(-1);
    expect(globalJson).toBeGreaterThan(-1);
    expect(globalUrlencoded).toBeGreaterThan(-1);
    // A global parser runs before route middleware. Registered after them, a
    // body they rejected would be answered by the global JSON error handler —
    // outside this route's security headers, pause guard, and HTML contract,
    // and logged by a handler that prints the error.
    expect(confirmationPost).toBeLessThan(globalJson);
    expect(confirmationPost).toBeLessThan(globalUrlencoded);

    // The global parsers themselves are untouched for every other route.
    expect(appSource).toContain("app.use(express.json({ limit: '100kb' }));");
    expect(appSource).toContain(
      "app.use(express.urlencoded({ extended: true, limit: '100kb' }));"
    );
    expect(appSource.match(/app\.use\(express\.json\(/g)).toHaveLength(1);
    expect(appSource.match(/app\.use\(express\.urlencoded\(/g)).toHaveLength(1);
  });

  it("registers the confirmation flow from its own route module", () => {
    expect(appSource).toContain('from "./src/confirmSubscriptionRoute.js"');
    // Both halves of the browser flow share one locked path constant.
    expect(appSource).not.toContain('"/api/subscribe/confirm"');
    expect(
      appSource.match(/CONFIRMATION_ROUTE_PATH,/g)?.length
    ).toBeGreaterThanOrEqual(2);
  });

  it("leaves the shared signup limiter unchanged", () => {
    expect(appSource).toContain(
      "const limiter = rateLimit({ windowMs: 60_000, max: 5 })"
    );
    expect(appSource.match(/rateLimit\(/g)).toHaveLength(1);
  });

  it("registers the one persistent confirmation limiter, not a fresh instance", () => {
    // Tests build their own buckets through the factory; production must keep
    // a single instance, or each registration would start an empty window.
    expect(appSource).toContain("confirmationRateLimiter,");
    expect(appSource).not.toContain("createConfirmationRateLimiter");
  });

  it("renders the unsubscribe GET behind headers and the HTML pause guard", () => {
    const registration = appSource.match(
      /app\.get\(\s*UNSUBSCRIBE_ROUTE_PATH,[\s\S]*?\);/
    );

    expect(registration).not.toBeNull();
    const line = registration![0];
    const order = [
      "unsubscribeSecurityHeaders",
      "pauseUnsubscribePage",
      "showUnsubscribePage",
    ];
    const positions = order.map((name) => line.indexOf(name));
    expect(positions.every((index) => index > -1)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);

    // Opening an emailed link must not be throttled: mail clients prefetch,
    // and the GET renders a form rather than mutating anything.
    expect(line).not.toContain("unsubscribeRateLimiter");
    // The JSON guard would answer an emailed link with an error envelope.
    expect(line).not.toContain("pausePublicAction");
    expect(line).not.toContain("unsubscribePage,");
  });

  it("guards the unsubscribe POST before its own limiter, parser, and mutation", () => {
    const registration = appSource.match(
      /app\.post\(\s*UNSUBSCRIBE_ROUTE_PATH,[\s\S]*?\);/
    );

    expect(registration).not.toBeNull();
    const line = registration![0];
    const order = [
      "unsubscribeSecurityHeaders",
      "pauseUnsubscribePage",
      "unsubscribeRateLimiter",
      "unsubscribeBodyParser",
      "unsubscribePage",
      "unsubscribeParserError",
    ];
    const positions = order.map((name) => line.indexOf(name));
    expect(positions.every((index) => index > -1)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);

    expect(line).not.toContain("pausePublicAction");
    // Its own bucket: unsubscribing must not spend the signup allowance.
    expect(line).not.toMatch(/[^a-zA-Z]limiter[^a-zA-Z]/);
    expect(line).not.toContain("express.json");
  });

  it("registers the unsubscribe routes ahead of the global body parsers", () => {
    const unsubscribePost = appSource.indexOf(
      "app.post(\n  UNSUBSCRIBE_ROUTE_PATH"
    );
    const globalJson = appSource.indexOf("app.use(express.json(");
    const globalUrlencoded = appSource.indexOf("app.use(express.urlencoded(");

    expect(unsubscribePost).toBeGreaterThan(-1);
    // Same reason as the confirmation POST: a body a global parser rejected
    // would be answered outside this route's headers, pause guard, and HTML
    // contract, and logged by a handler that prints the error — and this
    // route's body carries the unsubscribe credential.
    expect(unsubscribePost).toBeLessThan(globalJson);
    expect(unsubscribePost).toBeLessThan(globalUrlencoded);
  });

  it("registers the unsubscribe flow from its own route module on one locked path", () => {
    expect(appSource).toContain('from "./src/unsubscribeRoute.js"');
    // Both halves share the constant the emailed link is built from, so a page
    // and a link can never drift onto different paths.
    expect(appSource).not.toContain('"/unsubscribe"');
    expect(
      appSource.match(/UNSUBSCRIBE_ROUTE_PATH,/g)?.length
    ).toBeGreaterThanOrEqual(2);
  });

  it("registers the one persistent unsubscribe limiter, not a fresh instance", () => {
    expect(appSource).toContain("unsubscribeRateLimiter,");
    expect(appSource).not.toContain("createUnsubscribeRateLimiter");
  });

  it("keeps alert delivery and signup paused now that unsubscribe is implemented", () => {
    // Redemption existing is not activation. Signup, confirmation, and both
    // send paths stay behind the pause until they are unpaused deliberately,
    // and the unsubscribe routes refuse while it holds like every other
    // emailed-link surface.
    const subscribeLine = registrationLine(
      /app\.post\('\/api\/subscribe',[^\n]*/
    );

    expect(subscribeLine).toContain("pausePublicAction");
    expect(subscribeLine.indexOf("pausePublicAction")).toBeLessThan(
      subscribeLine.indexOf("limiter")
    );
    expect(appSource).toContain('scheduleAppJob("5 * * * *"');
    expect(appSource).not.toContain("PUBLIC_ACTIONS_PAUSED=false");

    for (const registration of [
      appSource.match(/app\.get\(\s*UNSUBSCRIBE_ROUTE_PATH,[\s\S]*?\);/),
      appSource.match(/app\.post\(\s*UNSUBSCRIBE_ROUTE_PATH,[\s\S]*?\);/),
      appSource.match(/app\.get\(\s*CONFIRMATION_ROUTE_PATH,[\s\S]*?\);/),
      appSource.match(/app\.post\(\s*CONFIRMATION_ROUTE_PATH,[\s\S]*?\);/),
    ]) {
      expect(registration).not.toBeNull();
      expect(registration![0]).toMatch(/pause(Confirmation|Unsubscribe)Page/);
    }
  });

  it("keeps signup focused on pending confirmation without notification dispatch", () => {
    const routeSource = readFileSync(
      new URL("./subscribeRoute.ts", import.meta.url),
      "utf8"
    );
    const subscribeStart = appSource.indexOf("app.post('/api/subscribe'");
    const subscribeEnd = appSource.indexOf("// serve fulfill page", subscribeStart);
    const subscribeRegistration = appSource.slice(subscribeStart, subscribeEnd);

    expect(routeSource).not.toContain("notifySubscriberAboutRecentRequests");
    expect(routeSource).not.toContain("notifySubscribersForRequest");
    expect(subscribeRegistration).not.toContain("status = 'confirmed'");
    expect(subscribeRegistration).not.toContain("unsubToken");
    expect(subscribeRegistration).not.toContain("resend.emails.send");
  });

  it("leaves public browsing routes ungated", () => {
    const listRoute = registrationLine(/app\.get\("\/api\/requests",[^\n]*/);
    const detailRoute = registrationLine(
      /app\.get\("\/api\/request\/:id",[^\n]*/
    );

    expect(listRoute).not.toContain("pausePublicAction");
    expect(detailRoute).not.toContain("pausePublicAction");
  });

  it("exposes the pause state read-only for the web pages", () => {
    const statusRoute = registrationLine(
      /app\.get\("\/api\/public-actions",[^\n]*/
    );

    expect(statusRoute).not.toContain("pausePublicAction");
    expect(appSource).toContain("res.json({ paused: isPublicActionsPaused() })");
  });

  it("registers only the claim-authorized fulfillment handler", () => {
    // W4-H1a: the route owns its bounded body parser, so it is registered by
    // its own function (rate limiter, 3 MB parser, handler, parser-error
    // boundary — proven in `fulfillmentEvidenceRoute.test.ts`) AHEAD of the
    // global 100 KB parser. A second, plain registration would be refused by
    // that global parser first.
    expect(appSource.match(/registerFulfillmentRoute\(app\);/g)).toHaveLength(1);
    expect(appSource.indexOf("registerFulfillmentRoute(app);")).toBeLessThan(
      appSource.indexOf("app.use(express.json({ limit: '100kb' }));")
    );
    expect(appSource).not.toMatch(/app\.post\(\s*FULFILLMENT_ROUTE_PATH/);
    expect(appSource).not.toContain("registerFulfillmentPause");
    expect(appSource).not.toContain(
      'app.post("/api/request/:id/fulfill"'
    );
    // Still not paused: a helper holding a real order must be able to record it.
    const registration = appSource.slice(
      appSource.indexOf("registerFulfillmentRoute(app);") - 60,
      appSource.indexOf("registerFulfillmentRoute(app);") + 40
    );
    expect(registration).not.toContain("pausePublicAction");
  });

  it("guards claim and extension before independent rate-limit buckets", () => {
    const claimRoute = appSource.match(
      /app\.post\(\s*CLAIM_ROUTE_PATH,\s*pauseDay4Mutation,\s*claimRateLimiter,\s*claimRequest\s*\)/
    );
    const extensionRoute = appSource.match(
      /app\.post\(\s*CLAIM_EXTENSION_ROUTE_PATH,\s*pauseDay4Mutation,\s*claimExtensionRateLimiter,\s*extendClaim\s*\)/
    );

    expect(claimRoute).not.toBeNull();
    expect(extensionRoute).not.toBeNull();
    expect(claimRoute![0]).not.toContain("claimExtensionRateLimiter");
    expect(extensionRoute![0]).not.toContain("claimRateLimiter,");
  });

  it("removes the temporary unauthenticated DELETE route", () => {
    expect(appSource).not.toMatch(/app\.delete\(\s*["']\/api\/request\/:id/);
    expect(appSource).not.toContain("findByIdAndDelete");
  });

  it("uses effective availability for list and digest queries", () => {
    // The list handler lives in its own module since W4-R5; `app.ts` only
    // registers it.
    expect(appSource).toContain('app.get("/api/requests", getPublicRequestList)');
    const listFileSource = readFileSync(
      new URL("./requestListRoute.ts", import.meta.url),
      "utf8"
    );
    const digestStart = appSource.indexOf(
      'scheduleAppJob("5 * * * *"'
    );
    // The digest cron ends where the next cron begins. This sentinel must match
    // the real five-field expression in app.ts — a sentinel that is never found
    // yields -1 and silently widens the slice to almost the whole file.
    const digestEnd = appSource.indexOf(
      'scheduleAppJob("0 3 * * *"',
      digestStart
    );

    expect(digestStart).toBeGreaterThan(-1);
    expect(digestEnd).toBeGreaterThan(digestStart);

    const listSource = listFileSource;
    const digestSource = appSource.slice(digestStart, digestEnd);

    expect(listSource).toContain("buildEffectiveAvailabilityFilter(now)");
    expect(digestSource).toContain(
      "buildEffectiveAvailabilityFilter(digestNow)"
    );
    // Neither path may hand-roll an expiration bound: the five-minute minimum
    // that gates claiming lives in the shared helper, and a local `expiresAt`
    // clause here is exactly how the two would drift back apart.
    expect(listSource).not.toMatch(/expiresAt:\s*\{/);
    expect(digestSource).not.toMatch(/expiresAt:\s*\{/);
  });

  it("uses deleteAt for backup physical cleanup", () => {
    expect(appSource).toContain(
      "MealRequest.deleteMany({ deleteAt: { $lte: now } })"
    );
    expect(appSource).not.toContain(
      "MealRequest.deleteMany({ expiresAt: { $lte: now } })"
    );
  });

  it("checks the pause in the digest cron before any query or send", () => {
    const cronStart = appSource.indexOf('scheduleAppJob("5 * * * *"');
    const pauseCheck = appSource.indexOf("isPublicActionsPaused()", cronStart);
    const firstQuery = appSource.indexOf("MealRequest.find(", cronStart);
    const firstSend = appSource.indexOf("sendDigestEmail(", cronStart);
    const firstSendLogWrite = appSource.indexOf("SendLog.create(", cronStart);

    expect(cronStart).toBeGreaterThan(-1);
    expect(pauseCheck).toBeGreaterThan(cronStart);
    expect(pauseCheck).toBeLessThan(firstQuery);
    expect(pauseCheck).toBeLessThan(firstSend);
    expect(pauseCheck).toBeLessThan(firstSendLogWrite);
  });

  it("pins every digest eligibility predicate to the production query", () => {
    const digestStart = appSource.indexOf('scheduleAppJob("5 * * * *"');
    // Five-field cron, matching app.ts. A boundary that does not resolve would
    // silently widen the slice to the rest of the file, so both ends are
    // asserted before slicing: `status: "confirmed"` also appears in the daily
    // reset job and the active-subscriber-count route.
    const digestEnd = appSource.indexOf('scheduleAppJob("0 3 * * *"', digestStart);
    expect(digestStart).toBeGreaterThanOrEqual(0);
    expect(digestEnd).toBeGreaterThan(digestStart);
    const digestSource = appSource.slice(digestStart, digestEnd);

    const queryStart = digestSource.indexOf(
      "const eligible = await Subscriber.find({"
    );
    expect(queryStart).toBeGreaterThanOrEqual(0);
    const queryEnd = digestSource.indexOf("});", queryStart);
    expect(queryEnd).toBeGreaterThan(queryStart);
    const eligibilityQuery = digestSource.slice(queryStart, queryEnd);

    expect(eligibilityQuery).toContain('status: "confirmed"');
    expect(eligibilityQuery).not.toMatch(/status:\s*\{\s*\$in:/);

    // Status alone does not describe who receives a digest. A bounced address,
    // a subscriber already at the daily budget, or one still inside the hourly
    // cooldown must stay out too, so every predicate is pinned here: dropping
    // any one of them silently widens the send set without failing a test.
    expect(eligibilityQuery).toMatch(/bounced:\s*false/);
    expect(eligibilityQuery).toMatch(/dailyCount:\s*\{\s*\$lt:\s*4\s*\}/);

    // Both cooldown alternatives, matching app.ts: a subscriber who has never
    // been sent to (`lastSentAt: null`) or whose last send precedes the hourly
    // window. Losing either branch drops or over-sends a whole cohort.
    expect(eligibilityQuery).toMatch(/\$or:\s*\[/);
    expect(eligibilityQuery).toMatch(
      /\{\s*lastSentAt:\s*\{\s*\$lt:\s*oneHourAgo\s*\}\s*\}/
    );
    expect(eligibilityQuery).toMatch(/\{\s*lastSentAt:\s*null\s*\}/);
  });
});
