import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { Subscriber } from "../models/db.js";
import { unsubscribeSubscriberByPrincipal } from "./participantEmailUnsubscribe.js";

/**
 * Real-Mongo acceptance for the participant-authorized unsubscribe primitive:
 * that absent, pending, confirmed, and already-unsubscribed principals all
 * converge to the same declarative Off result and the same persisted shape,
 * and that concurrent calls for the same principal are safely idempotent.
 * Route-level authority-gate behavior is proved against stubbed persistence
 * in `participantEmailUnsubscribeRoute.test.ts`.
 */
const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

const now = new Date("2026-08-10T18:30:00.000Z");

async function unsubscribe(email: string) {
  const session = await mongoose.startSession();
  try {
    return await session.withTransaction(() =>
      unsubscribeSubscriberByPrincipal(email, now, session)
    );
  } finally {
    await session.endSession();
  }
}

describeMongo(
  "participant-authorized email unsubscribe against real MongoDB",
  () => {
    beforeAll(async () => {
      await mongoose.connect(mongoUri!, {
        dbName: "commonplate_participant_unsubscribe_test",
      });
    });

    afterEach(async () => {
      await Subscriber.deleteMany({});
    });

    afterAll(async () => {
      await mongoose.disconnect();
    });

    it("reports unsubscribed for a principal with no Subscriber row, and creates none", async () => {
      const result = await unsubscribe("nobody@nyu.edu");

      expect(result).toEqual({ outcome: "unsubscribed" });
      expect(await Subscriber.countDocuments({})).toBe(0);
    });

    it("converges a pending Subscriber to unsubscribed", async () => {
      const created = await Subscriber.create({
        email: "pending@nyu.edu",
        status: "pending",
        confirmationTokenDigest: "digest",
        confirmationExpiresAt: new Date(now.getTime() + 60_000),
      });

      const result = await unsubscribe("pending@nyu.edu");

      expect(result).toEqual({ outcome: "unsubscribed" });
      const stored = await Subscriber.findById(created._id)
        .select("+confirmationTokenDigest +confirmationExpiresAt")
        .lean<Record<string, unknown>>()
        .exec();
      expect(stored?.status).toBe("unsubscribed");
      expect(stored?.unsubscribedAt).toBeInstanceOf(Date);
      expect(stored?.confirmationTokenDigest).toBeUndefined();
      expect(stored?.confirmationExpiresAt).toBeUndefined();
    });

    it("converges a confirmed Subscriber to unsubscribed", async () => {
      const created = await Subscriber.create({
        email: "confirmed@nyu.edu",
        status: "confirmed",
      });

      const result = await unsubscribe("confirmed@nyu.edu");

      expect(result).toEqual({ outcome: "unsubscribed" });
      const stored = await Subscriber.findById(created._id).lean<Record<string, unknown>>().exec();
      expect(stored?.status).toBe("unsubscribed");
    });

    it("leaves an already-unsubscribed Subscriber's original unsubscribe timestamp untouched", async () => {
      const original = new Date(now.getTime() - 86_400_000);
      const created = await Subscriber.create({
        email: "already@nyu.edu",
        status: "unsubscribed",
        unsubscribedAt: original,
      });

      const result = await unsubscribe("already@nyu.edu");

      expect(result).toEqual({ outcome: "unsubscribed" });
      const stored = await Subscriber.findById(created._id).lean<Record<string, unknown>>().exec();
      expect(stored?.status).toBe("unsubscribed");
      expect((stored?.unsubscribedAt as Date)?.getTime()).toBe(original.getTime());
    });

    it("never writes a participantId or any new field onto the Subscriber", async () => {
      const created = await Subscriber.create({
        email: "helper@nyu.edu",
        status: "confirmed",
      });

      await unsubscribe("helper@nyu.edu");

      const stored = await Subscriber.findById(created._id).lean<Record<string, unknown>>().exec();
      expect(stored).not.toHaveProperty("participantId");
      expect(Object.keys(stored ?? {})).not.toContain("participantId");
    });

    it("preserves the unsubscribe credential version and delivery counters", async () => {
      const created = await Subscriber.create({
        email: "counters@nyu.edu",
        status: "confirmed",
        dailyCount: 3,
        bounced: false,
        unsubscribeCredentialVersion: 1,
      });

      await unsubscribe("counters@nyu.edu");

      const stored = await Subscriber.findById(created._id).lean<Record<string, unknown>>().exec();
      expect(stored?.dailyCount).toBe(3);
      expect(stored?.unsubscribeCredentialVersion).toBe(1);
    });

    it("is idempotent and safe under concurrent calls for the same principal", async () => {
      await Subscriber.create({ email: "concurrent@nyu.edu", status: "confirmed" });

      const results = await Promise.all(
        Array.from({ length: 5 }, () =>
          unsubscribe("concurrent@nyu.edu")
        )
      );

      for (const result of results) {
        expect(result).toEqual({ outcome: "unsubscribed" });
      }
      expect(await Subscriber.countDocuments({ email: "concurrent@nyu.edu" })).toBe(1);
      const stored = await Subscriber.findOne({ email: "concurrent@nyu.edu" })
        .lean<Record<string, unknown>>()
        .exec();
      expect(stored?.status).toBe("unsubscribed");
    });
  }
);
