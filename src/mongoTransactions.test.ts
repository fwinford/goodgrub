import { describe, expect, it } from "vitest";
import { isTransactionCapableMongo } from "./mongoTransactions.js";

describe("MongoDB transaction capability", () => {
  it("accepts replica sets and sharded clusters", () => {
    expect(isTransactionCapableMongo({ setName: "commonplate" })).toBe(true);
    expect(isTransactionCapableMongo({ msg: "isdbgrid" })).toBe(true);
  });

  it("rejects a standalone mongod", () => {
    expect(isTransactionCapableMongo({})).toBe(false);
  });
});
