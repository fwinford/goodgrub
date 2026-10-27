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
import { Participant, Request as MealRequest } from "../models/db.js";
import { claimRequest } from "./claimRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  CLAIM_MINIMUM_REMAINING_MS,
  buildEffectiveAvailabilityFilter,
} from "./requestAvailability.js";
import {
  buildPublicRequestListResponse,
  type RequestListDocument,
} from "./requestListResponse.js";
import { prepareParticipantIdentityMongoTestState } from "./participantIdentityMongoTestSupport.js";

const participantSecretText = "availability-mongo-participant-secret-32b";
const participantSecret = Buffer.from(participantSecretText);
const helperParticipantId = new mongoose.Types.ObjectId(
  "64d0000000000000000000c2"
);
const helperPrincipal = "availability-mongo-helper@nyu.edu";
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);

/**
 * Integration files run in parallel against the same mongod, and this suite
 * clears the collection between cases. It gets its own database so that cleanup
 * cannot delete another file's fixtures mid-run.
 */
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  uri.pathname = `${uri.pathname}_availability`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

/**
 * Every advertising query is driven by one instant the caller captures, and
 * these fixtures are positioned relative to that same instant. Nothing here
 * compares against a clock read later in the test, so the boundary cases are
 * exact rather than racy.
 */
function fixtures(now: Date) {
  const exactMinimum = new Date(now.getTime() + CLAIM_MINIMUM_REMAINING_MS);
  const justShort = new Date(exactMinimum.getTime() - 1);
  const farFuture = new Date(now.getTime() + 60 * 60 * 1000);

  const scheduledStart = new Date(now.getTime() + 60 * 60 * 1000);

  return [
    { food: "exact-minimum", status: "open", expiresAt: exactMinimum },
    {
      // A Later request whose start has not arrived. It has hours of runway,
      // so only the visibility clause can withhold it.
      food: "not-started",
      status: "open",
      visibleFrom: scheduledStart,
      expiresAt: new Date(scheduledStart.getTime() + 3 * 60 * 60 * 1000),
    },
    {
      // The inclusive boundary: a start exactly at the captured instant.
      food: "starting-now",
      status: "open",
      visibleFrom: now,
      expiresAt: new Date(now.getTime() + 3 * 60 * 60 * 1000),
    },
    {
      // One millisecond before its start, and nothing else wrong with it.
      food: "starting-in-one-millisecond",
      status: "open",
      visibleFrom: new Date(now.getTime() + 1),
      expiresAt: new Date(now.getTime() + 3 * 60 * 60 * 1000),
    },
    {
      // An expired claim on a request that has not started cannot reopen: the
      // two rules compose rather than one overriding the other.
      food: "not-started-expired-claim",
      status: "claimed",
      visibleFrom: scheduledStart,
      expiresAt: new Date(scheduledStart.getTime() + 3 * 60 * 60 * 1000),
      claimExpiresAt: new Date(now.getTime() - 1),
    },
    { food: "just-short", status: "open", expiresAt: justShort },
    {
      food: "expired-claim-with-runway",
      status: "claimed",
      expiresAt: farFuture,
      claimExpiresAt: new Date(now.getTime() - 1),
    },
    {
      food: "expired-claim-too-short",
      status: "claimed",
      expiresAt: justShort,
      claimExpiresAt: new Date(now.getTime() - 1),
    },
    {
      food: "active-claim",
      status: "claimed",
      expiresAt: farFuture,
      claimExpiresAt: new Date(now.getTime() + 10 * 60 * 1000),
    },
    { food: "already-expired", status: "open", expiresAt: now },
  ];
}

async function seed(now: Date) {
  await MealRequest.insertMany(
    fixtures(now).map((fixture) => ({
      vendor: "Boundary Cafe",
      pickupName: "Boundary Requester",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      createdAt: new Date(now.getTime() - 60 * 1000),
      // Retention, not availability. Held past the run so the TTL monitor can
      // never remove a fixture mid-test.
      deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
      ...fixture,
    }))
  );
}

function foods(documents: { food: string }[]): string[] {
  return documents.map((document) => document.food).sort();
}

describeMongo("advertised availability against a real database", () => {
  beforeAll(async () => {
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "real-mongo-test-secret-material-32-bytes"
    );
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await prepareParticipantIdentityMongoTestState();
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await Participant.updateOne(
      { _id: helperParticipantId },
      {
        $set: { email: helperPrincipal, verifiedAt: new Date() },
        $setOnInsert: { authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("excludes short-lived requests from the GET /api/requests query", async () => {
    const now = new Date();
    await seed(now);

    // The exact query and projection GET /api/requests runs, both handed the
    // one captured instant.
    const documents = await MealRequest.find(
      buildEffectiveAvailabilityFilter(now)
    )
      .limit(200)
      .lean()
      .exec();
    const response = buildPublicRequestListResponse(
      documents as unknown as RequestListDocument[],
      now
    );

    expect(foods(documents as unknown as { food: string }[])).toEqual([
      "exact-minimum",
      "expired-claim-with-runway",
      "starting-now",
    ]);
    expect(foods(response.requests)).toEqual([
      "exact-minimum",
      "expired-claim-with-runway",
      "starting-now",
    ]);
    expect(
      response.requests.map((request) => request.status)
    ).toEqual(["open", "open", "open"]);
  });

  it("leaves every record untouched while reading", async () => {
    const now = new Date();
    await seed(now);
    const before = await MealRequest.find({}).sort({ food: 1 }).lean();

    await MealRequest.find(buildEffectiveAvailabilityFilter(now)).lean();

    const after = await MealRequest.find({}).sort({ food: 1 }).lean();
    expect(after).toEqual(before);
    // The reopened request is still persisted as a claim; only the projection
    // called it open.
    expect(
      after.find((document) => document.food === "expired-claim-with-runway")
        ?.status
    ).toBe("claimed");
  });

  it("excludes short-lived requests from the hourly digest query", async () => {
    const digestNow = new Date();
    await seed(digestNow);
    const oneHourAgo = new Date(digestNow.getTime() - 60 * 60 * 1000);

    const recentRequests = await MealRequest.find({
      createdAt: { $gte: oneHourAgo },
      ...buildEffectiveAvailabilityFilter(digestNow),
    }).lean();

    expect(foods(recentRequests as unknown as { food: string }[])).toEqual([
      "exact-minimum",
      "expired-claim-with-runway",
      "starting-now",
    ]);
  });

  it("excludes short-lived requests from recent-request notification queries", async () => {
    const availabilityNow = new Date();
    await seed(availabilityNow);
    const since = new Date(availabilityNow.getTime() - 24 * 60 * 60 * 1000);

    const recentRequests = await MealRequest.find({
      createdAt: { $gte: since },
      ...buildEffectiveAvailabilityFilter(availabilityNow),
    })
      .sort({ createdAt: -1 })
      .limit(50)
      .lean();

    expect(foods(recentRequests as unknown as { food: string }[])).toEqual([
      "exact-minimum",
      "expired-claim-with-runway",
      "starting-now",
    ]);
  });

  it("excludes a single request from the real-time alert availability check", async () => {
    const now = new Date();
    await seed(now);
    const shortLived = await MealRequest.findOne({ food: "just-short" }).lean();

    const stillAvailable = await MealRequest.exists({
      _id: shortLived!._id,
      ...buildEffectiveAvailabilityFilter(now),
    });

    expect(stillAvailable).toBeNull();
  });

  it("refuses to claim what it refuses to advertise", async () => {
    const now = new Date();
    await seed(now);
    const shortLived = await MealRequest.findOne({ food: "just-short" }).lean();
    // The claim route captures its own instant, which can only be later than
    // `now` — so a request already inside the final five minutes is refused
    // regardless of how long this test takes.
    // A real verified helper, so the availability refusal below is the reason
    // the claim fails rather than the participant gate in front of it (W3-I1).
    const req = {
      params: { id: String(shortLived!._id) },
      headers: { [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority },
    } as unknown as Request;
    const res = {} as Response;
    let statusCode = 200;
    let body: any;
    res.status = vi.fn((value: number) => {
      statusCode = value;
      return res;
    }) as any;
    res.json = vi.fn((value: unknown) => {
      body = value;
      return res;
    }) as any;

    await claimRequest(req, res);

    expect(statusCode).toBe(409);
    expect(body.error.code).toBe("REQUEST_INSUFFICIENT_TIME");
  });

  it("advertises a request at exactly its start and not one millisecond before", async () => {
    const now = new Date();
    await seed(now);

    const documents = await MealRequest.find(
      buildEffectiveAvailabilityFilter(now)
    )
      .lean()
      .exec();
    const advertised = foods(documents as unknown as { food: string }[]);

    expect(advertised).toContain("starting-now");
    expect(advertised).not.toContain("starting-in-one-millisecond");
    expect(advertised).not.toContain("not-started");
    expect(advertised).not.toContain("not-started-expired-claim");
  });

  it("still advertises rows written before visibleFrom existed", async () => {
    const now = new Date();
    // `$unset` rather than a null: this is the shape of a row persisted by an
    // earlier build, which no slice migrates.
    await MealRequest.create({
      vendor: "Boundary Cafe",
      food: "legacy-no-visible-from",
      pickupName: "Boundary Requester",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
    });
    await MealRequest.collection.updateOne(
      { food: "legacy-no-visible-from" },
      { $unset: { visibleFrom: "" } }
    );

    const stored = await MealRequest.collection.findOne({
      food: "legacy-no-visible-from",
    });
    expect(stored).not.toHaveProperty("visibleFrom");

    const documents = await MealRequest.find(
      buildEffectiveAvailabilityFilter(now)
    )
      .lean()
      .exec();

    expect(foods(documents as unknown as { food: string }[])).toContain(
      "legacy-no-visible-from"
    );
  });

  it("refuses to claim a request it refuses to advertise for not having started", async () => {
    const now = new Date();
    await seed(now);
    const notStarted = await MealRequest.findOne({ food: "not-started" }).lean();
    const req = {
      params: { id: String(notStarted!._id) },
      headers: { [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority },
    } as unknown as Request;
    const res = {} as Response;
    let statusCode = 200;
    let body: any;
    res.status = vi.fn((value: number) => {
      statusCode = value;
      return res;
    }) as any;
    res.json = vi.fn((value: unknown) => {
      body = value;
      return res;
    }) as any;

    await claimRequest(req, res);

    expect(statusCode).toBe(409);
    // Not "expired" and not "insufficient time": nothing has run out.
    expect(body.error.code).toBe("REQUEST_NOT_YET_AVAILABLE");

    const untouched = await MealRequest.findById(notStarted!._id).lean();
    expect(untouched?.status).toBe("open");
    expect(untouched?.claimedAt).toBeFalsy();
  });
});
