import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Participant,
  ParticipantBlock,
  Request as MealRequest,
} from "../models/db.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { getActiveReservation } from "./reservationRoute.js";

const now = new Date("2026-08-01T12:00:00.000Z");
const helperParticipantId = new mongoose.Types.ObjectId(
  "64f0000000000000000000e1"
);
const helperPrincipal = "reservation-unit-helper@nyu.edu";
const participantSecretText = "reservation-route-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);

function routeContext(
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
  }
) {
  const req = { headers } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

function stubVerifiedParticipant() {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi
          .fn()
          .mockResolvedValue({ _id: helperParticipantId, email: helperPrincipal }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

/**
 * The placed-result read requests the private W4-U1.1 suppression marker with
 * `.select("+contactMessageSuppressed")`, so every double here supports both
 * the bare `.lean()` chain (the active-claim read) and the `.select().lean()`
 * chain. Each selection is recorded on the returned spy for assertions.
 */
function queryDouble(exec: ReturnType<typeof vi.fn>) {
  const select = vi.fn();
  const chain = { lean: () => ({ exec }), select };
  select.mockReturnValue(chain);
  return { chain, select };
}

function mockActiveReservationResult(result: unknown, placed: unknown[] = []) {
  const { chain: claimChain, select } = queryDouble(
    vi.fn().mockResolvedValue(result)
  );
  const spy = vi
    .spyOn(MealRequest, "findOne")
    .mockReturnValue(
      claimChain as unknown as ReturnType<typeof MealRequest.findOne>
    );
  // W4-R3: the helper's placed set is one `MealRequest.find` (never
  // newest-only), read whether or not a claim is held. It shares the `select`
  // spy with the claim read so call order stays assertable; the placed read is
  // the only one selecting the content-free Message markers.
  const sort = vi.fn();
  const placedChain = {
    sort,
    select,
    lean: () => ({ exec: vi.fn().mockResolvedValue(placed) }),
  };
  sort.mockReturnValue(placedChain);
  select.mockImplementation((fields: string) =>
    /contactMessage|requesterPickupConfirmedAt/.test(String(fields)) ? placedChain : claimChain
  );
  const find = vi
    .spyOn(MealRequest, "find")
    .mockReturnValue(
      placedChain as unknown as ReturnType<typeof MealRequest.find>
    );
  return Object.assign(spy, { select, find, sort });
}

/**
 * `results` is the claim result followed by any placed documents.
 */
function mockSequentialActiveReservationResults(...results: unknown[]) {
  const [claim, ...placed] = results;
  return mockActiveReservationResult(
    claim,
    placed.filter((document) => document !== null && document !== undefined)
  );
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(now);
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
  stubVerifiedParticipant();
  // W4-U1.2: the suspension read behind the contact-restriction signal.
  vi.spyOn(Participant, "exists").mockResolvedValue(null as never);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("GET /api/participant/active-reservation", () => {
  it("requires a verified participant before any database read", async () => {
    const query = vi.spyOn(MealRequest, "findOne");
    const context = routeContext({});

    await getActiveReservation(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_VERIFICATION_REQUIRED_CODE
    );
    expect(query).not.toHaveBeenCalled();
  });

  it("resolves the caller's own active reservation by helperParticipantId, never by any submitted id", async () => {
    const requestId = new mongoose.Types.ObjectId("64f0000000000000000000f2");
    const claimExpiresAt = new Date(now.getTime() + 10 * 60 * 1000);
    const query = mockActiveReservationResult({
      _id: requestId,
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP",
      pickupName: "Private Pickup Name",
      windowStart: null,
      windowEnd: null,
      status: "claimed",
      createdAt: new Date(now.getTime() - 5 * 60 * 1000),
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      claimExpiresAt,
      claimExtendedAt: null,
    });
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    const [filter] = query.mock.calls[0] as any[];
    expect(filter).toEqual({
      helperParticipantId,
      status: "claimed",
      claimExpiresAt: { $gt: now },
    });
    const body = responseBody(context);
    expect(body.reservation.request.id).toBe(String(requestId));
    // W4-R4: pickup name is gone from the request contract, so an active
    // reservation no longer republishes one.
    expect(body.reservation).not.toHaveProperty("pickupName");
    expect(JSON.stringify(body)).not.toMatch(/Private Pickup/);
    expect(body.reservation.claimExpiresAt).toEqual(claimExpiresAt);
    expect(body.reservation.claimExtendedAt).toBeNull();
    // The raw claim token was never persisted, so it can never appear here.
    expect(JSON.stringify(body)).not.toMatch(/claimToken/);
    // An active reservation always takes priority; the placement re-entry
    // read never even runs.
    expect(body.placement).toBeNull();
  });

  describe("W4-U1.3 post-Yes Stop destination signal (C3)", () => {
    const requesterParticipantId = new mongoose.Types.ObjectId(
      "64f0000000000000000000b7"
    );

    function heldReservation(extra: Record<string, unknown>) {
      return {
        _id: new mongoose.Types.ObjectId("64f0000000000000000000f3"),
        vendor: "Palladium",
        food: "Rice bowl",
        pickupWindowText: "ASAP",
        windowStart: null,
        windowEnd: null,
        status: "claimed",
        createdAt: new Date(now.getTime() - 5 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        claimExpiresAt: new Date(now.getTime() + 10 * 60 * 1000),
        claimExtendedAt: null,
        requesterParticipantId,
        ...extra,
      };
    }

    function stubPairFence(fenced: boolean) {
      return vi.spyOn(ParticipantBlock, "findOne").mockReturnValue({
        lean: () => ({
          exec: vi.fn().mockResolvedValue(fenced ? { _id: "row" } : null),
        }),
      } as unknown as ReturnType<typeof ParticipantBlock.findOne>);
    }

    async function read(document: unknown, fenced: boolean) {
      const query = mockActiveReservationResult(document);
      stubPairFence(fenced);
      const context = routeContext();
      await getActiveReservation(context.req, context.res);
      return { body: responseBody(context), query };
    }

    it("reads the private authority on the live-reservation read only", async () => {
      const { query } = await read(heldReservation({}), false);
      expect(query.select).toHaveBeenCalledWith(
        "+requesterParticipantId +externalOrderAffirmed +reservationLapseHold"
      );
    });

    it("reports stopAsksOrderQuestion affirmatively only for L without E (FD-1 Option B)", async () => {
      const withL = await read(heldReservation({ reservationLapseHold: true }), false);
      expect(withL.body.reservation.stopAsksOrderQuestion).toBe(true);
      expect(JSON.stringify(withL.body)).not.toContain("reservationLapseHold");

      const lAndE = await read(
        heldReservation({ reservationLapseHold: true, externalOrderAffirmed: true }),
        false
      );
      expect(lAndE.body.reservation).not.toHaveProperty("stopAsksOrderQuestion");

      const ordinary = await read(heldReservation({}), false);
      expect(ordinary.body.reservation).not.toHaveProperty("stopAsksOrderQuestion");
    });

    it("reports directContactRestricted when either party is suspended, like a pair fence", async () => {
      vi.spyOn(Participant, "exists").mockResolvedValue({ _id: "x" } as never);
      const { body } = await read(heldReservation({}), false);
      expect(body.reservation.directContactRestricted).toBe(true);
    });

    it("reports only the Stop consequence, affirmatively, when the authority exists and no pair restriction remains", async () => {
      const { body } = await read(
        heldReservation({ externalOrderAffirmed: true }),
        false
      );
      expect(body.reservation.stopReturnsHome).toBe(true);
      expect(body.reservation).not.toHaveProperty("directContactRestricted");
      expect(JSON.stringify(body)).not.toMatch(/affirmed|ParticipantId|block/i);
      expect(body.reservation.request).not.toHaveProperty("stopReturnsHome");
    });

    it("never reports it while a pair restriction remains, so the restricted read is the same with or without the authority", async () => {
      const marked = await read(
        heldReservation({ externalOrderAffirmed: true }),
        true
      );
      vi.restoreAllMocks();
      stubVerifiedParticipant();
      const unmarked = await read(heldReservation({}), true);

      expect(marked.body.reservation).not.toHaveProperty("stopReturnsHome");
      expect(marked.body.reservation.directContactRestricted).toBe(true);
      expect(marked.body).toEqual(unmarked.body);
    });

    it("omits it entirely, never false, for an ordinary reservation", async () => {
      const { body } = await read(heldReservation({}), false);
      expect(Object.keys(body.reservation).sort()).toEqual([
        "claimExpiresAt",
        "claimExtendedAt",
        "request",
      ]);
    });
  });

  it("resolves both null when the verified helper holds neither an active reservation nor a placed request", async () => {
    mockActiveReservationResult(null);
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    expect(responseBody(context)).toEqual({
      reservation: null,
      placement: null,
      placements: [],
      pickupConfirmations: [],
      serverNow: now,
    });
  });

  describe("W3-H2 fulfillment re-entry", () => {
    it("reports the most recently placed still-existing request when no active reservation exists", async () => {
      const placedRequestId = new mongoose.Types.ObjectId(
        "64f0000000000000000000f3"
      );
      const query = mockSequentialActiveReservationResults(null, {
        _id: placedRequestId,
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupWindowText: "ASAP",
        mealSwipes: 3,
        windowStart: null,
        windowEnd: null,
        status: "placed",
        createdAt: new Date(now.getTime() - 30 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "00070154321",
        etaText: "15 minutes",
        notificationStatus: "sent",
      });
      const context = routeContext();

      await getActiveReservation(context.req, context.res);

      expect(query).toHaveBeenCalledTimes(1);
      expect(query.find).toHaveBeenCalledTimes(2);
      expect(query.find.mock.calls[0]).toEqual([
        {
          helperParticipantId,
          status: "placed",
          requesterPickupConfirmedAt: { $exists: false },
          deleteAt: { $gt: now },
        },
      ]);
      expect(query.sort).toHaveBeenCalledWith({ placedAt: -1, _id: -1 });

      const body = responseBody(context);
      expect(body.reservation).toBeNull();
      expect(body.placement.request.id).toBe(String(placedRequestId));
      expect(body.placement.request.status).toBe("placed");
      expect(body.placement.request).not.toHaveProperty("orderNumber");
      expect(body.placement.request).not.toHaveProperty("etaText");
      expect(body.placement.orderNumber).toBe("00070154321");
      expect(body.placement.etaText).toBe("15 minutes");
      expect(body.placement.notification).toEqual({ status: "sent" });
      // Order context is helper-authored; pickup/claim authority and requester
      // identity remain private.
      expect(JSON.stringify(body)).not.toMatch(
        /pickupName|claimToken|claimExpiresAt|requesterPickupConfirmedAt|requesterParticipantId/
      );
    });

    it("reports an unknown notification outcome as null rather than guessing", async () => {
      mockSequentialActiveReservationResults(null, {
        _id: new mongoose.Types.ObjectId("64f0000000000000000000f4"),
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupWindowText: "ASAP",
        mealSwipes: 2,
        windowStart: null,
        windowEnd: null,
        status: "placed",
        createdAt: new Date(now.getTime() - 30 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "70154322",
        etaText: "30 minutes",
        notificationStatus: "pending",
      });
      const context = routeContext();

      await getActiveReservation(context.req, context.res);

      expect(responseBody(context).placement.notification).toBeNull();
    });

    describe("W4-U1.1 content-free Message-suppression marker", () => {
      const placedFixture = {
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupWindowText: "ASAP",
        mealSwipes: 2,
        windowStart: null,
        windowEnd: null,
        status: "placed",
        createdAt: new Date(now.getTime() - 30 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        orderNumber: "70154323",
        etaText: "15 minutes",
        notificationStatus: "sent",
      };

      it("requests the private marker only on the participant-scoped placed read", async () => {
        const query = mockSequentialActiveReservationResults(null, {
          _id: new mongoose.Types.ObjectId("64f0000000000000000000f5"),
          ...placedFixture,
        });
        const context = routeContext();

        await getActiveReservation(context.req, context.res);

        // The active-claim read (first) never selects the Message markers — it
        // selects only the requester binding and the post-Yes authority
        // (W4-U1.3), to answer whether direct contact is restricted and where a
        // Stop ends; the placed read selects both content-free Message markers
        // and never the post-Yes authority.
        expect(query.select).toHaveBeenCalledTimes(3);
        expect(query.select).toHaveBeenNthCalledWith(
          1,
          "+requesterParticipantId +externalOrderAffirmed +reservationLapseHold"
        );
        expect(query.select).toHaveBeenNthCalledWith(
          2,
          "+contactMessageSuppressed +contactMessageWithheld"
        );
        // The pickup-confirmation read asks only for the confirmation marker.
        expect(query.select).toHaveBeenNthCalledWith(3, "+requesterPickupConfirmedAt");
      });

      it("reports messageSuppressed: true when the durable marker proves suppression at placement", async () => {
        mockSequentialActiveReservationResults(null, {
          _id: new mongoose.Types.ObjectId("64f0000000000000000000f6"),
          ...placedFixture,
          contactMessageSuppressed: true,
        });
        const context = routeContext();

        await getActiveReservation(context.req, context.res);

        const body = responseBody(context);
        expect(body.placement.messageSuppressed).toBe(true);
        expect(body.placement.request.status).toBe("placed");
        expect(body.placement.orderNumber).toBe("70154323");
        expect(body.placement.notification).toEqual({ status: "sent" });
      });

      it("omits the field entirely, never false, when suppression is not established", async () => {
        for (const marker of [undefined, false, null, "true", 1]) {
          vi.restoreAllMocks();
          stubVerifiedParticipant();
          mockSequentialActiveReservationResults(null, {
            _id: new mongoose.Types.ObjectId("64f0000000000000000000f7"),
            ...placedFixture,
            ...(marker === undefined ? {} : { contactMessageSuppressed: marker }),
          });
          const context = routeContext();

          await getActiveReservation(context.req, context.res);

          const body = responseBody(context);
          expect(Object.keys(body.placement).sort()).toEqual([
            "estimatedReadyAt",
            "etaText",
            "helperVisibleUntil",
            "notification",
            "orderNumber",
            "request",
          ]);
          expect(JSON.stringify(body)).not.toMatch(/messageSuppressed|contactMessage/);
        }
      });

      it("never places the marker inside the public request projection", async () => {
        mockSequentialActiveReservationResults(null, {
          _id: new mongoose.Types.ObjectId("64f0000000000000000000f8"),
          ...placedFixture,
          contactMessageSuppressed: true,
        });
        const context = routeContext();

        await getActiveReservation(context.req, context.res);

        const body = responseBody(context);
        expect(body.placement.request).not.toHaveProperty("messageSuppressed");
        expect(body.placement.request).not.toHaveProperty("contactMessageSuppressed");
        expect(body.reservation).toBeNull();
      });
    });

    it("resolves null placement when this participant has never placed a still-existing request", async () => {
      const query = mockSequentialActiveReservationResults(null, null);
      const context = routeContext();

      await getActiveReservation(context.req, context.res);

      expect(query).toHaveBeenCalledTimes(1);
      expect(query.find).toHaveBeenCalledTimes(2);
      expect(responseBody(context)).toEqual({
        reservation: null,
        placement: null,
        placements: [],
        pickupConfirmations: [],
        serverNow: now,
      });
    });
  });

  describe("helper pickup confirmation fact", () => {
    function chainOf(documents: unknown[]) {
      const chain: Record<string, unknown> = {};
      for (const name of ["sort", "select", "lean"]) {
        chain[name] = vi.fn().mockReturnValue(chain);
      }
      chain.exec = vi.fn().mockResolvedValue(documents);
      return chain as unknown as ReturnType<typeof MealRequest.find>;
    }

    const confirmedBase = {
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP",
      mealSwipes: 1,
      windowStart: null,
      windowEnd: null,
      status: "placed",
      orderNumber: "70154399",
      etaText: "15 minutes",
    };

    it("reports a confirmed pickup once, inside the helper visibility window, by request identity only", async () => {
      mockActiveReservationResult(null, []);
      const id = new mongoose.Types.ObjectId("64f0000000000000000000c1");
      const confirmed = {
        ...confirmedBase,
        _id: id,
        createdAt: new Date(now.getTime() - 30 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        estimatedReadyAt: new Date(now.getTime() + 10 * 60 * 1000),
        requesterPickupConfirmedAt: new Date(now.getTime() - 60 * 1000),
        deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
      };
      const find = vi
        .spyOn(MealRequest, "find")
        .mockReturnValueOnce(chainOf([]))
        .mockReturnValueOnce(chainOf([confirmed]));
      const context = routeContext();

      await getActiveReservation(context.req, context.res);

      expect(find.mock.calls[1]).toEqual([
        {
          helperParticipantId,
          status: "placed",
          requesterPickupConfirmedAt: { $exists: true },
          deleteAt: { $gt: now },
        },
      ]);
      const body = responseBody(context);
      expect(body.placements).toEqual([]);
      expect(body.pickupConfirmations).toEqual([{ requestId: String(id) }]);
      expect(JSON.stringify(body)).not.toMatch(/requesterPickupConfirmedAt|requesterParticipantId/);
    });

    it("does not report a confirmation after the helper visibility cutoff", async () => {
      mockActiveReservationResult(null, []);
      const confirmed = {
        ...confirmedBase,
        _id: new mongoose.Types.ObjectId("64f0000000000000000000c2"),
        createdAt: new Date(now.getTime() - 5 * 60 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 4 * 60 * 60 * 1000),
        estimatedReadyAt: new Date(now.getTime() - 3 * 60 * 60 * 1000),
        requesterPickupConfirmedAt: new Date(now.getTime() - 2 * 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
      };
      vi.spyOn(MealRequest, "find")
        .mockReturnValueOnce(chainOf([]))
        .mockReturnValueOnce(chainOf([confirmed]));
      const context = routeContext();

      await getActiveReservation(context.req, context.res);

      expect(responseBody(context).pickupConfirmations).toEqual([]);
    });
  });

  describe("W4-R3 multiple helper continuations and asymmetric helper cutoff", () => {
    const placedBase = {
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP",
      mealSwipes: 2,
      windowStart: null,
      windowEnd: null,
      status: "placed",
      createdAt: new Date(now.getTime() - 3 * 60 * 60 * 1000),
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      notificationStatus: "sent",
    };
    const placedAgo = (minutes: number) =>
      new Date(now.getTime() - minutes * 60 * 1000);
    const placed = (id: string, placedAt: Date, etaText = "15 minutes") => ({
      _id: new mongoose.Types.ObjectId(id),
      ...placedBase,
      placedAt,
      orderNumber: `7015${id.slice(-4).replace(/[a-f]/g, "1")}`,
      etaText,
    });
    const heldClaim = {
      _id: new mongoose.Types.ObjectId("64f0000000000000000000c1"),
      vendor: "Palladium",
      food: "Rice bowl",
      pickupWindowText: "ASAP",
      windowStart: null,
      windowEnd: null,
      status: "claimed",
      createdAt: new Date(now.getTime() - 5 * 60 * 1000),
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      claimExpiresAt: new Date(now.getTime() + 10 * 60 * 1000),
      claimExtendedAt: null,
    };

    async function readBody(claim: unknown, docs: unknown[]) {
      mockActiveReservationResult(claim, docs);
      vi.spyOn(ParticipantBlock, "findOne").mockReturnValue({
        lean: () => ({ exec: vi.fn().mockResolvedValue(null) }),
      } as unknown as ReturnType<typeof ParticipantBlock.findOne>);
      const context = routeContext();
      await getActiveReservation(context.req, context.res);
      return responseBody(context);
    }

    it("returns every waiting placement alongside a held claim, never hidden by it", async () => {
      const body = await readBody(heldClaim, [
        placed("64f0000000000000000000c2", placedAgo(20)),
        placed("64f0000000000000000000c3", placedAgo(40)),
      ]);

      expect(body.reservation.request.id).toBe("64f0000000000000000000c1");
      expect(body.placements.map((entry: any) => entry.request.id)).toEqual([
        "64f0000000000000000000c2",
        "64f0000000000000000000c3",
      ]);
      expect(body.serverNow).toEqual(now);
    });

    it("returns two waiting placements with no claim, and keeps `placement` as the first", async () => {
      const body = await readBody(null, [
        placed("64f0000000000000000000c2", placedAgo(20)),
        placed("64f0000000000000000000c3", placedAgo(40)),
      ]);

      expect(body.reservation).toBeNull();
      expect(body.placements).toHaveLength(2);
      expect(body.placement.request.id).toBe("64f0000000000000000000c2");
    });

    it("projects helperVisibleUntil as estimatedReadyAt plus one hour", async () => {
      const placedAt = placedAgo(20);
      const body = await readBody(null, [
        placed("64f0000000000000000000c2", placedAt, "30 minutes"),
      ]);

      expect(new Date(body.placements[0].helperVisibleUntil).getTime()).toBe(
        placedAt.getTime() + 30 * 60_000 + 60 * 60_000
      );
    });

    it("drops only the placement whose helper window has ended, never another", async () => {
      // A: ready 15m after placement 80m ago -> ready 65m ago -> cutoff 5m ago (gone).
      // B: placed 20m ago -> still inside its window.
      const body = await readBody(null, [
        placed("64f0000000000000000000c2", placedAgo(20)),
        placed("64f0000000000000000000c3", placedAgo(80)),
      ]);

      expect(body.placements.map((entry: any) => entry.request.id)).toEqual([
        "64f0000000000000000000c2",
      ]);
    });

    it("keeps a placement until exactly one hour after estimatedReadyAt, then drops it (boundary)", async () => {
      // Placed 75m ago + 15m ETA -> ready 60m ago -> cutoff == now (not visible).
      const atCutoff = await readBody(null, [
        placed("64f0000000000000000000c2", placedAgo(75)),
      ]);
      expect(atCutoff.placements).toEqual([]);

      vi.restoreAllMocks();
      stubVerifiedParticipant();
      // One minute earlier it is still visible.
      const beforeCutoff = await readBody(null, [
        placed("64f0000000000000000000c2", placedAgo(74)),
      ]);
      expect(beforeCutoff.placements).toHaveLength(1);
    });

    it("fails closed on a missing or unrecognized ETA with the content-free diagnostic", async () => {
      const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
      const body = await readBody(null, [
        placed("64f0000000000000000000c2", placedAgo(5), "whenever"),
        { ...placed("64f0000000000000000000c3", placedAgo(5)), etaText: undefined },
        placed("64f0000000000000000000c4", placedAgo(5)),
      ]);

      expect(body.placements.map((entry: any) => entry.request.id)).toEqual([
        "64f0000000000000000000c4",
      ]);
      expect(consoleError).toHaveBeenCalledWith(
        "[route] Placed-order fulfillment invariant failed"
      );
      expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(/whenever|Vegetable/);
    });

    it("never mutates requester pickup truth when the helper cutoff passes (read-only)", async () => {
      const update = vi.spyOn(MealRequest, "updateOne");
      const updateMany = vi.spyOn(MealRequest, "updateMany");
      const findOneAndUpdate = vi.spyOn(MealRequest, "findOneAndUpdate");
      await readBody(null, [placed("64f0000000000000000000c2", placedAgo(80))]);

      expect(update).not.toHaveBeenCalled();
      expect(updateMany).not.toHaveBeenCalled();
      expect(findOneAndUpdate).not.toHaveBeenCalled();
    });
  });

  it("answers 503 without leaking detail when the lookup fails", async () => {
    const { chain } = queryDouble(
      vi.fn().mockRejectedValue(new Error("connection reset"))
    );
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      chain as unknown as ReturnType<typeof MealRequest.findOne>
    );
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(
      /connection reset/
    );
  });
});
