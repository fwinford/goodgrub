import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { Participant, Request as MealRequest } from "../models/db.js";
import { getHelperReservationContact } from "./helperReservationContactRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_reservation_contact`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const secretText = "reservation-contact-mongo-secret-32bytes";
const helperId = new mongoose.Types.ObjectId("64e0000000000000000000e1");
const otherHelperId = new mongoose.Types.ObjectId("64e0000000000000000000e2");
const requesterId = new mongoose.Types.ObjectId("64e0000000000000000000e3");
const authority = signParticipantAuthority(helperId, 1, Buffer.from(secretText));

function routeContext(requestId: string) {
  let statusCode = 200;
  let body: unknown;
  const res = {
    status: vi.fn((value: number) => {
      statusCode = value;
      return res;
    }),
    json: vi.fn((value: unknown) => {
      body = value;
      return res;
    }),
    setHeader: vi.fn(() => res),
  } as unknown as Response;
  const req = {
    params: { requestId },
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: authority },
  } as unknown as Request;
  return {
    req,
    res,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return body;
    },
  };
}

async function reservation(overrides: Record<string, unknown> = {}) {
  const now = new Date();
  return MealRequest.create({
    vendor: "Crave NYU",
    food: "Rice bowl",
    pickupWindowText: "ASAP",
    email: "legacy-request-email@nyu.edu",
    status: "claimed",
    expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
    deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
    claimedAt: now,
    claimExpiresAt: new Date(now.getTime() + 10 * 60 * 1000),
    claimTokenDigest: "e".repeat(64),
    helperParticipantId: helperId,
    requesterParticipantId: requesterId,
    ...overrides,
  });
}

async function read(requestId: string) {
  const context = routeContext(requestId);
  await getHelperReservationContact(context.req, context.res);
  return context;
}

describeMongo("real MongoDB helper reservation contact (W4-N1)", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, secretText);
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    for (const [id, email] of [
      [helperId, "contact-helper@nyu.edu"],
      [otherHelperId, "contact-other@nyu.edu"],
      [requesterId, "contact-requester@nyu.edu"],
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
    await MealRequest.deleteMany({});
    await Participant.collection.updateMany({}, { $unset: { suspended: "" } });
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("returns the requester participant's address to the reserving helper", async () => {
    const request = await reservation();

    const context = await read(String(request._id));

    expect(context.statusCode).toBe(200);
    expect(context.body).toEqual({ contactRequesterEmail: "contact-requester@nyu.edu" });
  });

  it("refuses expired, another helper's, placed, moderation-removed, and suspended-pair reservations uniformly", async () => {
    const now = Date.now();
    const expired = await reservation({ claimExpiresAt: new Date(now - 60_000) });
    const others = await reservation({ helperParticipantId: otherHelperId });
    const placed = await reservation({ status: "placed", placedAt: new Date() });
    const removed = await reservation({ moderationUnavailable: true });
    const outcomes = [
      await read(String(expired._id)),
      await read(String(others._id)),
      await read(String(placed._id)),
      await read(String(removed._id)),
    ];

    const live = await reservation();
    await Participant.collection.updateOne({ _id: requesterId }, { $set: { suspended: true } });
    outcomes.push(await read(String(live._id)));

    for (const outcome of outcomes) {
      expect(outcome.statusCode).toBe(404);
      expect(outcome.body).toEqual(outcomes[0].body);
      expect(JSON.stringify(outcome.body)).not.toContain("@");
    }
  });
});
