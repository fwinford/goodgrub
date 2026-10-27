import { afterEach, describe, expect, it, vi } from "vitest";
import { Subscriber } from "../models/db.js";
import { readEmailAlertState } from "./emailAlertState.js";

const PRINCIPAL = "helper@nyu.edu";

function mockExists(value: unknown) {
  return vi.spyOn(Subscriber, "exists").mockResolvedValue(value as never);
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("readEmailAlertState", () => {
  it("reports active when an active/confirmed Subscriber matches the exact principal", async () => {
    mockExists({ _id: "64f0000000000000000000a1" });

    expect(await readEmailAlertState(PRINCIPAL)).toEqual({ active: true });
  });

  it("reports inactive when no active/confirmed Subscriber matches", async () => {
    mockExists(null);

    expect(await readEmailAlertState(PRINCIPAL)).toEqual({ active: false });
  });

  it("evaluates the exact active/confirmed condition against only the given principal", async () => {
    const exists = mockExists(null);

    await readEmailAlertState(PRINCIPAL);

    expect(exists).toHaveBeenCalledExactlyOnceWith({
      email: PRINCIPAL,
      status: "confirmed",
    });
  });

  it("performs no mutation", async () => {
    mockExists(null);
    const updateOne = vi.spyOn(Subscriber, "updateOne");
    const findOneAndUpdate = vi.spyOn(Subscriber, "findOneAndUpdate");
    const deleteOne = vi.spyOn(Subscriber, "deleteOne");

    await readEmailAlertState(PRINCIPAL);

    expect(updateOne).not.toHaveBeenCalled();
    expect(findOneAndUpdate).not.toHaveBeenCalled();
    expect(deleteOne).not.toHaveBeenCalled();
  });

  it("propagates a database failure rather than reporting inactive", async () => {
    vi.spyOn(Subscriber, "exists").mockRejectedValue(new Error("connection reset"));

    await expect(readEmailAlertState(PRINCIPAL)).rejects.toThrow(
      "connection reset"
    );
  });
});
