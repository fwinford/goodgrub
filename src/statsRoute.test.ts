import type { NextFunction, Request, Response } from "express";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Fulfillment } from "../models/db.js";
import { getStats } from "./statsRoute.js";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("GET /api/stats", () => {
  it("preserves the all-time count from durable Fulfillment records", async () => {
    const count = vi.spyOn(Fulfillment, "countDocuments").mockResolvedValue(42);
    const json = vi.fn();
    const next = vi.fn() as unknown as NextFunction;

    await getStats({} as Request, { json } as unknown as Response, next);

    expect(count).toHaveBeenCalledWith();
    expect(json).toHaveBeenCalledWith({ totalShared: 42 });
    expect(next).not.toHaveBeenCalled();
  });
});
