import { readFileSync } from "node:fs";
import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Participant,
  ParticipantBlock,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_AUTHORITY_INVALID_CODE,
  PARTICIPANT_AUTHORITY_INVALID_MESSAGE,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
  PARTICIPANT_VERIFICATION_REQUIRED_MESSAGE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS } from "./participantIdentityKeys.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";
import { getPublicRequestList } from "./requestListRoute.js";
import * as requestParticipation from "./requestParticipation.js";

/**
 * W4-R5 verified-only gate on exactly `GET /api/requests` and
 * `GET /api/request/:id`.
 *
 * Both handlers are driven directly (the list handler was extracted from
 * `app.ts` so it is executable here). The proof is the contract's: every
 * unusable-credential state is refused with the shared structured envelope,
 * the refusal is identical whatever the id is, no request-dependent lookup runs
 * before the gate, and no credential reaches a log. Persisted revocation and
 * replacement are proven against real MongoDB in `requestReadGate.mongo.test.ts`.
 */

const SECRET_TEXT = "request-read-gate-unit-secret-32-bytes!!";
const FOREIGN_SECRET = Buffer.from("another-deployments-signing-secret-xx");
const appSource = readFileSync(new URL("../app.ts", import.meta.url), "utf8");
const healthSource = readFileSync(
  new URL("./healthRoutes.ts", import.meta.url),
  "utf8"
);
const PARTICIPANT_ID = new mongoose.Types.ObjectId("64f0000000000000000000e1");
const VALID_AUTHORITY = signParticipantAuthority(
  PARTICIPANT_ID,
  1,
  Buffer.from(SECRET_TEXT)
);
const REQUEST_ID = "64b000000000000000000001";

type HandlerResult = {
  status: number | undefined;
  body: unknown;
  setHeaders: Record<string, string>;
  next: ReturnType<typeof vi.fn>;
  jsonCalls: unknown[][];
};

function makeResponse() {
  const setHeaders: Record<string, string> = {};
  const result: HandlerResult = {
    status: undefined,
    body: undefined,
    setHeaders,
    next: vi.fn(),
    jsonCalls: [],
  };
  const res = {
    status: vi.fn((value: number) => {
      result.status = value;
      return res;
    }),
    json: vi.fn((value: unknown) => {
      result.body = value;
      result.jsonCalls.push([value]);
      return res;
    }),
    setHeader: vi.fn((name: string, value: string) => {
      setHeaders[name] = value;
    }),
  } as unknown as Response;
  return { res, result };
}

async function callDetail(
  id: string,
  headers: Record<string, string>
): Promise<HandlerResult> {
  const { res, result } = makeResponse();
  const req = { params: { id }, headers } as unknown as Request;
  await getPublicRequestDetail(req, res, result.next as unknown as NextFunction);
  return result;
}

async function callList(headers: Record<string, string>): Promise<HandlerResult> {
  const { res, result } = makeResponse();
  const req = { params: {}, headers } as unknown as Request;
  await getPublicRequestList(req, res, result.next as unknown as NextFunction);
  return result;
}

function stubParticipant(
  resolve: (filter: Record<string, unknown>) => unknown | Promise<unknown>
) {
  return vi.spyOn(Participant, "findOne").mockImplementation(((
    filter: Record<string, unknown>
  ) => ({
    select: () => ({
      lean: () => ({
        exec: async () => resolve(filter),
      }),
    }),
  })) as unknown as typeof Participant.findOne);
}

/** Spies on every request-dependent read so "no lookup ran" is assertable. */
function spyOnRequestDependentReads() {
  return {
    find: vi.spyOn(MealRequest, "find"),
    findById: vi.spyOn(MealRequest, "findById"),
    participation: vi.spyOn(RequestParticipation, "find"),
    blockFind: vi.spyOn(ParticipantBlock, "find"),
    blockFindOne: vi.spyOn(ParticipantBlock, "findOne"),
  };
}

function expectNoRequestDependentRead(
  spies: ReturnType<typeof spyOnRequestDependentReads>
) {
  for (const spy of Object.values(spies)) {
    expect(spy).not.toHaveBeenCalled();
  }
}

function refusalBody(code: string, message: string) {
  return { error: { code, message, fields: null } };
}

const REFUSAL_SCENARIOS: Array<{
  name: string;
  headers: () => Record<string, string>;
  arrange?: () => void;
  status: number;
  code: string;
  message: string;
}> = [
  {
    name: "a missing credential",
    headers: () => ({}),
    status: 401,
    code: PARTICIPANT_VERIFICATION_REQUIRED_CODE,
    message: PARTICIPANT_VERIFICATION_REQUIRED_MESSAGE,
  },
  {
    name: "an empty credential",
    headers: () => ({ [PARTICIPANT_AUTHORITY_HEADER]: "" }),
    status: 401,
    code: PARTICIPANT_VERIFICATION_REQUIRED_CODE,
    message: PARTICIPANT_VERIFICATION_REQUIRED_MESSAGE,
  },
  {
    name: "a malformed credential",
    headers: () => ({ [PARTICIPANT_AUTHORITY_HEADER]: "not-a-credential" }),
    status: 401,
    code: PARTICIPANT_AUTHORITY_INVALID_CODE,
    message: PARTICIPANT_AUTHORITY_INVALID_MESSAGE,
  },
  {
    name: "an unsigned credential",
    headers: () => ({
      [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY.split(".")[0] ?? "x",
    }),
    status: 401,
    code: PARTICIPANT_AUTHORITY_INVALID_CODE,
    message: PARTICIPANT_AUTHORITY_INVALID_MESSAGE,
  },
  {
    name: "a credential signed by another deployment's secret",
    headers: () => ({
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
        PARTICIPANT_ID,
        1,
        FOREIGN_SECRET
      ),
    }),
    status: 401,
    code: PARTICIPANT_AUTHORITY_INVALID_CODE,
    message: PARTICIPANT_AUTHORITY_INVALID_MESSAGE,
  },
  {
    name: "a well-signed credential naming no such participant",
    headers: () => ({ [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY }),
    arrange: () => {
      stubParticipant(() => null);
    },
    status: 401,
    code: PARTICIPANT_AUTHORITY_INVALID_CODE,
    message: PARTICIPANT_AUTHORITY_INVALID_MESSAGE,
  },
  {
    name: "a credential signed at a revoked authority version",
    headers: () => ({ [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY }),
    arrange: () => {
      // The persisted participant is now at version 2; the lookup is bound to
      // the version the credential was signed at, so it finds nothing.
      stubParticipant((filter) =>
        filter.authorityVersion === 2
          ? { _id: PARTICIPANT_ID, email: "reader@nyu.edu" }
          : null
      );
    },
    status: 401,
    code: PARTICIPANT_AUTHORITY_INVALID_CODE,
    message: PARTICIPANT_AUTHORITY_INVALID_MESSAGE,
  },
  {
    name: "a credential whose stored principal is no longer eligible",
    headers: () => ({ [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY }),
    arrange: () => {
      stubParticipant(() => ({
        _id: PARTICIPANT_ID,
        email: "someone@gmail.com",
      }));
    },
    status: 401,
    code: PARTICIPANT_AUTHORITY_INVALID_CODE,
    message: PARTICIPANT_AUTHORITY_INVALID_MESSAGE,
  },
  {
    name: "a gate that cannot read its signing secret",
    headers: () => ({ [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY }),
    arrange: () => {
      vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, "");
    },
    status: 503,
    code: PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
    message: PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  },
  {
    name: "a participant lookup that fails",
    headers: () => ({ [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY }),
    arrange: () => {
      stubParticipant(() => {
        throw new Error("database unavailable");
      });
    },
    status: 503,
    code: PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
    message: PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  },
];

beforeEach(() => {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, SECRET_TEXT);
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("W4-R5 verified-only request reads: refusals", () => {
  for (const scenario of REFUSAL_SCENARIOS) {
    describe(`with ${scenario.name}`, () => {
      it("refuses GET /api/requests with the shared envelope and no request lookup", async () => {
        scenario.arrange?.();
        const spies = spyOnRequestDependentReads();

        const result = await callList(scenario.headers());

        expect(result.status).toBe(scenario.status);
        expect(result.body).toEqual(refusalBody(scenario.code, scenario.message));
        expect(result.next).not.toHaveBeenCalled();
        expectNoRequestDependentRead(spies);
      });

      it("refuses GET /api/request/:id with the shared envelope and no request lookup", async () => {
        scenario.arrange?.();
        const spies = spyOnRequestDependentReads();

        const result = await callDetail(REQUEST_ID, scenario.headers());

        expect(result.status).toBe(scenario.status);
        expect(result.body).toEqual(refusalBody(scenario.code, scenario.message));
        expect(result.next).not.toHaveBeenCalled();
        expectNoRequestDependentRead(spies);
      });

      it("never lets a refusal be cached or reused across callers", async () => {
        scenario.arrange?.();

        const list = await callList(scenario.headers());
        const detail = await callDetail(REQUEST_ID, scenario.headers());

        for (const result of [list, detail]) {
          expect(result.setHeaders["Cache-Control"]).toBe("private, no-store");
          expect(result.setHeaders["Vary"]).toBe(PARTICIPANT_AUTHORITY_HEADER);
        }
      });

      it("answers a direct request id identically whether or not it exists, is fenced, or is not yet visible", async () => {
        scenario.arrange?.();
        const spies = spyOnRequestDependentReads();
        const ids = [
          REQUEST_ID, // a request that exists
          "64b0000000000000000000ff", // a request that does not
          "64b0000000000000000000aa", // stands for a fenced counterpart's
          "64b0000000000000000000bb", // stands for a not-yet-visible one
          "not-an-object-id", // not even a valid id
        ];

        const results = [];
        for (const id of ids) {
          results.push(await callDetail(id, scenario.headers()));
        }

        for (const result of results) {
          expect(result.status).toBe(results[0].status);
          expect(result.body).toEqual(results[0].body);
        }
        // Not even id validation (400) distinguishes the ids.
        expect(results[4].status).toBe(scenario.status);
        expectNoRequestDependentRead(spies);
      });
    });
  }

  it("carries no request content or participant material in any refusal", async () => {
    for (const scenario of REFUSAL_SCENARIOS) {
      scenario.arrange?.();
      for (const result of [
        await callList(scenario.headers()),
        await callDetail(REQUEST_ID, scenario.headers()),
      ]) {
        const serialized = JSON.stringify(result.body);
        expect(serialized).not.toMatch(
          /vendor|food|pickup|claimToken|participantId|requesterParticipantId|isOwnRequest|alreadyParticipated|"request"/
        );
        expect(serialized).not.toContain(REQUEST_ID);
      }
      vi.restoreAllMocks();
      vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, SECRET_TEXT);
    }
  });

  it("logs no credential, secret, or protected data on any refusal", async () => {
    const sinks = [
      vi.spyOn(console, "log").mockImplementation(() => undefined),
      vi.spyOn(console, "info").mockImplementation(() => undefined),
      vi.spyOn(console, "warn").mockImplementation(() => undefined),
      vi.spyOn(console, "error").mockImplementation(() => undefined),
    ];

    for (const scenario of REFUSAL_SCENARIOS) {
      scenario.arrange?.();
      await callList(scenario.headers());
      await callDetail(REQUEST_ID, scenario.headers());
      vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, SECRET_TEXT);
    }

    const logged = sinks
      .flatMap((sink) => sink.mock.calls)
      .map((args) => args.map(String).join(" "))
      .join("\n");
    expect(logged).not.toContain(VALID_AUTHORITY);
    expect(logged).not.toContain(SECRET_TEXT);
    expect(logged).not.toContain("not-a-credential");
    expect(logged).not.toContain(REQUEST_ID);
  });
});

describe("W4-R5 verified-only request reads: a verified caller", () => {
  it("is served the list, caller-specific and uncacheable, through the pair fence", async () => {
    stubParticipant(() => ({ _id: PARTICIPANT_ID, email: "reader@nyu.edu" }));
    const fencedCounterpart = new mongoose.Types.ObjectId(
      "64f0000000000000000000e2"
    );
    const blockQuery = {
      maxTimeMS: vi.fn(),
      select: () => blockQuery,
      lean: () => blockQuery,
      exec: async () => [
        {
          blockerParticipantId: PARTICIPANT_ID,
          blockedParticipantId: fencedCounterpart,
        },
      ],
    };
    vi.spyOn(ParticipantBlock, "find").mockReturnValue(
      blockQuery as unknown as ReturnType<typeof ParticipantBlock.find>
    );
    const aggregate = vi.spyOn(MealRequest, "aggregate").mockReturnValue({
      option: () => ({ exec: async () => [] }),
    } as unknown as ReturnType<typeof MealRequest.aggregate>);
    vi.spyOn(
      requestParticipation,
      "findParticipatedRequestIds"
    ).mockResolvedValue(new Set());

    const result = await callList({
      [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY,
    });

    expect(result.status).toBeUndefined();
    expect(result.body).toEqual({ requests: [] });
    expect(result.setHeaders["Cache-Control"]).toBe("private, no-store");
    expect(result.setHeaders["Vary"]).toBe(PARTICIPANT_AUTHORITY_HEADER);
    expect(blockQuery.maxTimeMS).toHaveBeenCalledWith(
      PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS
    );
    // The U1.3 fence is applied in the query itself, ahead of the limit.
    expect(aggregate.mock.calls[0]?.[0]?.[0]).toHaveProperty(
      "$match.requesterParticipantId.$nin"
    );
  });

  it("abandons list enforcement when canceled during the bounded pair-fence read", async () => {
    stubParticipant(() => ({ _id: PARTICIPANT_ID, email: "reader@nyu.edu" }));
    let resolveFenceRows!: (rows: unknown[]) => void;
    const fenceReadStarted = vi.fn();
    const blockQuery = {
      maxTimeMS: vi.fn(),
      select: () => blockQuery,
      lean: () => blockQuery,
      exec: () => {
        fenceReadStarted();
        return new Promise<unknown[]>((resolve) => {
          resolveFenceRows = resolve;
        });
      },
    };
    vi.spyOn(ParticipantBlock, "find").mockReturnValue(
      blockQuery as unknown as ReturnType<typeof ParticipantBlock.find>
    );
    const aggregate = vi.spyOn(MealRequest, "aggregate");
    const req = {
      params: {},
      headers: { [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY },
      aborted: false,
    } as unknown as Request;
    const { res, result } = makeResponse();

    const pending = getPublicRequestList(
      req,
      res,
      result.next as unknown as NextFunction
    );
    await vi.waitFor(() => expect(fenceReadStarted).toHaveBeenCalledOnce());
    req.aborted = true;
    resolveFenceRows([]);
    await pending;

    expect(blockQuery.maxTimeMS).toHaveBeenCalledWith(
      PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS
    );
    expect(aggregate).not.toHaveBeenCalled();
    expect(result.status).toBe(503);
    expect(result.body).not.toHaveProperty("requests");
  });

  it("delegates a downstream failure to the shared error handler after the gate", async () => {
    stubParticipant(() => ({ _id: PARTICIPANT_ID, email: "reader@nyu.edu" }));
    vi.spyOn(ParticipantBlock, "find").mockImplementation((() => {
      throw new Error("block lookup failed");
    }) as never);

    const result = await callList({
      [PARTICIPANT_AUTHORITY_HEADER]: VALID_AUTHORITY,
    });

    expect(result.next).toHaveBeenCalledTimes(1);
    expect(result.jsonCalls).toHaveLength(0);
  });
});

describe("W4-R5 verified-only request reads: wiring by source", () => {
  const read = (path: string) =>
    readFileSync(new URL(path, import.meta.url), "utf8");
  const appSource = read("../app.ts");
  const detailSource = read("./requestDetailRoute.ts");
  const listSource = read("./requestListRoute.ts");
  const participationSource = read("./requestParticipation.ts");

  it("registers exactly the two gated handlers in app.ts", () => {
    expect(appSource).toContain('app.get("/api/requests", getPublicRequestList);');
    expect(appSource).toContain('app.get("/api/request/:id", getPublicRequestDetail);');
  });

  it("resolves authority before id validation or any request-dependent work", () => {
    const gate = detailSource.indexOf("requireVerifiedCallerForRead(req, res)");
    expect(gate).toBeGreaterThan(-1);
    for (const later of [
      "isValid(",
      "MealRequest.findById(",
      "isParticipantPairFenced(",
      "isVisibleNow(",
      "findParticipatedRequestIds(",
    ]) {
      expect(detailSource.indexOf(later), later).toBeGreaterThan(gate);
    }

    const listGate = listSource.indexOf("requireVerifiedCallerForRead(req, res)");
    expect(listGate).toBeGreaterThan(-1);
    for (const later of [
      "buildParticipantFenceFilter(",
      "const visibleDocs = await scanParticipationAwareRequests(",
    ]) {
      expect(listSource.indexOf(later), later).toBeGreaterThan(listGate);
    }
    expect(listSource).toContain("MealRequest.aggregate(pipeline)");
  });

  it("keeps no permissive fallback: the browse resolver and anonymous contexts are gone from both routes", () => {
    for (const source of [appSource, detailSource, listSource]) {
      expect(source).not.toContain("resolveCallerForBrowse");
      expect(source).not.toContain("resolveOptionalParticipantAuthority");
      expect(source).not.toContain('kind: "anonymous"');
      expect(source).not.toContain('kind: "unresolved"');
    }
    expect(participationSource).not.toContain("resolveCallerForBrowse");
  });

  it("sets the refusal's no-store headers inside the gate, ahead of the refusal", () => {
    const gate = participationSource.slice(
      participationSource.indexOf("export async function requireVerifiedCallerForRead")
    );
    expect(gate.indexOf('"Cache-Control", "private, no-store"')).toBeLessThan(
      gate.indexOf("sendParticipantAuthorityRefusal(")
    );
    expect(gate).toContain("PARTICIPANT_AUTHORITY_HEADER");
  });

  it("leaves the public aggregates, signup, health and static shells unregistered behind the gate", () => {
    for (const path of [
      '"/api/stats"',
      '"/api/active-subscriber-count"',
      '"/api/public-actions"',
      '"/health"',
    ]) {
      const source = path === '"/health"' ? healthSource : appSource;
      const registration = source.indexOf(`app.get(${path}`);
      expect(registration, `no registration for ${path}`).toBeGreaterThan(-1);
      const line = source.slice(registration, source.indexOf("\n", registration));
      expect(line).not.toContain("requireVerifiedCallerForRead");
    }
    expect(appSource).not.toMatch(/app\.(use|all)\([^)]*requireVerifiedCallerForRead/);
  });
});
