import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("./placedOrderRoutes.js", () => ({
  hasUnfinishedPlacedPickupObligation: vi.fn(async () => false),
}));

import { Request as MealRequest } from "../models/db.js";
import { listEmailReplacementBlockers } from "./emailReplacementGate.js";

const now = new Date("2026-08-05T15:00:00.000Z");
const participantId = "64b000000000000000000001";
const future = new Date("2026-08-06T15:00:00.000Z");

function stubOwnedRequests(documents: object[]) {
  const select = vi.fn().mockReturnValue({
    lean: () => ({ exec: vi.fn().mockResolvedValue(documents) }),
  });
  vi.spyOn(MealRequest, "find").mockReturnValue({ select } as never);
  vi.spyOn(MealRequest, "exists").mockReturnValue({
    exec: vi.fn().mockResolvedValue(null),
  } as never);
  return select;
}

describe("Change Email blockers and moderation-unavailable requests", () => {
  afterEach(() => vi.restoreAllMocks());

  it("reads the private moderation markers so a removed request is not an open one", async () => {
    const select = stubOwnedRequests([]);
    await listEmailReplacementBlockers(participantId, now);
    const projection = String(select.mock.calls[0][0]);
    expect(projection).toContain("+moderationUnavailable");
    expect(projection).toContain("+reservationLapseHold");
  });

  it("does not report a moderation-removed request as an own open request", async () => {
    stubOwnedRequests([
      { status: "open", expiresAt: future, moderationUnavailable: true },
    ]);
    expect(await listEmailReplacementBlockers(participantId, now)).toEqual([]);
  });

  it("still reports an ordinary open request", async () => {
    stubOwnedRequests([{ status: "open", expiresAt: future }]);
    expect(await listEmailReplacementBlockers(participantId, now)).toEqual([
      "ownRequestOpen",
    ]);
  });
});
