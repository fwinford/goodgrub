import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("./emailHelpers.js", () => ({
  sendParticipantVerificationEmail: vi.fn(),
}));

// This route layer stubs the obligation read and the Participant/Verification
// models directly; it never exercises a real Mongo session. Without this
// mock, participantVerification's redeem path calls the real
// runModerationTransaction, which opens an actual mongoose session and hangs
// in a unit run with no replica set.
vi.mock("./safetyIdentity.js", () => ({
  runModerationTransaction: async (work: (session: unknown) => unknown) => work(undefined),
  checkParticipantCreationRestriction: async () => ({ restricted: false, identityId: null }),
}));

import {
  EMAIL_REPLACEMENT_BLOCKED_CODE,
  createEmailReplacementEligibilityHandler,
  type EmailReplacementBlocker,
  type EmailReplacementGateDependencies,
} from "./emailReplacementGate.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import { MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES } from "./participantCredentials.js";
import type { ParticipantVerificationDependencies } from "./participantVerification.js";
import {
  createRedeemParticipantVerificationHandler,
  createStartParticipantVerificationHandler,
} from "./participantVerificationRoute.js";
import {
  Participant,
  ParticipantBlock,
  ParticipantIdentityKeyVersion,
  ParticipantVerification,
} from "../models/db.js";

const participationKey = Buffer.alloc(32, 0x31);
const blockSafetyKey = Buffer.alloc(32, 0x52);

/**
 * Successful redemption (W4-P2) also runs `rebindRetainedParticipantBlocks`
 * inside the same transaction. This is the happy-path double for that: a
 * valid block-safety keyring, one current key version row, and no retained
 * blocks to rebind — matching the mocks already established for the same
 * code path in `participantVerificationRoute.test.ts`. Both keyrings are
 * read and cross-checked for independence even when only one purpose is
 * requested, so both must be stubbed.
 */
function mockRetainedBlockRebindNoOp(principal: string) {
  vi.stubEnv(
    "PARTICIPATION_HMAC_KEYRING",
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": participationKey.toString("base64") },
    })
  );
  vi.stubEnv(
    "BLOCK_SAFETY_HMAC_KEYRING",
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": blockSafetyKey.toString("base64") },
    })
  );
  vi.spyOn(ParticipantIdentityKeyVersion, "find").mockImplementation(
    ((filter: { purpose: string }) => {
      const query: any = {
        session: () => query,
        maxTimeMS: () => query,
        select: () => query,
        lean: () => query,
        exec: vi
          .fn()
          .mockResolvedValue([
            { purpose: filter.purpose, version: 1, normalizationVersion: 1 },
          ]),
      };
      return query;
    }) as never
  );
  vi.spyOn(ParticipantBlock, "exists").mockReturnValue({
    session: () => Promise.resolve(null),
  } as never);
  vi.spyOn(ParticipantBlock, "find").mockReturnValue({
    select: () => ({
      session: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue([]) }) }),
    }),
  } as never);
  // `touchParticipantAccountsInSession` always fences the just-established
  // participant itself, even with no retained blocks to rebind.
  vi.spyOn(Participant, "findById").mockImplementation(((id: unknown) => {
    const query: any = {
      select: () => query,
      session: () => query,
      lean: () => query,
      exec: vi.fn().mockResolvedValue({ _id: id, authorityVersion: 1, email: principal }),
    };
    return query;
  }) as never);
  vi.spyOn(Participant, "updateOne").mockReturnValue({
    exec: vi.fn().mockResolvedValue({ matchedCount: 1, modifiedCount: 1 }),
  } as unknown as ReturnType<typeof Participant.updateOne>);
}

/**
 * The replacement gate at the route layer, with a stubbed obligation read. The
 * obligation query itself runs against real Mongo in
 * `emailReplacementGate.mongo.test.ts`.
 */
const secret = Buffer.from("p".repeat(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES));
const now = new Date("2026-08-05T15:00:00.000Z");
const current = "current@nyu.edu";
const target = "new@nyu.edu";

function context(body: unknown, authority?: string) {
  const headers: Record<string, string> = {};
  if (authority !== undefined) headers[PARTICIPANT_AUTHORITY_HEADER] = authority;
  const req = { body, headers } as unknown as Request;
  const res = { setHeader: vi.fn() } as unknown as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function gate(
  options: {
    blockers?: EmailReplacementBlocker[];
    principal?: string;
    refusal?: "invalid" | "unavailable" | "missing";
    listFails?: boolean;
  } = {}
) {
  const listBlockers = vi.fn(async () => {
    if (options.listFails) throw new Error("read failed");
    return options.blockers ?? [];
  });
  const dependencies: EmailReplacementGateDependencies = {
    now: () => now,
    listBlockers,
    resolveAuthority: async () =>
      options.refusal
        ? { ok: false, refusal: options.refusal }
        : {
            ok: true,
            participant: {
              participantId: "64c0000000000000000000a1",
              principal: options.principal ?? current,
              authorityVersion: 1,
            },
          },
  };
  return { dependencies, listBlockers };
}

const base = (): Partial<ParticipantVerificationDependencies> => ({
  now: () => now,
  generateCode: () => "424242",
  readSecret: () => secret,
  sendVerificationEmail: vi.fn().mockResolvedValue(undefined),
});

let challengeWrite: ReturnType<typeof vi.spyOn>;
let challengeRead: ReturnType<typeof vi.spyOn>;
let participantWrite: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  vi.spyOn(console, "error").mockImplementation(() => {});
  challengeRead = vi.spyOn(ParticipantVerification, "findOne").mockReturnValue({
    select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
  } as never);
  challengeWrite = vi
    .spyOn(ParticipantVerification, "findOneAndUpdate")
    .mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue({}) }) }),
    } as never);
  participantWrite = vi.spyOn(Participant, "findOneAndUpdate");
});

afterEach(() => vi.restoreAllMocks());

describe("email replacement gate — start", () => {
  it("sends the code when no blocking activity exists", async () => {
    const { dependencies } = gate();
    const c = context({ email: target }, "cred");
    await createStartParticipantVerificationHandler(base(), dependencies)(c.req, c.res);
    expect(c.status).toHaveBeenCalledWith(202);
  });

  it.each([
    [["ownRequestOpen"]],
    [["ownRequestHelped"]],
    [["helping"]],
    [["helping", "ownRequestHelped", "ownRequestOpen"]],
  ] as [EmailReplacementBlocker[]][])(
    "refuses %j with no code sent and no challenge written",
    async (blockers) => {
      const { dependencies } = gate({ blockers });
      const handlerDeps = base();
      const c = context({ email: target }, "cred");
      await createStartParticipantVerificationHandler(handlerDeps, dependencies)(c.req, c.res);
      expect(c.status).toHaveBeenCalledWith(409);
      const body = c.json.mock.calls[0][0];
      expect(body.error.code).toBe(EMAIL_REPLACEMENT_BLOCKED_CODE);
      expect(body.blockers).toEqual(blockers);
      expect(handlerDeps.sendVerificationEmail).not.toHaveBeenCalled();
      expect(challengeWrite).not.toHaveBeenCalled();
    }
  );

  it("fails closed when eligibility cannot be read", async () => {
    const { dependencies } = gate({ listFails: true });
    const handlerDeps = base();
    const c = context({ email: target }, "cred");
    await createStartParticipantVerificationHandler(handlerDeps, dependencies)(c.req, c.res);
    expect(c.status).toHaveBeenCalledWith(503);
    expect(handlerDeps.sendVerificationEmail).not.toHaveBeenCalled();
  });

  it("fails closed when the credential cannot be checked", async () => {
    const { dependencies } = gate({ refusal: "unavailable" });
    const c = context({ email: target }, "cred");
    await createStartParticipantVerificationHandler(base(), dependencies)(c.req, c.res);
    expect(c.status).toHaveBeenCalledWith(503);
  });

  it("leaves first-time verification (no credential) unchecked", async () => {
    const { dependencies, listBlockers } = gate({ blockers: ["helping"] });
    const c = context({ email: target });
    await createStartParticipantVerificationHandler(base(), dependencies)(c.req, c.res);
    expect(listBlockers).not.toHaveBeenCalled();
    expect(c.status).toHaveBeenCalledWith(202);
  });

  it("does not gate a revoked credential or a same-address reverify", async () => {
    for (const options of [{ refusal: "invalid" as const }, { principal: target }]) {
      const { dependencies, listBlockers } = gate({ ...options, blockers: ["helping"] });
      const c = context({ email: target }, "cred");
      await createStartParticipantVerificationHandler(base(), dependencies)(c.req, c.res);
      expect(listBlockers).not.toHaveBeenCalled();
      expect(c.status).toHaveBeenCalledWith(202);
    }
  });
});

describe("email replacement gate — redeem", () => {
  it("refuses before consuming the code", async () => {
    const { dependencies } = gate({ blockers: ["ownRequestOpen"] });
    const c = context({ email: target, code: "424242" }, "cred");
    await createRedeemParticipantVerificationHandler(base(), dependencies)(c.req, c.res);
    expect(c.status).toHaveBeenCalledWith(409);
    expect(challengeWrite).not.toHaveBeenCalled();
    expect(challengeRead).not.toHaveBeenCalled();
    expect(participantWrite).not.toHaveBeenCalled();
    expect(c.json.mock.calls[0][0]).not.toHaveProperty("authority");
  });

  it("rechecks at the transition and issues no credential if activity began meanwhile", async () => {
    const listBlockers = vi
      .fn<(id: string, at: Date) => Promise<EmailReplacementBlocker[]>>()
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce(["helping"]);
    const { dependencies } = gate();
    // `redeemParticipantVerificationCode` runs its mutations inside a real
    // `mongoose.startSession()`/`withTransaction` (W4-P2); the happy-path
    // double here matches the one established in `claimRoute.test.ts`.
    vi.spyOn(mongoose, "startSession").mockResolvedValue({
      withTransaction: vi.fn(async (work: () => Promise<void>) => work()),
      endSession: vi.fn().mockResolvedValue(undefined),
    } as never);
    vi.spyOn(ParticipantVerification, "findOne").mockReturnValue({
      select: () => ({
        session: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue({ _id: "64c0000000000000000000b2" }) }) }),
      }),
    } as never);
    vi.spyOn(ParticipantVerification, "findOneAndUpdate").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue({}) }) }),
    } as never);
    vi.spyOn(Participant, "findOneAndUpdate").mockReturnValue({
      exec: vi.fn().mockResolvedValue({ _id: "64c0000000000000000000b2", authorityVersion: 1 }),
    } as never);
    mockRetainedBlockRebindNoOp(target);
    const c = context({ email: target, code: "424242" }, "cred");
    await createRedeemParticipantVerificationHandler(base(), { ...dependencies, listBlockers })(c.req, c.res);
    expect(listBlockers).toHaveBeenCalledTimes(2);
    expect(c.status).toHaveBeenCalledWith(409);
    expect(c.json.mock.calls[0][0]).not.toHaveProperty("authority");
  });

  it("issues the credential when no activity blocks either check", async () => {
    const { dependencies, listBlockers } = gate();
    vi.spyOn(mongoose, "startSession").mockResolvedValue({
      withTransaction: vi.fn(async (work: () => Promise<void>) => work()),
      endSession: vi.fn().mockResolvedValue(undefined),
    } as never);
    vi.spyOn(ParticipantVerification, "findOne").mockReturnValue({
      select: () => ({
        session: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue({ _id: "64c0000000000000000000b2" }) }) }),
      }),
    } as never);
    vi.spyOn(ParticipantVerification, "findOneAndUpdate").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue({}) }) }),
    } as never);
    vi.spyOn(Participant, "findOneAndUpdate").mockReturnValue({
      exec: vi.fn().mockResolvedValue({ _id: "64c0000000000000000000b2", authorityVersion: 1 }),
    } as never);
    mockRetainedBlockRebindNoOp(target);
    const c = context({ email: target, code: "424242" }, "cred");
    await createRedeemParticipantVerificationHandler(base(), dependencies)(c.req, c.res);
    expect(listBlockers).toHaveBeenCalledTimes(2);
    expect(c.status).toHaveBeenCalledWith(200);
    expect(c.json.mock.calls[0][0]).toHaveProperty("authority");
  });
});

describe("GET email-replacement-eligibility", () => {
  it("reports eligibility and blockers, privately cached", async () => {
    const { dependencies } = gate({ blockers: ["helping"] });
    const c = context(undefined, "cred");
    await createEmailReplacementEligibilityHandler(dependencies)(c.req, c.res);
    expect(c.json).toHaveBeenCalledWith({ eligible: false, blockers: ["helping"] });
    expect(c.res.setHeader).toHaveBeenCalledWith("Cache-Control", "private, no-store");
  });

  it("reports eligible when nothing blocks and refuses a missing credential", async () => {
    const ok = context(undefined, "cred");
    await createEmailReplacementEligibilityHandler(gate().dependencies)(ok.req, ok.res);
    expect(ok.json).toHaveBeenCalledWith({ eligible: true, blockers: [] });
    const none = context(undefined);
    await createEmailReplacementEligibilityHandler(gate({ refusal: "missing" }).dependencies)(none.req, none.res);
    expect(none.status).toHaveBeenCalledWith(401);
  });

  it("fails closed when the read fails", async () => {
    const c = context(undefined, "cred");
    await createEmailReplacementEligibilityHandler(gate({ listFails: true }).dependencies)(c.req, c.res);
    expect(c.status).toHaveBeenCalledWith(503);
  });
});
