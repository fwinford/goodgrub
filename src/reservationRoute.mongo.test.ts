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
import { getActiveReservation } from "./reservationRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_reservation`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

// W4-R3: the read also carries `placements` and `serverNow`; "nothing" means
// no claim and no placement of either shape.
const NOTHING_TO_CONTINUE = {
  reservation: null,
  placement: null,
  placements: [],
};

const participantSecretText = "reservation-mongo-participant-secret-32b";
const participantSecret = Buffer.from(participantSecretText);
const helperParticipantId = new mongoose.Types.ObjectId(
  "64e0000000000000000000d1"
);
const helperPrincipal = "reservation-mongo-helper@nyu.edu";
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);

function routeContext(authority: string | null = participantAuthority) {
  const req = {
    headers: authority
      ? { [PARTICIPANT_AUTHORITY_HEADER]: authority }
      : {},
  } as unknown as Request;
  const res = {} as Response;
  let statusCode = 200;
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

describeMongo("real MongoDB active-reservation continuation (W3-H1)", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
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

  it("resolves nothing for a verified helper with no active reservation", async () => {
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body).toMatchObject(NOTHING_TO_CONTINUE);
  });

  it("resolves the active reservation bound to the verified helper, without a raw claim token", async () => {
    const now = new Date();
    const claimExpiresAt = new Date(now.getTime() + 10 * 60 * 1000);
    const request = await MealRequest.create({
      vendor: "Continuation Cafe",
      food: "Noodle bowl",
      pickupName: "Continuation Pickup",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "claimed",
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
      claimedAt: now,
      claimExpiresAt,
      claimTokenDigest: "c".repeat(64),
      helperParticipantId,
    });

    const context = routeContext();
    await getActiveReservation(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.reservation.request.id).toBe(String(request._id));
    // W4-R4: an active reservation no longer republishes a pickup name.
    expect(context.body.reservation).not.toHaveProperty("pickupName");
    expect(JSON.stringify(context.body)).not.toMatch(/Continuation Pickup/);
    expect(new Date(context.body.reservation.claimExpiresAt)).toEqual(
      claimExpiresAt
    );
    expect(context.body.reservation.claimExtendedAt).toBeNull();
    // Never persisted, so it can never be handed back either.
    expect(JSON.stringify(context.body)).not.toMatch(/claimToken/);
  });

  it("resolves nothing once the reservation has expired", async () => {
    const now = new Date();
    await MealRequest.create({
      vendor: "Continuation Cafe",
      food: "Noodle bowl",
      pickupName: "Lapsed Pickup",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "claimed",
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
      claimedAt: new Date(now.getTime() - 20 * 60 * 1000),
      claimExpiresAt: new Date(now.getTime() - 60 * 1000),
      claimTokenDigest: "d".repeat(64),
      helperParticipantId,
    });

    const context = routeContext();
    await getActiveReservation(context.req, context.res);

    expect(context.body).toMatchObject(NOTHING_TO_CONTINUE);
  });

  it("requires participant verification", async () => {
    const context = routeContext(null);

    await getActiveReservation(context.req, context.res);

    expect(context.statusCode).toBe(401);
  });

  describe("W3-H2 fulfillment re-entry", () => {
    it("restores placed-by-me truth once the reservation is gone, with a settled notification outcome", async () => {
      const now = new Date();
      const request = await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Grain bowl",
        pickupName: "Placed Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "70154321",
        etaText: "15 minutes",
        notificationStatus: "sent",
        helperParticipantId,
      });

      const context = routeContext();
      await getActiveReservation(context.req, context.res);

      expect(context.statusCode).toBe(200);
      expect(context.body.reservation).toBeNull();
      expect(context.body.placement.request.id).toBe(String(request._id));
      expect(context.body.placement.request.status).toBe("placed");
      expect(context.body.placement.orderNumber).toBe("70154321");
      expect(context.body.placement.etaText).toBe("15 minutes");
      expect(context.body.placement.notification).toEqual({ status: "sent" });
      // Order context remains helper-authored; pickup timestamp and requester
      // identity stay private.
      expect(JSON.stringify(context.body)).not.toMatch(
        /pickupName|claimToken|claimExpiresAt|requesterPickupConfirmedAt|requesterParticipantId/
      );
    });

    it("retires the helper continuation after requester-authoritative pickup", async () => {
      const now = new Date();
      await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Grain bowl",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "70154321",
        etaText: "15 minutes",
        requesterPickupConfirmedAt: new Date(now.getTime() - 1000),
        helperParticipantId,
      });

      const context = routeContext();
      await getActiveReservation(context.req, context.res);

      expect(context.statusCode).toBe(200);
      expect(context.body).toMatchObject(NOTHING_TO_CONTINUE);
    });

    it("reports a still-pending notification outcome as unknown rather than guessing", async () => {
      const now = new Date();
      await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Grain bowl",
        pickupName: "Placed Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "70154322",
        etaText: "15 minutes",
        notificationStatus: "pending",
        helperParticipantId,
      });

      const context = routeContext();
      await getActiveReservation(context.req, context.res);

      expect(context.body.placement.notification).toBeNull();
    });

    it("reports the most recent placement when this participant placed more than one still-existing request", async () => {
      const now = new Date();
      await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Older bowl",
        pickupName: "Older Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 30 * 60 * 1000),
        orderNumber: "70154323",
        etaText: "15 minutes",
        notificationStatus: "sent",
        helperParticipantId,
      });
      const mostRecent = await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Newer bowl",
        pickupName: "Newer Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "70154324",
        etaText: "15 minutes",
        notificationStatus: "sent",
        helperParticipantId,
      });

      const context = routeContext();
      await getActiveReservation(context.req, context.res);

      // W4-R3: every placement is kept, newest first; `placement` stays the newest.
      expect(context.body.placement.request.id).toBe(String(mostRecent._id));
      expect(context.body.placements).toHaveLength(2);
      expect(context.body.placements[0].request.id).toBe(String(mostRecent._id));
    });

    it("never restores placement for a different participant's placed request", async () => {
      const now = new Date();
      await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Grain bowl",
        pickupName: "Someone Else's Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "70154325",
        etaText: "15 minutes",
        notificationStatus: "sent",
        helperParticipantId: new mongoose.Types.ObjectId(),
      });

      const context = routeContext();
      await getActiveReservation(context.req, context.res);

      expect(context.body).toMatchObject(NOTHING_TO_CONTINUE);
    });

    it("excludes a placed request whose retention horizon has already elapsed even though the document still physically exists", async () => {
      // Models Mongo's TTL monitor not having physically deleted the document
      // yet: `deleteAt` is already in the past, but the row is still there.
      // Authoritative retention must be decided by comparing `deleteAt` to
      // backend `now`, never by whether the physical sweep has run.
      const now = new Date();
      await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Stale bowl",
        pickupName: "Stale Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() - 8 * 24 * 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() - 60 * 1000),
        placedAt: new Date(now.getTime() - 8 * 24 * 60 * 60 * 1000),
        orderNumber: "70154399",
        etaText: "15 minutes",
        notificationStatus: "sent",
        helperParticipantId,
      });

      const context = routeContext();
      await getActiveReservation(context.req, context.res);

      expect(context.body).toMatchObject(NOTHING_TO_CONTINUE);
    });

    it("still restores a placement exactly at its retention boundary as within horizon, and excludes one exactly past it", async () => {
      const now = new Date();
      await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Boundary bowl",
        pickupName: "Boundary Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() - 60 * 1000),
        deleteAt: now,
        placedAt: new Date(now.getTime() - 60 * 1000),
        orderNumber: "70154400",
        etaText: "15 minutes",
        notificationStatus: "sent",
        helperParticipantId,
      });

      const context = routeContext();
      await getActiveReservation(context.req, context.res);

      // `deleteAt: { $gt: now }` excludes a row exactly at `now`, matching the
      // exclusive TTL boundary MongoDB itself uses to reclaim the document.
      expect(context.body).toMatchObject(NOTHING_TO_CONTINUE);
    });

    it("prefers an active reservation over a still-existing prior placement", async () => {
      const now = new Date();
      await MealRequest.create({
        vendor: "Placed Cafe",
        food: "Grain bowl",
        pickupName: "Placed Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "placed",
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "70154326",
        etaText: "15 minutes",
        notificationStatus: "sent",
        helperParticipantId,
      });
      const activeRequest = await MealRequest.create({
        vendor: "Continuation Cafe",
        food: "Noodle bowl",
        pickupName: "Active Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "claimed",
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
        claimedAt: now,
        claimExpiresAt: new Date(now.getTime() + 10 * 60 * 1000),
        claimTokenDigest: "e".repeat(64),
        helperParticipantId,
      });

      const context = routeContext();
      await getActiveReservation(context.req, context.res);

      expect(context.body.reservation.request.id).toBe(String(activeRequest._id));
      expect(context.body.placement).toBeNull();
    });
  });
});
