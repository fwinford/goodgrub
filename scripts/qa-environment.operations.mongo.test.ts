import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Request, Response } from "express";
import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const { resendSend, notifySubscribersForRequest, startHelperNewRequestPush } =
  vi.hoisted(() => ({
    resendSend: vi.fn(),
    notifySubscribersForRequest: vi.fn(),
    startHelperNewRequestPush: vi.fn(),
  }));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));
vi.mock("../src/notifySubscribers.js", () => ({ notifySubscribersForRequest }));
vi.mock("../src/helperNewRequestPush.js", () => ({ startHelperNewRequestPush }));

import {
  Participant,
  Request as MealRequest,
  RequestOperation,
  RequestOperationAuthority,
} from "../models/db.js";
import {
  createRequest,
  OPERATION_EXPIRED_CODE,
  OPERATION_IDENTITY_HEADER,
} from "../src/createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "../src/participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "../src/participantCredentials.js";
import { establishRequestOperationLedger } from "../src/requestOperationAuthority.js";
import { DAILY_REQUEST_LIMIT } from "../src/requestDailyQuota.js";
import { readRequestEligibilityState } from "../src/requestEligibility.js";
import { runQaEnvironmentTool } from "./qa-environment.js";

/**
 * W4-QA1 proof that a normal environment reset works *with* the accepted
 * D1/D2 operation ledger, participant authority, and the real daily quota
 * rather than around them. Everything that decides an outcome here is the
 * product's own code: `createRequest`, `readRequestEligibilityState`, and the
 * signed participant authority. The tool is only ever asked to reset or load a
 * scenario. This suite owns its own database.
 */
const baseUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = baseUri ? describe : describe.skip;

const SLUG = "envtest_ops";
const DATABASE = `commonplate_qa_${SLUG}`;

const participantSecretText = "qa1-operations-mongo-participant-secret-32b";
const participantSecret = Buffer.from(participantSecretText);
const requesterId = new mongoose.Types.ObjectId("64f0000000000000000000c1");
const requesterEmail = "qa1-ops-requester@nyu.edu";
// Signed once, as the Simulator's stored credential would be, and reused
// unchanged across every reset below.
const requesterAuthority = signParticipantAuthority(requesterId, 1, participantSecret);

function asapPayload() {
  return {
    vendor: "Jasper Kane Cafe",
    timing: "asap",
    menuPath: "meal-exchange",
    mealSwipes: 1,
    mealItems: [{ name: "Vegetable rice bowl" }],
  };
}

function routeContext(operationId: string) {
  const req = {
    body: asapPayload(),
    headers: {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    },
  } as unknown as Request;
  const res = {} as Response;
  let statusCode = 0;
  let bodyValue: any;
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    bodyValue = value;
    return res;
  }) as any;
  return {
    req,
    res,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return bodyValue;
    },
  };
}

describeMongo("W4-QA1 reset against the real D1/D2 ledger, identity and quota", () => {
  let directory: string;
  let configPath: string;
  let log: ReturnType<typeof vi.spyOn>;

  async function tool(args: string[], extra: Record<string, string> = {}) {
    // The tool owns its own mongoose connection and closes it when done.
    await mongoose.disconnect();
    try {
      await runQaEnvironmentTool(args, {
        NODE_ENV: "test",
        ALLOW_LOCAL_SEED: "true",
        QA_ENV_FILE: configPath,
        ...extra,
      });
    } finally {
      await connect();
    }
  }

  async function connect() {
    const uri = new URL(baseUri!);
    uri.pathname = `/${DATABASE}`;
    await mongoose.connect(uri.toString());
  }

  async function create(operationId: string) {
    const context = routeContext(operationId);
    await createRequest(context.req, context.res);
    return context;
  }

  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    directory = mkdtempSync(path.join(tmpdir(), "qa1-env-ops-"));
    configPath = path.join(directory, "ops.json");
    const uri = new URL(baseUri!);
    uri.pathname = `/${DATABASE}`;
    writeFileSync(
      configPath,
      JSON.stringify({
        slug: SLUG,
        database: DATABASE,
        mongoUri: uri.toString(),
        backendPort: 3060,
        mailSinkPort: 8060,
      })
    );
    await connect();
    await mongoose.connection.dropDatabase();
  });

  beforeEach(async () => {
    log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    await mongoose.connection.dropDatabase();
    // What backend startup does for this database, then the participant that
    // verified through the app, then the tool's own marker.
    await MealRequest.syncIndexes();
    await establishRequestOperationLedger();
    await Participant.create({
      _id: requesterId,
      email: requesterEmail,
      authorityVersion: 1,
      verifiedAt: new Date(),
    });
    await tool(["init"]);
    resendSend.mockReset().mockResolvedValue({ data: { id: "x" }, error: null });
    notifySubscribersForRequest.mockReset().mockResolvedValue(undefined);
    startHelperNewRequestPush.mockReset();
  });

  afterEach(() => {
    log.mockRestore();
  });

  afterAll(async () => {
    await mongoose.connection.dropDatabase();
    await mongoose.disconnect();
    vi.unstubAllEnvs();
    rmSync(directory, { recursive: true, force: true });
  });

  it("keeps a pre-reset operation burned: replay never recreates a Request, and no NO-CREATE is invented", async () => {
    const operationId = "qa1-ops-pre-reset-operation";
    const created = await create(operationId);
    expect(created.statusCode).toBe(201);
    const authorityBefore = await RequestOperationAuthority.find({}).lean();
    const ledgerBefore = await RequestOperation.find({})
      .select("+participantId +requestId")
      .lean();
    expect(ledgerBefore).toHaveLength(1);

    await tool(["reset"]);

    expect(await MealRequest.countDocuments({})).toBe(0);
    // The ledger and its authority are byte-for-byte what they were.
    expect(await RequestOperationAuthority.find({}).lean()).toEqual(authorityBefore);
    expect(
      await RequestOperation.find({}).select("+participantId +requestId").lean()
    ).toEqual(ledgerBefore);
    expect(await RequestOperation.countDocuments({ outcome: "no-create" })).toBe(0);

    // Replaying the same exact identity: terminal expired, never a fresh create,
    // and repeatably so.
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const replay = await create(operationId);
      expect(replay.statusCode).toBe(410);
      expect(replay.body).toEqual({
        error: expect.objectContaining({ code: OPERATION_EXPIRED_CODE }),
      });
      expect(await MealRequest.countDocuments({})).toBe(0);
    }
    expect(await RequestOperation.countDocuments({ operationId })).toBe(1);
    expect(await RequestOperation.countDocuments({ outcome: "no-create" })).toBe(0);
  });

  it("leaves the verified identity usable: the same credential still creates a Request after reset", async () => {
    expect((await create("qa1-ops-identity-1")).statusCode).toBe(201);
    // Read after the create, which now also advances the W4-U1.2 create-gate
    // epoch on this row; what matters is that reset leaves it untouched.
    const participantBefore = await Participant.collection.findOne({ _id: requesterId });

    await tool(["reset"]);

    expect(await Participant.collection.findOne({ _id: requesterId })).toEqual(participantBefore);
    const next = await create("qa1-ops-identity-2");
    expect(next.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("restores eligibility only by removing Request rows; the real quota then counts the boundary preset", async () => {
    expect(DAILY_REQUEST_LIMIT).toBe(3);
    const eligibility = async () =>
      (await readRequestEligibilityState(requesterEmail, new Date())).eligibility;

    // Exhaust the real quota through the real route.
    for (const id of ["a", "b", "c"]) {
      expect((await create(`qa1-ops-quota-${id}`)).statusCode).toBe(201);
    }
    expect(await eligibility()).toBe("exhausted");
    expect((await create("qa1-ops-quota-d")).statusCode).toBe(429);

    // Reset removes the Request rows; the unchanged quota query now reports the new truth.
    await tool(["reset"]);
    expect(await MealRequest.countDocuments({})).toBe(0);
    expect(await eligibility()).toBe("eligible");

    // Two seeded current-day Requests are counted by the real quota path:
    // still eligible, and the next real submission is the third of the day.
    await tool(["scenario", "requester-quota-boundary"], { QA_REQUESTER_EMAIL: requesterEmail });
    expect(await MealRequest.countDocuments({ email: requesterEmail })).toBe(2);
    expect(await eligibility()).toBe("eligible");
    expect((await create("qa1-ops-boundary-third")).statusCode).toBe(201);
    expect(await eligibility()).toBe("exhausted");
    expect((await create("qa1-ops-boundary-fourth")).statusCode).toBe(429);

    // And a single-request preset leaves headroom for two more real submissions.
    await tool(["scenario", "requester-below-quota"], { QA_REQUESTER_EMAIL: requesterEmail });
    expect(await MealRequest.countDocuments({ email: requesterEmail })).toBe(1);
    expect((await create("qa1-ops-below-2")).statusCode).toBe(201);
    expect((await create("qa1-ops-below-3")).statusCode).toBe(201);
    expect((await create("qa1-ops-below-4")).statusCode).toBe(429);
  });

  it("is the full teardown, and only that, that discards the operation ledger and authority", async () => {
    expect((await create("qa1-ops-teardown-op")).statusCode).toBe(201);
    await tool(["reset"]);
    expect(await RequestOperation.countDocuments({})).toBe(1);
    expect(await RequestOperationAuthority.countDocuments({})).toBe(1);
    expect(await Participant.countDocuments({})).toBe(1);

    await tool(["drop", "--confirm-database", DATABASE]);

    expect(await RequestOperation.countDocuments({})).toBe(0);
    expect(await RequestOperationAuthority.countDocuments({})).toBe(0);
    expect(await Participant.countDocuments({})).toBe(0);
  });
});
