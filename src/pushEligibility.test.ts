import mongoose from "mongoose";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Installation, Participant } from "../models/db.js";
import * as blocks from "./participantBlocks.js";
import * as moderation from "./moderationEnforcement.js";
import { selectEligiblePushInstallations } from "./pushEligibility.js";

const participantId = new mongoose.Types.ObjectId();
const requesterId = new mongoose.Types.ObjectId();
const row = {
  _id: new mongoose.Types.ObjectId(),
  participantId,
  participantAuthorityVersion: 2,
  apnsToken: "ab".repeat(32),
  apnsEnvironment: "development",
};

function query<T>(value: T) {
  return { select: () => ({ lean: () => ({ exec: async () => value }) }) };
}

afterEach(() => vi.restoreAllMocks());

describe("shared Push recipient authority", () => {
  it.each([
    ["eligible", {}, [{ _id: participantId, authorityVersion: 2 }], false, false, true],
    ["unbound", { participantId: null }, [], false, false, false],
    ["missing participant", {}, [], false, false, false],
    ["stale version", {}, [{ _id: participantId, authorityVersion: 3 }], false, false, false],
    ["missing version", { participantAuthorityVersion: undefined }, [{ _id: participantId, authorityVersion: 2 }], false, false, false],
    ["suspended", {}, [{ _id: participantId, authorityVersion: 2 }], true, false, false],
    ["fenced", {}, [{ _id: participantId, authorityVersion: 2 }], false, true, false],
    ["requester", { participantId: requesterId }, [{ _id: requesterId, authorityVersion: 2 }], false, false, false],
    ["empty token", { apnsToken: "" }, [{ _id: participantId, authorityVersion: 2 }], false, false, false],
    ["malformed token", { apnsToken: "not a token" }, [{ _id: participantId, authorityVersion: 2 }], false, false, false],
  ])("%s", async (_, overrides, participants, suspended, fenced, eligible) => {
    const find = vi.spyOn(Installation, "find").mockReturnValue(
      query([{ ...row, ...overrides }]) as unknown as ReturnType<typeof Installation.find>
    );
    vi.spyOn(Participant, "find").mockReturnValue(
      query(participants) as unknown as ReturnType<typeof Participant.find>
    );
    vi.spyOn(moderation, "isParticipantSuspended").mockResolvedValue(suspended);
    vi.spyOn(blocks, "findFencedCounterpartIds").mockResolvedValue(
      new Set(fenced ? [String(participantId)] : [])
    );

    const result = await selectEligiblePushInstallations({ excludeParticipantId: requesterId });
    expect(result).toHaveLength(eligible ? 1 : 0);
    expect(find).toHaveBeenCalledWith({
      pushEnabled: true,
      apnsToken: { $type: "string" },
      invalidatedAt: null,
      participantId: { $ne: null },
    }, undefined, undefined);
  });

  it("propagates eligibility lookup errors instead of delivering optimistically", async () => {
    vi.spyOn(Installation, "find").mockImplementation(() => { throw new Error("database unavailable"); });
    await expect(selectEligiblePushInstallations()).rejects.toThrow("database unavailable");
  });
});
