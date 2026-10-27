import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { Request as MealRequest } from "../models/db.js";
import { listEmailReplacementBlockers } from "./emailReplacementGate.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_email_replacement_gate`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const now = new Date("2026-08-05T15:00:00.000Z");
const later = new Date(now.getTime() + 3_600_000);
const earlier = new Date(now.getTime() - 3_600_000);

describeMongo("real MongoDB W4-B1 email-replacement obligation read", () => {
  const me = new mongoose.Types.ObjectId();
  const other = new mongoose.Types.ObjectId();

  beforeAll(async () => {
    await mongoose.connect(mongoUri!);
  });
  afterEach(async () => {
    await MealRequest.collection.deleteMany({});
  });
  afterAll(async () => {
    await mongoose.disconnect();
  });

  async function insert(fields: Record<string, unknown>) {
    await MealRequest.collection.insertOne({ createdAt: earlier, ...fields });
  }

  it("is clear with no activity and ignores other participants' activity", async () => {
    await insert({ requesterParticipantId: other, status: "open", expiresAt: later });
    await insert({ helperParticipantId: other, status: "claimed", expiresAt: later, claimExpiresAt: later });
    expect(await listEmailReplacementBlockers(String(me), now)).toEqual([]);
  });

  it("blocks an own open request and an own scheduled request", async () => {
    await insert({ requesterParticipantId: me, status: "open", expiresAt: later });
    await insert({ requesterParticipantId: me, status: "open", expiresAt: later, visibleFrom: later });
    expect(await listEmailReplacementBlockers(String(me), now)).toEqual(["ownRequestOpen"]);
  });

  it("blocks while someone holds a live reservation on the participant's request", async () => {
    await insert({
      requesterParticipantId: me, helperParticipantId: other,
      status: "claimed", expiresAt: later, claimExpiresAt: later,
    });
    expect(await listEmailReplacementBlockers(String(me), now)).toEqual(["ownRequestHelped"]);
  });

  it("blocks an active helper reservation and one held by post-Yes authority", async () => {
    await insert({ helperParticipantId: me, status: "claimed", expiresAt: later, claimExpiresAt: later });
    expect(await listEmailReplacementBlockers(String(me), now)).toEqual(["helping"]);
    await MealRequest.collection.deleteMany({});
    await insert({
      helperParticipantId: me, status: "claimed", expiresAt: later,
      claimExpiresAt: earlier, externalOrderAffirmed: true,
    });
    expect(await listEmailReplacementBlockers(String(me), now)).toEqual(["helping"]);
  });

  it("reports every blocker, helper first", async () => {
    await insert({ helperParticipantId: me, status: "claimed", expiresAt: later, claimExpiresAt: later });
    await insert({
      requesterParticipantId: me, helperParticipantId: other,
      status: "claimed", expiresAt: later, claimExpiresAt: later,
    });
    await insert({ requesterParticipantId: me, status: "open", expiresAt: later });
    expect(await listEmailReplacementBlockers(String(me), now)).toEqual([
      "helping", "ownRequestHelped", "ownRequestOpen",
    ]);
  });

  it("does not block on terminal or lapsed activity", async () => {
    await insert({ requesterParticipantId: me, status: "withdrawn", expiresAt: later });
    await insert({ requesterParticipantId: me, status: "placed", expiresAt: later });
    await insert({ requesterParticipantId: me, status: "open", expiresAt: earlier });
    await insert({ helperParticipantId: me, status: "placed", expiresAt: later, claimExpiresAt: earlier });
    await insert({ helperParticipantId: me, status: "claimed", expiresAt: later, claimExpiresAt: earlier });
    expect(await listEmailReplacementBlockers(String(me), now)).toEqual([]);
  });

  describe("W4-R3 unfinished placed pickup", () => {
    const retained = new Date(now.getTime() + 6 * 24 * 3_600_000);
    const placed = (fields: Record<string, unknown> = {}) => ({
      requesterParticipantId: me,
      status: "placed",
      expiresAt: later,
      etaText: "30 minutes",
      placedAt: new Date(now.getTime() - 30 * 60_000),
      deleteAt: retained,
      ...fields,
    });

    it("blocks an own placed order whose pickup is unconfirmed before the requester cutoff", async () => {
      await insert(placed());
      expect(await listEmailReplacementBlockers(String(me), now)).toEqual(["ownPlacedPickup"]);
    });

    it("does not block once pickup is confirmed", async () => {
      await insert(placed({ requesterPickupConfirmedAt: now }));
      expect(await listEmailReplacementBlockers(String(me), now)).toEqual([]);
    });

    it("does not block after the requester visibility cutoff, though the row is still retained", async () => {
      await insert(placed({ placedAt: new Date(now.getTime() - 3 * 24 * 3_600_000) }));
      expect(await listEmailReplacementBlockers(String(me), now)).toEqual([]);
    });

    it("does not block on another participant's placed order or a retired row", async () => {
      await insert(placed({ requesterParticipantId: other }));
      await insert(placed({ deleteAt: earlier }));
      expect(await listEmailReplacementBlockers(String(me), now)).toEqual([]);
    });

    it("fails closed rather than clear when the required ETA is invalid", async () => {
      await insert(placed({ etaText: "whenever" }));
      await expect(listEmailReplacementBlockers(String(me), now)).rejects.toThrow();
    });
  });

  it("never mutates the requests it reads", async () => {
    await insert({ requesterParticipantId: me, status: "open", expiresAt: later });
    const before = await MealRequest.collection.find({}).toArray();
    await listEmailReplacementBlockers(String(me), now);
    expect(await MealRequest.collection.find({}).toArray()).toEqual(before);
  });
});
