import { afterEach, describe, expect, it, vi } from "vitest";
import { Request as MealRequest } from "../models/db.js";
import { readRequestEligibilityState } from "./requestEligibility.js";

const PRINCIPAL = "eligibility-unit@nyu.edu";

function mockCount(value: number) {
  return vi.spyOn(MealRequest, "countDocuments").mockResolvedValue(value as never);
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("readRequestEligibilityState", () => {
  it("reports eligible below the three-request threshold", async () => {
    mockCount(2);

    await expect(
      readRequestEligibilityState(PRINCIPAL, new Date())
    ).resolves.toEqual({ eligibility: "eligible" });
  });

  it("reports exhausted at the three-request threshold", async () => {
    mockCount(3);

    await expect(
      readRequestEligibilityState(PRINCIPAL, new Date())
    ).resolves.toEqual({ eligibility: "exhausted" });
  });

  it("reports exhausted above the three-request threshold", async () => {
    mockCount(5);

    await expect(
      readRequestEligibilityState(PRINCIPAL, new Date())
    ).resolves.toEqual({ eligibility: "exhausted" });
  });

  it("counts only against the exact given principal", async () => {
    const count = mockCount(0);

    await readRequestEligibilityState(PRINCIPAL, new Date());

    expect(count).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({ email: PRINCIPAL })
    );
  });

  it("propagates a database failure rather than reporting eligible or exhausted", async () => {
    vi.spyOn(MealRequest, "countDocuments").mockRejectedValue(
      new Error("count unavailable")
    );

    await expect(
      readRequestEligibilityState(PRINCIPAL, new Date())
    ).rejects.toThrow("count unavailable");
  });
});
