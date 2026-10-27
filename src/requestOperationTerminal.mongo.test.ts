import type { Request, Response } from "express";
import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
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

vi.mock("./notifySubscribers.js", () => ({
  notifySubscribersForRequest,
}));

vi.mock("./helperNewRequestPush.js", () => ({
  startHelperNewRequestPush,
}));

import {
  Participant,
  Request as MealRequest,
  RequestOperation,
  RequestOperationAuthority,
} from "../models/db.js";
import {
  createRequest,
  OPERATION_IDENTITY_HEADER,
  OPERATION_NOT_CREATED_CODE,
} from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  establishRequestOperationLedger,
  OPERATION_AUTHORITY_HEADER,
} from "./requestOperationAuthority.js";
import { resolveRequestOperationTerminal } from "./requestOperationTerminalRoute.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

/**
 * W4-D2 real-Mongo proof: exact-operation terminal NO-CREATE occupies the same
 * unique identity authority (`request_operation_ledger_identity_unique`) as a
 * created operation, so create and terminalization have exactly one winner per
 * identity under real transactions and real concurrency. Its own database, so
 * collection clears here never touch the W3-D1 suite's fixtures.
 */
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_request_operation_terminal`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const participantSecretText = "request-operation-terminal-mongo-secret-32b";
const participantSecret = Buffer.from(participantSecretText);

const requesterAId = new mongoose.Types.ObjectId("64f0000000000000000000c1");
const requesterAPrincipal = "d2-mongo-requester-a@nyu.edu";
const requesterAAuthority = signParticipantAuthority(
  requesterAId,
  1,
  participantSecret
);
const requesterBId = new mongoose.Types.ObjectId("64f0000000000000000000c2");
const requesterBPrincipal = "d2-mongo-requester-b@nyu.edu";
const requesterBAuthority = signParticipantAuthority(
  requesterBId,
  1,
  participantSecret
);

function payload(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Jasper Kane Cafe",
    timing: "asap",
    menuPath: "meal-exchange",
    mealSwipes: 1,
    mealItems: [{ name: "Private meal detail that must never reach the ledger" }],
    ...overrides,
  };
}

function context(
  headers: Record<string, string>,
  body: unknown = undefined
) {
  const req = { body, headers } as unknown as Request;
  const res = {} as Response;
  let statusCode = 0;
  let bodyValue: any;
  const setHeaders = new Map<string, string>();
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    bodyValue = value;
    return res;
  }) as any;
  res.setHeader = vi.fn((name: string, value: string) => {
    setHeaders.set(name, value);
    return res;
  }) as any;
  return {
    req,
    res,
    setHeaders,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return bodyValue;
    },
  };
}

/** This database's ledger identity, established in `beforeAll`. */
let ledgerAuthority = "";

function headers(
  operationId: string,
  authority = requesterAAuthority,
  ledger = ledgerAuthority
) {
  return {
    [PARTICIPANT_AUTHORITY_HEADER]: authority,
    [OPERATION_IDENTITY_HEADER]: operationId,
    [OPERATION_AUTHORITY_HEADER]: ledger,
  };
}

async function create(
  operationId: string,
  body: unknown = payload(),
  ledger = ledgerAuthority
) {
  const call = context(headers(operationId, requesterAAuthority, ledger), body);
  await createRequest(call.req, call.res);
  return call;
}

async function terminalize(
  operationId: string,
  authority = requesterAAuthority,
  ledger = ledgerAuthority
) {
  const call = context(headers(operationId, authority, ledger));
  await resolveRequestOperationTerminal(call.req, call.res);
  return call;
}

type CallResult = { statusCode: number; body: any };

/** The one terminal outcome a create or terminalization answer names. */
function outcomeOf(result: CallResult): "created" | "not-created" | "other" {
  if (result.statusCode === 201) return "created";
  if (result.statusCode === 200 && result.body?.request) return "created";
  if (result.statusCode === 200 && result.body?.outcome === "not-created") {
    return "not-created";
  }
  if (
    result.statusCode === 409 &&
    result.body?.error?.code === OPERATION_NOT_CREATED_CODE
  ) {
    return "not-created";
  }
  return "other";
}

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

/**
 * Gates the create path's transactional ledger insert (the array + session
 * form) so a test can hold an original create in flight at a chosen point
 * inside its real transaction. Terminalization's own insert (the plain object
 * form) passes straight through.
 */
function gateTransactionalLedgerInsert(position: "start" | "before" | "after") {
  if (position === "start") return gateCreateTransactionStart();
  const original = RequestOperation.create.bind(RequestOperation);
  const reached = deferred();
  const release = deferred();
  let gated = false;
  vi.spyOn(RequestOperation, "create").mockImplementation((async (
    ...args: unknown[]
  ) => {
    const transactional = Array.isArray(args[0]);
    if (!transactional || gated) {
      return (original as (...a: unknown[]) => Promise<unknown>)(...args);
    }
    gated = true;
    if (position === "before") {
      reached.resolve();
      await release.promise;
      return (original as (...a: unknown[]) => Promise<unknown>)(...args);
    }
    const inserted = await (original as (...a: unknown[]) => Promise<unknown>)(
      ...args
    );
    reached.resolve();
    await release.promise;
    return inserted;
  }) as never);
  return { reached: reached.promise, release: release.resolve };
}

/**
 * Holds an original create at the first write of its real transaction (the
 * U1.2 suspension anchor on the Participant row), before it holds any lock.
 * Once that anchor has run, the create owns the Participant row and the
 * account-fence touch in terminalization serializes behind it, so "terminalization
 * commits first" can only be staged from here.
 */
function gateCreateTransactionStart() {
  const original = Participant.updateOne.bind(Participant);
  const reached = deferred();
  const release = deferred();
  let gated = false;
  vi.spyOn(Participant, "updateOne").mockImplementation(((
    ...args: unknown[]
  ) => {
    const options = args[2] as { session?: unknown } | undefined;
    const update = args[1] as { $inc?: Record<string, unknown> } | undefined;
    const anchor =
      !gated &&
      options?.session !== undefined &&
      update?.$inc?.suspensionFenceEpoch !== undefined;
    if (!anchor) return (original as (...a: unknown[]) => unknown)(...args);
    gated = true;
    reached.resolve();
    return {
      exec: () =>
        release.promise.then(() =>
          (original as (...a: unknown[]) => { exec(): Promise<unknown> })(
            ...args
          ).exec()
        ),
    };
  }) as never);
  return { reached: reached.promise, release: release.resolve };
}

async function ledgerRows(operationId: string) {
  return RequestOperation.find({ operationId })
    .select("+participantId +requestId")
    .lean()
    .exec();
}

describeMongo("real MongoDB exact-operation terminal reconciliation (W4-D2)", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await RequestOperation.syncIndexes();
    ledgerAuthority = await establishRequestOperationLedger();
    for (const [id, email] of [
      [requesterAId, requesterAPrincipal],
      [requesterBId, requesterBPrincipal],
    ] as const) {
      await Participant.updateOne(
        { _id: id },
        {
          $set: { email, verifiedAt: new Date() },
          $setOnInsert: { authorityVersion: 1 },
        },
        { upsert: true }
      ).exec();
    }
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await MealRequest.deleteMany({});
    await RequestOperation.deleteMany({});
    resendSend.mockReset().mockResolvedValue({ data: { id: "x" }, error: null });
    notifySubscribersForRequest.mockReset().mockResolvedValue(undefined);
    startHelperNewRequestPush.mockReset();
  });

  afterAll(async () => {
    await Participant.deleteMany({ _id: { $in: [requesterAId, requesterBId] } });
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it.each([
    {
      label: "a different ledger behind the same service",
      ledger: () => "0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3",
      status: 409,
      code: "OPERATION_AUTHORITY_MISMATCH",
    },
    {
      label: "no named ledger",
      ledger: () => "",
      status: 409,
      code: "OPERATION_AUTHORITY_MISMATCH",
    },
  ])(
    "never terminalizes or creates against $label",
    async ({ ledger, status, code }) => {
      const terminal = await terminalize(
        "d2-foreign-ledger",
        requesterAAuthority,
        ledger()
      );
      const replay = await create("d2-foreign-ledger", payload(), ledger());

      for (const answer of [terminal, replay]) {
        expect(answer.statusCode).toBe(status);
        expect(answer.body.error.code).toBe(code);
      }
      expect(await ledgerRows("d2-foreign-ledger")).toHaveLength(0);
      expect(await MealRequest.countDocuments({})).toBe(0);
    }
  );

  it("stops answering for a ledger whose identity was reset, and serves only the new identity", async () => {
    const previous = ledgerAuthority;
    try {
      // A reset database: the identity row is gone. Nothing may be answered
      // or written until an identity is established again.
      await RequestOperationAuthority.deleteMany({});
      const unavailable = await terminalize("d2-reset-ledger", requesterAAuthority, previous);
      expect(unavailable.statusCode).toBe(503);
      expect(unavailable.body.error.code).toBe("OPERATION_AUTHORITY_UNAVAILABLE");
      expect(await ledgerRows("d2-reset-ledger")).toHaveLength(0);

      // Re-establishing mints a new identity; the old one never matches it.
      ledgerAuthority = await establishRequestOperationLedger();
      expect(ledgerAuthority).not.toBe(previous);
      const stale = await terminalize("d2-reset-ledger", requesterAAuthority, previous);
      expect(stale.statusCode).toBe(409);
      expect(await ledgerRows("d2-reset-ledger")).toHaveLength(0);

      const current = await terminalize("d2-reset-ledger");
      expect(current.body).toEqual({ outcome: "not-created" });
    } finally {
      // Establishing again is idempotent and never replaces an identity.
      expect(await establishRequestOperationLedger()).toBe(ledgerAuthority);
    }
  });

  it("uses the same unique identity index for created and NO-CREATE rows", async () => {
    const indexes = await RequestOperation.collection.indexes();
    const identity = indexes.find(
      (index) => index.name === "request_operation_ledger_identity_unique"
    );
    expect(identity).toMatchObject({ key: { operationId: 1 }, unique: true });
    expect(identity?.partialFilterExpression).toBeUndefined();
    expect(identity?.sparse).toBeFalsy();
  });

  it("establishes NO-CREATE for an unclaimed identity, storing only identity, participant, and outcome", async () => {
    const result = await terminalize("d2-unclaimed");

    expect(result.statusCode).toBe(200);
    expect(result.body).toEqual({ outcome: "not-created" });
    expect(result.setHeaders.get("Cache-Control")).toBe("private, no-store");
    expect(result.setHeaders.get("Vary")).toBe(PARTICIPANT_AUTHORITY_HEADER);

    const rows = await ledgerRows("d2-unclaimed");
    expect(rows).toHaveLength(1);
    expect(Object.keys(rows[0]).sort()).toEqual(
      ["__v", "_id", "createdAt", "operationId", "outcome", "participantId", "updatedAt"].sort()
    );
    expect(rows[0].outcome).toBe("no-create");
    expect(String(rows[0].participantId)).toBe(String(requesterAId));
    expect(rows[0].requestId).toBeUndefined();
    expect(JSON.stringify(rows)).not.toContain("Private meal detail");
    expect(await MealRequest.countDocuments({})).toBe(0);
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    expect(startHelperNewRequestPush).not.toHaveBeenCalled();
  });

  it("returns the exact created Request for an identity that already created, and never replaces it", async () => {
    const created = await create("d2-created-first");
    expect(created.statusCode).toBe(201);

    const first = await terminalize("d2-created-first");
    const again = await terminalize("d2-created-first");

    for (const answer of [first, again]) {
      expect(answer.statusCode).toBe(200);
      expect(answer.body.outcome).toBe("created");
      expect(answer.body.request.id).toBe(created.body.request.id);
      expect(answer.body.request.mealItems).toEqual(payload().mealItems);
    }
    const rows = await ledgerRows("d2-created-first");
    expect(rows).toHaveLength(1);
    expect(rows[0].outcome).toBe("created");
    expect(String(rows[0].requestId)).toBe(created.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(1);

    // And replay still reconciles to that same Request.
    const replay = await create("d2-created-first");
    expect(replay.statusCode).toBe(200);
    expect(replay.body.request.id).toBe(created.body.request.id);
  });

  it("keeps an expired operation terminal: 410 from terminalization, never NO-CREATE, never resurrected", async () => {
    const created = await create("d2-expired");
    await MealRequest.deleteOne({ _id: created.body.request.id });

    const terminal = await terminalize("d2-expired");
    expect(terminal.statusCode).toBe(410);
    expect(terminal.body.error.code).toBe("OPERATION_EXPIRED");

    const rows = await ledgerRows("d2-expired");
    expect(rows).toHaveLength(1);
    expect(rows[0].outcome).toBe("created");

    const replay = await create("d2-expired");
    expect(replay.statusCode).toBe(410);
    expect(await MealRequest.countDocuments({})).toBe(0);
  });

  it("keeps a terminalized identity terminal: every later create, including a different body, answers NO-CREATE", async () => {
    await terminalize("d2-terminal-forever");

    for (const body of [payload(), payload({ vendor: "   " }), { food: "pre-R4" }]) {
      const late = await create("d2-terminal-forever", body);
      expect(late.statusCode).toBe(409);
      expect(late.body.error.code).toBe(OPERATION_NOT_CREATED_CODE);
    }
    const repeat = await terminalize("d2-terminal-forever");
    expect(repeat.body).toEqual({ outcome: "not-created" });

    expect(await MealRequest.countDocuments({})).toBe(0);
    expect(await ledgerRows("d2-terminal-forever")).toHaveLength(1);
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    expect(startHelperNewRequestPush).not.toHaveBeenCalled();
  });

  it("refuses another participant generically for both created and terminalized identities, changing nothing", async () => {
    const created = await create("d2-owned-created");
    await terminalize("d2-owned-terminal");

    const intoCreated = await terminalize("d2-owned-created", requesterBAuthority);
    const intoTerminal = await terminalize("d2-owned-terminal", requesterBAuthority);

    expect(intoCreated.statusCode).toBe(403);
    expect(intoTerminal.statusCode).toBe(403);
    // Identical answers: the other participant cannot tell which terminal
    // outcome the identity holds, or learn anything about the Request.
    expect(intoCreated.body).toEqual(intoTerminal.body);
    expect(JSON.stringify(intoCreated.body)).not.toContain("Jasper Kane Cafe");
    expect(JSON.stringify(intoCreated.body)).not.toContain(created.body.request.id);

    expect((await ledgerRows("d2-owned-created"))[0].outcome).toBe("created");
    expect((await ledgerRows("d2-owned-terminal"))[0].outcome).toBe("no-create");
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("is idempotent under concurrent terminalization: one row, one answer", async () => {
    const answers = await Promise.all(
      Array.from({ length: 6 }, () => terminalize("d2-concurrent-terminal"))
    );

    for (const answer of answers) {
      expect(answer.statusCode).toBe(200);
      expect(answer.body).toEqual({ outcome: "not-created" });
    }
    expect(await ledgerRows("d2-concurrent-terminal")).toHaveLength(1);
  });

  it("consumes no daily quota: terminalized identities never count toward the three-request limit", async () => {
    for (const id of ["d2-quota-1", "d2-quota-2", "d2-quota-3", "d2-quota-4"]) {
      await terminalize(id);
    }
    const first = await create("d2-quota-create-1");
    const second = await create("d2-quota-create-2");
    const third = await create("d2-quota-create-3");
    const fourth = await create("d2-quota-create-4");

    expect([first, second, third].map((call) => call.statusCode)).toEqual([
      201, 201, 201,
    ]);
    expect(fourth.statusCode).toBe(429);
    expect(fourth.body.error.code).toBe("REQUEST_LIMIT_REACHED");
  });

  it("converges on one outcome when terminalization and an original create race freely", async () => {
    let createdWins = 0;
    let noCreateWins = 0;
    for (let round = 0; round < 20; round += 1) {
      const operationId = `d2-free-race-${round}`;
      const [created, terminal] = await Promise.all([
        create(operationId),
        terminalize(operationId),
      ]);
      const outcomes = [outcomeOf(created), outcomeOf(terminal)];
      const requests = await MealRequest.countDocuments({});

      expect(outcomes[0]).toBe(outcomes[1]);
      if (outcomes[0] === "created") {
        createdWins += 1;
        expect(requests).toBe(1);
        expect(terminal.body.request.id).toBe(created.body.request.id);
      } else {
        expect(outcomes[0]).toBe("not-created");
        noCreateWins += 1;
        expect(requests).toBe(0);
      }
      const rows = await ledgerRows(operationId);
      expect(rows).toHaveLength(1);
      await MealRequest.deleteMany({});
    }
    expect(createdWins + noCreateWins).toBe(20);
  });

  it("makes an in-flight original create lose forever once terminalization wins first", async () => {
    // The create's transaction has not yet written anything (so it holds no
    // lock) when terminalization commits NO-CREATE.
    const gate = gateTransactionalLedgerInsert("start");
    const inFlight = create("d2-in-flight-loses");
    await gate.reached;

    const terminal = await terminalize("d2-in-flight-loses");
    expect(terminal.body).toEqual({ outcome: "not-created" });

    gate.release();
    const original = await inFlight;

    expect(original.statusCode).toBe(409);
    expect(original.body.error.code).toBe(OPERATION_NOT_CREATED_CODE);
    // The transaction rolled back its Request too.
    expect(await MealRequest.countDocuments({})).toBe(0);
    const rows = await ledgerRows("d2-in-flight-loses");
    expect(rows).toHaveLength(1);
    expect(rows[0].outcome).toBe("no-create");
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    expect(startHelperNewRequestPush).not.toHaveBeenCalled();

    const later = await create("d2-in-flight-loses");
    expect(later.statusCode).toBe(409);
    expect(await MealRequest.countDocuments({})).toBe(0);
  });

  it("never lets terminalization erase an original create that already holds the identity in its open transaction", async () => {
    // The create's transaction holds its (uncommitted) ledger row when
    // terminalization starts; terminalization must end up agreeing with it.
    const gate = gateTransactionalLedgerInsert("after");
    const inFlight = create("d2-in-flight-wins");
    await gate.reached;

    const terminalPromise = terminalize("d2-in-flight-wins");
    // Give terminalization time to reach the conflicting insert while the
    // transaction is still open.
    await new Promise((resolve) => setTimeout(resolve, 200));
    gate.release();
    const [original, terminal] = await Promise.all([inFlight, terminalPromise]);

    // The outside NO-CREATE insert waits on the open transaction's identity
    // key and then loses to its commit: create wins, terminalization agrees.
    expect(original.statusCode).toBe(201);
    expect(outcomeOf(terminal)).toBe("created");
    expect(terminal.body.request.id).toBe(original.body.request.id);
    const rows = await ledgerRows("d2-in-flight-wins");
    expect(rows).toHaveLength(1);
    expect(rows[0].outcome).toBe("created");
    expect(await MealRequest.countDocuments({})).toBe(1);

    const repeat = await terminalize("d2-in-flight-wins");
    expect(outcomeOf(repeat)).toBe("created");
    expect(repeat.body.request.id).toBe(original.body.request.id);
  });
});
