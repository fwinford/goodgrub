import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";
import { pauseDay4Mutation } from "./claimRoute.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";

/**
 * `app.ts` cannot be imported into a test (it connects and listens at module
 * scope), so the W4-U1.3 wiring is asserted from source, like the other
 * route-registration suites. Behavior is covered by
 * `participantBlock.mongo.test.ts`.
 */
const appSource = readFileSync(new URL("../app.ts", import.meta.url), "utf8");
const routeSource = readFileSync(
  new URL("./participantBlockRoute.ts", import.meta.url),
  "utf8"
);
const claimSource = readFileSync(
  new URL("./claimRoute.ts", import.meta.url),
  "utf8"
);
const fulfillmentSource = readFileSync(
  new URL("./fulfillmentRoute.ts", import.meta.url),
  "utf8"
);
const listResponseSource = readFileSync(
  new URL("./requestListResponse.ts", import.meta.url),
  "utf8"
);
const reservationSource = readFileSync(
  new URL("./reservationRoute.ts", import.meta.url),
  "utf8"
);
// The request list handler moved out of `app.ts` into its own module when
// W4-R5 made it executable-testable; the assertions below are unchanged.
const requestListSource = readFileSync(
  new URL("./requestListRoute.ts", import.meta.url),
  "utf8"
);

function registration(path: string, method: "post" | "get" | "delete") {
  const start = appSource.indexOf(`app.${method}(\n  ${path}`);
  expect(start, `no ${method} registration for ${path}`).toBeGreaterThan(-1);
  return appSource.slice(start, appSource.indexOf(");", start));
}

describe("W4-U1.3 route registration", () => {
  it("leaves Block, Unblock, and the list out of the operational pause", () => {
    // Accepted 2026-10-13 clarification: safety controls are not generally
    // disabled by PUBLIC_ACTIONS_PAUSED. Only the release inside the `No`
    // branch is pause-governed, and the handler checks that itself.
    for (const [path, method] of [
      ["REQUEST_BLOCK_ROUTE_PATH", "post"],
      ["PARTICIPANT_BLOCK_ROUTE_PATH", "delete"],
      ["PARTICIPANT_BLOCKS_ROUTE_PATH", "get"],
    ] as const) {
      const line = registration(path, method);
      expect(line, `${path} must not be behind the pause`).not.toMatch(
        /pauseDay4Mutation|pausePublicAction/
      );
    }
  });

  it("keeps the existing pause on Claim, Extend, and direct Release, ahead of their limiters", () => {
    for (const [path, limiter] of [
      ["CLAIM_ROUTE_PATH", "claimRateLimiter"],
      ["CLAIM_EXTENSION_ROUTE_PATH", "claimExtensionRateLimiter"],
      ["CLAIM_RELEASE_ROUTE_PATH", "claimReleaseRateLimiter"],
    ] as const) {
      const line = registration(path, "post");
      expect(line).toContain("pauseDay4Mutation");
      expect(line.indexOf("pauseDay4Mutation")).toBeLessThan(line.indexOf(limiter));
    }
  });

  it("checks the release pause itself, before the first write of the No branch", () => {
    const attempt = routeSource.slice(
      routeSource.indexOf("async function attemptCreateBlock"),
      routeSource.indexOf("/** `POST /api/request/:id/block` */")
    );
    const guard = attempt.indexOf("throw new ReservationReleasePaused()");
    expect(guard).toBeGreaterThan(-1);
    // Only the `No` answer on a live reservation is paused.
    expect(attempt.slice(guard - 220, guard)).toMatch(
      /heldReservation &&\s+externalOrderPlaced === false &&\s+isPublicActionsPaused\(\)/
    );
    expect(guard).toBeLessThan(attempt.indexOf("ParticipantBlock.findOneAndUpdate"));
    expect(guard).toBeLessThan(attempt.indexOf("bumpBlockFence("));
    expect(guard).toBeLessThan(attempt.indexOf("releaseReservationWithinSession(session"));
  });

  it("establishes the block uniqueness index before accepting traffic", () => {
    const index = appSource.indexOf("await ParticipantBlock.createIndexes()");
    const listen = appSource.indexOf("app.listen(");
    expect(index).toBeGreaterThan(-1);
    expect(index).toBeLessThan(listen);
  });

  it("applies the participant-pair fence in the board query, ahead of the limit", () => {
    expect(appSource).toContain('app.get("/api/requests", getPublicRequestList)');
    const board = requestListSource;
    expect(board).toContain("buildParticipantFenceFilter");
    expect(board.indexOf("buildParticipantFenceFilter")).toBeLessThan(
      board.indexOf("$limit: PARTICIPATION_SCAN_PAGE_SIZE")
    );
    expect(board).toContain("...fenceFilter");
    expect(board).toContain("PARTICIPATION_SCAN_PAGE_SIZE = 200");
  });
});

describe("W4-U1.3 authority boundaries by source", () => {
  it("accepts no participant identifier, address, or search on the block route", () => {
    expect(routeSource).toContain(".strict()");
    // The only accepted body field is the external-order answer.
    expect(routeSource).toMatch(
      /z\s*\.object\(\{\s*(?:\/\*\*[\s\S]*?\*\/\s*)?externalOrderPlaced: z\.boolean\(\)\.optional\(\),\s*\}\)\s*\.strict\(\)/
    );
    expect(routeSource).not.toMatch(/req\.(body|query)\.(participant|email)/);
  });

  it("never selects or serializes a participant id onto a response", () => {
    const serializer = routeSource.slice(
      routeSource.indexOf("function toPublicBlock"),
      routeSource.indexOf("function isDuplicateKeyError")
    );
    expect(serializer).not.toMatch(/ParticipantId|email/i);
  });

  it("reuses the one accepted release mutation rather than a second implementation", () => {
    expect(routeSource).toContain("releaseReservationWithinSession");
    expect(claimSource).toContain(
      "export async function releaseReservationWithinSession"
    );
    // One declaration of the retired reservation fields, shared by the
    // ordinary release and the W4-U1.2/U1.3 retire-in-place branch inside
    // that one function, so the two can never diverge about what a release
    // removes. The reopen branch additionally unsets L on a confirmed No, via
    // a spread of the same shared declaration — not a second one.
    expect(claimSource.match(/claimedAt: 1,/g)?.length).toBe(1);
    const mutation = claimSource.slice(
      claimSource.indexOf("export async function releaseReservationWithinSession"),
      claimSource.indexOf("export async function releaseClaim")
    );
    expect(mutation).toContain("...retiredFields,");
    expect(mutation).toContain("$unset: reopenUnset");
    expect(mutation.match(/\$unset: retiredFields/g)?.length).toBe(1);
    expect(mutation).toContain("externalOrderAffirmed: { $ne: true }");
    expect(mutation).toContain("externalOrderAffirmed: true");
    // W4-U1.2 (boundary contract EO): M and L fold into the same mutation
    // rather than a parallel implementation.
    expect(mutation).toContain("moderationUnavailable: { $ne: true }");
    expect(mutation).toContain("moderationUnavailable: true");
  });

  it("never gates placement on a block: the fulfillment filter and refusals are unchanged", () => {
    const filter = fulfillmentSource.slice(
      fulfillmentSource.indexOf("placedRequest = await MealRequest.findOneAndUpdate("),
      fulfillmentSource.indexOf("if (!placedRequest) {")
    );
    expect(filter).not.toMatch(/block|fence/i);
    expect(fulfillmentSource).not.toMatch(/REQUEST_NOT_FOUND[\s\S]{0,200}fence/);
  });
});

describe("the existing Day-4 pause gate is unchanged", () => {
  afterEach(() => vi.unstubAllEnvs());

  function run() {
    const next = vi.fn();
    const json = vi.fn();
    const status = vi.fn(() => ({ json }));
    pauseDay4Mutation({} as never, { status } as never, next);
    return { next, json, status };
  }

  it("refuses with PUBLIC_ACTIONS_PAUSED while paused and passes through otherwise", () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    const paused = run();
    expect(paused.next).not.toHaveBeenCalled();
    expect(paused.status).toHaveBeenCalledWith(503);
    expect(paused.json.mock.calls[0][0].error.code).toBe("PUBLIC_ACTIONS_PAUSED");

    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
    expect(run().next).toHaveBeenCalledOnce();
  });
});

describe("W4-U1.3 post-Block autonomy authority boundaries by source", () => {
  it("leaves extension to the ordinary rules: the extension mutation never consults the pair fence", () => {
    const extension = claimSource.slice(
      claimSource.indexOf("export async function extendClaim"),
      claimSource.indexOf("async function explainReleaseFailure")
    );
    expect(extension.length).toBeGreaterThan(500);
    expect(extension).not.toMatch(/isParticipantPairFenced|BlockedPair/);
    expect(extension).toContain(
      '.select("+requesterParticipantId +helperParticipantId")'
    );
    expect(extension).toContain("fenceReservationParticipants(");
    // New claims remain fenced.
    const claim = claimSource.slice(
      claimSource.indexOf("export async function claimRequest"),
      claimSource.indexOf("export type ClaimActionAuthorization")
    );
    expect(claim).toContain("isParticipantPairFenced");
  });

  it("writes the post-Yes authority inside the Block's own transaction, pinned to the caller's live reservation", () => {
    const attempt = routeSource.slice(
      routeSource.indexOf("async function attemptCreateBlock"),
      routeSource.indexOf("/** `POST /api/request/:id/block` */")
    );
    const transaction = attempt.indexOf("session.withTransaction(");
    const marker = attempt.indexOf("externalOrderAffirmed: true");
    const blockRow = attempt.indexOf("ParticipantBlock.findOneAndUpdate");
    expect(transaction).toBeGreaterThan(-1);
    expect(marker).toBeGreaterThan(transaction);
    expect(marker).toBeGreaterThan(blockRow);
    const write = attempt.slice(marker - 400, marker + 200);
    expect(write).toContain("MealRequest.updateOne(");
    expect(write).toContain("{ session }");
    expect(write).toMatch(/status: "claimed"/);
    expect(write).toMatch(/helperParticipantId: callerId/);
    // Pinned to the exact reservation the snapshot read: its binding and its
    // deadline, not "any live reservation".
    expect(write).toMatch(/claimExpiresAt: request\.claimExpiresAt/);
    // A Yes that could not be made durable refuses the whole Block.
    expect(attempt.slice(marker, marker + 800)).toContain(
      "throw new ReservationStateChanged()"
    );
    // Only a Yes writes it; a No never does.
    expect(attempt.slice(marker - 1200, marker + 20)).toMatch(
      /boundToCaller && externalOrderPlaced === true/
    );
  });

  it("keeps the authority out of every projection, response and log", () => {
    const projection = listResponseSource.slice(
      listResponseSource.indexOf("export function mapPublicRequestFields"),
      listResponseSource.indexOf("export function buildPublicRequestDetailResponse")
    );
    expect(projection).not.toMatch(/externalOrderAffirmed/);
    // The active-reservation read (C3) may read the authority only inside its
    // own live-reservation branch, to derive the one gated Stop consequence;
    // the placed read never selects it, and no response object names it.
    const liveStart = reservationSource.indexOf("const document = await MealRequest.findOne({");
    const liveEnd = reservationSource.indexOf("placement: null,", liveStart);
    const live = reservationSource.slice(liveStart, liveEnd);
    expect(liveStart).toBeGreaterThan(-1);
    expect(live.match(/externalOrderAffirmed/g)?.length).toBe(
      reservationSource.match(/externalOrderAffirmed/g)?.length
    );
    expect(live).toContain(
      '"+requesterParticipantId +externalOrderAffirmed +reservationLapseHold"'
    );
    expect(live).toMatch(
      /const stopReturnsHome =\s*!directContactRestricted &&\s*\(document as unknown as \{ externalOrderAffirmed\?: unknown \}\)\s*\.externalOrderAffirmed === true;/
    );
    expect(live).toContain("...(stopReturnsHome ? { stopReturnsHome: true } : {}),");
    expect(reservationSource).not.toMatch(/externalOrderAffirmed[^\n]*[:,]\s*$/m);
    expect(reservationSource).toContain(
      '.select("+contactMessageSuppressed +contactMessageWithheld")'
    );
    for (const source of [claimSource, routeSource, fulfillmentSource]) {
      for (const log of source.match(/console\.(error|log|info|warn)\([^)]*\)/g) ??
        []) {
        expect(log).not.toMatch(/externalOrderAffirmed|affirm/i);
      }
    }
    // Never selected by a public-facing read except the two effective-status
    // derivations, and never copied onto a response object.
    expect(routeSource).not.toMatch(/res\.json\([^)]*externalOrderAffirmed/);
  });

  it("refuses a Yes that is not bound to the caller before the first write of the Block transaction (C1)", () => {
    const attempt = routeSource.slice(
      routeSource.indexOf("async function attemptCreateBlock"),
      routeSource.indexOf("/** `POST /api/request/:id/block` */")
    );
    const transaction = attempt.indexOf("session.withTransaction(");
    const refusal = attempt.search(
      /if \(\s*!callerIsRequester &&\s*externalOrderPlaced === true &&\s*\(!boundToCaller \|\|/
    );
    const blockRow = attempt.indexOf("ParticipantBlock.findOneAndUpdate");
    const fence = attempt.indexOf("await bumpBlockFence(");
    const marker = attempt.indexOf("externalOrderAffirmed: true");
    expect(refusal).toBeGreaterThan(transaction);
    expect(refusal).toBeLessThan(blockRow);
    expect(refusal).toBeLessThan(fence);
    expect(refusal).toBeLessThan(marker);
    expect(attempt.slice(refusal, refusal + 300)).toContain(
      "throw new ReservationStateChanged()"
    );
    // The request deadline is part of the same check.
    expect(attempt.slice(refusal, refusal + 300)).toMatch(
      /request\.expiresAt\.getTime\(\) <= now\.getTime\(\)/
    );
  });

  it("applies the authority as a predicate everywhere a request can be offered or claimed", () => {
    const availability = readFileSync(
      new URL("./requestAvailability.ts", import.meta.url),
      "utf8"
    );
    expect(availability).toContain("externalOrderAffirmed: { $ne: true }");
    expect(availability).toMatch(/externalOrderAffirmed === true/);
    // The claim grant itself carries it inside the conditional mutation.
    const grantStart = claimSource.indexOf("await MealRequest.findOneAndUpdate(");
    const grant = claimSource.slice(
      grantStart,
      claimSource.indexOf("if (!document) {", grantStart)
    );
    expect(grant).toContain("externalOrderAffirmed: { $ne: true }");
  });
});
